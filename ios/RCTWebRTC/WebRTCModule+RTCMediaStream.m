#import <objc/runtime.h>

#import <WebRTC/RTCCameraVideoCapturer.h>
#import <WebRTC/RTCMediaConstraints.h>
#import <WebRTC/RTCMediaStreamTrack.h>
#import <WebRTC/RTCVideoTrack.h>

#import "RTCMediaStreamTrack+React.h"
#import "WebRTCModule+RTCMediaStream.h"
#import "WebRTCModule+RTCPeerConnection.h"
#import "WebRTCModuleOptions.h"

#import <React/RCTConvert.h>
#import <React/RCTUIManager.h>

#import "ProcessorProvider.h"
#import "ScreenCaptureController.h"
#import "ScreenCapturer.h"
#import "TrackCapturerEventsEmitter.h"
#import "VideoCaptureController.h"
#import "ViewCaptureController.h"
#import "ViewFrameCapturer.h"
#import "FileCaptureController.h"
#import "FileFrameSource.h"

@implementation WebRTCModule (RTCMediaStream)

- (VideoEffectProcessor *)videoEffectProcessor {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setVideoEffectProcessor:(VideoEffectProcessor *)videoEffectProcessor {
    objc_setAssociatedObject(
        self, @selector(videoEffectProcessor), videoEffectProcessor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - getUserMedia

/**
 * Initializes a new {@link RTCAudioTrack} which satisfies the given constraints.
 *
 * @param constraints The {@code MediaStreamConstraints} which the new
 * {@code RTCAudioTrack} instance is to satisfy.
 */
- (RTCAudioTrack *)createAudioTrack:(NSDictionary *)constraints {
    NSString *trackId = [[NSUUID UUID] UUIDString];
    RTCAudioTrack *audioTrack = [self.peerConnectionFactory audioTrackWithTrackId:trackId];
    return audioTrack;
}
/**
 * Initializes a new {@link RTCVideoTrack} with the given capture controller
 */
- (RTCVideoTrack *)createVideoTrackWithCaptureController:
    (CaptureController * (^)(RTCVideoSource *))captureControllerCreator {
#if TARGET_OS_TV
    return nil;
#else

    RTCVideoSource *videoSource = [self.peerConnectionFactory videoSource];

    NSString *trackUUID = [[NSUUID UUID] UUIDString];
    RTCVideoTrack *videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource trackId:trackUUID];

    CaptureController *captureController = captureControllerCreator(videoSource);
    videoTrack.captureController = captureController;
    [captureController startCapture];

    return videoTrack;
#endif
}
/**
 * Initializes a new {@link RTCMediaTrack} with the given tracks.
 *
 * @return An array with the mediaStreamId in index 0, and track infos in index 1.
 */
- (NSArray *)createMediaStream:(NSArray<RTCMediaStreamTrack *> *)tracks {
#if TARGET_OS_TV
    return nil;
#else
    NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
    RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
    NSMutableArray<NSDictionary *> *trackInfos = [NSMutableArray array];

    for (RTCMediaStreamTrack *track in tracks) {
        if ([track.kind isEqualToString:@"audio"]) {
            [mediaStream addAudioTrack:(RTCAudioTrack *)track];
        } else if ([track.kind isEqualToString:@"video"]) {
            [mediaStream addVideoTrack:(RTCVideoTrack *)track];
        }

        NSString *trackId = track.trackId;

        self.localTracks[trackId] = track;

        NSDictionary *settings = @{};
        if ([track.kind isEqualToString:@"video"]) {
            RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
            if ([videoTrack.captureController isKindOfClass:[CaptureController class]]) {
                settings = [videoTrack.captureController getSettings];
            }
        } else if ([track.kind isEqualToString:@"audio"]) {
            settings = @{
                @"deviceId" : @"audio",
                @"groupId" : @"",
            };
        }

        [trackInfos addObject:@{
            @"enabled" : @(track.isEnabled),
            @"id" : trackId,
            @"kind" : track.kind,
            @"readyState" : @"live",
            @"remote" : @(NO),
            @"settings" : settings
        }];
    }

    self.localStreams[mediaStreamId] = mediaStream;
    return @[ mediaStreamId, trackInfos ];
#endif
}

/**
 * Initializes a new {@link RTCVideoTrack} which satisfies the given constraints.
 */
- (RTCVideoTrack *)createVideoTrack:(NSDictionary *)constraints {
#if TARGET_OS_TV
    return nil;
#else
    RTCVideoSource *videoSource = [self.peerConnectionFactory videoSource];

    NSString *trackUUID = [[NSUUID UUID] UUIDString];
    RTCVideoTrack *videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource trackId:trackUUID];

    BOOL hasRuntimeVideoDevice = YES;
#if TARGET_IPHONE_SIMULATOR
    // On simulator, a runtime-provided video source may exist (e.g. virtual camera),
    // so only skip camera capture setup when no runtime video device is available.
    hasRuntimeVideoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo] != nil;
#endif

    if (hasRuntimeVideoDevice) {
        RTCCameraVideoCapturer *videoCapturer = [[RTCCameraVideoCapturer alloc] initWithDelegate:videoSource];
        VideoCaptureController *videoCaptureController =
            [[VideoCaptureController alloc] initWithCapturer:videoCapturer andConstraints:constraints[@"video"]];
        videoCaptureController.enableMultitaskingCameraAccess =
            [WebRTCModuleOptions sharedInstance].enableMultitaskingCameraAccess;
        videoTrack.captureController = videoCaptureController;
        [videoCaptureController startCapture];
    }

    return videoTrack;
#endif
}

