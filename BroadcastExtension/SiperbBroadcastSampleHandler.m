#import "SiperbBroadcastSampleHandler.h"
#import "SiperbBroadcastFrameUploader.h"
#import "SiperbBroadcastSocketClient.h"

/** Info.plist key naming the App Group. Same key the app's ScreenCaptureController reads (kRTCAppGroupIdentifier). */
static NSString *const kAppGroupInfoPlistKey = @"RTCAppGroupIdentifier";

/** Socket file inside the App Group container. Must equal kRTCScreensharingSocketFD in ScreenCaptureController.m. */
static NSString *const kSocketFileName = @"rtc_SSFD";

/** Every Nth ReplayKit frame is offered to the uploader. ReplayKit runs ~30 fps; 3 gives ~10 fps, which is what a shared screen needs and what the app's decoder comfortably keeps up with. */
static const NSUInteger kFrameDivisor = 3;

/** How long to keep trying to reach the app before giving up on this broadcast. */
static const NSTimeInterval kConnectTimeoutSeconds = 15.0;
static const int64_t kConnectRetryIntervalMs = 100;

/** Error domain/code for the broadcast-ending errors this class reports. */
static NSString *const kErrorDomain = @"com.siperb.broadcast";
typedef NS_ENUM(NSInteger, SiperbBroadcastError) {
    SiperbBroadcastErrorNotConfigured = 1,
    SiperbBroadcastErrorAppNotListening = 2,
    SiperbBroadcastErrorStoppedByApp = 3,
    SiperbBroadcastErrorConnectionLost = 4,
};

@interface SiperbBroadcastSampleHandler ()

@property(nonatomic, strong, nullable) SiperbBroadcastSocketClient *client;
@property(nonatomic, strong, nullable) SiperbBroadcastFrameUploader *uploader;
@property(nonatomic, strong, nullable) dispatch_source_t connectTimer;
@property(nonatomic, strong) dispatch_queue_t connectQueue;
@property(nonatomic, assign) NSUInteger frameCount;

@end

@implementation SiperbBroadcastSampleHandler

- (instancetype)init {
    self = [super init];
    if (self) {
        _connectQueue = dispatch_queue_create("com.siperb.broadcast.connect", DISPATCH_QUEUE_SERIAL);
        NSString *socketPath = [self socketFilePath];
        if (socketPath != nil) {
            _client = [[SiperbBroadcastSocketClient alloc] initWithFilePath:socketPath];
            _uploader = [[SiperbBroadcastFrameUploader alloc] initWithClient:_client];

            __weak __typeof__(self) weakSelf = self;
            _client.didClose = ^(NSError *_Nullable error) {
                [weakSelf connectionClosedWithError:error];
            };
        }
    }
    return self;
}

// MARK: - RPBroadcastSampleHandler

- (void)broadcastStartedWithSetupInfo:(nullable NSDictionary<NSString *, NSObject *> *)setupInfo {
    self.frameCount = 0;

    if (self.client == nil) {
        [self finishBroadcastWithError:
                  [self errorWithCode:SiperbBroadcastErrorNotConfigured
                          description:@"Screen sharing is not configured: RTCAppGroupIdentifier is missing from the "
                                      @"extension's Info.plist, or the App Group is not entitled."]];
        return;
    }

    [self connectWithRetry];
}

- (void)broadcastPaused {
    // Frames stop arriving; nothing to do. The socket stays up.
}

- (void)broadcastResumed {
}

- (void)broadcastFinished {
    [self cancelConnectTimer];
    [self.client close];
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)sampleBufferType {
    if (sampleBufferType != RPSampleBufferTypeVideo) {
        // Audio is deliberately not carried: the app's getDisplayMedia is video-only, and
        // system audio would loop the call's own downlink back to the far end.
        return;
    }

    self.frameCount += 1;
    if (self.frameCount % kFrameDivisor != 0) {
        return;
    }

    [self.uploader sendSampleBuffer:sampleBuffer];
}

// MARK: - Connecting

- (void)connectWithRetry {
    [self cancelConnectTimer];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kConnectTimeoutSeconds];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.connectQueue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)kConnectRetryIntervalMs * NSEC_PER_MSEC,
                              (uint64_t)50 * NSEC_PER_MSEC);

    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if ([strongSelf.client open]) {
            NSLog(@"[SiperbBroadcast] connected to the app");
            [strongSelf cancelConnectTimer];
            return;
        }
        if ([[NSDate date] compare:deadline] == NSOrderedDescending) {
            [strongSelf cancelConnectTimer];
            [strongSelf finishBroadcastWithError:
                            [strongSelf errorWithCode:SiperbBroadcastErrorAppNotListening
                                          description:@"Start screen sharing from the app first."]];
        }
    });
    self.connectTimer = timer;
    dispatch_resume(timer);
}

- (void)cancelConnectTimer {
    dispatch_source_t timer = self.connectTimer;
    if (timer != nil) {
        dispatch_source_cancel(timer);
        self.connectTimer = nil;
    }
}

- (void)connectionClosedWithError:(nullable NSError *)error {
    if (error != nil) {
        NSLog(@"[SiperbBroadcast] connection lost: %@", error.localizedDescription);
        [self finishBroadcastWithError:[self errorWithCode:SiperbBroadcastErrorConnectionLost
                                                description:@"Screen sharing stopped: the connection to the app was lost."]];
        return;
    }
    // A clean end-of-stream is the app stopping the share. The only way to end a broadcast is
    // with an error, so this is the friendliest one there is.
    [self finishBroadcastWithError:[self errorWithCode:SiperbBroadcastErrorStoppedByApp
                                            description:@"Screen sharing stopped."]];
}

// MARK: - Helpers

- (nullable NSString *)socketFilePath {
    NSString *appGroup = [NSBundle mainBundle].infoDictionary[kAppGroupInfoPlistKey];
    if (![appGroup isKindOfClass:[NSString class]] || appGroup.length == 0) {
        NSLog(@"[SiperbBroadcast] %@ missing from the extension's Info.plist", kAppGroupInfoPlistKey);
        return nil;
    }
    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:appGroup];
    if (container == nil) {
        NSLog(@"[SiperbBroadcast] no container for App Group %@ — is the extension entitled to it?", appGroup);
        return nil;
    }
    return [container URLByAppendingPathComponent:kSocketFileName].path;
}

- (NSError *)errorWithCode:(SiperbBroadcastError)code description:(NSString *)description {
    return [NSError errorWithDomain:kErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : description}];
}

@end
