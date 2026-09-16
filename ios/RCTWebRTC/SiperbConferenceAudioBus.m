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
/**
 * Applied to the RENDER consumer only - the presenter's local volume for an aux source.
 * Legs and the recording always get it at unity; turning the local copy down must not
 * turn the far end down.
 */
@property(atomic, assign) float renderGain;
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
        _renderGain = 1.0f;
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

/** Drain one consumer's ring and keep it. No-op for an unknown consumer. */
- (void)drainConsumer:(NSString *)consumerId {
    os_unfair_lock_lock(&_ringLock);
    SiperbAudioSource *ring = _rings[consumerId];
    os_unfair_lock_unlock(&_ringLock);
    if (ring == nil) {
        return;
    }
    int16_t scratch[512];
    while ([ring pullSamples:scratch count:512] > 0) {
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
    /** auxId -> source. Same lock; membership outlives a conference. */
    NSMutableDictionary<NSString *, SiperbBusSource *> *_aux;
    NSMutableArray<NSString *> *_consumers;
    os_unfair_lock _legLock;

}

+ (NSString *)renderConsumer {
    return @"__render__";
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
        _aux = [NSMutableDictionary new];
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

- (void)pushAux:(NSString *)auxId
        samples:(const int16_t *)samples
          count:(NSUInteger)count
     sampleRate:(double)sampleRate {
    if (auxId == nil) {
        return;
    }
    os_unfair_lock_lock(&_legLock);
    SiperbBusSource *source = _aux[auxId];
    os_unfair_lock_unlock(&_legLock);
    [source push:samples count:count sampleRate:sampleRate];  // nil source: a message to nil, i.e. no-op
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
    NSArray<SiperbBusSource *> *auxSources = _aux.allValues;
    os_unfair_lock_unlock(&_legLock);

    for (NSString *consumerId in consumers) {
        [_mic ensureConsumer:consumerId];
        for (SiperbBusSource *existing in sources) {
            [existing ensureConsumer:consumerId];
        }
        // A fresh, empty ring per aux for the new leg - so a leg attached AFTER the aux
        // (the SDK's order: the presentation source connects before the host leg attaches)
        // hears nothing stale.
        for (SiperbBusSource *a in auxSources) {
            [a ensureConsumer:consumerId];
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
    NSArray<SiperbBusSource *> *auxSources = _aux.allValues;
    const BOOL lastLegGone = _legs.count == 0;
    os_unfair_lock_unlock(&_legLock);

    [_mic removeConsumer:legId];
    for (SiperbBusSource *source in remaining) {
        [source removeConsumer:legId];
    }
    for (SiperbBusSource *a in auxSources) {
        [a removeConsumer:legId];
    }

    // Mute is a property of the conference, and the last leg leaving IS the end of the
    // conference. The host detaches leg by leg and never calls clear, so without this a
    // hang-up while muted left micMuted YES on the process-wide bus and the NEXT conference
    // opened with the host silently absent from every mix.
    if (lastLegGone) {
        self.micMuted = NO;
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
    NSArray<NSString *> *goneConsumers = [_consumers copy];
    NSArray<SiperbBusSource *> *auxSources = _aux.allValues;
    [_legs removeAllObjects];
    [_consumers removeAllObjects];
    [_consumers addObject:[[self class] recordingConsumer]];
    os_unfair_lock_unlock(&_legLock);

    // Aux MEMBERSHIP survives the conference - the presentation is still running - but the
    // rings for the legs that just left are pruned, or an aux would fan into dead rings for
    // the life of the process.
    for (NSString *consumerId in goneConsumers) {
        if ([consumerId isEqualToString:[[self class] recordingConsumer]]) {
            continue;
        }
        for (SiperbBusSource *a in auxSources) {
            [a removeConsumer:consumerId];
        }
    }

    self.micMuted = NO;

    // THE DRAIN IS NOT TIDINESS. Leg sources die with their legs, but the microphone is
    // process-wide and survives - whatever it still held would be the first thing mixed into
    // the NEXT conference, sending up to half a second of one call's audio to someone who
    // was never on it.
    [_mic drainAll];
    [_mic ensureConsumer:[[self class] recordingConsumer]];
}

- (void)addAux:(NSString *)auxId {
    if (auxId.length == 0 || [auxId isEqualToString:[[self class] recordingConsumer]] ||
        [auxId isEqualToString:[[self class] renderConsumer]]) {
        return;
    }
    os_unfair_lock_lock(&_legLock);
    if (_aux[auxId] != nil) {
        os_unfair_lock_unlock(&_legLock);
        return;  // idempotent: a re-attach patches, never replaces
    }
    SiperbBusSource *source = [SiperbBusSource new];
    _aux[auxId] = source;
    NSArray<NSString *> *consumers = [_consumers copy];
    os_unfair_lock_unlock(&_legLock);

    // Every consumer there is - each leg's mix, the recording - plus the render consumer,
    // which only aux sources feed.
    for (NSString *consumerId in consumers) {
        [source ensureConsumer:consumerId];
    }
    [source ensureConsumer:[[self class] renderConsumer]];
}

- (void)removeAux:(NSString *)auxId {
    if (auxId == nil) {
        return;
    }
    os_unfair_lock_lock(&_legLock);
    [_aux removeObjectForKey:auxId];
    os_unfair_lock_unlock(&_legLock);
}

- (BOOL)hasAux {
    os_unfair_lock_lock(&_legLock);
    const BOOL any = _aux.count > 0;
    os_unfair_lock_unlock(&_legLock);
    return any;
}

- (void)setAuxRenderGain:(NSString *)auxId gain:(float)gain {
    if (auxId == nil) {
        return;
    }
    os_unfair_lock_lock(&_legLock);
    SiperbBusSource *source = _aux[auxId];
    os_unfair_lock_unlock(&_legLock);
    source.renderGain = gain < 0.f ? 0.f : (gain > 1.f ? 1.f : gain);
}

- (void)clearRecordingRings {
    NSString *consumer = [[self class] recordingConsumer];
    os_unfair_lock_lock(&_legLock);
    NSArray<SiperbBusSource *> *legs = _legs.allValues;
    NSArray<SiperbBusSource *> *auxSources = _aux.allValues;
    os_unfair_lock_unlock(&_legLock);

    [_mic drainConsumer:consumer];
    for (SiperbBusSource *leg in legs) {
        [leg drainConsumer:consumer];
    }
    for (SiperbBusSource *a in auxSources) {
        [a drainConsumer:consumer];
    }
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

    // DRAINED UNCONDITIONALLY, ADDED CONDITIONALLY - the Android bus's fix, ported. Muting
    // used to skip the drain as well, so nothing consumed the mic's ring while capture kept
    // filling it: it saturated at its 500 ms capacity and HELD the last half second said
    // while muted, which unmute then shipped to the far end, with every later word ~490 ms
    // late for the rest of the call.
    const NSUInteger micSamples = [_mic drain:legId into:_scratch frames:frames];
    if (!self.micMuted && micSamples > 0) {
        for (NSUInteger i = 0; i < micSamples; i++) {
            _accumulator[i] += _scratch[i];
        }
        any = YES;
    }

    os_unfair_lock_lock(&_legLock);
    NSDictionary<NSString *, SiperbBusSource *> *snapshot = [_legs copy];
    NSArray<SiperbBusSource *> *auxSnapshot = _aux.allValues;
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

    // Aux sources go to EVERY leg, and they are deliberately outside the micMuted test:
    // mute silences the presenter, never the file they are presenting.
    for (SiperbBusSource *a in auxSnapshot) {
        any |= [self accumulate:a consumer:legId frames:frames accumulator:_accumulator scratch:_scratch];
    }

    for (NSUInteger i = 0; i < frames; i++) {
        out[i] = ClampToInt16(_accumulator[i]);
    }
    return any;
}

- (BOOL)pullAuxSumForConsumer:(NSString *)consumerId
                         into:(int16_t *)out
                       frames:(NSUInteger)frames
                  accumulator:(int32_t *)_accumulator
                      scratch:(int16_t *)_scratch {
    if (consumerId == nil || out == NULL || _accumulator == NULL || _scratch == NULL || frames == 0 ||
        frames > kMaxFrames) {
        return NO;
    }
    memset(_accumulator, 0, frames * sizeof(int32_t));
    BOOL any = NO;
    const BOOL render = [consumerId isEqualToString:[[self class] renderConsumer]];

    os_unfair_lock_lock(&_legLock);
    NSArray<SiperbBusSource *> *snapshot = _aux.allValues;
    os_unfair_lock_unlock(&_legLock);

    for (SiperbBusSource *a in snapshot) {
        if (!render) {
            any |= [self accumulate:a consumer:consumerId frames:frames accumulator:_accumulator scratch:_scratch];
            continue;
        }
        // The ring is DRAINED even at gain 0, so muting the local copy cannot let it saturate
        // and replay half a second of old audio when it is turned back up.
        const NSUInteger n = [a drain:consumerId into:_scratch frames:frames];
        const float gain = a.renderGain;
        if (n == 0 || gain <= 0.f) {
            continue;
        }
        for (NSUInteger i = 0; i < n; i++) {
            _accumulator[i] += (int32_t)(_scratch[i] * gain);
        }
        any = YES;
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
