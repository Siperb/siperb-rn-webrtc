#import "ConferenceSpike.h"

#import <React/RCTLog.h>

static const double kToneHz = 440.0;
/** Well under full scale: a diagnostic tone someone has to listen to. */
static const double kToneAmplitude = 0.25;

#pragma mark - Tone injector

/**
 * Overwrites a capture buffer with a continuous sine.
 *
 * PHASE IS CARRIED ACROSS CALLBACKS. A tone restarted at phase 0 every 10 ms is a buzz with
 * a 100 Hz component - it would sound broken and discredit a passing test.
 */
@interface SiperbSpikeToneInjector : NSObject <RTCAudioCustomProcessingDelegate>
@property(nonatomic, assign) double phase;
@property(nonatomic, assign) int32_t sampleRate;
@property(nonatomic, weak) SiperbConferenceSpike *owner;
@end

@implementation SiperbConferenceSpike {
    RTCDefaultAudioProcessingModule *_audioProcessingModule;
    SiperbSpikeToneInjector *_injector;
    NSUInteger _captureCallbacks;
}

+ (instancetype)sharedSpike {
    static SiperbConferenceSpike *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SiperbConferenceSpike alloc] init];
    });
    return shared;
}

- (NSUInteger)captureCallbacks {
    return _captureCallbacks;
}

- (void)countCallback {
    _captureCallbacks++;
}

- (BOOL)startWithEncoderFactory:(id<RTCVideoEncoderFactory>)encoderFactory
                 decoderFactory:(id<RTCVideoDecoderFactory>)decoderFactory {
    if (_syntheticFactory != nil) {
        RCTLogInfo(@"[ConferenceSpike] start: already running");
        return YES;
    }

    _captureCallbacks = 0;
    _injector = [SiperbSpikeToneInjector new];
    _injector.owner = self;

    // Its OWN processing module, so writing here cannot touch the app's factory. The module
    // holds its delegate weakly, which is why this object retains the injector.
    _audioProcessingModule =
        [[RTCDefaultAudioProcessingModule alloc] initWithConfig:nil
                                 capturePostProcessingDelegate:_injector
                                   renderPreProcessingDelegate:nil];

    _syntheticFactory =
        [[RTCPeerConnectionFactory alloc] initWithBypassVoiceProcessing:NO
                                                        encoderFactory:encoderFactory
                                                        decoderFactory:decoderFactory
                                                 audioProcessingModule:_audioProcessingModule];

    if (_syntheticFactory == nil) {
        RCTLogWarn(@"[ConferenceSpike] start: second RTCPeerConnectionFactory could not be built");
        _audioProcessingModule = nil;
        _injector = nil;
        return NO;
    }

    RCTLogInfo(@"[ConferenceSpike] start: second factory up (capture replaced with a %.0fHz tone)", kToneHz);
    return YES;
}

- (NSString *)audioDeviceDiagnosis:(RTCPeerConnectionFactory *)appFactory {
    if (_syntheticFactory == nil) {
        return @"spike not started";
    }
    RTCAudioDeviceModule *appAdm = appFactory.audioDeviceModule;
    RTCAudioDeviceModule *spikeAdm = _syntheticFactory.audioDeviceModule;

    if (appAdm == nil || spikeAdm == nil) {
        return [NSString stringWithFormat:@"audioDeviceModule unavailable (app=%@ spike=%@)",
                                          appAdm ? @"yes" : @"nil", spikeAdm ? @"yes" : @"nil"];
    }
    const BOOL shared = (appAdm == spikeAdm);
    return [NSString
        stringWithFormat:@"factories=%p/%p adm=%p/%p SHARED=%@ -- %@", appFactory, _syntheticFactory,
                         appAdm, spikeAdm, shared ? @"YES" : @"NO",
                         shared ? @"one capture stream for both legs: the Android design does NOT port"
                                : @"separate capture per factory: the Android design ports"];
}

- (void)stop {
    _syntheticFactory = nil;
    _audioProcessingModule = nil;
    _injector = nil;
    RCTLogInfo(@"[ConferenceSpike] stop: second factory released (callbacks seen: %lu)",
               (unsigned long)_captureCallbacks);
}

@end

#pragma mark -

@implementation SiperbSpikeToneInjector

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz channels:(size_t)channels {
    _sampleRate = (int32_t)sampleRateHz;
    _phase = 0.0;
}

- (void)audioProcessingProcess:(RTCAudioBuffer *)audioBuffer {
    const size_t frames = audioBuffer.frames;
    const size_t channels = audioBuffer.channels;
    if (frames == 0 || channels == 0) {
        return;
    }

    double rate = (double)_sampleRate;
    if (rate <= 0) {
        // The APM works in 10 ms chunks, so the rate can be derived if initialize never fired.
        rate = (double)frames * 100.0;
    }

    // FloatS16, NOT normalised: these floats are already in int16 range (+/-32768). Scaling
    // by 32767 on top clipped every sample into square-wave static once already - the fix is
    // recorded in CallRecordingAudioProcessingDelegate.m and this is the same trap.
    const double step = 2.0 * M_PI * kToneHz / rate;
    const double amplitude = kToneAmplitude * 32767.0;

    double phase = _phase;
    for (size_t c = 0; c < channels; c++) {
        float *samples = [audioBuffer rawBufferForChannel:c];
        if (samples == NULL) {
            continue;
        }
        double p = _phase;
        for (size_t i = 0; i < frames; i++) {
            samples[i] = (float)(sin(p) * amplitude);
            p += step;
        }
        phase = p;
    }
    _phase = fmod(phase, 2.0 * M_PI);

    [self.owner countCallback];
}

- (void)audioProcessingRelease {
    _phase = 0.0;
}

@end
