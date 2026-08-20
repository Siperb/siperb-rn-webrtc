#import "SiperbConferenceMixManager.h"

#import <React/RCTLog.h>
#import <os/lock.h>

#import "SiperbAudioSource.h"
#import "SiperbConferenceAudioBus.h"

static const NSUInteger kMaxFrames = 4096;

#pragma mark - Capture fan-out

/**
 * Lets the call recorder and the conference mixer share iOS's single capture-post slot.
 *
 * ORDER IS THE WHOLE POINT: delegates run in the order added, the recorder's read-only tap
 * is added first, and the conference overwrite second. Reversed, a recording's "left is us"
 * channel would carry the entire conference instead of the microphone - a corruption that
 * would only ever be noticed by listening to a finished file.
 */
@interface SiperbCaptureFanout : NSObject <RTCAudioCustomProcessingDelegate>
- (void)addDelegate:(id<RTCAudioCustomProcessingDelegate>)delegate;
@end

@implementation SiperbCaptureFanout {
    NSMutableArray *_delegates;  // strong: the module's own slot is weak
    os_unfair_lock _lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _delegates = [NSMutableArray new];
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)addDelegate:(id<RTCAudioCustomProcessingDelegate>)delegate {
    if (delegate == nil) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    if (![_delegates containsObject:delegate]) {
        [_delegates addObject:delegate];
    }
    os_unfair_lock_unlock(&_lock);
}

- (NSArray *)snapshot {
    os_unfair_lock_lock(&_lock);
    NSArray *copy = [_delegates copy];
    os_unfair_lock_unlock(&_lock);
    return copy;
}

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz channels:(size_t)channels {
    for (id<RTCAudioCustomProcessingDelegate> d in [self snapshot]) {
        [d audioProcessingInitializeWithSampleRate:sampleRateHz channels:channels];
    }
}

- (void)audioProcessingProcess:(RTCAudioBuffer *)audioBuffer {
    for (id<RTCAudioCustomProcessingDelegate> d in [self snapshot]) {
        [d audioProcessingProcess:audioBuffer];
    }
}

- (void)audioProcessingRelease {
    for (id<RTCAudioCustomProcessingDelegate> d in [self snapshot]) {
        [d audioProcessingRelease];
    }
}

@end

#pragma mark - Per-leg capture mixer

/**
 * Reads the microphone onto the bus (host leg only) and overwrites the buffer with what
 * this leg should be sent.
 *
 * ONE DELEGATE, BOTH DIRECTIONS on the host, and the order matters: the mic reaches the bus
 * before the mix is drawn, or the host's outbound runs a frame behind and the first frame of
 * every conference is missing us entirely.
 */
@interface SiperbLegCaptureMixer : NSObject <RTCAudioCustomProcessingDelegate>
@property(nonatomic, copy) NSString *legId;
/** Only the host reads the real microphone; a synthesised leg's capture is discarded. */
@property(nonatomic, assign) BOOL feedsMicrophone;
@end

@implementation SiperbLegCaptureMixer {
    int32_t _sampleRate;
    int16_t *_mono;
    int16_t *_mix;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mono = malloc(kMaxFrames * sizeof(int16_t));
        _mix = malloc(kMaxFrames * sizeof(int16_t));
    }
    return self;
}

- (void)dealloc {
    free(_mono);
    free(_mix);
}

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz channels:(size_t)channels {
    _sampleRate = (int32_t)sampleRateHz;
}

- (void)audioProcessingRelease {
}

- (void)audioProcessingProcess:(RTCAudioBuffer *)audioBuffer {
    NSString *legId = self.legId;
    if (legId == nil) {
        return;  // idle: no conference on this factory
    }

    const size_t frames = audioBuffer.frames;
    const size_t channels = audioBuffer.channels;
    if (frames == 0 || channels == 0 || frames > kMaxFrames) {
        return;
    }

    double rate = (double)_sampleRate;
    if (rate <= 0) {
        rate = (double)frames * 100.0;  // the APM works in 10 ms chunks
    }

    SiperbConferenceAudioBus *bus = [SiperbConferenceAudioBus sharedBus];

    // FloatS16, NOT normalised: these floats are already in int16 range. Scaling by 32767 on
    // top is what turned the recorder's mic into square-wave static once.
    float *channel0 = [audioBuffer rawBufferForChannel:0];
    if (channel0 == NULL) {
        return;
    }

    if (self.feedsMicrophone) {
        for (size_t i = 0; i < frames; i++) {
            const float v = channel0[i];
            _mono[i] = (int16_t)(v > 32767.f ? 32767.f : (v < -32768.f ? -32768.f : v));
        }
        [bus pushMicrophone:_mono count:frames sampleRate:rate];
    }

    if (![bus pullForLeg:legId into:_mix frames:frames]) {
        // Nothing to send but us. On the host the buffer already holds exactly that, so
        // leaving it untouched is both correct and cheaper; a synthesised leg has no
        // microphone worth sending, so it is silenced instead.
        if (!self.feedsMicrophone) {
            for (size_t c = 0; c < channels; c++) {
                float *samples = [audioBuffer rawBufferForChannel:c];
                if (samples) {
                    memset(samples, 0, frames * sizeof(float));
                }
            }
        }
        return;
    }

    for (size_t c = 0; c < channels; c++) {
        float *samples = [audioBuffer rawBufferForChannel:c];
        if (samples == NULL) {
            continue;
        }
        for (size_t i = 0; i < frames; i++) {
            samples[i] = (float)_mix[i];
        }
    }
}

