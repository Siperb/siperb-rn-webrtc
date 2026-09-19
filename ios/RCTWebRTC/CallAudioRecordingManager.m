#import <os/lock.h>

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <React/RCTLog.h>

#import "CallAudioRecorder.h"
#import "CallAudioRecordingManager.h"
#import "CallVideoRecorder.h"
#import "CallVideoSink.h"
#import "RemoteAudioSink.h"

/** Slot index for the local/presentation source. Must match CallVideoRecorder.m's kLocalSlot. */
static const NSInteger kLocalVideoSlot = -1;

/**
 * Stamps what the file ACTUALLY is onto a recorder's result.
 *
 * Every stop path goes through here so the two fields cannot be forgotten on one of them —
 * and they are the whole point of the contract: a caller must never infer a file's contents
 * from the recording it asked for. A video segment that lost its picture reports NO here and
 * hands back its .m4a, which is the honest answer rather than the requested one.
 */
/**
 * A poster frame for a recorded mp4, as a `data:image/jpeg;base64,…` data URL, or nil.
 *
 * A DATA URL, not a `file://` path, because the recording row it ends up on is replicated
 * across the user's devices — a device-local path would render broken everywhere else. It is
 * generated from the FINALIZED file (off the encoder hot path) with AVAssetImageGenerator, and
 * JPEG-encoded with CoreImage's CIContext so no ImageIO/UIKit framework is pulled in. Scaled to
 * 320px so the string stays small enough to ride on the synced row. Best-effort: a nil here just
 * means no poster, never a failed recording.
 */
static NSString *SiperbVideoPosterDataURL(NSString *path) {
    if (path.length == 0) {
        return nil;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;  // honour the recording's rotation
    generator.maximumSize = CGSizeMake(320, 320);
    // Grab the nearest available frame to the start rather than demanding an exact t=0 keyframe.
    generator.requestedTimeToleranceBefore = kCMTimePositiveInfinity;
    generator.requestedTimeToleranceAfter = kCMTimePositiveInfinity;

    NSError *error = nil;
    CGImageRef cgImage = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];
    if (cgImage == NULL) {
        RCTLogWarn(@"[CallRecording] poster generation failed: %@", error.localizedDescription ?: @"unknown");
        return nil;
    }

    static CIContext *ciContext = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ciContext = [CIContext contextWithOptions:nil];
    });

    CIImage *ciImage = [CIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSData *jpeg = [ciContext JPEGRepresentationOfImage:ciImage
                                            colorSpace:colorSpace
                                               options:@{}];
    CGColorSpaceRelease(colorSpace);
    if (jpeg.length == 0) {
        return nil;
    }
    NSString *base64 = [jpeg base64EncodedStringWithOptions:0];
    if (base64.length == 0) {
        return nil;
    }
    return [@"data:image/jpeg;base64," stringByAppendingString:base64];
}

static NSDictionary *AnnotateResult(NSDictionary *result, BOOL withVideo) {
    if (result == nil) {
        return nil;
    }
    NSMutableDictionary *annotated = [result mutableCopy];
    annotated[@"withVideo"] = @(withVideo);
    annotated[@"mimeType"] = withVideo ? @"video/mp4" : @"audio/mp4";
    // The web builds its poster from the compositor canvas; a DOM-less host has none, so the
    // recording's thumbnail is generated here from the finalized mp4 and handed up in the stop
    // result (JS RecordingBlob.thumbnail -> the SDK's recording.Thumbnail). Video segments only.
    if (withVideo) {
        NSString *poster = SiperbVideoPosterDataURL(annotated[@"filePath"]);
        if (poster.length > 0) {
            annotated[@"thumbnail"] = poster;
        }
    }
    return annotated;
}

@implementation CallAudioRecordingManager {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, CallAudioRecorder *> *_recorders;
    NSMutableDictionary<NSString *, NSArray<RemoteAudioSink *> *> *_sinks;
    // Video is a PARALLEL registry keyed by the same id rather than fields on the audio
    // recorder: most segments have no video, and an audio recorder that knows what an mp4 is
    // would carry the concept into every audio-only call for nothing.
    NSMutableDictionary<NSString *, CallVideoRecorder *> *_videoRecorders;
    NSMutableDictionary<NSString *, NSArray<CallVideoSink *> *> *_videoSinks;
}

