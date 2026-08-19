#import <os/lock.h>

#import "CallAudioRecorder.h"
#import "CallAudioRecordingManager.h"
#import "RemoteAudioSink.h"

@implementation CallAudioRecordingManager {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, CallAudioRecorder *> *_recorders;
    NSMutableDictionary<NSString *, NSArray<RemoteAudioSink *> *> *_sinks;
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
                     m4aPath:(NSString *)m4aPath
                  includeMic:(BOOL)includeMic
                      stereo:(BOOL)stereo
                remoteTracks:(NSArray<RTCAudioTrack *> *)remoteTracks
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

    CallAudioRecorder *recorder = [[CallAudioRecorder alloc] initWithRecordingId:recordingId
                                                                         wavPath:wavPath
                                                                         m4aPath:m4aPath
                                                                     includesMic:includeMic
                                                                          stereo:stereo
                                                               remoteSourceCount:remoteTracks.count];
    if (![recorder start:error]) {
        return NO;
    }

    NSMutableArray<RemoteAudioSink *> *sinks = [NSMutableArray arrayWithCapacity:remoteTracks.count];
    for (NSUInteger i = 0; i < remoteTracks.count; i++) {
        [sinks addObject:[[RemoteAudioSink alloc] initWithTrack:remoteTracks[i] recorder:recorder sourceIndex:i]];
    }

    os_unfair_lock_lock(&_lock);
    _recorders[recordingId] = recorder;
    _sinks[recordingId] = [sinks copy];
    [self refreshMicFanoutLocked];
    os_unfair_lock_unlock(&_lock);

    // Attach after registering; the recorder's warmup covers the sub-millisecond gap.
    for (RemoteAudioSink *sink in sinks) {
        [sink.track addRenderer:sink];
    }
    return YES;
}

- (BOOL)stopRecording:(NSString *)recordingId
           completion:(void (^)(NSDictionary *result, NSError *error))completion {
    os_unfair_lock_lock(&_lock);
    CallAudioRecorder *recorder = recordingId != nil ? _recorders[recordingId] : nil;
    NSArray<RemoteAudioSink *> *sinks = nil;
    if (recorder != nil) {
        [_recorders removeObjectForKey:recordingId];
        sinks = _sinks[recordingId];
        [_sinks removeObjectForKey:recordingId];
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
    [recorder stopWithCompletion:completion];
    return YES;
}

- (void)detachSinksForTrack:(RTCAudioTrack *)track {
    NSMutableArray<RemoteAudioSink *> *matches = [NSMutableArray new];
    os_unfair_lock_lock(&_lock);
    for (NSArray<RemoteAudioSink *> *sinks in _sinks.allValues) {
        for (RemoteAudioSink *sink in sinks) {
            if (sink.track == track) {
                [matches addObject:sink];
            }
        }
    }
    os_unfair_lock_unlock(&_lock);
    // The sinks stay registered; stop's removeRenderer on an already-detached sink is a no-op.
    for (RemoteAudioSink *sink in matches) {
        [sink.track removeRenderer:sink];
    }
}

@end