- (RTCVideoTrack *)createScreenCaptureVideoTrack {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_OSX || TARGET_OS_TV
    return nil;
#endif

    RTCVideoSource *videoSource = [self.peerConnectionFactory videoSourceForScreenCast:YES];

    NSString *trackUUID = [[NSUUID UUID] UUIDString];
    RTCVideoTrack *videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource trackId:trackUUID];

    ScreenCapturer *screenCapturer = [[ScreenCapturer alloc] initWithDelegate:videoSource];
    ScreenCaptureController *screenCaptureController =
        [[ScreenCaptureController alloc] initWithCapturer:screenCapturer];

    TrackCapturerEventsEmitter *emitter = [[TrackCapturerEventsEmitter alloc] initWith:trackUUID webRTCModule:self];
    screenCaptureController.eventsDelegate = emitter;
    videoTrack.captureController = screenCaptureController;
    [screenCaptureController startCapture];

    return videoTrack;
}

RCT_EXPORT_METHOD(getDisplayMedia : (NSDictionary *)constraints resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
#if TARGET_OS_TV
    reject(@"unsupported_platform", @"tvOS is not supported", nil);
    return;
#else

    RTCVideoTrack *videoTrack = [self createScreenCaptureVideoTrack];

    if (videoTrack == nil) {
        reject(@"DOMException", @"AbortError", nil);
        return;
    }

    NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
    RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
    [mediaStream addVideoTrack:videoTrack];

    NSString *trackId = videoTrack.trackId;
    self.localTracks[trackId] = videoTrack;

    // BORN MUTED. The track exists now, but no frame can arrive until the user starts the
    // Broadcast Upload Extension from the picker and it connects to our socket — and the picker
    // has no cancel callback, so this is the only honest state to hand back. MDN's `muted` means
    // exactly "temporarily unable to provide data"; ScreenCapturer un-mutes it on connection
    // (capturerDidStart) and JS can await `unmute` — or `ended`, or a timeout — to tell consent
    // from dismissal.
    NSDictionary *trackInfo = @{
        @"enabled" : @(videoTrack.isEnabled),
        @"id" : videoTrack.trackId,
        @"kind" : videoTrack.kind,
        @"muted" : @YES,
        @"readyState" : @"live",
        @"remote" : @(NO)
    };

    self.localStreams[mediaStreamId] = mediaStream;
    resolve(@{@"streamId" : mediaStreamId, @"track" : trackInfo});
#endif
}

#pragma mark - View source (whiteboard / picture)

#if TARGET_OS_IOS

