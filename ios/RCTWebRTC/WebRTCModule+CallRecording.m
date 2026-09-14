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
 * Resolves a remote track id, trying the hinted peer connections first and then all of them
 * (same lookup as trackForId:pcId:, remote side only). Runs on the module's workerQueue like
 * every other method touching self.peerConnections.
 */
- (RTCMediaStreamTrack *)remoteTrackForRecording:(NSString *)trackId
                                           hints:(NSArray<NSNumber *> *)peerConnectionIds {
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
    return track;
}

- (RTCAudioTrack *)audioTrackForRecording:(NSString *)trackId hints:(NSArray<NSNumber *> *)peerConnectionIds {
    RTCMediaStreamTrack *track = [self remoteTrackForRecording:trackId hints:peerConnectionIds];
    return [track isKindOfClass:[RTCAudioTrack class]] ? (RTCAudioTrack *)track : nil;
}

- (RTCVideoTrack *)videoTrackForRecording:(NSString *)trackId hints:(NSArray<NSNumber *> *)peerConnectionIds {
    RTCMediaStreamTrack *track = [self remoteTrackForRecording:trackId hints:peerConnectionIds];
    return [track isKindOfClass:[RTCVideoTrack class]] ? (RTCVideoTrack *)track : nil;
}

/**
 * Builds the video config from the JS `video` block, or nil for an audio-only segment.
 *
 * RESOLVES NOTHING IS NOT AN ERROR. A camera that is off and a remote that has not started
 * sending both land here with no tracks, and the honest outcome is an audio recording that
 * SAYS it has no video — not a refused segment. Only a `video` block on a build that cannot
 * encode is a failure, and JS has `supportsVideo` to avoid asking.
 */