@end

#pragma mark - Remote tap

/** One remote track feeding one leg's rings. Mirrors the recorder's RemoteAudioSink. */
@interface SiperbRemoteTap : NSObject <RTCAudioRenderer>
@property(nonatomic, strong) RTCAudioTrack *track;
@property(nonatomic, copy) NSString *legId;
@end

@implementation SiperbRemoteTap {
    int16_t *_copy;
    NSUInteger _capacity;
}

- (void)dealloc {
    free(_copy);
}

- (void)renderPCMBuffer:(AVAudioPCMBuffer *)pcmBuffer {
    const AVAudioFrameCount frames = pcmBuffer.frameLength;
    if (frames == 0) {
        return;
    }
    const AVAudioChannelCount channels = pcmBuffer.format.channelCount;
    const double rate = pcmBuffer.format.sampleRate;
    if (channels == 0 || rate <= 0) {
        return;
    }

    if (_capacity < frames) {
        free(_copy);
        _copy = malloc(frames * sizeof(int16_t));
        _capacity = frames;
    }

    // Downmix to mono by averaging, whatever the source layout - the same rule
    // RemoteAudioSink follows, so both taps mean the same thing.
    if (pcmBuffer.int16ChannelData != NULL) {
        int16_t *const *data = pcmBuffer.int16ChannelData;
        for (AVAudioFrameCount i = 0; i < frames; i++) {
            int32_t sum = 0;
            for (AVAudioChannelCount c = 0; c < channels; c++) {
                sum += data[c][i];
            }
            _copy[i] = (int16_t)(sum / (int32_t)channels);
        }
    } else if (pcmBuffer.floatChannelData != NULL) {
        float *const *data = pcmBuffer.floatChannelData;
        for (AVAudioFrameCount i = 0; i < frames; i++) {
            float sum = 0.f;
            for (AVAudioChannelCount c = 0; c < channels; c++) {
                sum += data[c][i];
            }
            const float v = (sum / (float)channels) * 32767.f;
            _copy[i] = (int16_t)(v > 32767.f ? 32767.f : (v < -32768.f ? -32768.f : v));
        }
    } else {
        return;
    }

    [[SiperbConferenceAudioBus sharedBus] pushLeg:self.legId samples:_copy count:frames sampleRate:rate];
}

@end

#pragma mark - Manager

@implementation SiperbConferenceMixManager {
    SiperbCaptureFanout *_fanout;
    SiperbLegCaptureMixer *_hostMixer;

    /** legId -> factory, for synthesised legs. */
    NSMutableDictionary<NSString *, RTCPeerConnectionFactory *> *_legFactories;
    /** legId -> the mixer feeding that factory's capture. Retained: the module slot is weak. */
    NSMutableDictionary<NSString *, SiperbLegCaptureMixer *> *_legMixers;
    NSMutableDictionary<NSString *, RTCDefaultAudioProcessingModule *> *_legModules;
    NSMutableDictionary<NSString *, NSMutableArray<SiperbRemoteTap *> *> *_taps;
    os_unfair_lock _lock;
}

+ (instancetype)sharedManager {
    static SiperbConferenceMixManager *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[SiperbConferenceMixManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _fanout = [SiperbCaptureFanout new];
        _hostMixer = [SiperbLegCaptureMixer new];
        _hostMixer.feedsMicrophone = YES;
        _legFactories = [NSMutableDictionary new];
        _legMixers = [NSMutableDictionary new];
        _legModules = [NSMutableDictionary new];
        _taps = [NSMutableDictionary new];
    }
    return self;
}

- (void)installOnAudioProcessingModule:(RTCDefaultAudioProcessingModule *)module {
    if (module == nil) {
        RCTLogWarn(@"[ConferenceMix] no audio processing module - conference mixing unavailable");
        return;
    }
    // Chain whoever already holds the slot (the call recorder's mic tap) FIRST, so a
    // recording still captures the real microphone rather than the conference mix.
    [_fanout addDelegate:module.capturePostProcessingDelegate];
    [_fanout addDelegate:_hostMixer];
    module.capturePostProcessingDelegate = _fanout;
}

