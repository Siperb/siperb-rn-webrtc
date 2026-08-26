#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

@class CallVideoRecorder;

NS_ASSUME_NONNULL_BEGIN

/**
 * Taps one RTCVideoTrack via the RTCVideoRenderer protocol ([track addRenderer:]) and hands
 * each frame to its recorder's slot. The video counterpart of RemoteAudioSink, attached and
 * detached by CallAudioRecordingManager.
 *
 * Same shape as the TrackMuteDetector in WebRTCModule+VideoTrackAdapter.m, which is already an
 * RTCVideoRenderer attached to a live track for a non-display purpose — a renderer is how you
 * observe a track on this SDK, whether or not you intend to draw it.
 */
@interface CallVideoSink : NSObject <RTCVideoRenderer>

/** Retained so the manager can detach ([track removeRenderer:]) at stop or track teardown. */
@property(nonatomic, strong, readonly) RTCVideoTrack *track;

/** -1 for the local/presentation source, 0..n for remotes. */
@property(nonatomic, readonly) NSInteger slot;

- (instancetype)initWithTrack:(RTCVideoTrack *)track recorder:(CallVideoRecorder *)recorder slot:(NSInteger)slot;

@end

NS_ASSUME_NONNULL_END
