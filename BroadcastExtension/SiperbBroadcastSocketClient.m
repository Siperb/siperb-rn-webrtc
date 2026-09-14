#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#import "SiperbBroadcastSocketClient.h"

@interface SiperbBroadcastSocketClient () <NSStreamDelegate>

@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, assign) int socketHandle;
@property(nonatomic, strong) NSThread *streamThread;
@property(nonatomic, strong, nullable) NSInputStream *inputStream;
@property(nonatomic, strong, nullable) NSOutputStream *outputStream;
@property(atomic, assign) BOOL closed;

@end

@implementation SiperbBroadcastSocketClient

- (instancetype)initWithFilePath:(NSString *)filePath {
    self = [super init];
    if (self) {
        _filePath = [filePath copy];
        _socketHandle = -1;
        _closed = NO;
        [self setupStreamThread];
    }
    return self;
}

- (BOOL)open {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    // sun_path is 104 bytes on Darwin; an App Group container path is ~80. Checked rather than
    // truncated, because a truncated path silently connects to nothing.
    if (self.filePath.length >= sizeof(addr.sun_path)) {
        NSLog(@"[SiperbBroadcast] socket path too long: %@", self.filePath);
        return NO;
    }
    strncpy(addr.sun_path, self.filePath.UTF8String, sizeof(addr.sun_path) - 1);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[SiperbBroadcast] socket() failed");
        return NO;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        // Nothing listening: the normal answer until the app's getDisplayMedia() has run.
        close(fd);
        return NO;
    }
    self.socketHandle = fd;

    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &readStream, &writeStream);

    self.inputStream = (__bridge_transfer NSInputStream *)readStream;
    self.outputStream = (__bridge_transfer NSOutputStream *)writeStream;
    self.inputStream.delegate = self;
    self.outputStream.delegate = self;
    // Let the streams own the descriptor, so closing them closes it exactly once.
    [self.inputStream setProperty:(__bridge id)kCFBooleanTrue
                           forKey:(__bridge NSString *)kCFStreamPropertyShouldCloseNativeSocket];
    [self.outputStream setProperty:(__bridge id)kCFBooleanTrue
                            forKey:(__bridge NSString *)kCFStreamPropertyShouldCloseNativeSocket];
    self.socketHandle = -1;

    if (!self.streamThread.isExecuting) {
        [self.streamThread start];
    }
    [self performSelector:@selector(scheduleStreams) onThread:self.streamThread withObject:nil waitUntilDone:YES];

    return YES;
}

- (void)close {
    // Idempotent, and safe from the stream thread itself: performSelector:onThread: with
    // waitUntilDone:YES runs inline when the target is the current thread. Owned by the sample
    // handler for the life of the extension process, so there is no dealloc path to hop threads
    // from.
    self.closed = YES;

    if (self.streamThread.isExecuting) {
        [self performSelector:@selector(tearDownStreams) onThread:self.streamThread withObject:nil waitUntilDone:YES];
        [self.streamThread cancel];
    }
    if (self.socketHandle >= 0) {
        close(self.socketHandle);
        self.socketHandle = -1;
    }
}

- (NSInteger)writeBytes:(const uint8_t *)buffer maxLength:(NSUInteger)length {
    NSOutputStream *stream = self.outputStream;
    if (stream == nil || self.closed) {
        return -1;
    }
    return [stream write:buffer maxLength:length];
}

- (void)performOnStreamThread:(dispatch_block_t)block {
    if (!self.streamThread.isExecuting) {
        return;
    }
    [self performSelector:@selector(runBlock:) onThread:self.streamThread withObject:[block copy] waitUntilDone:NO];
}

// MARK: - Stream thread

- (void)setupStreamThread {
    __weak __typeof__(self) weakSelf = self;
    self.streamThread = [[NSThread alloc] initWithBlock:^{
        // A run loop with no input sources returns from -run immediately, and a loop around
        // that is a busy-wait at 100% CPU inside a process with a 50 MB budget and a shared
        // battery. The mach port is a permanent source that keeps the loop parked until a
        // stream event or a performSelector:onThread: arrives.
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        while (!NSThread.currentThread.isCancelled) {
            @autoreleasepool {
                [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            }
        }
        (void)weakSelf;
    }];
    self.streamThread.name = @"com.siperb.broadcast.socket";
    self.streamThread.qualityOfService = NSQualityOfServiceUserInitiated;
}

- (void)scheduleStreams {
    [self.inputStream scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
    [self.outputStream scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
    [self.inputStream open];
    [self.outputStream open];
}

- (void)tearDownStreams {
    self.inputStream.delegate = nil;
    self.outputStream.delegate = nil;
    [self.inputStream removeFromRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
    [self.outputStream removeFromRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
    [self.inputStream close];
    [self.outputStream close];
    self.inputStream = nil;
    self.outputStream = nil;
}

- (void)runBlock:(dispatch_block_t)block {
    if (block) {
        block();
    }
}

- (void)notifyClosedWithError:(nullable NSError *)error {
    // Once. End-of-stream and an error can both arrive, on either stream.
    if (self.closed) {
        return;
    }
    self.closed = YES;
    [self tearDownStreams];
    if (self.didClose) {
        self.didClose(error);
    }
}

// MARK: - NSStreamDelegate (stream thread)

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    switch (eventCode) {
        case NSStreamEventOpenCompleted:
            if (aStream == self.outputStream && self.didOpen) {
                self.didOpen();
            }
            break;
        case NSStreamEventHasSpaceAvailable:
            if (aStream == self.outputStream && self.hasSpaceAvailable) {
                self.hasSpaceAvailable();
            }
            break;
        case NSStreamEventEndEncountered:
            // The app closed its end: it stopped capture, or was killed.
            [self notifyClosedWithError:nil];
            break;
        case NSStreamEventErrorOccurred:
            [self notifyClosedWithError:aStream.streamError];
            break;
        default:
            break;
    }
}

@end
