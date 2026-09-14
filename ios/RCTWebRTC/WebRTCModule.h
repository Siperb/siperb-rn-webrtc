#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import <React/RCTBridgeModule.h>
#import <React/RCTConvert.h>
#import <React/RCTEventEmitter.h>

#import <WebRTC/WebRTC.h>

static NSString *const kEventPeerConnectionSignalingStateChanged = @"peerConnectionSignalingStateChanged";
static NSString *const kEventPeerConnectionStateChanged = @"peerConnectionStateChanged";
static NSString *const kEventPeerConnectionOnRenegotiationNeeded = @"peerConnectionOnRenegotiationNeeded";
static NSString *const kEventPeerConnectionIceConnectionChanged = @"peerConnectionIceConnectionChanged";
static NSString *const kEventPeerConnectionIceGatheringChanged = @"peerConnectionIceGatheringChanged";
static NSString *const kEventPeerConnectionGotICECandidate = @"peerConnectionGotICECandidate";
static NSString *const kEventPeerConnectionDidOpenDataChannel = @"peerConnectionDidOpenDataChannel";
static NSString *const kEventDataChannelDidChangeBufferedAmount = @"dataChannelDidChangeBufferedAmount";
static NSString *const kEventDataChannelStateChanged = @"dataChannelStateChanged";
static NSString *const kEventDataChannelReceiveMessage = @"dataChannelReceiveMessage";
static NSString *const kEventMediaStreamTrackMuteChanged = @"mediaStreamTrackMuteChanged";
static NSString *const kEventMediaStreamTrackEnded = @"mediaStreamTrackEnded";
static NSString *const kEventPeerConnectionOnRemoveTrack = @"peerConnectionOnRemoveTrack";
static NSString *const kEventPeerConnectionOnTrack = @"peerConnectionOnTrack";
static NSString *const kEventAudioRecordingStarted = @"audioRecordingStarted";
static NSString *const kEventAudioRecordingStopped = @"audioRecordingStopped";
static NSString *const kEventAudioRecordingError = @"audioRecordingError";

// RTCAudioSessionDelegate: microphone state for local audio tracks, implemented in
// WebRTCModule+RTCAudioSession.m and registered in init.
@interface WebRTCModule : RCTEventEmitter<RCTBridgeModule, RTCAudioSessionDelegate>

@property(nonatomic, strong) dispatch_queue_t workerQueue;

@property(nonatomic, strong) RTCPeerConnectionFactory *peerConnectionFactory;
@property(nonatomic, strong) id<RTCVideoDecoderFactory> decoderFactory;
@property(nonatomic, strong) id<RTCVideoEncoderFactory> encoderFactory;

// Retained because the factory does not own it and it holds the call-recording mic
// delegate weakly; nil when a custom audioDevice was injected via WebRTCModuleOptions.
@property(nonatomic, strong) RTCDefaultAudioProcessingModule *audioProcessingModule;

@property(nonatomic, strong) NSMutableDictionary<NSNumber *, RTCPeerConnection *> *peerConnections;

/**
 * YES while the microphone is known to be failing (audio unit refused to start, interruption
 * in progress, media server gone). Confined to workerQueue. Local audio tracks mirror it as
 * `muted` -- see WebRTCModule+RTCAudioSession.m.
 */
@property(nonatomic, assign) BOOL micCaptureMuted;

/** The factory a conference leg must be built on, or nil for the app's own. */
- (RTCPeerConnectionFactory *)conferenceFactoryForLeg:(NSString *)legId;
@property(nonatomic, strong) NSMutableDictionary<NSString *, RTCMediaStream *> *localStreams;
@property(nonatomic, strong) NSMutableDictionary<NSString *, RTCMediaStreamTrack *> *localTracks;

- (RTCMediaStream *)streamForReactTag:(NSString *)reactTag;

/** Default home of recordings started without paths; also exported as the `recordingsDirectory` constant. */
+ (NSString *)recordingsDirectory;

@end
