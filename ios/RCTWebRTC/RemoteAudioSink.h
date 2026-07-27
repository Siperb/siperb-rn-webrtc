#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

@class CallAudioRecorder;

/**
 * Taps one remote RTCAudioTrack via the RTCAudioRenderer protocol ([track addRenderer:])
 * and feeds downmixed mono int16 PCM into one source slot of its recorder. Attached and
 * detached by CallAudioRecordingManager.
 */
@interface RemoteAudioSink : NSObject<RTCAudioRenderer>

/** Retained so the manager can detach ([track removeRenderer:]) at stop or track teardown. */
@property(nonatomic, strong, readonly) RTCAudioTrack *track;

- (instancetype)initWithTrack:(RTCAudioTrack *)track
                     recorder:(CallAudioRecorder *)recorder
                  sourceIndex:(NSUInteger)sourceIndex;

@end
