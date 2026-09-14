#import "TrackCapturerEventsEmitter.h"
#import "CapturerEventsDelegate.h"
#import "WebRTCModule.h"

NS_ASSUME_NONNULL_BEGIN

@interface TrackCapturerEventsEmitter ()

@property(copy, nonatomic) NSString *trackId;
@property(weak, nonatomic) WebRTCModule *module;

@end

@implementation TrackCapturerEventsEmitter

- (instancetype)initWith:(NSString *)trackId webRTCModule:(WebRTCModule *)module {
    self = [super init];
    if (self) {
        self.trackId = trackId;
        self.module = module;
    }

    return self;
}

/**
 * A LOCAL-track mute change: no `pcId`, on purpose. RTCPeerConnection's listener for this
 * event filters on `ev.pcId !== this._pcId` and so ignores it; MediaStreamTrack's local
 * listener matches on trackId alone. The screen track is created `muted` (see getDisplayMedia
 * in WebRTCModule+RTCMediaStream.m) and this is what un-mutes it.
 */
- (void)capturerDidStart:(RTCVideoCapturer *)capturer {
    [self.module sendEventWithName:kEventMediaStreamTrackMuteChanged
                              body:@{
                                  @"trackId" : self.trackId,
                                  @"muted" : @NO,
                              }];

    RCTLog(@"[TrackCapturerEventsEmitter] started (unmute) event for track %@", self.trackId);
}

- (void)capturerDidEnd:(RTCVideoCapturer *)capturer {
    [self.module sendEventWithName:kEventMediaStreamTrackEnded
                              body:@{
                                  @"trackId" : self.trackId,
                              }];

    RCTLog(@"[TrackCapturerEventsEmitter] ended event for track %@", self.trackId);
}

@end

NS_ASSUME_NONNULL_END