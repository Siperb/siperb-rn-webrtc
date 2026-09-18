#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <WebRTC/RTCVideoCapturer.h>
#import "CapturerEventsDelegate.h"

NS_ASSUME_NONNULL_BEGIN

/** One playback-state report, the shape every control reply and every event carries. */
typedef void (^FileFrameSourceEventBlock)(NSString *type, NSDictionary *body);

/**
 * A video capturer whose frames come from a FILE — the React Native analogue of the web's
 * "load a file into `<video>`, then `captureStream()`". The sibling of ViewFrameCapturer: the
 * same `RTCVideoCapturer` → `RTCVideoFrame` → `RTCVideoSource` machinery, with the pixels
 * coming from an AVPlayer's video output instead of a rasterised view.
 *
 * ONE OBJECT OWNS BOTH HALVES. The player is the clock: its `AVPlayerItemVideoOutput` yields the
 * frames, and a SECOND, INDEPENDENT `AVAssetReader` decode of the audio track — paced against the
 * player's clock — yields the soundtrack as PCM, which is pushed onto the native conference bus as
 * an AUX source under `auxId` (the video track's id). (This replaced an `MTAudioProcessingTap` on
 * the player's audio mix: a muted `AVPlayer` under WebRTC's PlayAndRecord audio session does not
 * reliably clock the tap, so the soundtrack never reached the far end — the offline reader is
 * independent of the audio session, exactly like the Android MediaCodec feeder.) The player's own
 * audio output is MUTED: the presenter's copy is played by WebRTC's render hook (SiperbRenderAuxMixer),
 * which is what keeps the file inside the echo canceller's reference on a loudspeaker. So
 * play/pause/seek/ended act on picture and sound together, and teardown takes both down at once.
 *
 * TWO PAUSE FLAGS, INDEPENDENT. `userPaused` is the presenter's; `suspended` is the track being
 * disabled (the SDK disables every sender track on hold). Playing ⇔ neither is set and the file
 * has not ended. While paused or ended the last frame is re-emitted at a low rate so the far end
 * keeps the picture — the web's last frame stays on the wire too.
 *
 * Frames are sampled on a GCD timer on a private serial queue, NOT a CADisplayLink: the display
 * link pauses when the app backgrounds, and nothing here needs the main thread.
 */
@interface FileFrameSource : RTCVideoCapturer

@property(nonatomic, weak) id<CapturerEventsDelegate> eventsDelegate;
/** The bus key for the soundtrack. Set before `loadURL:` — it is the video track's id. */
@property(nonatomic, copy, nullable) NSString *auxId;
/** Playback events for JS (`playing` / `paused` / `ended` / `progress` / `error`). */
@property(nonatomic, copy, nullable) FileFrameSourceEventBlock onEvent;

/** Rotation-corrected frame size, known once `loadURL:` completes. */
@property(nonatomic, readonly) CGSize frameSize;
@property(nonatomic, readonly) NSInteger fps;
@property(nonatomic, readonly) BOOL hasAudio;
@property(nonatomic, readonly) Float64 duration;

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate;

/**
 * Open the file. Completes on an arbitrary queue once the asset's metadata is known — the
 * caller then knows the size and duration and can register the track. Frames start on the
 * first `setSuspended:NO`; playback starts on `play` (or immediately when `autoplay`).
 */
- (void)loadURL:(NSURL *)url
            fps:(NSInteger)fps
       autoplay:(BOOL)autoplay
     completion:(void (^)(NSError *_Nullable error))completion;

// Transport. Safe to call on any thread; the player is driven on the main queue.
- (void)play;
- (void)pause;
- (void)seekToSeconds:(Float64)seconds;
/** The presenter's local volume 0..1 — the render hook's gain, never what the far end gets. */
- (void)setLocalVolume:(float)volume;
- (NSDictionary *)state;

/** The track was disabled (YES) or re-enabled (NO): pause/resume without forgetting a user pause. */
- (void)setSuspended:(BOOL)suspended;

/** Release everything: the player, the audio reader, both timers, the aux. Idempotent. */
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
