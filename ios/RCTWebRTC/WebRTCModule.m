#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>

#import "CallAudioRecordingManager.h"
#import "WebRTCModule+RTCPeerConnection.h"
#import "SiperbConferenceMixManager.h"
#import "WebRTCModule.h"
#import "WebRTCModuleOptions.h"

@interface WebRTCModule ()
@end

@implementation WebRTCModule

// RN injects the view registry into a module that synthesizes this property (RCTBridgeModule.h).
// It is how getWhiteboardMedia resolves a React tag to a UIView on BOTH renderers: RCTUIManager's
// addUIBlock registry is Paper-only (a Fabric <View> is never in it) and addUIBlock asserts the
// UIManager queue, which this module's methodQueue is not. Main-queue only.
@synthesize viewRegistry_DEPRECATED = _viewRegistry_DEPRECATED;

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

/**
 * Synchronous capability facts JS can read without a round trip.
 *
 * `callRecordingSupportsVideo` is what CallRecorder.supportsVideo answers from. A CONSTANT
 * rather than a probe on some proxy method, because it states the fact directly: an OTA JS
 * bundle can reach an app binary older than this file, where the key is simply absent and
 * reads as false. Version skew is then handled by construction rather than by a check someone
 * has to remember to write.
 *
 * `displayMediaSupported` is what mediaDevices.supportsDisplayMedia answers from: whether
 * getDisplayMedia() on THIS build can ever deliver a frame. The screen capturer itself always
 * constructs — it opens a socket and waits — so the track alone proves nothing; what decides it
 * is app packaging the JS cannot see (below). False here is the host's cue to withhold
 * getDisplayMedia altogether, so shared code that feature-detects it reads "not supported"
 * instead of presenting a black screen.
 *
 * `supportsFrameSource` is what mediaDevices.supportsFrameSource answers from: whether
 * getWhiteboardMedia()/getPictureMedia() exist on THIS build. Unlike screen share the source is
 * in-process (a rasterised view / decoded image), so there is no extension, App Group, entitlement
 * or Simulator gate — it is simply YES wherever the code is present. The point of the constant is
 * version skew: an OTA JS bundle reaching an older binary reads the absent key as false and the
 * package withholds the builders (publish-or-don't), rather than calling a method that is not there.
 *
 * Nothing here may touch UIKit — requiresMainQueueSetup is NO above.
 */
- (NSDictionary *)constantsToExport {
    return @{
        @"callRecordingSupportsVideo" : @YES,
        @"displayMediaSupported" : @([self isDisplayMediaSupported]),
        @"supportsFrameSource" : @([self isFrameSourceSupported]),
        @"supportsFileSource" : @([self isFrameSourceSupported]),
        @"recordingsDirectory" : [WebRTCModule recordingsDirectory],
    };
}

// In-process view/image capture works on every iOS build (device and Simulator); tvOS/macOS have
// no UIKit view-capture path here. Stated as a method so the constant stays a one-liner and the
// gate lives beside isDisplayMediaSupported.
- (BOOL)isFrameSourceSupported {
#if TARGET_OS_IOS
    return YES;
#else
    return NO;
#endif
}

/**
 * Where a recording started without paths is written. Application Support, not Caches: the OS
 * may evict caches under pressure, and a call recording cannot be regenerated. Reported as a
 * constant so JS can find the files (crash salvage scans it); created lazily by the first
 * recording that needs it (startCallRecording).
 */
+ (NSString *)recordingsDirectory {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:@"siperb-rn-webrtc"] stringByAppendingPathComponent:@"recordings"];
}