// The view-capture sibling of createScreenCaptureVideoTrack. Same source/track/controller shape;
// videoSourceForScreenCast:YES on purpose — a whiteboard IS screen-like content (sharp strokes,
// low motion), so the encoder's detail-over-framerate bias is what we want.
- (RTCVideoTrack *)createViewSourceTrackWithController:(ViewCaptureController **)outController {
    RTCVideoSource *videoSource = [self.peerConnectionFactory videoSourceForScreenCast:YES];
    NSString *trackUUID = [[NSUUID UUID] UUIDString];
    RTCVideoTrack *videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource trackId:trackUUID];

    ViewFrameCapturer *capturer = [[ViewFrameCapturer alloc] initWithDelegate:videoSource];
    ViewCaptureController *controller = [[ViewCaptureController alloc] initWithCapturer:capturer];

    TrackCapturerEventsEmitter *emitter = [[TrackCapturerEventsEmitter alloc] initWith:trackUUID webRTCModule:self];
    controller.eventsDelegate = emitter;
    videoTrack.captureController = controller;

    if (outController) {
        *outController = controller;
    }
    return videoTrack;
}

// Register the track+stream and hand JS the same shape getDisplayMedia does — but NOT born muted:
// view/image frames flow from the first tick, there is no picker/consent to wait on.
- (void)resolveViewSourceTrack:(RTCVideoTrack *)videoTrack resolver:(RCTPromiseResolveBlock)resolve {
    NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
    RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
    [mediaStream addVideoTrack:videoTrack];

    self.localTracks[videoTrack.trackId] = videoTrack;
    self.localStreams[mediaStreamId] = mediaStream;

    NSDictionary *trackInfo = @{
        @"enabled" : @(videoTrack.isEnabled),
        @"id" : videoTrack.trackId,
        @"kind" : videoTrack.kind,
        @"muted" : @NO,
        @"readyState" : @"live",
        @"remote" : @(NO)
    };
    resolve(@{@"streamId" : mediaStreamId, @"track" : trackInfo});
}

#pragma mark - File source (a presented video file)

// The file-source sibling of createViewSourceTrackWithController. videoSourceForScreenCast:NO —
// a film is motion video, and the screencast bias (detail over framerate) is the wrong trade.
- (RTCVideoTrack *)createFileSourceTrackWithController:(FileCaptureController **)outController
                                                source:(FileFrameSource **)outSource
                                           videoSource:(RTCVideoSource **)outVideoSource {
    RTCVideoSource *videoSource = [self.peerConnectionFactory videoSourceForScreenCast:NO];
    NSString *trackUUID = [[NSUUID UUID] UUIDString];
    RTCVideoTrack *videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource trackId:trackUUID];

    FileFrameSource *source = [[FileFrameSource alloc] initWithDelegate:videoSource];
    source.auxId = trackUUID;   // the soundtrack's bus key IS the video track's id
    FileCaptureController *controller = [[FileCaptureController alloc] initWithSource:source];

    TrackCapturerEventsEmitter *emitter = [[TrackCapturerEventsEmitter alloc] initWith:trackUUID webRTCModule:self];
    controller.eventsDelegate = emitter;
    videoTrack.captureController = controller;

    __weak __typeof__(self) weakSelf = self;
    source.onEvent = ^(NSString *type, NSDictionary *body) {
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSMutableDictionary *payload = [body mutableCopy];
        payload[@"trackId"] = trackUUID;
        [strongSelf sendEventWithName:kEventFileMedia body:payload];
    };

    if (outController) {
        *outController = controller;
    }
    if (outSource) {
        *outSource = source;
    }
    if (outVideoSource) {
        *outVideoSource = videoSource;
    }
    return videoTrack;
}

/**
 * `getFileMedia({ uri, fps, maxSide, autoplay })` — present a video FILE: its frames as a real
 * video track through the file source, its soundtrack as an AUX on the native bus (see
 * FileFrameSource). Resolves once the asset's metadata is known, with `audio` describing the
 * aux JS should wrap as a virtual track (null when the file has no audio), and the duration.
 */
