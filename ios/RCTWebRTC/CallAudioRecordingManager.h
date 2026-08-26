#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

#import "CallRecordingAudioProcessingDelegate.h"
#import "CallVideoRecorder.h"

/**
 * Registry of active call recordings. Owns the shared mic processing delegate (the
 * RTCDefaultAudioProcessingModule only holds it weakly) and, per recording, the
 * RemoteAudioSink taps attached to remote audio tracks — plus, for a video segment, the
 * CallVideoSink taps and the mp4 writer they feed.
 *
 * start/stop are expected on the WebRTCModule worker queue (its methodQueue), which
 * serializes them; the internal lock only shields the registry from the audio threads.
 */
@interface CallAudioRecordingManager : NSObject

+ (instancetype)sharedManager;

/** Installed as capturePostProcessingDelegate on the factory's audio processing module. */
@property(nonatomic, strong, readonly) CallRecordingAudioProcessingDelegate *micDelegate;

/** YES only when the factory was built with our audio processing module (no injected audioDevice). */
@property(nonatomic, assign) BOOL micCaptureAvailable;

- (NSArray<NSString *> *)activeRecordingIds;
- (BOOL)isRecordingActive:(NSString *)recordingId;

/** Guards finalizeOrphanRecording against salvaging a WAV that is still being written. */
- (BOOL)isWavPathActive:(NSString *)wavPath;

/**
 * Creates and starts a recorder, registers it and attaches one RemoteAudioSink per track.
 * includeMic must already be gated on micCaptureAvailable by the caller. NO + error with
 * kCallRecordingErrorDomain code CallRecordingErrorDuplicate or CallRecordingErrorIO.
 *
 * `outputPath` is the finalized container — `.m4a` when videoConfig is nil, `.mp4` when it is
 * not. A nil videoConfig is audio-only and behaves exactly as it did before video existed.
 *
 * A VIDEO LEG THAT WILL NOT START DOES NOT FAIL THE SEGMENT. If the mp4 writer cannot open,
 * the recording continues as audio and stop reports `withVideo` NO — the audio is worth
 * keeping, and that field is what tells the caller which it got.
 */
- (BOOL)startRecordingWithId:(NSString *)recordingId
                     wavPath:(NSString *)wavPath
                  outputPath:(NSString *)outputPath
                  includeMic:(BOOL)includeMic
                      stereo:(BOOL)stereo
                remoteTracks:(NSArray<RTCAudioTrack *> *)remoteTracks
                 videoConfig:(CallVideoRecordingConfig *)videoConfig
                       error:(NSError **)error;

/**
 * Swap the composited video sources mid-segment — the presentation case, where the local slot
 * must follow a screen-share track rather than the camera.
 *
 * A NO-OP on an unknown id or an audio-only segment: the caller is reporting a source change,
 * not asserting that a compositor exists to hear it.
 */
- (void)updateVideoSources:(NSString *)recordingId
                localTrack:(RTCVideoTrack *)localTrack
              remoteTracks:(NSArray<RTCVideoTrack *> *)remoteTracks;

/**
 * Detaches the recording's sinks and finalizes it (see CallAudioRecorder stopWithCompletion).
 * Returns NO — without invoking the completion — when the id is unknown.
 *
 * The result carries `withVideo` and `mimeType` alongside the file. A segment that asked for
 * video and lost it — backgrounded, camera off, writer died — resolves as the audio file it
 * actually produced, so a caller never infers the contents from the request.
 */
- (BOOL)stopRecording:(NSString *)recordingId
           completion:(void (^)(NSDictionary *result, NSError *error))completion;

/**
 * Safety hook for track teardown: detaches any sinks attached to the track, audio or video.
 * The affected recordings keep running — audio zero-padded, video drawing that slot black —
 * until stopped.
 *
 * Takes the BASE track type because both kinds need it for the same reason and a second
 * method would be the same body with one dictionary swapped.
 */
- (void)detachSinksForTrack:(RTCMediaStreamTrack *)track;

@end
