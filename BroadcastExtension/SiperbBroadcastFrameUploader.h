#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

@class SiperbBroadcastSocketClient;

NS_ASSUME_NONNULL_BEGIN

/**
 * Turns ReplayKit sample buffers into the frames the app's ScreenCapturer expects and writes
 * them down the socket, one at a time.
 *
 * THE WIRE FORMAT IS THE RECEIVER'S (ios/RCTWebRTC/ScreenCapturer.m, `Message`): an HTTP
 * message — CFHTTPMessage, so the framing parser on the other side is CFNetwork's — with the
 * headers `Content-Length`, `Buffer-Width`, `Buffer-Height`, `Buffer-Orientation` and a JPEG
 * body. The receiver creates a BGRA pixel buffer of Buffer-Width × Buffer-Height, decodes the
 * body into it with CoreImage, and hands it to WebRTC with the rotation the orientation maps
 * to. Change any of those four names here and the picture silently stops.
 *
 * ONE FRAME IN FLIGHT. `sendSampleBuffer:` returns NO — and drops the frame — while the previous
 * one is still being written. That is the frame-rate limiter and the memory limiter in one:
 * ReplayKit delivers up to 60 fps, the extension has a ~50 MB budget, and a queue of encoded
 * frames waiting on a slow socket is how broadcast extensions get killed.
 */
@interface SiperbBroadcastFrameUploader : NSObject

- (instancetype)initWithClient:(SiperbBroadcastSocketClient *)client;

/**
 * Encode and queue one video frame. Call from ReplayKit's sample queue. NO when dropped
 * (previous frame still writing, socket not open yet, or nothing to encode).
 */
- (BOOL)sendSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

NS_ASSUME_NONNULL_END
