#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

/**
 * Wires SiperbConferenceAudioBus into WebRTC's actual audio paths on iOS.
 *
 * THE SHAPE, and why it is asymmetric. An audio device is set per RTCPeerConnectionFactory
 * and feeds every sender on it, and a PeerConnection belongs to its factory for life. One
 * factory therefore produces exactly ONE outbound signal, while a three-way call needs two.
 * So the HOST leg stays on the app's existing factory and has its capture buffer overwritten
 * in place - sound only because it is the sole leg there - and every further leg is born on
 * a factory of its own.
 *
 * Measured before any of this was written: two factories on iOS get SEPARATE
 * RTCAudioDeviceModules (adm=0x117849700/0x117841160, SHARED=NO on an iPhone 12). Had they
 * shared one, there would be a single capture stream, one outbound for both legs, and no
 * per-leg mix at any price.
 *
 * CAPTURE-POST, not the render side, for injection: post-AEC is downstream of the echo
 * canceller, so what we write is not fed back into it as if the microphone had heard it.
 *
 * ONE DELEGATE SLOT, TWO CONSUMERS. Unlike Android - where the recorder uses the ADM's
 * samples callback and the conference uses a separate processing factory - iOS has a single
 * `capturePostProcessingDelegate`, and the call recorder already owns it. This class
 * therefore installs a FAN-OUT and the ORDER IS LOAD-BEARING: the recorder's read-only tap
 * runs FIRST so a recording captures the real microphone, and the conference overwrite runs
 * second. Reversed, every recording's "left is us" channel would silently contain the whole
 * conference instead.
 */
@interface SiperbConferenceMixManager : NSObject

+ (instancetype)sharedManager;

/**
 * Take over the app factory's capture-post slot, chaining whatever already held it.
 *
 * Called once at module construction. Idempotent, and a no-op when the module has no
 * processing module of its own (an injected custom audio device rules it out).
 */
- (void)installOnAudioProcessingModule:(RTCDefaultAudioProcessingModule *)module;

/**
 * The factory a conference leg's PeerConnection must be created on.
 *
 * Called before the leg is dialled, because the factory is fixed at construction and can
 * never change afterwards. That is also why two calls that ALREADY exist cannot be merged:
 * both are on the app's factory and would share one outbound.
 */
- (RTCPeerConnectionFactory *)factoryForLeg:(NSString *)legId
                             encoderFactory:(id<RTCVideoEncoderFactory>)encoderFactory
                             decoderFactory:(id<RTCVideoDecoderFactory>)decoderFactory;

/**
 * Put a leg on the bus and start tapping its remote audio.
 *
 * @param host YES for the leg carried by the app's own factory. Exactly one leg can be the
 *             host, because that factory has a single outbound to overwrite.
 */
- (void)attachLeg:(NSString *)legId remoteTracks:(NSArray<RTCAudioTrack *> *)remoteTracks host:(BOOL)host;

/** Take one leg out of the mix. The rest of the conference carries on. */
- (void)detachLeg:(NSString *)legId;

/** The conference is over. Idempotent, and safe when none was ever up. */
- (void)teardown;

- (NSArray<NSString *> *)legIds;
- (void)setMicMuted:(BOOL)muted;

/**
 * Put an AUX source - a presented file's soundtrack, keyed by its video track id - on the
 * bus: every leg's outbound mix sums it, and the render hook plays the presenter's copy
 * through WebRTC's playout so it sits in the echo canceller's reference. Idempotent. Not a
 * leg, and bound to the bus rather than to a leg, so attach order does not matter.
 */
- (void)attachAux:(NSString *)auxId;
/** Take an aux off the bus. Safe for one never attached, or already gone. */
- (void)detachAux:(NSString *)auxId;

@end
