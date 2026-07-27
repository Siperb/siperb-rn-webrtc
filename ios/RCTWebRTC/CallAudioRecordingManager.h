#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

#import "CallRecordingAudioProcessingDelegate.h"

/**
 * Registry of active call recordings. Owns the shared mic processing delegate (the
 * RTCDefaultAudioProcessingModule only holds it weakly) and, per recording, the
 * RemoteAudioSink taps attached to remote audio tracks.
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
 */
- (BOOL)startRecordingWithId:(NSString *)recordingId
                     wavPath:(NSString *)wavPath
                     m4aPath:(NSString *)m4aPath
                  includeMic:(BOOL)includeMic
                remoteTracks:(NSArray<RTCAudioTrack *> *)remoteTracks
                       error:(NSError **)error;

/**
 * Detaches the recording's sinks and finalizes it (see CallAudioRecorder stopWithCompletion).
 * Returns NO — without invoking the completion — when the id is unknown.
 */
- (BOOL)stopRecording:(NSString *)recordingId
           completion:(void (^)(NSDictionary *result, NSError *error))completion;

/**
 * Safety hook for track teardown: detaches any sinks attached to the track. The affected
 * recordings keep running zero-padded until stopped.
 */
- (void)detachSinksForTrack:(RTCAudioTrack *)track;

@end