RCT_EXPORT_METHOD(getFileMedia : (NSDictionary *)constraints resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
#if !TARGET_OS_IOS
    reject(@"unsupported_platform", @"File source is iOS only", nil);
#else
    NSString *uri = [RCTConvert NSString:constraints[@"uri"]];
    NSInteger fps = constraints[@"fps"] ? [RCTConvert NSInteger:constraints[@"fps"]] : 25;
    NSInteger maxSide = constraints[@"maxSide"] ? [RCTConvert NSInteger:constraints[@"maxSide"]] : 360;
    BOOL autoplay = constraints[@"autoplay"] ? [RCTConvert BOOL:constraints[@"autoplay"]] : NO;
    NSURL *url = uri.length ? [NSURL URLWithString:uri] : nil;
    if (url == nil || url.scheme == nil) {
        url = uri.length ? [NSURL fileURLWithPath:uri] : nil;
    }
    if (url == nil) {
        reject(@"DOMException", @"NotFoundError", nil);
        return;
    }

    FileCaptureController *controller = nil;
    FileFrameSource *source = nil;
    RTCVideoSource *videoSource = nil;
    RTCVideoTrack *videoTrack = [self createFileSourceTrackWithController:&controller source:&source videoSource:&videoSource];

    __weak __typeof__(self) weakSelf = self;
    [source loadURL:url fps:fps autoplay:autoplay completion:^(NSError *_Nullable error) {
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            [controller dispose];
            reject(@"DOMException", @"AbortError", nil);
            return;
        }
        // Back onto the module queue: localTracks/localStreams are written there and nowhere else.
        dispatch_async(strongSelf.methodQueue, ^{
            if (error) {
                [controller dispose];
                reject(@"DOMException", @"NotSupportedError", error);
                return;
            }
            // The web caps the SHORTER side at VideoResampleSize; WebRTC scales natively.
            CGSize size = source.frameSize;
            if (size.width > 0 && size.height > 0 && maxSide > 0) {
                const CGFloat shorter = MIN(size.width, size.height);
                if (shorter > maxSide) {
                    const CGFloat scale = (CGFloat)maxSide / shorter;
                    [videoSource adaptOutputFormatToWidth:(int)llround(size.width * scale)
                                                   height:(int)llround(size.height * scale)
                                                      fps:(int)fps];
                } else {
                    [videoSource adaptOutputFormatToWidth:(int)size.width height:(int)size.height fps:(int)fps];
                }
            }
            [controller startCapture];   // frames begin (held first frame while paused)

            NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
            RTCMediaStream *mediaStream = [strongSelf.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
            [mediaStream addVideoTrack:videoTrack];
            strongSelf.localTracks[videoTrack.trackId] = videoTrack;
            strongSelf.localStreams[mediaStreamId] = mediaStream;

            NSDictionary *trackInfo = @{
                @"enabled" : @(videoTrack.isEnabled),
                @"id" : videoTrack.trackId,
                @"kind" : videoTrack.kind,
                @"muted" : @NO,
                @"readyState" : @"live",
                @"remote" : @(NO),
                @"settings" : [controller getSettings]
            };
            id audio = source.hasAudio ? @{@"auxId" : videoTrack.trackId} : [NSNull null];
            resolve(@{
                @"streamId" : mediaStreamId,
                @"track" : trackInfo,
                @"audio" : audio,
                @"duration" : @(source.duration),
                @"width" : @((NSInteger)size.width),
                @"height" : @((NSInteger)size.height),
                @"playing" : @(autoplay)
            });
        });
    }];
#endif
}

/** `fileMediaControl(trackId, { action, position, value })` → the playback state. */
RCT_EXPORT_METHOD(fileMediaControl : (nonnull NSString *)trackID command : (NSDictionary *)command resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
#if !TARGET_OS_IOS
    reject(@"unsupported_platform", @"File source is iOS only", nil);
#else
    RTCMediaStreamTrack *track = self.localTracks[trackID];
    if (![track.captureController isKindOfClass:[FileCaptureController class]]) {
        reject(@"DOMException", @"NotFoundError", nil);
        return;
    }
    FileFrameSource *source = ((FileCaptureController *)track.captureController).source;
    NSString *action = [RCTConvert NSString:command[@"action"]];
    if ([action isEqualToString:@"play"]) {
        [source play];
    } else if ([action isEqualToString:@"pause"]) {
        [source pause];
    } else if ([action isEqualToString:@"seek"]) {
        [source seekToSeconds:[RCTConvert double:command[@"position"]]];
    } else if ([action isEqualToString:@"volume"]) {
        [source setLocalVolume:[RCTConvert float:command[@"value"]]];
    } else {
        reject(@"DOMException", @"NotSupportedError", nil);
        return;
    }
    resolve([source state]);
#endif
}

