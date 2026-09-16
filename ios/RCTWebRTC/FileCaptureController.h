#import <Foundation/Foundation.h>
#import "CaptureController.h"
#import "CapturerEventsDelegate.h"

NS_ASSUME_NONNULL_BEGIN

@class FileFrameSource;

/**
 * Owns a {@link FileFrameSource} and binds it to a track — the file-source sibling of
 * ViewCaptureController. `startCapture` / `stopCapture` are RESUME / SUSPEND (the SDK disables
 * the sender track on hold, and a suspended file pauses picture and sound together);
 * `dispose` is the real teardown, called by mediaStreamTrackRelease.
 */
@interface FileCaptureController : CaptureController

- (instancetype)initWithSource:(nonnull FileFrameSource *)source;

@property(nonatomic, readonly) FileFrameSource *source;

- (void)startCapture;
- (void)stopCapture;
- (void)dispose;

@end

NS_ASSUME_NONNULL_END
