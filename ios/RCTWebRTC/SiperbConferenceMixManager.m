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
    if (delegate == nil || delegate == self) {
        return;  // documented idempotent: adding the fanout to itself would recurse forever
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
// ATOMIC: read on the APM capture thread every 10 ms, written from the module queue on
// attach/detach. A nonatomic object property across threads is a use-after-free window.
@property(atomic, copy) NSString *legId;
/**
 * Only the host reads the real microphone onto the bus. A synthesised leg's capture is
 * discarded once a host is attached (it sends the mix instead) and passed through untouched
 * before that, while it is still an ordinary consultation call.
 */
@property(nonatomic, assign) BOOL feedsMicrophone;
@end

@implementation SiperbLegCaptureMixer {
    int32_t _sampleRate;
    int16_t *_mono;
    int16_t *_mix;
    int16_t *_scratch;
    int32_t *_accumulator;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mono = malloc(kMaxFrames * sizeof(int16_t));
        _mix = malloc(kMaxFrames * sizeof(int16_t));
        // PER-INSTANCE, never shared with the bus: every leg mixes on its own capture thread
        // and shared scratch would let one leg zero another's half-summed frame.
        _scratch = malloc(kMaxFrames * sizeof(int16_t));
        _accumulator = malloc(kMaxFrames * sizeof(int32_t));
    }
    return self;
}

