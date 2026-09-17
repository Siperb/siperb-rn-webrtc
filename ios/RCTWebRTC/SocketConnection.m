#include <sys/socket.h>
#include <sys/un.h>

#import "SocketConnection.h"

@interface SocketConnection ()

@property(nonatomic, assign) int serverSocket;
/** The fd accept() handed us, or -1. Kept so close can close it: the streams do not. */
@property(nonatomic, assign) int clientSocket;
@property(nonatomic, strong) dispatch_source_t listeningSource;

@property(nonatomic, strong) NSThread *networkThread;

@property(nonatomic, strong) NSInputStream *inputStream;
@property(nonatomic, strong) NSOutputStream *outputStream;

@end

@implementation SocketConnection

- (instancetype)initWithFilePath:(nonnull NSString *)filePath {
    self = [super init];

    [self setupNetworkThread];

    self.clientSocket = -1;
    self.serverSocket = socket(AF_UNIX, SOCK_STREAM, 0);
    if (self.serverSocket < 0) {
        NSLog(@"failure creating socket");
        return nil;
    }

    if (![self setupSocketWithFileAtPath:filePath]) {
        close(self.serverSocket);
        return nil;
    }

    return self;
}

- (void)openWithStreamDelegate:(id<NSStreamDelegate>)streamDelegate {
    int status = listen(self.serverSocket, 10);
    if (status < 0) {
        NSLog(@"failure: socket listening");
        return;
    }

    int serverSocket = self.serverSocket;
    dispatch_source_t listeningSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, serverSocket, 0, NULL);
    // THE SERVER FD IS CLOSED HERE AND NOWHERE ELSE. dispatch_source_cancel is asynchronous;
    // close()-ing an fd a READ source still monitors is the libdispatch client bug it aborts the
    // process for ("Unexpected EV_VANISHED — do not destroy random file descriptors"). The
    // cancel handler is the one point where the source is guaranteed off the fd.
    dispatch_source_set_cancel_handler(listeningSource, ^{
        close(serverSocket);
    });
    dispatch_source_set_event_handler(listeningSource, ^{
        int clientSocket = accept(self.serverSocket, NULL, NULL);
        if (clientSocket < 0) {
            NSLog(@"failure accepting connection");
            return;
        }
        self.clientSocket = clientSocket;

        CFReadStreamRef readStream;
        CFWriteStreamRef writeStream;

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, clientSocket, &readStream, &writeStream);

        // The streams do NOT own the descriptor: close owns it, below. Handing ownership to the
        // streams needs kCFStreamPropertyShouldCloseNativeSocket set to the real kCFBooleanTrue
        // (a string in its place is silently ignored), and even then closing one stream of the
        // pair races the other. Owning the fd ourselves is what makes the extension see EOF.
        self.inputStream = (__bridge_transfer NSInputStream *)readStream;
        self.inputStream.delegate = streamDelegate;

        self.outputStream = (__bridge_transfer NSOutputStream *)writeStream;

        [self.networkThread start];
        [self performSelector:@selector(scheduleStreams) onThread:self.networkThread withObject:nil waitUntilDone:true];

        [self.inputStream open];
        [self.outputStream open];
    });

    self.listeningSource = listeningSource;
    dispatch_resume(listeningSource);
}

- (void)close {
    // The network thread starts only once the extension has connected (accept above). A share
    // stopped before that — picker dismissed, the consent timeout, a hangup with the picker up —
    // has an unstarted thread here, and performSelector:onThread: with waitUntilDone:YES onto a
    // thread that never runs blocks this caller for good: the module's worker queue, and with
    // it every later native call. Guarded the way the extension's own client guards it.
    if (self.networkThread.isExecuting) {
        [self performSelector:@selector(unscheduleStreams) onThread:self.networkThread withObject:nil waitUntilDone:true];
    }

    self.inputStream.delegate = nil;
    self.outputStream.delegate = nil;

    [self.inputStream close];
    [self.outputStream close];

    // CLOSING THE CLIENT FD IS WHAT ENDS THE BROADCAST. The extension finishes its broadcast on
    // NSStreamEventEndEncountered, which it only sees when this end of the socket is closed —
    // and closing the NSStreams alone leaves the descriptor open (see the accept block). Left
    // open, the red status pill outlives the call and the next share cannot start because
    // ReplayKit is still broadcasting.
    if (self.clientSocket >= 0) {
        close(self.clientSocket);
        self.clientSocket = -1;
    }

    [self.networkThread cancel];

    // Cancels asynchronously; the server fd is closed in the source's cancel handler, never here.
    // No source means listen() failed before one was made (dispatch_source_cancel(NULL) is itself
    // a crash), and then the fd is ours to close directly.
    if (self.listeningSource) {
        dispatch_source_cancel(self.listeningSource);
        self.listeningSource = nil;
    } else if (self.serverSocket >= 0) {
        close(self.serverSocket);
    }
    self.serverSocket = -1;
}

// MARK: - Private Methods

- (void)setupNetworkThread {
    self.networkThread = [[NSThread alloc] initWithBlock:^{
        // runUntilDate: rather than run: the perform-selector port keeps the loop supplied with
        // sources, so `run` never returns and isCancelled was never re-read — one leaked thread
        // per share. A bounded slice is what lets cancel actually end the thread.
        do {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            }
        } while (![NSThread currentThread].isCancelled);
    }];
    self.networkThread.qualityOfService = NSQualityOfServiceUserInitiated;
}

- (BOOL)setupSocketWithFileAtPath:(NSString *)filePath {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    if (filePath.length > sizeof(addr.sun_path)) {
        NSLog(@"failure: path too long");
        return false;
    }

    unlink(filePath.UTF8String);
    strncpy(addr.sun_path, filePath.UTF8String, sizeof(addr.sun_path) - 1);

    int status = bind(self.serverSocket, (struct sockaddr *)&addr, sizeof(addr));
    if (status < 0) {
        NSLog(@"failure: socket binding");
        return false;
    }

    return true;
}

- (void)scheduleStreams {
    [self.inputStream scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    [self.outputStream scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
}

- (void)unscheduleStreams {
    [self.inputStream removeFromRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    [self.outputStream removeFromRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
}

@end