+ (instancetype)sharedManager {
    static CallAudioRecordingManager *sharedManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[CallAudioRecordingManager alloc] init];
    });
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _recorders = [NSMutableDictionary new];
        _sinks = [NSMutableDictionary new];
        _videoRecorders = [NSMutableDictionary new];
        _videoSinks = [NSMutableDictionary new];
        _micDelegate = [[CallRecordingAudioProcessingDelegate alloc] init];
    }
    return self;
}

- (NSArray<NSString *> *)activeRecordingIds {
    os_unfair_lock_lock(&_lock);
    NSArray<NSString *> *ids = _recorders.allKeys;
    os_unfair_lock_unlock(&_lock);
    return ids;
}

- (BOOL)isRecordingActive:(NSString *)recordingId {
    os_unfair_lock_lock(&_lock);
    BOOL active = recordingId != nil && _recorders[recordingId] != nil;
    os_unfair_lock_unlock(&_lock);
    return active;
}

- (BOOL)isWavPathActive:(NSString *)wavPath {
    BOOL active = NO;
    os_unfair_lock_lock(&_lock);
    for (CallAudioRecorder *recorder in _recorders.allValues) {
        if ([recorder.wavPath isEqualToString:wavPath]) {
            active = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&_lock);
    return active;
}

/** Must be called with _lock held. */
- (void)refreshMicFanoutLocked {
    NSMutableArray<CallAudioRecorder *> *micRecorders = [NSMutableArray new];
    for (CallAudioRecorder *recorder in _recorders.allValues) {
        if (recorder.includesMic) {
            [micRecorders addObject:recorder];
        }
    }
    _micDelegate.micRecorders = micRecorders;
}

- (BOOL)startRecordingWithId:(NSString *)recordingId
                     wavPath:(NSString *)wavPath
                  outputPath:(NSString *)outputPath
                  includeMic:(BOOL)includeMic
                      stereo:(BOOL)stereo
                remoteTracks:(NSArray<RTCAudioTrack *> *)remoteTracks
                 videoConfig:(CallVideoRecordingConfig *)videoConfig
                       error:(NSError **)error {
    if ([self isRecordingActive:recordingId]) {
        if (error) {
            *error = [NSError errorWithDomain:kCallRecordingErrorDomain
                                         code:CallRecordingErrorDuplicate
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : [NSString
                                             stringWithFormat:@"Recording %@ is already active", recordingId]
                                     }];
        }
        return NO;
    }

    // The WAV is written for every segment, video or not — it is the only crash-recoverable
    // copy, because an mp4's moov atom is not written until stop. On a video segment the audio
    // is therefore written twice, deliberately.
    //
    // m4aPath is the AUDIO output. On a video segment the mp4 is the artifact and this .m4a is
    // never finalized on the happy path — but it is exactly what the fallback needs when the
    // video leg dies mid-call, so it is derived here rather than left nil.
    NSString *audioPath = videoConfig ? [[outputPath stringByDeletingPathExtension]
                                            stringByAppendingPathExtension:@"m4a"]
                                      : outputPath;

    CallAudioRecorder *recorder = [[CallAudioRecorder alloc] initWithRecordingId:recordingId
                                                                         wavPath:wavPath
                                                                         m4aPath:audioPath
                                                                     includesMic:includeMic
                                                                          stereo:stereo
                                                               remoteSourceCount:remoteTracks.count];

    // Built and started BEFORE the audio recorder, so the pcmTap is in place before the first
    // 10 ms tick fires and the mp4 does not start with a hole where its first frames of audio
    // should be.
    CallVideoRecorder *videoRecorder = nil;
    NSMutableArray<CallVideoSink *> *videoSinks = [NSMutableArray new];
    if (videoConfig) {
        NSError *videoError = nil;
        CallVideoRecorder *candidate = [[CallVideoRecorder alloc] initWithOutputPath:outputPath
                                                                             config:videoConfig
                                                                             stereo:stereo];
        if ([candidate start:&videoError]) {
            videoRecorder = candidate;
            __weak CallVideoRecorder *weakVideo = candidate;
            recorder.pcmTap = ^(const int16_t *samples, NSUInteger count) {
                [weakVideo appendAudioTick:samples count:count];
            };
            if (videoConfig.localTrack) {
                [videoSinks addObject:[[CallVideoSink alloc] initWithTrack:videoConfig.localTrack
                                                                 recorder:candidate
                                                                     slot:kLocalVideoSlot]];
            }
            for (NSUInteger i = 0; i < videoConfig.remoteTracks.count; i++) {
                [videoSinks addObject:[[CallVideoSink alloc] initWithTrack:videoConfig.remoteTracks[i]
                                                                 recorder:candidate
                                                                     slot:(NSInteger)i]];
            }
        } else {
            // DEGRADE, DO NOT FAIL. The caller asked for video and is getting audio; stop will
            // report withVideo NO and the file will be the .m4a. Failing here would throw away
            // a perfectly recordable call because its picture could not be encoded.
            RCTLogWarn(@"[CallRecording] video leg failed to start for %@ (%@) — recording audio only",
                       recordingId, videoError.localizedDescription ?: @"unknown");
        }
    }

    if (![recorder start:error]) {
        [videoRecorder stopWithCompletion:^(NSDictionary *result, NSError *stopError){
            // Nothing to report: the segment never began, so there is no row to reconcile.
        }];
        return NO;
    }

    NSMutableArray<RemoteAudioSink *> *sinks = [NSMutableArray arrayWithCapacity:remoteTracks.count];
    for (NSUInteger i = 0; i < remoteTracks.count; i++) {
        [sinks addObject:[[RemoteAudioSink alloc] initWithTrack:remoteTracks[i] recorder:recorder sourceIndex:i]];
    }

    os_unfair_lock_lock(&_lock);
    _recorders[recordingId] = recorder;
    _sinks[recordingId] = [sinks copy];
    if (videoRecorder) {
        _videoRecorders[recordingId] = videoRecorder;
        _videoSinks[recordingId] = [videoSinks copy];
    }
    [self refreshMicFanoutLocked];
    os_unfair_lock_unlock(&_lock);

    // Attach after registering; the recorder's warmup covers the sub-millisecond gap.
    for (RemoteAudioSink *sink in sinks) {
        [sink.track addRenderer:sink];
    }
    for (CallVideoSink *sink in videoSinks) {
        [sink.track addRenderer:sink];
    }
    return YES;
}

