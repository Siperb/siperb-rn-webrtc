#import "SiperbConferenceAudioBus.h"

#import <os/lock.h>

#import "SiperbAudioSource.h"

/** 10 ms at 48 kHz - the cadence every capture callback arrives on. */
static const NSUInteger kMaxFrames = 4096;

#pragma mark - Fan-out source

/**
 * One input, fanned out to every consumer.
 *
 * Wraps one SiperbAudioSource for the downmix/resample it already does, then copies each
 * resampled frame into a per-consumer ring - see the class note in the header on why one
 * ring cannot serve two readers.
 */
@interface SiperbBusSource : NSObject
@property(nonatomic, strong) SiperbAudioSource *input;
/** consumerId -> SiperbAudioSource used purely as a ring. */
@property(nonatomic, strong) NSMutableDictionary<NSString *, SiperbAudioSource *> *rings;
@end

@implementation SiperbBusSource {
    os_unfair_lock _ringLock;
    int16_t *_staging;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ringLock = OS_UNFAIR_LOCK_INIT;
        _input = [SiperbAudioSource new];
        _rings = [NSMutableDictionary new];
        _staging = malloc(kMaxFrames * sizeof(int16_t));
    }
    return self;
}

- (void)dealloc {
    free(_staging);
}

- (void)ensureConsumer:(NSString *)consumerId {
    os_unfair_lock_lock(&_ringLock);
    if (_rings[consumerId] == nil) {
        _rings[consumerId] = [SiperbAudioSource new];
    }
    os_unfair_lock_unlock(&_ringLock);
}

- (void)removeConsumer:(NSString *)consumerId {
    os_unfair_lock_lock(&_ringLock);
    [_rings removeObjectForKey:consumerId];
    os_unfair_lock_unlock(&_ringLock);
}

/** Drain everything buffered for every consumer. */
- (void)drainAll {
    os_unfair_lock_lock(&_ringLock);
    NSArray<SiperbAudioSource *> *rings = _rings.allValues;
    os_unfair_lock_unlock(&_ringLock);

    int16_t scratch[512];
    for (SiperbAudioSource *ring in rings) {
        while ([ring pullSamples:scratch count:512] > 0) {
        }
    }
}

/** Push, then fan the resampled frame out to every consumer's ring. */
- (void)push:(const int16_t *)samples count:(NSUInteger)count sampleRate:(double)sampleRate {
    [_input pushSamples:samples count:count sampleRate:sampleRate];

    os_unfair_lock_lock(&_ringLock);
    NSArray<SiperbAudioSource *> *rings = _rings.allValues;
    os_unfair_lock_unlock(&_ringLock);
    if (rings.count == 0) {
        return;
    }

    NSUInteger pulled;
    while ((pulled = [_input pullSamples:_staging count:kMaxFrames]) > 0) {
        for (SiperbAudioSource *ring in rings) {
            [ring appendSamples:_staging count:pulled];
        }
        if (pulled < kMaxFrames) {
            break;
        }
    }
}

- (NSUInteger)drain:(NSString *)consumerId into:(int16_t *)out frames:(NSUInteger)frames {
    os_unfair_lock_lock(&_ringLock);
    SiperbAudioSource *ring = _rings[consumerId];
    os_unfair_lock_unlock(&_ringLock);
    return ring ? [ring pullSamples:out count:frames] : 0;
}

@end

#pragma mark - Bus

@implementation SiperbConferenceAudioBus {
    SiperbBusSource *_mic;
    /** legId -> source. Guarded by _legLock; snapshotted before any mix. */
    NSMutableDictionary<NSString *, SiperbBusSource *> *_legs;
    NSMutableArray<NSString *> *_consumers;
    os_unfair_lock _legLock;

}

+ (NSString *)recordingConsumer {
    // Double-underscored because it shares a namespace with session ids, and a leg called
    // "recording" would otherwise silently drain the recorder's rings.
    return @"__recording__";
}

+ (instancetype)sharedBus {
    static SiperbConferenceAudioBus *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[SiperbConferenceAudioBus alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _legLock = OS_UNFAIR_LOCK_INIT;
        _mic = [SiperbBusSource new];
        _legs = [NSMutableDictionary new];
        _consumers = [NSMutableArray arrayWithObject:[[self class] recordingConsumer]];
        [_mic ensureConsumer:[[self class] recordingConsumer]];
    }
    return self;
}

- (BOOL)active {
    os_unfair_lock_lock(&_legLock);
    BOOL any = _legs.count > 0;
    os_unfair_lock_unlock(&_legLock);
    return any;
}

- (NSArray<NSString *> *)legIds {
    os_unfair_lock_lock(&_legLock);
    NSArray<NSString *> *ids = _legs.allKeys;
    os_unfair_lock_unlock(&_legLock);
    return ids;
}

#pragma mark Producers

- (void)pushMicrophone:(const int16_t *)samples count:(NSUInteger)count sampleRate:(double)sampleRate {
    [_mic push:samples count:count sampleRate:sampleRate];
}

- (void)pushLeg:(NSString *)legId
        samples:(const int16_t *)samples
          count:(NSUInteger)count
     sampleRate:(double)sampleRate {
    if (legId == nil) {
        return;
    }
    os_unfair_lock_lock(&_legLock);
    SiperbBusSource *source = _legs[legId];
    os_unfair_lock_unlock(&_legLock);
    [source push:samples count:count sampleRate:sampleRate];
}

#pragma mark Membership

