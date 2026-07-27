#import <React/RCTLog.h>

#import "CallAudioRecorder.h"
#import "CallAudioRecordingManager.h"
#import "WebRTCModule+CallRecording.h"
#import "WebRTCModule+RTCPeerConnection.h"

/** Maps a kCallRecordingErrorDomain error to the JS rejection code contract. */
static NSString *RejectionCodeForError(NSError *error) {
    if ([error.domain isEqualToString:kCallRecordingErrorDomain]) {
        switch (error.code) {
            case CallRecordingErrorDuplicate:
                return @"duplicate_id";
            case CallRecordingErrorEncode:
                return @"encode_error";
            default:
                break;
        }
    }
    return @"io_error";
}

@implementation WebRTCModule (CallRecording)

/**
 * Resolves a remote track id to its RTCAudioTrack, trying the hinted peer connections first
 * and then all of them (same lookup as trackForId:pcId:, remote side only). Runs on the
 * module's workerQueue like every other method touching self.peerConnections.
 */
- (RTCAudioTrack *)audioTrackForRecording:(NSString *)trackId hints:(NSArray<NSNumber *> *)peerConnectionIds {
    RTCMediaStreamTrack *track = nil;
    for (NSNumber *peerConnectionId in peerConnectionIds) {
        track = self.peerConnections[peerConnectionId].remoteTracks[trackId];
        if (track != nil) {
            break;
        }
    }
    if (track == nil) {
        for (NSNumber *peerConnectionId in self.peerConnections) {
            track = self.peerConnections[peerConnectionId].remoteTracks[trackId];
            if (track != nil) {
                break;
            }
        }
    }
    if (track == nil || ![track isKindOfClass:[RTCAudioTrack class]]) {
        return nil;
    }
    return (RTCAudioTrack *)track;
}

RCT_EXPORT_METHOD(startCallRecording : (NSDictionary *)options
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject) {
    NSString *recordingId = [RCTConvert NSString:options[@"recordingId"]];
    NSString *wavPath = [RCTConvert NSString:options[@"wavPath"]];
    NSString *m4aPath = [RCTConvert NSString:options[@"m4aPath"]];
    BOOL includeMic = [RCTConvert BOOL:options[@"includeMic"]];
    NSArray<NSString *> *remoteTrackIds = [RCTConvert NSStringArray:options[@"remoteTrackIds"]];
    NSArray<NSNumber *> *peerConnectionIds = [RCTConvert NSNumberArray:options[@"peerConnectionIds"]];
    if (recordingId.length == 0 || wavPath.length == 0 || m4aPath.length == 0) {
        reject(@"io_error", @"recordingId, wavPath and m4aPath are required", nil);
        return;
    }

    CallAudioRecordingManager *manager = [CallAudioRecordingManager sharedManager];
    if ([manager isRecordingActive:recordingId]) {
        reject(@"duplicate_id", [NSString stringWithFormat:@"Recording %@ is already active", recordingId], nil);
        return;
    }

    NSMutableArray<RTCAudioTrack *> *tracks = [NSMutableArray arrayWithCapacity:remoteTrackIds.count];
    for (NSString *trackId in remoteTrackIds) {
        RTCAudioTrack *track = [self audioTrackForRecording:trackId hints:peerConnectionIds];
        if (track == nil) {
            RCTLogWarn(@"[CallRecording] Remote audio track %@ not found, skipping", trackId);
        } else if (![tracks containsObject:track]) {
            [tracks addObject:track];
        }
    }

    BOOL wantMic = includeMic && manager.micCaptureAvailable;
    if (includeMic && !manager.micCaptureAvailable) {
        RCTLogWarn(@"[CallRecording] Mic capture unavailable (custom audioDevice injected); recording without mic");
    }
    if (tracks.count == 0 && !wantMic) {
        reject(@"no_sources", @"No recordable audio sources (no remote tracks resolved, mic unavailable)", nil);
        return;
    }

    NSError *error = nil;
    if (![manager startRecordingWithId:recordingId
                               wavPath:wavPath
                               m4aPath:m4aPath
                            includeMic:wantMic
                          remoteTracks:tracks
                                 error:&error]) {
        reject(RejectionCodeForError(error), error.localizedDescription ?: @"Failed to start recording", error);
        return;
    }
    RCTLogInfo(@"[CallRecording] Started %@ (mic: %d, remote sources: %lu)",
               recordingId,
               wantMic,
               (unsigned long)tracks.count);
    [self sendEventWithName:kEventAudioRecordingStarted body:@{@"recordingId" : recordingId}];
    resolve(nil);
}

RCT_EXPORT_METHOD(stopCallRecording : (NSString *)recordingId
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject) {
    __weak WebRTCModule *weakSelf = self;
    BOOL found = [[CallAudioRecordingManager sharedManager]
        stopRecording:recordingId
           completion:^(NSDictionary *result, NSError *error) {
               // The module can be gone on bridge reload; the file result stands regardless.
               WebRTCModule *module = weakSelf;
               if (error != nil) {
                   RCTLogWarn(@"[CallRecording] Finalize failed for %@ (WAV kept): %@",
                              recordingId,
                              error.localizedDescription);
                   [module sendEventWithName:kEventAudioRecordingError
                                        body:@{
                                            @"recordingId" : recordingId,
                                            @"error" : error.localizedDescription ?: @"encode failed"
                                        }];
                   reject(@"encode_error", error.localizedDescription ?: @"Failed to finalize recording", error);
                   return;
               }
               NSMutableDictionary *payload = [result mutableCopy];
               payload[@"recordingId"] = recordingId;
               NSMutableDictionary *event = [payload mutableCopy];
               event[@"reason"] = @"user";
               [module sendEventWithName:kEventAudioRecordingStopped body:event];
               resolve(payload);
           }];
    if (!found) {
        reject(@"not_found", [NSString stringWithFormat:@"No active recording %@", recordingId], nil);
    }
}

RCT_EXPORT_METHOD(getActiveCallRecordings : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject) {
    resolve([[CallAudioRecordingManager sharedManager] activeRecordingIds]);
}

RCT_EXPORT_METHOD(finalizeOrphanRecording : (NSString *)wavPath
                  m4aPath : (NSString *)m4aPath
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject) {
    if (wavPath.length == 0 || m4aPath.length == 0) {
        reject(@"io_error", @"wavPath and m4aPath are required", nil);
        return;
    }
    if ([[CallAudioRecordingManager sharedManager] isWavPathActive:wavPath]) {
        reject(@"io_error", @"WAV file belongs to an active recording", nil);
        return;
    }
    // Off the workerQueue: salvage + AAC encode must not stall WebRTC signaling calls.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSDictionary *result = [CallAudioRecorder finalizeWavAtPath:wavPath toM4aPath:m4aPath error:&error];
        if (result == nil) {
            reject(RejectionCodeForError(error), error.localizedDescription ?: @"Failed to salvage recording", error);
            return;
        }
        resolve(result);
    });
}

@end