- (void)updateVideoSources:(NSString *)recordingId
                localTrack:(RTCVideoTrack *)localTrack
              remoteTracks:(NSArray<RTCVideoTrack *> *)remoteTracks {
    os_unfair_lock_lock(&_lock);
    CallVideoRecorder *videoRecorder = recordingId != nil ? _videoRecorders[recordingId] : nil;
    NSArray<CallVideoSink *> *previous = recordingId != nil ? _videoSinks[recordingId] : nil;
    os_unfair_lock_unlock(&_lock);
    if (videoRecorder == nil) {
        return;  // audio-only segment, or unknown id — a no-op by contract
    }

    NSMutableArray<CallVideoSink *> *replacements = [NSMutableArray new];
    if (localTrack) {
        [replacements addObject:[[CallVideoSink alloc] initWithTrack:localTrack
                                                           recorder:videoRecorder
                                                               slot:kLocalVideoSlot]];
    }
    for (NSUInteger i = 0; i < remoteTracks.count; i++) {
        [replacements addObject:[[CallVideoSink alloc] initWithTrack:remoteTracks[i]
                                                           recorder:videoRecorder
                                                               slot:(NSInteger)i]];
    }

    os_unfair_lock_lock(&_lock);
    _videoSinks[recordingId] = [replacements copy];
    os_unfair_lock_unlock(&_lock);

    // Detach the old set first, then clear any slot the new set does not cover, then attach.
    // CLEARING MATTERS: a slot keeps its last frame forever otherwise, so dropping the camera
    // would freeze its final picture into the recording rather than going black.
    for (CallVideoSink *sink in previous) {
        [sink.track removeRenderer:sink];
    }
    if (localTrack == nil) {
        [videoRecorder clearSlot:kLocalVideoSlot];
    }
    for (NSInteger slot = (NSInteger)remoteTracks.count; slot < (NSInteger)previous.count; slot++) {
        [videoRecorder clearSlot:slot];
    }
    for (CallVideoSink *sink in replacements) {
        [sink.track addRenderer:sink];
    }
}

