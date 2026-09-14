#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * The extension's end of the Unix-domain socket that carries screen frames to the app.
 *
 * The APP is the server: ScreenCaptureController (ios/RCTWebRTC) binds `rtc_SSFD` inside the
 * App Group container when getDisplayMedia() runs and waits for exactly one client. This class
 * is that client. Everything stream-related happens on ONE private thread — the streams are
 * scheduled there, the delegate fires there, and writes are only ever issued there through
 * `performOnStreamThread:` — because NSStream is not thread-safe and a write from a second
 * thread is undefined behaviour that happens to work until it doesn't.
 */
@interface SiperbBroadcastSocketClient : NSObject

/** Fired once the output stream is open: bytes may be written from here on. Stream thread. */
@property(nonatomic, copy, nullable) void (^didOpen)(void);

/** Fired once, when the app closes its end or the stream errors. Stream thread. */
@property(nonatomic, copy, nullable) void (^didClose)(NSError *_Nullable error);

/** Fired whenever the output stream can take more bytes. Stream thread. */
@property(nonatomic, copy, nullable) void (^hasSpaceAvailable)(void);

- (instancetype)initWithFilePath:(NSString *)filePath;

/**
 * Connect. Returns NO when nothing is listening yet — the app has not called getDisplayMedia(),
 * or the user started the broadcast from Control Center before the app was ready. Cheap to
 * retry.
 */
- (BOOL)open;

- (void)close;

/** Write on the stream thread. Bytes written, or -1 on error. Only call from `hasSpaceAvailable` or a `performOnStreamThread:` block. */
- (NSInteger)writeBytes:(const uint8_t *)buffer maxLength:(NSUInteger)length;

/** Run a block on the stream thread, asynchronously. */
- (void)performOnStreamThread:(dispatch_block_t)block;

@end

NS_ASSUME_NONNULL_END