// Decode a local file / file:// / data: URI to a UIImage. The image picker hands a local file,
// so no network read is expected; dataWithContentsOfURL: is only a last resort for a bare URL.
- (UIImage *)decodeImageFromUri:(NSString *)uri {
    if (uri.length == 0) {
        return nil;
    }
    if ([uri hasPrefix:@"data:"]) {
        NSRange comma = [uri rangeOfString:@","];
        if (comma.location == NSNotFound) {
            return nil;
        }
        NSString *b64 = [uri substringFromIndex:comma.location + 1];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:b64
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
        return data ? [UIImage imageWithData:data] : nil;
    }
    NSString *path = [uri hasPrefix:@"file://"] ? [[NSURL URLWithString:uri] path] : uri;
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image) {
        return image;
    }
    NSURL *url = [NSURL URLWithString:uri];
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    return data ? [UIImage imageWithData:data] : nil;
}

#endif

/**
 * `getWhiteboardMedia({ sourceTag, fps })` — the native `canvas.captureStream(fps)`. Samples the
 * mounted view identified by `sourceTag` (a React tag) at `fps` (default 10) and resolves a
 * MediaStream carrying one video track. Runs on the module's serial queue; the ONLY main-thread
 * work is resolving the view, after which it hops back so the localTracks/localStreams writes
 * stay on _workerQueue with every other method's.
 */
RCT_EXPORT_METHOD(getWhiteboardMedia : (NSDictionary *)constraints resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
#if !TARGET_OS_IOS
    reject(@"unsupported_platform", @"View capture is iOS only", nil);
#else
    NSNumber *sourceTag = [RCTConvert NSNumber:constraints[@"sourceTag"]];
    NSInteger fps = constraints[@"fps"] ? [RCTConvert NSInteger:constraints[@"fps"]] : 10;
    if (sourceTag == nil) {
        reject(@"DOMException", @"NotFoundError", nil);
        return;
    }

    // The tag → UIView lookup goes through RCTViewRegistry on the MAIN queue, not through
    // RCTUIManager.addUIBlock: (1) addUIBlock asserts the UIManager queue and this method runs on
    // the module's worker queue — an RCTAssert, i.e. SIGABRT in a debug build; (2) addUIBlock's
    // registry is Paper's, so under Fabric (the New Architecture) the board view is never in it.
    // RCTViewRegistry answers for both renderers and is what RN injects for exactly this use.
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) {
            reject(@"DOMException", @"AbortError", nil);
            return;
        }
        UIView *view = [strongSelf.viewRegistry_DEPRECATED viewForReactTag:sourceTag];
        if (![view isKindOfClass:[UIView class]]) {
            reject(@"DOMException", @"NotFoundError", nil);
            return;
        }
        dispatch_async(strongSelf.methodQueue, ^{
            ViewCaptureController *controller = nil;
            RTCVideoTrack *videoTrack = [strongSelf createViewSourceTrackWithController:&controller];
            [controller startCaptureWithView:view fps:fps];
            [strongSelf resolveViewSourceTrack:videoTrack resolver:resolve];
        });
    });
#endif
}

/**
 * `getPictureMedia({ uri, fps })` — present a still image as a video track. Same view source, one
 * decoded frame re-emitted at a low `fps` (default 2) to keep the track flowing.
 */