- (RTCPeerConnectionFactory *)factoryForLeg:(NSString *)legId
                             encoderFactory:(id<RTCVideoEncoderFactory>)encoderFactory
                             decoderFactory:(id<RTCVideoDecoderFactory>)decoderFactory {
    if (legId.length == 0) {
        return nil;
    }
    os_unfair_lock_lock(&_lock);
    RTCPeerConnectionFactory *existing = _legFactories[legId];
    os_unfair_lock_unlock(&_lock);
    if (existing != nil) {
        return existing;
    }

    [[SiperbConferenceAudioBus sharedBus] addLeg:legId];

    SiperbLegCaptureMixer *mixer = [SiperbLegCaptureMixer new];
    mixer.legId = legId;
    mixer.feedsMicrophone = NO;  // only the host reads the real mic

    RTCDefaultAudioProcessingModule *module =
        [[RTCDefaultAudioProcessingModule alloc] initWithConfig:nil
                                 capturePostProcessingDelegate:mixer
                                   renderPreProcessingDelegate:nil];

    RTCPeerConnectionFactory *factory =
        [[RTCPeerConnectionFactory alloc] initWithBypassVoiceProcessing:NO
                                                        encoderFactory:encoderFactory
                                                        decoderFactory:decoderFactory
                                                 audioProcessingModule:module];
    if (factory == nil) {
        RCTLogWarn(@"[ConferenceMix] could not build a factory for leg %@", legId);
        return nil;
    }

    os_unfair_lock_lock(&_lock);
    _legFactories[legId] = factory;
    _legMixers[legId] = mixer;
    _legModules[legId] = module;
    os_unfair_lock_unlock(&_lock);

    RCTLogInfo(@"[ConferenceMix] leg %@ has its own factory", legId);
    return factory;
}

- (void)attachLeg:(NSString *)legId remoteTracks:(NSArray<RTCAudioTrack *> *)remoteTracks host:(BOOL)host {
    if (legId.length == 0) {
        return;
    }
    [[SiperbConferenceAudioBus sharedBus] addLeg:legId];

    if (host) {
        // Pointing the host mixer at a leg is what un-idles the app factory's capture hook;
        // until this the delegate returns on its first line for every ordinary 1:1 call.
        _hostMixer.legId = legId;
    }

    NSMutableArray<SiperbRemoteTap *> *legTaps;
    os_unfair_lock_lock(&_lock);
    legTaps = _taps[legId];
    if (legTaps == nil) {
        legTaps = [NSMutableArray new];
        _taps[legId] = legTaps;
    }
    os_unfair_lock_unlock(&_lock);

    for (RTCAudioTrack *track in remoteTracks) {
        if (track == nil) {
            continue;
        }
        SiperbRemoteTap *tap = [SiperbRemoteTap new];
        tap.track = track;
        tap.legId = legId;
        [track addRenderer:tap];
        [legTaps addObject:tap];
    }
    RCTLogInfo(@"[ConferenceMix] attachLeg %@%@ taps=%lu", legId, host ? @" (host)" : @"",
               (unsigned long)legTaps.count);
}

- (void)detachLeg:(NSString *)legId {
    if (legId.length == 0) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    NSMutableArray<SiperbRemoteTap *> *legTaps = _taps[legId];
    [_taps removeObjectForKey:legId];
    [_legFactories removeObjectForKey:legId];
    [_legMixers removeObjectForKey:legId];
    [_legModules removeObjectForKey:legId];
    os_unfair_lock_unlock(&_lock);

    for (SiperbRemoteTap *tap in legTaps) {
        [tap.track removeRenderer:tap];
    }
    if ([_hostMixer.legId isEqualToString:legId]) {
        _hostMixer.legId = nil;  // back to idle on the app factory
    }
    [[SiperbConferenceAudioBus sharedBus] removeLeg:legId];
    RCTLogInfo(@"[ConferenceMix] detachLeg %@", legId);
}

- (void)teardown {
    os_unfair_lock_lock(&_lock);
    NSArray<NSMutableArray<SiperbRemoteTap *> *> *allTaps = _taps.allValues;
    [_taps removeAllObjects];
    [_legFactories removeAllObjects];
    [_legMixers removeAllObjects];
    [_legModules removeAllObjects];
    os_unfair_lock_unlock(&_lock);

    for (NSMutableArray<SiperbRemoteTap *> *legTaps in allTaps) {
        for (SiperbRemoteTap *tap in legTaps) {
            [tap.track removeRenderer:tap];
        }
    }
    _hostMixer.legId = nil;
    [[SiperbConferenceAudioBus sharedBus] clear];
    RCTLogInfo(@"[ConferenceMix] teardown: conference audio released");
}

- (NSArray<NSString *> *)legIds {
    return [SiperbConferenceAudioBus sharedBus].legIds;
}

- (void)setMicMuted:(BOOL)muted {
    [SiperbConferenceAudioBus sharedBus].micMuted = muted;
}

@end
