#import <objc/runtime.h>

#import <React/RCTBridge.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTLog.h>

#import "WebRTCModule.h"

@implementation WebRTCModule (RTCAudioSession)

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioSessionDidActivate) {
    [[RTCAudioSession sharedInstance] audioSessionDidActivate:[AVAudioSession sharedInstance]];
    return nil;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioSessionDidDeactivate) {
    [[RTCAudioSession sharedInstance] audioSessionDidDeactivate:[AVAudioSession sharedInstance]];
    return nil;
}

#pragma mark - Microphone state -> local audio track `muted`

/**
 * Flip every local audio track's `muted` when the microphone stops or resumes delivering.
 *
 * WHY: a local audio track otherwise stays `live`, `enabled`, `muted: false` for its whole life
 * whatever the audio unit does. In manual-audio mode the device module marks itself recording
 * before the voice-processing unit has started, and when that start fails, or an interruption
 * or media-server loss stops it, nothing reached JS -- the app believed it had a microphone and
 * the far end heard silence. W3C `muted` means exactly "temporarily unable to provide data".
 *
 * CONSERVATIVE BY DESIGN: `muted` starts NO and flips only on a real failure or interruption;
 * "audio not enabled yet" is not modelled, so an ordinary call sees no events. Delegates fire
 * on whatever thread the session notified from; the track registry is workerQueue-confined,
 * so the fan-out hops there. The event carries no pcId, which is what marks it LOCAL for
 * MediaStreamTrack's listener (RTCPeerConnection's ignores it).
 */
- (void)setMicCaptureFailed:(BOOL)failed reason:(NSString *)reason {
    dispatch_async(self.workerQueue, ^{
        if (self.micCaptureMuted == failed) {
            return;
        }
        self.micCaptureMuted = failed;
        if (failed) {
            RCTLogWarn(@"[WebRTCModule] microphone capture failed (%@); local audio tracks are muted until it recovers",
                       reason);
        } else {
            RCTLogInfo(@"[WebRTCModule] microphone capture recovered (%@); local audio tracks un-muted", reason);
        }
        for (RTCMediaStreamTrack *track in self.localTracks.allValues) {
            if (![track.kind isEqualToString:kRTCMediaStreamTrackKindAudio]) {
                continue;
            }
            [self sendEventWithName:kEventMediaStreamTrackMuteChanged
                               body:@{@"trackId" : track.trackId, @"muted" : @(failed)}];
        }
    });
}

- (void)audioSession:(RTCAudioSession *)audioSession audioUnitStartFailedWithError:(NSError *)error {
    [self setMicCaptureFailed:YES reason:[NSString stringWithFormat:@"audio unit start failed: %@", error]];
}

- (void)audioSessionDidBeginInterruption:(RTCAudioSession *)session {
    [self setMicCaptureFailed:YES reason:@"interruption began"];
}

- (void)audioSessionDidEndInterruption:(RTCAudioSession *)session shouldResumeSession:(BOOL)shouldResumeSession {
    // Optimistic: the device module restarts its unit on this notification, and a failure to
    // do so arrives as audioUnitStartFailedWithError and mutes again.
    [self setMicCaptureFailed:NO reason:@"interruption ended"];
}

- (void)audioSessionMediaServerTerminated:(RTCAudioSession *)session {
    [self setMicCaptureFailed:YES reason:@"media server terminated"];
}

- (void)audioSession:(RTCAudioSession *)session didChangeCanPlayOrRecord:(BOOL)canPlayOrRecord {
    // Manual audio mode: the app enabling audio is what starts the unit. A start that then
    // fails reports itself through audioUnitStartFailedWithError.
    if (canPlayOrRecord) {
        [self setMicCaptureFailed:NO reason:@"audio enabled"];
    }
}

- (void)audioSessionDidStartPlayOrRecord:(RTCAudioSession *)session {
    [self setMicCaptureFailed:NO reason:@"audio session started"];
}

@end