/**
 * Everything iOS screen capture needs from the app bundle, checked the way the capture path
 * will use it. Each is a silent failure at capture time and a clear NO here:
 *
 *   - not the Simulator / macOS / tvOS — createScreenCaptureVideoTrack returns nil there;
 *   - `RTCAppGroupIdentifier` in Info.plist — ScreenCaptureController reads the socket path
 *     off it, and without it startCapture returns before listening;
 *   - the App Group ENTITLEMENT, not just the key — containerURLForSecurityApplicationGroup
 *     Identifier: is nil when the app is not entitled, and the socket then has no home;
 *   - `RTCScreenSharingExtension` in Info.plist — the picker's preferredExtension; and
 *   - that extension actually BUNDLED under PlugIns/ as a broadcast-upload appex. The key
 *     alone is a promise; the .appex is the proof.
 *
 * The two Info.plist keys are react-native-webrtc's names (kRTCAppGroupIdentifier in
 * ScreenCaptureController.m, kRTCScreenSharingExtension in ScreenCapturePickerViewManager.m)
 * and must stay in step with them.
 */
- (BOOL)isDisplayMediaSupported {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_OSX || TARGET_OS_TV
    return NO;
#else
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSDictionary *info = mainBundle.infoDictionary;
    NSString *appGroup = info[@"RTCAppGroupIdentifier"];
    NSString *extensionId = info[@"RTCScreenSharingExtension"];
    if (![appGroup isKindOfClass:[NSString class]] || appGroup.length == 0) {
        return NO;
    }
    if (![extensionId isKindOfClass:[NSString class]] || extensionId.length == 0) {
        return NO;
    }
    if ([[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:appGroup] == nil) {
        return NO;
    }

    NSString *plugInsPath = mainBundle.builtInPlugInsPath;
    if (plugInsPath == nil) {
        return NO;
    }
    NSArray<NSString *> *plugIns = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:plugInsPath error:nil];
    for (NSString *name in plugIns) {
        if (![name.pathExtension isEqualToString:@"appex"]) {
            continue;
        }
        NSBundle *appex = [NSBundle bundleWithPath:[plugInsPath stringByAppendingPathComponent:name]];
        if (![appex.bundleIdentifier isEqualToString:extensionId]) {
            continue;
        }
        NSDictionary *extension = appex.infoDictionary[@"NSExtension"];
        NSString *point = [extension isKindOfClass:[NSDictionary class]] ? extension[@"NSExtensionPointIdentifier"] : nil;
        return [point isEqualToString:@"com.apple.broadcast-services-upload"];
    }
    return NO;
#endif
}

