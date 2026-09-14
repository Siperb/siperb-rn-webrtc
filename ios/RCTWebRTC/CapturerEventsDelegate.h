#import <WebRTC/RTCVideoCapturer.h>

NS_ASSUME_NONNULL_BEGIN

// <NSObject> so respondsToSelector: is available on an id<CapturerEventsDelegate>, which the
// @optional method below needs. Every conformer is an NSObject already.
@protocol CapturerEventsDelegate <NSObject>

/** Called when the capturer is ended and in an irrecoverable state. */
- (void)capturerDidEnd:(RTCVideoCapturer *)capturer;

@optional

/**
 * Called when a capturer that was born unable to deliver frames starts delivering them.
 *
 * Only the screen capturer sends this: its track exists from getDisplayMedia() onwards, but
 * frames only flow once the user has started the Broadcast Upload Extension and it has
 * connected. Camera capturers deliver from the first frame and never call it.
 */
- (void)capturerDidStart:(RTCVideoCapturer *)capturer;

@end

NS_ASSUME_NONNULL_END
