#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <ReplayKit/ReplayKit.h>

#import "SiperbBroadcastFrameUploader.h"
#import "SiperbBroadcastSocketClient.h"

/** Frames are sent at half the screen's pixel size. 1170×2532 → 585×1266: plenty for a shared screen, a quarter of the bytes. */
static const CGFloat kScaleDivisor = 2.0;

/** JPEG quality. Screen content survives 0.8 without visible loss; the receiver decodes every frame on the CPU, so bytes are time there too. */
static const float kJPEGQuality = 0.8f;

/** Same chunk size as the receiver's read buffer (kMaxReadLength in ScreenCapturer.m). */
static const NSUInteger kMaxChunkSize = 10 * 1024;

@interface SiperbBroadcastFrameUploader ()

@property(nonatomic, strong) SiperbBroadcastSocketClient *client;
@property(nonatomic, strong) CIContext *imageContext;

/** YES between the socket opening and a frame being handed over; NO while its bytes are going out. */
@property(atomic, assign) BOOL ready;

// Stream thread only.
@property(nonatomic, strong, nullable) NSData *pendingData;
@property(nonatomic, assign) NSUInteger pendingOffset;

@end

@implementation SiperbBroadcastFrameUploader

- (instancetype)initWithClient:(SiperbBroadcastSocketClient *)client {
    self = [super init];
    if (self) {
        _client = client;
        // One context for the life of the process: creating one is expensive and it caches
        // its GPU/CPU resources, which is exactly what a 10 fps encode loop wants.
        _imageContext = [CIContext contextWithOptions:nil];
        _ready = NO;

        __weak __typeof__(self) weakSelf = self;
        client.didOpen = ^{
            weakSelf.ready = YES;
        };
        client.hasSpaceAvailable = ^{
            [weakSelf writeNextChunk];
        };
    }
    return self;
}

- (BOOL)sendSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.ready) {
        return NO;
    }
    // Claimed BEFORE encoding, so the next ReplayKit callback sees it as busy. Encoding happens
    // here, on ReplayKit's queue, rather than on the stream thread: the pixel buffer is only
    // valid for the duration of this callback.
    self.ready = NO;

    NSData *frame = [self serializeFrame:sampleBuffer];
    if (frame == nil) {
        self.ready = YES;
        return NO;
    }

    __weak __typeof__(self) weakSelf = self;
    [self.client performOnStreamThread:^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.pendingData = frame;
        strongSelf.pendingOffset = 0;
        // The stream is idle (one frame in flight, and it finished), so its buffer has room:
        // write the first chunk now. The rest ride on hasSpaceAvailable, which the stream
        // raises again after each write while it can take more.
        [strongSelf writeNextChunk];
    }];
    return YES;
}

// MARK: - Stream thread

- (void)writeNextChunk {
    NSData *data = self.pendingData;
    if (data == nil) {
        return;
    }

    NSUInteger remaining = data.length - self.pendingOffset;
    NSUInteger length = MIN(remaining, kMaxChunkSize);
    const uint8_t *bytes = (const uint8_t *)data.bytes + self.pendingOffset;

    NSInteger written = [self.client writeBytes:bytes maxLength:length];
    if (written < 0) {
        // The socket is gone; didClose is on its way. Drop the frame rather than retry into a
        // dead stream. Ready again so the next frame is dropped cheaply at the top instead.
        NSLog(@"[SiperbBroadcast] write failed, dropping frame");
        self.pendingData = nil;
        self.pendingOffset = 0;
        self.ready = YES;
        return;
    }

    self.pendingOffset += (NSUInteger)written;
    if (self.pendingOffset >= data.length) {
        self.pendingData = nil;
        self.pendingOffset = 0;
        self.ready = YES;
    }
}

// MARK: - Encoding (ReplayKit's queue)

- (nullable NSData *)serializeFrame:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == NULL) {
        return nil;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    size_t width = CVPixelBufferGetWidth(pixelBuffer) / (size_t)kScaleDivisor;
    size_t height = CVPixelBufferGetHeight(pixelBuffer) / (size_t)kScaleDivisor;

    // ReplayKit stamps the device orientation on each buffer as a CGImagePropertyOrientation.
    // Forwarded verbatim: the receiver maps Left/Down/Right to WebRTC rotations and anything
    // else to 0, so a missing attachment (0) is upright.
    NSUInteger orientation = 0;
    CFTypeRef orientationAttachment = CMGetAttachment(sampleBuffer, (__bridge CFStringRef)RPVideoSampleOrientationKey, NULL);
    if (orientationAttachment != NULL && CFGetTypeID(orientationAttachment) == CFNumberGetTypeID()) {
        orientation = [(__bridge NSNumber *)orientationAttachment unsignedIntegerValue];
    }

    NSData *jpeg = [self jpegDataFromPixelBuffer:pixelBuffer];

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    if (jpeg == nil) {
        return nil;
    }

    CFHTTPMessageRef message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1);
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Content-Length"),
                                     (__bridge CFStringRef)[NSString stringWithFormat:@"%lu", (unsigned long)jpeg.length]);
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Buffer-Width"),
                                     (__bridge CFStringRef)[NSString stringWithFormat:@"%zu", width]);
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Buffer-Height"),
                                     (__bridge CFStringRef)[NSString stringWithFormat:@"%zu", height]);
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Buffer-Orientation"),
                                     (__bridge CFStringRef)[NSString stringWithFormat:@"%lu", (unsigned long)orientation]);
    CFHTTPMessageSetBody(message, (__bridge CFDataRef)jpeg);

    NSData *serialized = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(message));
    CFRelease(message);
    return serialized;
}

- (nullable NSData *)jpegDataFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    CIImage *image = [[CIImage imageWithCVPixelBuffer:pixelBuffer]
        imageByApplyingTransform:CGAffineTransformMakeScale(1.0 / kScaleDivisor, 1.0 / kScaleDivisor)];

    CGColorSpaceRef colorSpace = image.colorSpace;
    CGColorSpaceRef ownedColorSpace = NULL;
    if (colorSpace == NULL) {
        ownedColorSpace = CGColorSpaceCreateDeviceRGB();
        colorSpace = ownedColorSpace;
    }

    NSDictionary *options = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(kJPEGQuality)};
    NSData *jpeg = [self.imageContext JPEGRepresentationOfImage:image colorSpace:colorSpace options:options];

    if (ownedColorSpace != NULL) {
        CGColorSpaceRelease(ownedColorSpace);
    }
    return jpeg;
}

@end
