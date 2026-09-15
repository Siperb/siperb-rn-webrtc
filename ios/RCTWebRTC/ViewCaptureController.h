#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "CaptureController.h"
#import "CapturerEventsDelegate.h"

NS_ASSUME_NONNULL_BEGIN

@class ViewFrameCapturer;

/**
 * Owns a {@link ViewFrameCapturer} and binds it to a source — the view-capture sibling of
 * {@link ScreenCaptureController}. Unlike the screen controller there is no socket, no App Group
 * and no `startCapture` that can fail on missing packaging: view capture is in-process, so the
 * track delivers as soon as the view lays out.
 */
@interface ViewCaptureController : CaptureController

- (instancetype)initWithCapturer:(nonnull ViewFrameCapturer *)capturer;

/** Whiteboard: sample `view` at `fps`. */
- (void)startCaptureWithView:(nonnull UIView *)view fps:(NSInteger)fps;

/** Picture: re-emit `image` at `fps`. */
- (void)startCaptureWithImage:(nonnull UIImage *)image fps:(NSInteger)fps;

- (void)stopCapture;

@end

NS_ASSUME_NONNULL_END
