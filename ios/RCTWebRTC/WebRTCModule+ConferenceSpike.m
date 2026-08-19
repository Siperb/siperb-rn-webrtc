#import <objc/runtime.h>

#import <React/RCTLog.h>
#import <WebRTC/WebRTC.h>

#import "ConferenceSpike.h"
#import "WebRTCModule+RTCPeerConnection.h"
#import "WebRTCModule.h"

/**
 * PHASE 0 SPIKE test surface, iOS - THROWAWAY. Delete with the branch.
 *
 * A SEPARATE peerConnectionInit rather than a flag on the existing one, because iOS takes a
 * typed RTCConfiguration and RCTConvert+WebRTC drops any key it does not recognise - so
 * unlike Android there is no way to smuggle a selector through the configuration map. A
 * "next PeerConnection uses the other factory" latch would be a race by construction, so
 * the leg is named explicitly at the point of creation instead.
 */
@interface WebRTCModule (ConferenceSpike)
@end

@implementation WebRTCModule (ConferenceSpike)

RCT_EXPORT_METHOD(spikeStart : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
    BOOL ok = [[SiperbConferenceSpike sharedSpike] startWithEncoderFactory:self.encoderFactory
                                                           decoderFactory:self.decoderFactory];
    resolve(@(ok));
}

RCT_EXPORT_METHOD(spikeStop : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
    [[SiperbConferenceSpike sharedSpike] stop];
    resolve(@YES);
}

/** How many times the synthetic capture fired. Zero means the path never ran at all, which
 * is a completely different failure from "ran and was dropped" - the distinction Android's
 * spike turned on. */
RCT_EXPORT_METHOD(spikeCaptureCallbacks : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
    resolve(@([SiperbConferenceSpike sharedSpike].captureCallbacks));
}

/**
 * Create a PeerConnection on the SECOND factory, and give it an audio track from that same
 * factory.
 *
 * Both halves matter. The factory decides which audio device feeds this leg's outbound and
 * is fixed for the life of the connection; a track minted by the wrong factory does not
 * crash, it silently sends the wrong audio.
 */
RCT_EXPORT_METHOD(spikeCreatePeerConnection : (nonnull NSNumber *)objectID resolver : (RCTPromiseResolveBlock)
                      resolve rejecter : (RCTPromiseRejectBlock)reject) {
    RTCPeerConnectionFactory *factory = [SiperbConferenceSpike sharedSpike].syntheticFactory;
    if (factory == nil) {
        reject(@"spike_not_started", @"spikeStart() has not been called", nil);
        return;
    }

    __block BOOL ok = YES;
    dispatch_sync(self.workerQueue, ^{
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                                                                optionalConstraints:nil];
        RTCConfiguration *configuration = [[RTCConfiguration alloc] init];
        configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;

        RTCPeerConnection *peerConnection = [factory peerConnectionWithConfiguration:configuration
                                                                        constraints:constraints
                                                                           delegate:self];
        if (peerConnection == nil) {
            ok = NO;
            return;
        }

        peerConnection.dataChannels = [NSMutableDictionary new];
        peerConnection.reactTag = objectID;
        peerConnection.remoteStreams = [NSMutableDictionary new];
        peerConnection.remoteTracks = [NSMutableDictionary new];
        // No videoTrackAdapters: declared in the video category and irrelevant to an
        // audio-only spike connection.
        peerConnection.webRTCModule = self;
        self.peerConnections[objectID] = peerConnection;

        RTCAudioSource *source = [factory audioSourceWithConstraints:constraints];
        RTCAudioTrack *track = [factory audioTrackWithSource:source trackId:@"spike-synthetic-audio"];
        [peerConnection addTrack:track streamIds:@[ @"spike-stream" ]];
    });

    if (!ok) {
        reject(@"spike_pc_failed", @"Could not create a PeerConnection on the second factory", nil);
        return;
    }
    resolve(@YES);
}

@end
