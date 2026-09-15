#import <UIKit/UIKit.h>
#import <WebRTC/RTCVideoCapturer.h>
#import "CapturerEventsDelegate.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * A video capturer whose frames are a native VIEW, sampled on a timer — the React Native
 * analogue of the web's `canvas.captureStream(fps)`. It is the sibling of `ScreenCapturer`:
 * the same `RTCVideoCapturer` → `RTCVideoFrame` → `RTCVideoSource` machinery, but the pixels
 * come from rasterising a `UIView` layer in-process, not from a broadcast socket. So there is
 * NO extension, App Group, entitlement or picker — unlike screen share it just works on device
 * and in the Simulator, and its track delivers from the first tick (never born muted).
 *
 * Two modes:
 *   - VIEW:  every tick snapshots the target view's current on-screen content
 *            (`drawViewHierarchyInRect:afterScreenUpdates:NO`, which captures GPU-composited
 *            content such as Skia/Metal that `-[CALayer renderInContext:]` cannot). This is the
 *            whiteboard — draw with any renderer, the layer is what streams.
 *   - IMAGE: every tick re-pushes one decoded still. This is a "present a picture": a video
 *            track needs frames to keep flowing, so the same frame is re-emitted at a low rate.
 *
 * The tick runs on the MAIN run loop, because `drawViewHierarchyInRect:` must; keep `fps` modest
 * (a near-static drawing needs ~10, not 30). The frame handoff to the source is thread-safe.
 */
@interface ViewFrameCapturer : RTCVideoCapturer

@property(nonatomic, weak) id<CapturerEventsDelegate> eventsDelegate;

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate;

/** Sample `view`'s layer at `fps` frames/second. `view` is held weakly; if it deallocates the
 *  capturer reports `capturerDidEnd:` and stops. */
- (void)startCaptureWithView:(nonnull UIView *)view fps:(NSInteger)fps;

/** Re-emit `image` at `fps` frames/second (a still "picture" source). */
- (void)startCaptureWithImage:(nonnull UIImage *)image fps:(NSInteger)fps;

- (void)stopCapture;

@end

NS_ASSUME_NONNULL_END