RCT_EXPORT_METHOD(getPictureMedia : (NSDictionary *)constraints resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
#if !TARGET_OS_IOS
    reject(@"unsupported_platform", @"View capture is iOS only", nil);
#else
    NSString *uri = [RCTConvert NSString:constraints[@"uri"]];
    NSInteger fps = constraints[@"fps"] ? [RCTConvert NSInteger:constraints[@"fps"]] : 2;
    UIImage *image = [self decodeImageFromUri:uri];
    if (image == nil) {
        reject(@"DOMException", @"NotSupportedError", nil);
        return;
    }
    ViewCaptureController *controller = nil;
    RTCVideoTrack *videoTrack = [self createViewSourceTrackWithController:&controller];
    [controller startCaptureWithImage:image fps:fps];
    [self resolveViewSourceTrack:videoTrack resolver:resolve];
#endif
}

/**
 * Implements {@code getUserMedia}. Note that at this point constraints have
 * been normalized and permissions have been granted. The constraints only
 * contain keys for which permissions have already been granted, that is,
 * if audio permission was not granted, there will be no "audio" key in
 * the constraints dictionary.
 */
RCT_EXPORT_METHOD(getUserMedia : (NSDictionary *)constraints successCallback : (RCTResponseSenderBlock)
                      successCallback errorCallback : (RCTResponseSenderBlock)errorCallback) {
#if TARGET_OS_TV
    errorCallback(@[ @"PlatformNotSupported", @"getUserMedia is not supported on tvOS." ]);
    return;
#else
    RTCAudioTrack *audioTrack = nil;
    RTCVideoTrack *videoTrack = nil;

    if (constraints[@"audio"]) {
        audioTrack = [self createAudioTrack:constraints];
    }
    if (constraints[@"video"]) {
        videoTrack = [self createVideoTrack:constraints];
    }

    if (audioTrack == nil && videoTrack == nil) {
        // Fail with DOMException with name AbortError as per:
        // https://www.w3.org/TR/mediacapture-streams/#dom-mediadevices-getusermedia
        errorCallback(@[ @"DOMException", @"AbortError" ]);
        return;
    }

    NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
    RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
    NSMutableArray *tracks = [NSMutableArray array];
    NSMutableArray *tmp = [NSMutableArray array];
    if (audioTrack)
        [tmp addObject:audioTrack];
    if (videoTrack)
        [tmp addObject:videoTrack];

    for (RTCMediaStreamTrack *track in tmp) {
        if ([track.kind isEqualToString:@"audio"]) {
            [mediaStream addAudioTrack:(RTCAudioTrack *)track];
        } else if ([track.kind isEqualToString:@"video"]) {
            [mediaStream addVideoTrack:(RTCVideoTrack *)track];
        }

        NSString *trackId = track.trackId;

        self.localTracks[trackId] = track;

        NSDictionary *settings = @{};
        if ([track.kind isEqualToString:@"video"]) {
            RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
            if ([videoTrack.captureController isKindOfClass:[CaptureController class]]) {
                settings = [videoTrack.captureController getSettings];
            }
        } else if ([track.kind isEqualToString:@"audio"]) {
            settings = @{
                @"deviceId" : @"audio",
                @"groupId" : @"",
            };
        }

        // An audio track created while the microphone is failing is born muted; the session
        // delegate un-mutes it when capture recovers (WebRTCModule+RTCAudioSession.m).
        BOOL muted = [track.kind isEqualToString:@"audio"] && self.micCaptureMuted;

        [tracks addObject:@{
            @"enabled" : @(track.isEnabled),
            @"id" : trackId,
            @"kind" : track.kind,
            @"muted" : @(muted),
            @"readyState" : @"live",
            @"remote" : @(NO),
            @"settings" : settings
        }];
    }

    self.localStreams[mediaStreamId] = mediaStream;
    successCallback(@[ mediaStreamId, tracks ]);
#endif
}

#pragma mark - Other stream related APIs

