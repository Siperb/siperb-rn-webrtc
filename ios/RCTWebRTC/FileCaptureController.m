#if TARGET_OS_IOS

#import "FileCaptureController.h"
#import "FileFrameSource.h"

@interface FileCaptureController ()
@property(nonatomic, strong) FileFrameSource *source;
@end

@interface FileCaptureController (CapturerEventsDelegate)<CapturerEventsDelegate>
- (void)capturerDidEnd:(RTCVideoCapturer *)capturer;
@end

@implementation FileCaptureController

- (instancetype)initWithSource:(nonnull FileFrameSource *)source {
    self = [super init];
    if (self) {
        self.source = source;
        self.source.eventsDelegate = self;
        self.deviceId = @"file";
    }
    return self;
}

- (void)dealloc {
    [self.source teardown];
}

/** Resume: the track is enabled (first time, and after a hold). */
- (void)startCapture {
    [self.source setSuspended:NO];
}

/** Suspend: the track is disabled (hold). NOT teardown — a held call resumes. */
- (void)stopCapture {
    [self.source setSuspended:YES];
}

- (void)dispose {
    [self.source teardown];
}

- (NSDictionary *)getSettings {
    CGSize size = self.source.frameSize;
    return @{
        @"deviceId" : self.deviceId,
        @"groupId" : @"",
        @"width" : @((NSInteger)size.width),
        @"height" : @((NSInteger)size.height),
        @"frameRate" : @(self.source.fps)
    };
}

// MARK: CapturerEventsDelegate

- (void)capturerDidEnd:(RTCVideoCapturer *)capturer {
    [self.eventsDelegate capturerDidEnd:capturer];
}

@end

#endif