- (void)addLeg:(NSString *)legId {
    if (legId.length == 0 || [legId isEqualToString:[[self class] recordingConsumer]]) {
        return;
    }
    os_unfair_lock_lock(&_legLock);
    if (_legs[legId] != nil) {
        os_unfair_lock_unlock(&_legLock);
        return;  // idempotent: a re-join patches, never replaces
    }

    SiperbBusSource *source = [SiperbBusSource new];
    _legs[legId] = source;
    if (![_consumers containsObject:legId]) {
        [_consumers addObject:legId];
    }

    // Adding a leg adds a CONSUMER (its own mix), so every existing source gains a ring for
    // it and the new source gains rings for every existing consumer.
    NSArray<NSString *> *consumers = [_consumers copy];
    NSArray<SiperbBusSource *> *sources = _legs.allValues;
    os_unfair_lock_unlock(&_legLock);

    for (NSString *consumerId in consumers) {
        [_mic ensureConsumer:consumerId];
        for (SiperbBusSource *existing in sources) {
            [existing ensureConsumer:consumerId];
        }
    }
}

- (void)removeLeg:(NSString *)legId {
    if (legId == nil) {
        return;
    }
    os_unfair_lock_lock(&_legLock);
    if (_legs[legId] == nil) {
        os_unfair_lock_unlock(&_legLock);
        return;
    }
    [_legs removeObjectForKey:legId];
    [_consumers removeObject:legId];
    NSArray<SiperbBusSource *> *remaining = _legs.allValues;
    os_unfair_lock_unlock(&_legLock);

    [_mic removeConsumer:legId];
    for (SiperbBusSource *source in remaining) {
        [source removeConsumer:legId];
    }
}

- (BOOL)isActive {
    os_unfair_lock_lock(&_legLock);
    const BOOL any = _legs.count > 0;
    os_unfair_lock_unlock(&_legLock);
    return any;
}

- (void)clear {
    os_unfair_lock_lock(&_legLock);
    [_legs removeAllObjects];
    [_consumers removeAllObjects];
    [_consumers addObject:[[self class] recordingConsumer]];
    os_unfair_lock_unlock(&_legLock);

    self.micMuted = NO;

    // THE DRAIN IS NOT TIDINESS. Leg sources die with their legs, but the microphone is
    // process-wide and survives - whatever it still held would be the first thing mixed into
    // the NEXT conference, sending up to half a second of one call's audio to someone who
    // was never on it.
    [_mic drainAll];
    [_mic ensureConsumer:[[self class] recordingConsumer]];
}

#pragma mark Consumers

/** Saturating, NOT wrapping: wrapping turns a loud moment into full-scale noise of the
 * opposite sign, which is far worse than the distortion clipping causes. */
static inline int16_t ClampToInt16(int32_t v) {
    return v > INT16_MAX ? INT16_MAX : (v < INT16_MIN ? INT16_MIN : (int16_t)v);
}

- (BOOL)pullForLeg:(NSString *)legId
              into:(int16_t *)out
            frames:(NSUInteger)frames
       accumulator:(int32_t *)_accumulator
           scratch:(int16_t *)_scratch {
    if (legId == nil || out == NULL || _accumulator == NULL || _scratch == NULL || frames == 0 ||
        frames > kMaxFrames) {
        return NO;
    }
    memset(_accumulator, 0, frames * sizeof(int32_t));
    BOOL any = NO;

    if (!self.micMuted) {
        any |= [self accumulate:_mic consumer:legId frames:frames accumulator:_accumulator scratch:_scratch];
    }

    os_unfair_lock_lock(&_legLock);
    NSDictionary<NSString *, SiperbBusSource *> *snapshot = [_legs copy];
    os_unfair_lock_unlock(&_legLock);

    for (NSString *otherId in snapshot) {
        if ([otherId isEqualToString:legId]) {
            continue;  // never its own audio
        }
        any |= [self accumulate:snapshot[otherId]
                       consumer:legId
                         frames:frames
                    accumulator:_accumulator
                        scratch:_scratch];
    }

    for (NSUInteger i = 0; i < frames; i++) {
        out[i] = ClampToInt16(_accumulator[i]);
    }
    return any;
}

- (BOOL)pullRemoteSumInto:(int16_t *)out
                   frames:(NSUInteger)frames
              accumulator:(int32_t *)_accumulator
                  scratch:(int16_t *)_scratch {
    if (out == NULL || _accumulator == NULL || _scratch == NULL || frames == 0 || frames > kMaxFrames) {
        return NO;
    }
    memset(_accumulator, 0, frames * sizeof(int32_t));
    BOOL any = NO;

    os_unfair_lock_lock(&_legLock);
    NSArray<SiperbBusSource *> *snapshot = _legs.allValues;
    os_unfair_lock_unlock(&_legLock);

    for (SiperbBusSource *leg in snapshot) {
        any |= [self accumulate:leg
                       consumer:[[self class] recordingConsumer]
                         frames:frames
                    accumulator:_accumulator
                        scratch:_scratch];
    }

    for (NSUInteger i = 0; i < frames; i++) {
        out[i] = ClampToInt16(_accumulator[i]);
    }
    return any;
}

/** Adds one source's next frame into the accumulator, zero-padding an underrun. */
- (BOOL)accumulate:(SiperbBusSource *)source
          consumer:(NSString *)consumerId
            frames:(NSUInteger)frames
       accumulator:(int32_t *)_accumulator
           scratch:(int16_t *)_scratch {
    NSUInteger n = [source drain:consumerId into:_scratch frames:frames];
    if (n == 0) {
        return NO;
    }
    for (NSUInteger i = 0; i < n; i++) {
        _accumulator[i] += _scratch[i];
    }
    return YES;
}

@end
