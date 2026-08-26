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
 * Nothing here may touch UIKit — requiresMainQueueSetup is NO above.
 */
- (NSDictionary *)constantsToExport {
    return @{@"callRecordingSupportsVideo" : @YES};
}

- (void)dealloc {
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
        kEventAudioRecordingError
    ];
}

@end