- (void)dealloc {
    [[RTCAudioSession sharedInstance] removeDelegate:self];

    [_localTracks removeAllObjects];
    _localTracks = nil;
    [_localStreams removeAllObjects];
    _localStreams = nil;

    for (NSNumber *peerConnectionId in _peerConnections) {
        RTCPeerConnection *peerConnection = _peerConnections[peerConnectionId];
        peerConnection.delegate = nil;
        [peerConnection close];
    }
    [_peerConnections removeAllObjects];

    _peerConnectionFactory = nil;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        WebRTCModuleOptions *options = [WebRTCModuleOptions sharedInstance];
        id<RTCAudioDevice> audioDevice = options.audioDevice;
        id<RTCVideoDecoderFactory> decoderFactory = options.videoDecoderFactory;
        id<RTCVideoEncoderFactory> encoderFactory = options.videoEncoderFactory;
        NSDictionary *fieldTrials = options.fieldTrials;
        RTCLoggingSeverity loggingSeverity = options.loggingSeverity;

        // Initialize field trials.
        if (fieldTrials == nil) {
            // Fix for dual-sim connectivity:
            // https://bugs.chromium.org/p/webrtc/issues/detail?id=10966
            fieldTrials = @{kRTCFieldTrialUseNWPathMonitor : kRTCFieldTrialEnabledValue};
        }
        RTCInitFieldTrialDictionary(fieldTrials);

        // Initialize logging.
        RTCSetMinDebugLogLevel(loggingSeverity);

        if (encoderFactory == nil) {
            encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        }
        if (decoderFactory == nil) {
            decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        }
        _encoderFactory = encoderFactory;
        _decoderFactory = decoderFactory;

        RCTLogInfo(@"Using video encoder factory: %@", NSStringFromClass([encoderFactory class]));
        RCTLogInfo(@"Using video decoder factory: %@", NSStringFromClass([decoderFactory class]));

        if (audioDevice == nil) {
            // Build the factory with an audio processing module so the call recorder can tap
            // post-AEC mic audio. The module holds its capture delegate weakly (the recording
            // manager owns it) and the factory does not retain the module, hence the property.
            CallAudioRecordingManager *recordingManager = [CallAudioRecordingManager sharedManager];
            _audioProcessingModule =
                [[RTCDefaultAudioProcessingModule alloc] initWithConfig:nil
                                          capturePostProcessingDelegate:recordingManager.micDelegate
                                            renderPreProcessingDelegate:nil];
            recordingManager.micCaptureAvailable = YES;
            _peerConnectionFactory =
                [[RTCPeerConnectionFactory alloc] initWithBypassVoiceProcessing:NO
                                                                 encoderFactory:encoderFactory
                                                                 decoderFactory:decoderFactory
                                                          audioProcessingModule:_audioProcessingModule];
        } else {
            // A custom audio device rules out the processing-module initializer, so the call
            // recorder has no mic tap in this configuration (recordings drop the mic leg).
            RCTLogWarn(@"CallRecording: custom audioDevice injected, mic capture for recording is unavailable");
            _peerConnectionFactory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                                               decoderFactory:decoderFactory
                                                                                  audioDevice:audioDevice];
        }

        // Conference audio. Takes over the capture-post slot and CHAINS the recorder's mic
        // tap, which already holds it -- iOS has one delegate slot where Android has two
        // separate hooks. Idle until a leg is attached, so an ordinary 1:1 call is untouched.
        [[SiperbConferenceMixManager sharedManager] installOnAudioProcessingModule:_audioProcessingModule];

        _peerConnections = [NSMutableDictionary new];
        _localStreams = [NSMutableDictionary new];
        _localTracks = [NSMutableDictionary new];

        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -1);
        _workerQueue = dispatch_queue_create("WebRTCModule.queue", attributes);

        // Microphone truth for local audio tracks: the audio device sets `recording` the moment
        // it is asked to record, whether or not the voice-processing unit actually started, so
        // the only signals that capture failed or paused are the session delegate's. Weakly
        // held by RTCAudioSession; removed in dealloc. Handlers in WebRTCModule+RTCAudioSession.
        [[RTCAudioSession sharedInstance] addDelegate:self];
    }

    return self;
}

- (RTCMediaStream *)streamForReactTag:(NSString *)reactTag {
    RTCMediaStream *stream = _localStreams[reactTag];
    if (!stream) {
        for (NSNumber *peerConnectionId in _peerConnections) {
            RTCPeerConnection *peerConnection = _peerConnections[peerConnectionId];
            stream = peerConnection.remoteStreams[reactTag];
            if (stream) {
                break;
            }
        }
    }
    return stream;
}

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue {
    return _workerQueue;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        kEventPeerConnectionSignalingStateChanged,
        kEventPeerConnectionStateChanged,
        kEventPeerConnectionOnRenegotiationNeeded,
        kEventPeerConnectionIceConnectionChanged,
        kEventPeerConnectionIceGatheringChanged,
        kEventPeerConnectionGotICECandidate,
        kEventPeerConnectionDidOpenDataChannel,
        kEventDataChannelDidChangeBufferedAmount,
        kEventDataChannelStateChanged,
        kEventDataChannelReceiveMessage,
        kEventMediaStreamTrackMuteChanged,
        kEventMediaStreamTrackEnded,
        kEventPeerConnectionOnRemoveTrack,
        kEventPeerConnectionOnTrack,
        kEventAudioRecordingStarted,
        kEventAudioRecordingStopped,
        kEventAudioRecordingError,
        kEventFileMedia
    ];
}

@end