- (BOOL)stopRecording:(NSString *)recordingId
           completion:(void (^)(NSDictionary *result, NSError *error))completion {
    os_unfair_lock_lock(&_lock);
    CallAudioRecorder *recorder = recordingId != nil ? _recorders[recordingId] : nil;
    NSArray<RemoteAudioSink *> *sinks = nil;
    CallVideoRecorder *videoRecorder = nil;
    NSArray<CallVideoSink *> *videoSinks = nil;
    if (recorder != nil) {
        [_recorders removeObjectForKey:recordingId];
        sinks = _sinks[recordingId];
        [_sinks removeObjectForKey:recordingId];
        videoRecorder = _videoRecorders[recordingId];
        videoSinks = _videoSinks[recordingId];
        [_videoRecorders removeObjectForKey:recordingId];
        [_videoSinks removeObjectForKey:recordingId];
        [self refreshMicFanoutLocked];
    }
    os_unfair_lock_unlock(&_lock);
    if (recorder == nil) {
        return NO;
    }
    // Detach before stop so the drain inside stopWithCompletion can terminate.
    for (RemoteAudioSink *sink in sinks) {
        [sink.track removeRenderer:sink];
    }
    for (CallVideoSink *sink in videoSinks) {
        [sink.track removeRenderer:sink];
    }

    // AUDIO-ONLY: unchanged, and the common case. The result gains the two descriptive fields
    // so every caller reads the same shape whichever leg produced the file.
    if (videoRecorder == nil) {
        recorder.pcmTap = nil;
        [recorder stopWithCompletion:^(NSDictionary *result, NSError *error) {
            completion(AnnotateResult(result, NO), error);
        }];
        return YES;
    }

    // VIDEO: stop the mp4 FIRST, because whether it produced anything decides which file this
    // segment is. Only then stop the audio recorder — its .m4a is the fallback and is finalized
    // either way, since the WAV has to be closed and encoded regardless of what the video did.
    [videoRecorder stopWithCompletion:^(NSDictionary *videoResult, NSError *videoError) {
        recorder.pcmTap = nil;
        [recorder stopWithCompletion:^(NSDictionary *audioResult, NSError *audioError) {
            if (videoResult != nil) {
                // The mp4 carries the audio too, so the .m4a beside it is now redundant —
                // delete it rather than leave a second copy of every video call on the disk.
                if (audioResult[@"filePath"]) {
                    [[NSFileManager defaultManager] removeItemAtPath:audioResult[@"filePath"] error:nil];
                }
                completion(AnnotateResult(videoResult, YES), nil);
                return;
            }
            RCTLogWarn(@"[CallRecording] %@ requested video and produced none (%@) — reporting the audio file",
                       recordingId, videoError.localizedDescription ?: @"unknown");
            completion(AnnotateResult(audioResult, NO), audioError);
        }];
    }];
    return YES;
}

- (void)detachSinksForTrack:(RTCMediaStreamTrack *)track {
    NSMutableArray<RemoteAudioSink *> *audioMatches = [NSMutableArray new];
    NSMutableArray<CallVideoSink *> *videoMatches = [NSMutableArray new];
    os_unfair_lock_lock(&_lock);
    for (NSArray<RemoteAudioSink *> *sinks in _sinks.allValues) {
        for (RemoteAudioSink *sink in sinks) {
            if (sink.track == track) {
                [audioMatches addObject:sink];
            }
        }
    }
    for (NSArray<CallVideoSink *> *sinks in _videoSinks.allValues) {
        for (CallVideoSink *sink in sinks) {
            if (sink.track == track) {
                [videoMatches addObject:sink];
            }
        }
    }
    os_unfair_lock_unlock(&_lock);
    // The sinks stay registered; stop's removeRenderer on an already-detached sink is a no-op.
    for (RemoteAudioSink *sink in audioMatches) {
        [sink.track removeRenderer:sink];
    }
    for (CallVideoSink *sink in videoMatches) {
        [sink.track removeRenderer:sink];
    }
}

@end