RCT_EXPORT_METHOD(enumerateDevices : (RCTResponseSenderBlock)callback) {
#if TARGET_OS_TV
    callback(@[]);
#else
    NSMutableArray *devices = [NSMutableArray array];
    NSMutableArray *deviceTypes = [NSMutableArray array];
    [deviceTypes addObjectsFromArray:@[
        AVCaptureDeviceTypeBuiltInWideAngleCamera,
        AVCaptureDeviceTypeBuiltInUltraWideCamera,
        AVCaptureDeviceTypeBuiltInTelephotoCamera,
        AVCaptureDeviceTypeBuiltInDualCamera,
        AVCaptureDeviceTypeBuiltInDualWideCamera,
        AVCaptureDeviceTypeBuiltInTripleCamera
    ]];
    if (@available(macos 14.0, ios 17.0, tvos 17.0, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeExternal];
    }
    AVCaptureDeviceDiscoverySession *videoDevicesSession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    for (AVCaptureDevice *device in videoDevicesSession.devices) {
        if (device.uniqueID == nil) {
            continue;
        }
        NSString *position = @"unknown";
        if (device.position == AVCaptureDevicePositionBack) {
            position = @"environment";
        } else if (device.position == AVCaptureDevicePositionFront) {
            position = @"front";
        }
        NSString *label = @"Unknown video device";
        if (device.localizedName != nil) {
            label = device.localizedName;
        }

        [devices addObject:@{
            @"facing" : position,
            @"deviceId" : device.uniqueID,
            @"groupId" : @"",
            @"label" : label,
            @"kind" : @"videoinput",
        }];
    }

    AVCaptureDeviceDiscoverySession *audioDevicesSession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInMicrophone ]
                                                               mediaType:AVMediaTypeAudio
                                                                position:AVCaptureDevicePositionUnspecified];
    for (AVCaptureDevice *device in audioDevicesSession.devices) {
        if (device.uniqueID == nil) {
            continue;
        }
        NSString *label = @"Unknown audio device";
        if (device.localizedName != nil) {
            label = device.localizedName;
        }
        [devices addObject:@{
            @"deviceId" : device.uniqueID,
            @"groupId" : @"",
            @"label" : label,
            @"kind" : @"audioinput",
        }];
    }
    callback(@[ devices ]);
#endif
}

RCT_EXPORT_METHOD(mediaStreamCreate : (nonnull NSString *)streamID) {
    RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:streamID];
    self.localStreams[streamID] = mediaStream;
}

RCT_EXPORT_METHOD(mediaStreamAddTrack : (nonnull NSString *)streamID : (nonnull NSNumber *)pcId : (nonnull NSString *)
                      trackID) {
    RTCMediaStream *mediaStream = self.localStreams[streamID];
    if (mediaStream == nil) {
        return;
    }

    RTCMediaStreamTrack *track = [self trackForId:trackID pcId:pcId];
    if (track == nil) {
        return;
    }

    if ([track.kind isEqualToString:@"audio"]) {
        [mediaStream addAudioTrack:(RTCAudioTrack *)track];
    } else if ([track.kind isEqualToString:@"video"]) {
        [mediaStream addVideoTrack:(RTCVideoTrack *)track];
    }
}

RCT_EXPORT_METHOD(mediaStreamRemoveTrack : (nonnull NSString *)streamID : (nonnull NSNumber *)
                      pcId : (nonnull NSString *)trackID) {
    RTCMediaStream *mediaStream = self.localStreams[streamID];
    if (mediaStream == nil) {
        return;
    }

    RTCMediaStreamTrack *track = [self trackForId:trackID pcId:pcId];
    if (track == nil) {
        return;
    }

    if ([track.kind isEqualToString:@"audio"]) {
        [mediaStream removeAudioTrack:(RTCAudioTrack *)track];
    } else if ([track.kind isEqualToString:@"video"]) {
        [mediaStream removeVideoTrack:(RTCVideoTrack *)track];
    }
}

RCT_EXPORT_METHOD(mediaStreamRelease : (nonnull NSString *)streamID) {
    RTCMediaStream *stream = self.localStreams[streamID];
    if (stream) {
        [self.localStreams removeObjectForKey:streamID];
    }
}

