#import <Foundation/Foundation.h>
#import "CapturerEventsDelegate.h"

NS_ASSUME_NONNULL_BEGIN

@interface CaptureController : NSObject

@property(nonatomic, strong) id<CapturerEventsDelegate> eventsDelegate;
@property(nonatomic, copy, nullable) NSString *deviceId;

- (void)startCapture;
- (void)stopCapture;
/**
 * Release what the controller owns beyond the capture itself. A no-op for the camera, screen
 * and view controllers; the file controller uses it to tear down its player, tap and timer,
 * which retain it and would otherwise keep it alive past mediaStreamTrackRelease.
 */
- (void)dispose;
- (NSDictionary *)getSettings;
- (void)applyConstraints:(NSDictionary *)constraints error:(NSError **)outError;

@end

NS_ASSUME_NONNULL_END
