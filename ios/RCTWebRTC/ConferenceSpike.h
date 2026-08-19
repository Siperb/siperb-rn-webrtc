#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

/**
 * PHASE 0 SPIKE, iOS - THROWAWAY. The counterpart of the Android spike, proving the same
 * one thing before any of the real work is written for this platform:
 *
 *   a PeerConnection on a SECOND factory can send audio we synthesised, while a
 *   PeerConnection on the app's existing factory keeps sending the real microphone.
 *
 * WHY A SECOND RTCDefaultAudioProcessingModule AND NOT A CUSTOM RTCAudioDevice. Both are
 * per-factory, and either would give us a place to write samples - but a custom
 * RTCAudioDevice means owning the AudioUnit, the AVAudioSession category, route changes
 * and interruptions, which is precisely the machinery the app's CallKit manual-audio path
 * already depends on. A processing module leaves all of that alone and still hands us a
 * writable capture buffer. It is also the direct analogue of what already works on
 * Android, so a failure here is a platform difference rather than a design difference.
 *
 * THE RISK THIS EXISTS TO MEASURE is two factories, each with its own audio unit, sharing
 * one AVAudioSession. Android tolerates two AudioRecords; iOS may not, and no amount of
 * reading settles it.
 */
@interface SiperbConferenceSpike : NSObject

+ (instancetype)sharedSpike;

/**
 * Bring up the second factory. Its capture is replaced with a 440 Hz tone.
 *
 * @return NO if the factory could not be built, which is itself a result.
 */
- (BOOL)startWithEncoderFactory:(id<RTCVideoEncoderFactory>)encoderFactory
                 decoderFactory:(id<RTCVideoDecoderFactory>)decoderFactory;

- (void)stop;

/** The factory a spike PeerConnection is created on. nil until start succeeds. */
@property(nonatomic, strong, readonly) RTCPeerConnectionFactory *syntheticFactory;

/** How many times the synthetic capture callback has fired - the diagnostic that separates
 * "never produced a frame" from "produced and dropped". Android needed exactly this. */
@property(nonatomic, readonly) NSUInteger captureCallbacks;

/**
 * Whether the second factory got its OWN audio device, or shares the app's.
 *
 * THE DECISIVE QUESTION FOR IOS, and it needs no call, no ICE and no audio to answer. On
 * Android each JavaAudioDeviceModule opens its own AudioRecord, which is what lets two
 * factories carry two different outbound signals. If iOS hands both factories the same
 * device then there is only ever ONE capture stream, both legs share an outbound, and the
 * whole asymmetric design fails to port -- no amount of buffer-writing can fix it.
 */
- (NSString *)audioDeviceDiagnosis:(RTCPeerConnectionFactory *)appFactory;

@end