RCT_EXPORT_METHOD(mediaStreamTrackRelease : (nonnull NSString *)trackID) {
#if TARGET_OS_TV
    return;
#else

    RTCMediaStreamTrack *track = self.localTracks[trackID];
    if (track) {
        track.isEnabled = NO;
        [track.captureController stopCapture];
        // The file controller's player/tap/timer retain it, so dealloc never runs on its own.
        if ([track.captureController respondsToSelector:@selector(dispose)]) {
            [track.captureController dispose];
        }
        [self.localTracks removeObjectForKey:trackID];
    }
#endif
}

RCT_EXPORT_METHOD(mediaStreamTrackSetEnabled : (nonnull NSNumber *)pcId : (nonnull NSString *)trackID : (BOOL)enabled) {
    RTCMediaStreamTrack *track = [self trackForId:trackID pcId:pcId];
    if (track == nil) {
        return;
    }

    track.isEnabled = enabled;
#if !TARGET_OS_TV
    if (track.captureController) {  // It could be a remote track!
        if (enabled) {
            [track.captureController startCapture];
        } else {
            [track.captureController stopCapture];
        }
    }
#endif
}

RCT_EXPORT_METHOD(mediaStreamTrackApplyConstraints : (nonnull NSString *)trackID : (NSDictionary *)
                      constraints : (RCTPromiseResolveBlock)resolve : (RCTPromiseRejectBlock)reject) {
#if TARGET_OS_TV
    reject(@"unsupported_platform", @"tvOS is not supported", nil);
    return;
#else
    RTCMediaStreamTrack *track = self.localTracks[trackID];
    if (track) {
        if ([track.kind isEqualToString:@"video"]) {
            RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
            if ([videoTrack.captureController isKindOfClass:[CaptureController class]]) {
                CaptureController *vcc = (CaptureController *)videoTrack.captureController;
                NSError *error = nil;
                [vcc applyConstraints:constraints error:&error];
                if (error) {
                    reject(@"E_INVALID", error.localizedDescription, error);
                } else {
                    resolve([vcc getSettings]);
                }
            }
        } else {
            RCTLogWarn(@"mediaStreamTrackApplyConstraints() track is not video");
            reject(@"E_INVALID", @"Can't apply constraints on audio tracks", nil);
        }
    } else {
        RCTLogWarn(@"mediaStreamTrackApplyConstraints() track is null");
        reject(@"E_INVALID", @"Could not get track", nil);
    }
#endif
}

RCT_EXPORT_METHOD(mediaStreamTrackSetVolume : (nonnull NSNumber *)pcId : (nonnull NSString *)trackID : (double)volume) {
    RTCMediaStreamTrack *track = [self trackForId:trackID pcId:pcId];
    if (track && [track.kind isEqualToString:@"audio"]) {
        RTCAudioTrack *audioTrack = (RTCAudioTrack *)track;
        audioTrack.source.volume = volume;
    }
}

RCT_EXPORT_METHOD(mediaStreamTrackSetVideoEffects : (nonnull NSString *)trackID names : (nonnull NSArray<NSString *> *)
                      names) {
    RTCMediaStreamTrack *track = self.localTracks[trackID];
    if (track == nil) {
        return;
    }

    RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
    RTCVideoSource *videoSource = videoTrack.source;

    NSMutableArray *processors = [[NSMutableArray alloc] init];
    for (NSString *name in names) {
        NSObject<VideoFrameProcessorDelegate> *processor = [ProcessorProvider getProcessor:name];
        if (processor != nil) {
            [processors addObject:processor];
        }
    }

    self.videoEffectProcessor = [[VideoEffectProcessor alloc] initWithProcessors:processors videoSource:videoSource];

    VideoCaptureController *vcc = (VideoCaptureController *)videoTrack.captureController;
    RTCVideoCapturer *capturer = vcc.capturer;

    capturer.delegate = self.videoEffectProcessor;
}

#pragma mark - Helpers

- (RTCMediaStreamTrack *)trackForId:(nonnull NSString *)trackId pcId:(nonnull NSNumber *)pcId {
    if ([pcId isEqualToNumber:[NSNumber numberWithInt:-1]]) {
        return self.localTracks[trackId];
    }

    RTCPeerConnection *peerConnection = self.peerConnections[pcId];
    if (peerConnection == nil) {
        return nil;
    }

    return peerConnection.remoteTracks[trackId];
}

@end
