#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

@class CallAudioRecorder;

/**
 * Shared mic tap: installed once as the capturePostProcessingDelegate of the factory's
 * RTCDefaultAudioProcessingModule, so it sees post-AEC capture audio. It fans each 10 ms
 * frame out to every active recorder that wants the mic leg and is a fast no-op when none
 * do. The processing module holds this delegate weakly — CallAudioRecordingManager owns it.
 */
@interface CallRecordingAudioProcessingDelegate : NSObject<RTCAudioCustomProcessingDelegate>

/** Recorders currently wanting mic audio; the manager swaps in an immutable snapshot on start/stop. */
@property(atomic, copy) NSArray<CallAudioRecorder *> *micRecorders;

@end
