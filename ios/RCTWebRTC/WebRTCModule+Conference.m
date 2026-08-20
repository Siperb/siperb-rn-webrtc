#import <React/RCTLog.h>
#import <WebRTC/WebRTC.h>

#import "SiperbConferenceMixManager.h"
#import "WebRTCModule+RTCPeerConnection.h"
#import "WebRTCModule.h"

/**
 * The JS-facing conference surface, mirroring Android's method-for-method.
 *
 * `conferenceAttachLeg` is also the CAPABILITY PROBE: installPhoneGlobals only installs
 * phone.BuildConferenceMix when this method exists, so a host without it refuses with a
 * reason instead of failing three frames deep inside a merge.
 */
@interface WebRTCModule (Conference)
@end

@implementation WebRTCModule (Conference)

/**
 * The factory a conference leg must be built on, resolved from peerConnectionInit.
 *
 * Overrides the spike's version of the same selector once both are present; only one of the
 * two categories ships at a time.
 */
- (RTCPeerConnectionFactory *)conferenceFactoryForLeg:(NSString *)legId {
    return [[SiperbConferenceMixManager sharedManager] factoryForLeg:legId
                                                      encoderFactory:self.encoderFactory
                                                      decoderFactory:self.decoderFactory];
}

RCT_EXPORT_METHOD(conferenceAttachLeg : (nonnull NSNumber *)pcId legId : (NSString *)legId host : (BOOL)
                      host resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
    RTCPeerConnection *peerConnection = self.peerConnections[pcId];
    if (peerConnection == nil) {
        reject(@"no_peerconnection", [NSString stringWithFormat:@"No peer connection %@", pcId], nil);
        return;
    }

    NSMutableArray<RTCAudioTrack *> *remote = [NSMutableArray new];
    for (RTCMediaStreamTrack *track in peerConnection.remoteTracks.allValues) {
        if ([track.kind isEqualToString:kRTCMediaStreamTrackKindAudio]) {
            [remote addObject:(RTCAudioTrack *)track];
        }
    }

    [[SiperbConferenceMixManager sharedManager] attachLeg:legId remoteTracks:remote host:host];
    resolve(@YES);
}

/**
 * Give a synthesised leg a local audio track FROM ITS OWN FACTORY.
 *
 * Not getUserMedia, which always builds on the app's single factory: a track from the wrong
 * factory does not fail loudly, it silently sends the wrong audio.
 */
RCT_EXPORT_METHOD(conferenceAttachLegAudio : (nonnull NSNumber *)pcId legId : (NSString *)
                      legId resolver : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
    RTCPeerConnectionFactory *factory = [self conferenceFactoryForLeg:legId];
    if (factory == nil) {
        reject(@"no_leg_factory", [NSString stringWithFormat:@"No factory for leg %@", legId], nil);
        return;
    }
    RTCPeerConnection *peerConnection = self.peerConnections[pcId];
    if (peerConnection == nil) {
        reject(@"no_peerconnection", [NSString stringWithFormat:@"No peer connection %@", pcId], nil);
        return;
    }

    dispatch_sync(self.workerQueue, ^{
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                                                                optionalConstraints:nil];
        RTCAudioSource *source = [factory audioSourceWithConstraints:constraints];
        RTCAudioTrack *track =
            [factory audioTrackWithSource:source
                                  trackId:[NSString stringWithFormat:@"conference-%@", legId]];
        [peerConnection addTrack:track
                       streamIds:@[ [NSString stringWithFormat:@"conference-%@", legId] ]];
    });
    resolve(@YES);
}

RCT_EXPORT_METHOD(conferenceDetachLeg : (NSString *)legId resolver : (RCTPromiseResolveBlock)
                      resolve rejecter : (RCTPromiseRejectBlock)reject) {
    [[SiperbConferenceMixManager sharedManager] detachLeg:legId];
    resolve(@YES);
}

RCT_EXPORT_METHOD(conferenceTeardown : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
    [[SiperbConferenceMixManager sharedManager] teardown];
    resolve(@YES);
}

/**
 * Mute inside a conference.
 *
 * On the bus rather than the sender track, because in a conference that track is the MIX -
 * muting it would mute everyone.
 */
RCT_EXPORT_METHOD(conferenceSetMicMuted : (BOOL)muted resolver : (RCTPromiseResolveBlock)
                      resolve rejecter : (RCTPromiseRejectBlock)reject) {
    [[SiperbConferenceMixManager sharedManager] setMicMuted:muted];
    resolve(@YES);
}

RCT_EXPORT_METHOD(conferenceGetLegs : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
    resolve([[SiperbConferenceMixManager sharedManager] legIds]);
}

@end
