#import "CallVideoSink.h"

#import "CallVideoRecorder.h"

@implementation CallVideoSink {
    // Weak, for the same reason RemoteAudioSink holds its recorder weakly: the manager owns
    // both, and a strong back-reference would cycle recorder -> sink -> recorder and keep the
    // encoder alive past stop.
    __weak CallVideoRecorder *_recorder;
}

- (instancetype)initWithTrack:(RTCVideoTrack *)track recorder:(CallVideoRecorder *)recorder slot:(NSInteger)slot {
    self = [super init];
    if (self) {
        _track = track;
        _recorder = recorder;
        _slot = slot;
    }
    return self;
}

/**
 * Required by RTCVideoRenderer and deliberately empty. It reports the SOURCE's dimensions,
 * which this sink has no use for: the output size is fixed by the recording settings and every
 * frame is scaled to fill its slot, so a source that changes resolution mid-call (WebRTC does
 * this under congestion) needs no handling here at all.
 */
- (void)setSize:(CGSize)size {
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    [_recorder submitFrame:frame forSlot:_slot];
}

@end