- (CallVideoRecordingConfig *)videoConfigFromOptions:(NSDictionary *)video {
    if (![video isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSArray<NSNumber *> *pcHints = [RCTConvert NSNumberArray:video[@"peerConnectionIds"]];

    CallVideoRecordingConfig *config = [CallVideoRecordingConfig new];
    config.width = [RCTConvert NSInteger:video[@"width"]];
    config.height = [RCTConvert NSInteger:video[@"height"]];
    config.fps = [RCTConvert NSInteger:video[@"fps"]];
    config.pnpSize = [RCTConvert NSInteger:video[@"pnpSize"]];
    config.layout = CallVideoLayoutFromString([RCTConvert NSString:video[@"layout"]]);

    // The local camera / presentation track is a LOCAL track, so it is not in any peer
    // connection's remoteTracks — self.localTracks is the only place it lives.
    NSString *localId = [RCTConvert NSString:video[@"localTrackId"]];
    if (localId.length > 0) {
        RTCMediaStreamTrack *local = self.localTracks[localId];
        if ([local isKindOfClass:[RTCVideoTrack class]]) {
            config.localTrack = (RTCVideoTrack *)local;
        } else {
            RCTLogWarn(@"[CallRecording] Local video track %@ not found, compositing remote only", localId);
        }
    }

    NSMutableArray<RTCVideoTrack *> *remotes = [NSMutableArray new];
    for (NSString *trackId in [RCTConvert NSStringArray:video[@"remoteTrackIds"]]) {
        RTCVideoTrack *track = [self videoTrackForRecording:trackId hints:pcHints];
        if (track == nil) {
            RCTLogWarn(@"[CallRecording] Remote video track %@ not found, skipping", trackId);
        } else if (![remotes containsObject:track]) {
            [remotes addObject:track];
        }
    }
    config.remoteTracks = remotes;

    if (config.localTrack == nil && remotes.count == 0) {
        RCTLogWarn(@"[CallRecording] video requested but no video track resolved — recording audio only");
        return nil;
    }
    if (config.width <= 0 || config.height <= 0 || config.fps <= 0) {
        RCTLogWarn(@"[CallRecording] video block has no usable geometry (%ldx%ld @%ld) — recording audio only",
                   (long)config.width, (long)config.height, (long)config.fps);
        return nil;
    }
    return config;
}

RCT_EXPORT_METHOD(startCallRecording : (NSDictionary *)options
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject) {
    NSString *recordingId = [RCTConvert NSString:options[@"recordingId"]];
    NSString *wavPath = [RCTConvert NSString:options[@"wavPath"]];
    NSString *outputPath = [RCTConvert NSString:options[@"outputPath"]];
    BOOL includeMic = [RCTConvert BOOL:options[@"includeMic"]];
    // Absent means mono: the caller owns the product decision, and an older caller that
    // never sends the flag keeps the layout it was written against.
    BOOL stereo = [RCTConvert BOOL:options[@"stereo"]];
    NSArray<NSString *> *remoteTrackIds = [RCTConvert NSStringArray:options[@"remoteTrackIds"]];
    NSArray<NSNumber *> *peerConnectionIds = [RCTConvert NSNumberArray:options[@"peerConnectionIds"]];

    // REFUSE THE OLD KEY LOUDLY. `m4aPath` was renamed to `outputPath` when the container
    // stopped being fixed. Accepting it would mean a stale JS bundle silently writing mp4
    // bytes to a path called .m4a — playable by nothing, and traceable to nothing.
    if (outputPath.length == 0 && [RCTConvert NSString:options[@"m4aPath"]].length > 0) {
        reject(@"io_error", @"startCallRecording: `m4aPath` was renamed to `outputPath`; this JS bundle is too old",
               nil);
        return;
    }
    if (recordingId.length == 0) {
        reject(@"io_error", @"startCallRecording requires recordingId", nil);
        return;
    }
    // BOTH OR NEITHER. A caller that owns its files gives both paths; the library's MediaRecorder
    // gives none and records into recordingsDirectory. One of the two on its own is a caller
    // that forgot something, and a recording written half where it expects is worse than a
    // refusal.
    if ((wavPath.length == 0) != (outputPath.length == 0)) {
        reject(@"io_error", @"startCallRecording: give both wavPath and outputPath, or neither", nil);
        return;
    }
    if (wavPath.length == 0) {
        // The id becomes a file name; a path in it would escape the directory.
        if ([recordingId containsString:@"/"] || [recordingId containsString:@".."]) {
            reject(@"io_error", @"startCallRecording: recordingId must not contain '/' or '..'", nil);
            return;
        }
        NSString *dir = [WebRTCModule recordingsDirectory];
        NSError *dirError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&dirError]) {
            reject(@"io_error", [NSString stringWithFormat:@"startCallRecording: could not create %@", dir], dirError);
            return;
        }
        BOOL wantsVideo = [options[@"video"] isKindOfClass:[NSDictionary class]];
        wavPath = [dir stringByAppendingPathComponent:[recordingId stringByAppendingPathExtension:@"wav"]];
        outputPath = [dir stringByAppendingPathComponent:
                              [recordingId stringByAppendingPathExtension:wantsVideo ? @"mp4" : @"m4a"]];
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

    CallVideoRecordingConfig *videoConfig = [self videoConfigFromOptions:options[@"video"]];

    NSError *error = nil;
    if (![manager startRecordingWithId:recordingId
                               wavPath:wavPath
                            outputPath:outputPath
                            includeMic:wantMic
                                stereo:stereo
                          remoteTracks:tracks
                           videoConfig:videoConfig
                                 error:&error]) {
        reject(RejectionCodeForError(error), error.localizedDescription ?: @"Failed to start recording", error);
        return;
    }
    RCTLogInfo(@"[CallRecording] Started %@ (mic: %d, stereo: %d, remote sources: %lu, video: %@)",
               recordingId,
               wantMic,
               stereo,
               (unsigned long)tracks.count,
               videoConfig ? [NSString stringWithFormat:@"%ldx%ld@%ld", (long)videoConfig.width,
                                                        (long)videoConfig.height, (long)videoConfig.fps]
                           : @"no");
    [self sendEventWithName:kEventAudioRecordingStarted
                       body:@{@"recordingId" : recordingId, @"withVideo" : @(videoConfig != nil)}];
    resolve(nil);
}

RCT_EXPORT_METHOD(updateCallRecordingVideoSources : (NSString *)recordingId
                  sources : (NSDictionary *)sources
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject) {
    // NO-OP RATHER THAN REJECT on an unknown id or an audio-only segment — the caller is
    // reporting that its sources changed, not asserting a compositor exists to hear it. The
    // manager makes the same decision; this just resolves whatever it does.
    NSArray<NSNumber *> *pcHints = [RCTConvert NSNumberArray:sources[@"peerConnectionIds"]];

    RTCVideoTrack *localTrack = nil;
    NSString *localId = [RCTConvert NSString:sources[@"localTrackId"]];
    if (localId.length > 0) {
        RTCMediaStreamTrack *local = self.localTracks[localId];
        if ([local isKindOfClass:[RTCVideoTrack class]]) {
            localTrack = (RTCVideoTrack *)local;
        }
    }

    NSMutableArray<RTCVideoTrack *> *remotes = [NSMutableArray new];
    for (NSString *trackId in [RCTConvert NSStringArray:sources[@"remoteTrackIds"]]) {
        RTCVideoTrack *track = [self videoTrackForRecording:trackId hints:pcHints];
        if (track != nil && ![remotes containsObject:track]) {
            [remotes addObject:track];
        }
    }

    [[CallAudioRecordingManager sharedManager] updateVideoSources:recordingId
                                                       localTrack:localTrack
                                                     remoteTracks:remotes];
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
        // ALWAYS audio, by construction: the WAV is the only thing a crash leaves recoverable,
        // so a salvaged video segment comes back as its sound. Stamped rather than left off so
        // the result reads like every other one on this surface.
        NSMutableDictionary *payload = [result mutableCopy];
        payload[@"withVideo"] = @NO;
        payload[@"mimeType"] = @"audio/mp4";
        resolve(payload);
    });
}

@end