- (void)dealloc {
    free(_mono);
    free(_mix);
    free(_scratch);
    free(_accumulator);
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

    // BEFORE THE HOST JOINS, A SYNTHESISED LEG IS AN ORDINARY CALL. The SDK dials a
    // conference child as a plain consultation call and only builds the mix on Join, exactly
    // as the web does - the third party must hear us while we talk to them first. Nothing is
    // on the bus yet (no host leg is attached, so no microphone is ever pushed and pullForLeg
    // can only answer "nothing"), and overwriting with that sent them SILENCE for the whole
    // consultation. The buffer already holds this factory's own real microphone: leave it.
    //
    // Mute still applies. The SDK's SetMute already routes to the bus's micMuted during the
    // consultation (the host carries ConferenceChildren from the dial, so OnConferenceMute
    // claims it) and never disables the track, so a muted consultation has to be zeroed here.
    // Ahead of the sample-rate guard on purpose: nothing is being mixed, so "conference audio
    // disabled on this route" would be a lie.
    if (!self.feedsMicrophone && ![[SiperbConferenceMixManager sharedManager] hostAttached]) {
        if ([SiperbConferenceAudioBus sharedBus].micMuted) {
            for (size_t c = 0; c < channels; c++) {
                float *samples = [audioBuffer rawBufferForChannel:c];
                if (samples) {
                    memset(samples, 0, frames * sizeof(float));
                }
            }
        }
        return;
    }

    double rate = (double)_sampleRate;
    if (rate <= 0) {
        rate = (double)frames * 100.0;  // the APM works in 10 ms chunks
    }

    // THE BUS IS 48 kHz BY CONTRACT and sources resample on the way IN, but nothing
    // resamples on the way OUT. On a Bluetooth HFP route the session drops to 16 kHz and the
    // APM follows, so writing 48 kHz content into a 16 kHz buffer makes everyone ~3x slow AND
    // starves the rings, because only a third of what is pushed is consumed.
    //
    // Refused rather than resampled for now: emitting slow audio silently is the worst of the
    // three options, and the route is routine rather than exotic on this product.
    if ((NSUInteger)llround(rate) != (NSUInteger)SiperbAudioTargetSampleRate) {
        static dispatch_once_t warnOnce;
        dispatch_once(&warnOnce, ^{
            RCTLogWarn(@"[ConferenceMix] capture is %d Hz, bus is %.0f Hz - conference audio "
                       @"disabled on this route until the mix is resampled out",
                       _sampleRate, SiperbAudioTargetSampleRate);
        });
        return;
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

    if (![bus pullForLeg:legId into:_mix frames:frames accumulator:_accumulator scratch:_scratch]) {
        // Nothing was summed. On the host the buffer already holds the microphone, so leaving
        // it alone is right -- UNLESS WE ARE MUTED, in which case leaving it alone transmits
        // the live mic. "Nothing summed" is exactly the state a muted host reaches once the
        // other legs underrun or hang up, so this is a real leak and not a corner case.
        if (!self.feedsMicrophone || bus.micMuted) {
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

#pragma mark - Render aux mixer

/**
 * Adds the aux sources' local copy INTO the playout frame - the presenter's copy of the file
 * they are presenting, played through WebRTC's own render path rather than by a second
 * player.
 *
 * THROUGH THE PLAYOUT ON PURPOSE: what APM's render stage plays is what the echo canceller
 * uses as its reference, so the file that leaves the loudspeaker is subtracted from the
 * microphone by construction - by AEC3 and by the voice-processing unit alike, on any route.
 * An AVPlayer playing the same file beside WebRTC would be outside that reference and come
 * straight back in through the mic on speakerphone.
 *
 * Additive - the far end's audio in the buffer is untouched - and a pass-through when no aux
 * is attached. Only at the bus rate: the bus drains 48 kHz frames and this hook has no
 * resampler, so on a 16 kHz route it does nothing rather than play the file at the wrong
 * pitch; the presenter does not hear the local copy there, which is the lesser fault (the far
 * end still gets it through the capture path where the rate allows).
 */
@interface SiperbRenderAuxMixer : NSObject <RTCAudioCustomProcessingDelegate>
@end

@implementation SiperbRenderAuxMixer {
    int32_t _sampleRate;
    int16_t *_mix;
    int16_t *_scratch;
    int32_t *_accumulator;
    BOOL _warnedRate;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mix = malloc(kMaxFrames * sizeof(int16_t));
        _scratch = malloc(kMaxFrames * sizeof(int16_t));
        _accumulator = malloc(kMaxFrames * sizeof(int32_t));
    }
    return self;
}

- (void)dealloc {
    free(_mix);
    free(_scratch);
    free(_accumulator);
}

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz channels:(size_t)channels {
    _sampleRate = (int32_t)sampleRateHz;
}

- (void)audioProcessingRelease {
}

- (void)audioProcessingProcess:(RTCAudioBuffer *)audioBuffer {
    SiperbConferenceAudioBus *bus = [SiperbConferenceAudioBus sharedBus];
    if (![bus hasAux]) {
        return;  // idle: nothing is being presented
    }
    const size_t frames = audioBuffer.frames;
    const size_t channels = audioBuffer.channels;
    if (frames == 0 || channels == 0 || frames > kMaxFrames) {
        return;
    }
    double rate = (double)_sampleRate;
    if (rate <= 0) {
        rate = (double)frames * 100.0;
    }
    if ((NSUInteger)llround(rate) != (NSUInteger)SiperbAudioTargetSampleRate) {
        if (!_warnedRate) {
            _warnedRate = YES;
            RCTLogWarn(@"[ConferenceMix] render is %d Hz, bus is %.0f Hz - the presenter's local copy "
                       @"of the file is not played on this route",
                       _sampleRate, SiperbAudioTargetSampleRate);
        }
        return;
    }
    if (![bus pullAuxSumForConsumer:[SiperbConferenceAudioBus renderConsumer]
                               into:_mix
                             frames:frames
                        accumulator:_accumulator
                            scratch:_scratch]) {
        return;
    }
    // FloatS16 in, FloatS16 out; the sum is clamped so a loud file over loud far-end audio
    // clips rather than wraps.
    for (size_t c = 0; c < channels; c++) {
        float *samples = [audioBuffer rawBufferForChannel:c];
        if (samples == NULL) {
            continue;
        }
        for (size_t i = 0; i < frames; i++) {
            const float v = samples[i] + (float)_mix[i];
            samples[i] = v > 32767.f ? 32767.f : (v < -32768.f ? -32768.f : v);
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
    AVAudioFormat *format = pcmBuffer.format;
    const NSUInteger frames = pcmBuffer.frameLength;
    const NSUInteger channels = format.channelCount;
    const double sampleRate = format.sampleRate;
    if (frames == 0 || channels == 0 || sampleRate <= 0) {
        return;
    }

    if (frames > _capacity) {
        int16_t *grown = realloc(_copy, frames * sizeof(int16_t));
        if (grown == NULL) {
            return;  // checked: setting _capacity regardless would NULL-write on the next line
        }
        _copy = grown;
        _capacity = frames;
    }

    // ALL FOUR SHAPES, because webrtc-sdk delivers interleaved buffers and an interleaved
    // AVAudioPCMBuffer exposes a ONE-ELEMENT channel pointer array -- indexing data[c] for
    // c > 0 reads past it. Mono remotes hid this; the first stereo answer would crash the
    // render thread. Deliberately identical to RemoteAudioSink, which already got this right.
    if (format.commonFormat == AVAudioPCMFormatFloat32 && pcmBuffer.floatChannelData != NULL) {
        float *const *data = pcmBuffer.floatChannelData;
        const float scale = 32767.0f / (float)channels;
        if (format.isInterleaved) {
            const float *interleaved = data[0];
            for (NSUInteger i = 0; i < frames; i++) {
                float acc = 0;
                for (NSUInteger c = 0; c < channels; c++) acc += interleaved[i * channels + c];
                float v = acc * scale;
                _copy[i] = (int16_t)(v > 32767.0f ? 32767.0f : (v < -32768.0f ? -32768.0f : v));
            }
        } else {
            for (NSUInteger i = 0; i < frames; i++) {
                float acc = 0;
                for (NSUInteger c = 0; c < channels; c++) acc += data[c][i];
                float v = acc * scale;
                _copy[i] = (int16_t)(v > 32767.0f ? 32767.0f : (v < -32768.0f ? -32768.0f : v));
            }
        }
    } else if (format.commonFormat == AVAudioPCMFormatInt16 && pcmBuffer.int16ChannelData != NULL) {
        int16_t *const *data = pcmBuffer.int16ChannelData;
        if (format.isInterleaved) {
            const int16_t *interleaved = data[0];
            for (NSUInteger i = 0; i < frames; i++) {
                int32_t acc = 0;
                for (NSUInteger c = 0; c < channels; c++) acc += interleaved[i * channels + c];
                _copy[i] = (int16_t)(acc / (int32_t)channels);  // an average of int16 fits int16
            }
        } else {
            for (NSUInteger i = 0; i < frames; i++) {
                int32_t acc = 0;
                for (NSUInteger c = 0; c < channels; c++) acc += data[c][i];
                _copy[i] = (int16_t)(acc / (int32_t)channels);
            }
        }
    } else {
        return;  // webrtc-sdk only delivers float32/int16 PCM
    }

    [[SiperbConferenceAudioBus sharedBus] pushLeg:self.legId samples:_copy count:frames sampleRate:sampleRate];
}

@end

#pragma mark - Manager

@implementation SiperbConferenceMixManager {
    SiperbCaptureFanout *_fanout;
    SiperbLegCaptureMixer *_hostMixer;
    /** Retained here because the module's render slot is weak, like the capture one. */
    SiperbRenderAuxMixer *_renderMixer;

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
        _renderMixer = [SiperbRenderAuxMixer new];
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

    // The render slot: the local playout of a presented file (see SiperbRenderAuxMixer).
    // Nothing else holds it today; if something ever does, it is chained rather than
    // replaced, or one feature silently unwires the other.
    if (module.renderPreProcessingDelegate != nil && module.renderPreProcessingDelegate != _renderMixer) {
        RCTLogWarn(@"[ConferenceMix] render-pre slot already held by %@ - the presenter's local "
                   @"copy of a presented file will not be played",
                   NSStringFromClass([module.renderPreProcessingDelegate class]));
        return;
    }
    module.renderPreProcessingDelegate = _renderMixer;
}

- (void)attachAux:(NSString *)auxId {
    [[SiperbConferenceAudioBus sharedBus] addAux:auxId];
    RCTLogInfo(@"[ConferenceMix] attachAux %@", auxId);
}

- (void)detachAux:(NSString *)auxId {
    [[SiperbConferenceAudioBus sharedBus] removeAux:auxId];
    RCTLogInfo(@"[ConferenceMix] detachAux %@", auxId);
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

    // RE-ATTACH IS A REFRESH, NOT AN ADDITION. The SDK republishes a leg's mix on every join,
    // so this runs once per participant for the same leg; appending a second tap per remote
    // track summed that party twice into every mix (double level). Drop the previous taps and
    // re-tap from the tracks handed in now.
    NSMutableArray<SiperbRemoteTap *> *legTaps;
    NSArray<SiperbRemoteTap *> *stale = nil;
    os_unfair_lock_lock(&_lock);
    legTaps = _taps[legId];
    if (legTaps == nil) {
        legTaps = [NSMutableArray new];
        _taps[legId] = legTaps;
    } else {
        stale = [legTaps copy];
        [legTaps removeAllObjects];
    }
    os_unfair_lock_unlock(&_lock);

    for (SiperbRemoteTap *tap in stale) {
        [tap.track removeRenderer:tap];
    }

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

- (BOOL)hostAttached {
    // The host mixer's legId is what un-idles the app factory's capture hook, so it is
    // already the authority on "a host is on the bus"; atomic, so a capture thread may read it.
    return _hostMixer.legId != nil;
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
