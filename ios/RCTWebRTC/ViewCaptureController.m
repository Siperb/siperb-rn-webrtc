#if TARGET_OS_IOS

#import "ViewCaptureController.h"
#import "ViewFrameCapturer.h"

@interface ViewCaptureController ()
@property(nonatomic, retain) ViewFrameCapturer *capturer;
@property(nonatomic, assign) NSInteger frameRate;
@end

// Forward the capturer's one event (the target view went away) to whatever emitter the module
// attached, so a whiteboard whose screen unmounts ends its track cleanly.
@interface ViewCaptureController (CapturerEventsDelegate)<CapturerEventsDelegate>
- (void)capturerDidEnd:(RTCVideoCapturer *)capturer;
@end

@implementation ViewCaptureController

- (instancetype)initWithCapturer:(nonnull ViewFrameCapturer *)capturer {
    self = [super init];
    if (self) {
        self.capturer = capturer;
        self.capturer.eventsDelegate = self;
        self.deviceId = @"view-capture";
        self.frameRate = 10;
    }
    return self;
}

- (void)dealloc {
    [self.capturer stopCapture];
}

- (void)startCaptureWithView:(nonnull UIView *)view fps:(NSInteger)fps {
    self.frameRate = fps > 0 ? fps : 10;
    [self.capturer startCaptureWithView:view fps:fps];
}

- (void)startCaptureWithImage:(nonnull UIImage *)image fps:(NSInteger)fps {
    self.deviceId = @"picture";
    self.frameRate = fps > 0 ? fps : 2;
    [self.capturer startCaptureWithImage:image fps:self.frameRate];
}

- (void)stopCapture {
    [self.capturer stopCapture];
}

- (NSDictionary *)getSettings {
    return @{@"deviceId" : self.deviceId, @"groupId" : @"", @"frameRate" : @(self.frameRate)};
}

// MARK: CapturerEventsDelegate

- (void)capturerDidEnd:(RTCVideoCapturer *)capturer {
    [self.eventsDelegate capturerDidEnd:capturer];
}

@end

#endif
