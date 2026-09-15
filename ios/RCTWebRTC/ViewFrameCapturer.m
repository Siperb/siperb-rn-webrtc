#if TARGET_OS_IOS

#include <mach/mach_time.h>

#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrameBuffer.h>

#import "ViewFrameCapturer.h"

// A view drawn as SD-ish video by default. Even numbers only: H.264 wants even dimensions, and a
// pixel buffer whose width is odd trips the encoder's chroma subsampling. The capture size is
// derived from the view's own aspect at capture time and clamped to this, so a tall phone-shaped
// whiteboard is not stretched.
static const CGFloat kDefaultMaxDimension = 720.0;
// A drawing is near-static; this is the fallback rate when a caller passes none. Kept low on
// purpose — the tick is main-thread work and a whiteboard does not need 30fps.
static const NSInteger kDefaultFps = 10;

@interface ViewFrameCapturer ()
@property(nonatomic, weak) UIView *targetView;
@property(nonatomic, strong, nullable) UIImage *stillImage;
@property(nonatomic, strong, nullable) CADisplayLink *displayLink;
@end

@implementation ViewFrameCapturer {
    mach_timebase_info_data_t _timebaseInfo;
    int64_t _startTimeStampNs;
    CVPixelBufferPoolRef _pixelBufferPool;
    size_t _poolWidth;
    size_t _poolHeight;
    BOOL _didReportEnd;
}

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate {
    self = [super initWithDelegate:delegate];
    if (self) {
        mach_timebase_info(&_timebaseInfo);
        _startTimeStampNs = -1;
        _pixelBufferPool = NULL;
    }
    return self;
}

- (void)dealloc {
    [self teardownPool];
}

// MARK: Start / stop

- (void)startCaptureWithView:(nonnull UIView *)view fps:(NSInteger)fps {
    self.targetView = view;
    self.stillImage = nil;
    [self armWithFps:fps];
}

- (void)startCaptureWithImage:(nonnull UIImage *)image fps:(NSInteger)fps {
    self.stillImage = image;
    self.targetView = nil;
    [self armWithFps:fps];
}

- (void)armWithFps:(NSInteger)fps {
    _startTimeStampNs = -1;
    _didReportEnd = NO;

    NSInteger rate = fps > 0 ? fps : kDefaultFps;
    if (rate > 30) {
        rate = 30;
    }

    // CADisplayLink runs on the main run loop, which is exactly where the view snapshot has to
    // happen. preferredFramesPerSecond throttles it to our rate rather than the display's 60.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.displayLink invalidate];
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick)];
        link.preferredFramesPerSecond = rate;
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        self.displayLink = link;
    });
}

- (void)stopCapture {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.displayLink invalidate];
        self.displayLink = nil;
    });
    self.targetView = nil;
    self.stillImage = nil;
    [self teardownPool];
}

// MARK: The tick (main thread — CADisplayLink)

- (void)onTick {
    UIView *view = self.targetView;
    UIImage *image = self.stillImage;

    // The target view went away (its screen was torn down). Report end once — the emitter turns
    // that into a track `ended`, which the SDK's stop path already handles — and stop ticking.
    if (!view && !image) {
        if (!_didReportEnd) {
            _didReportEnd = YES;
            id<CapturerEventsDelegate> d = self.eventsDelegate;
            if ([d respondsToSelector:@selector(capturerDidEnd:)]) {
                [d capturerDidEnd:self];
            }
        }
        [self.displayLink invalidate];
        self.displayLink = nil;
        return;
    }

    CGSize points = image ? image.size : view.bounds.size;
    if (points.width < 1 || points.height < 1) {
        return;  // not laid out yet
    }

    // Fit the source aspect into the max dimension, rounded to even pixels.
    CGFloat scale = MIN(1.0, kDefaultMaxDimension / MAX(points.width, points.height));
    size_t w = (size_t)(points.width * scale) & ~(size_t)1;
    size_t h = (size_t)(points.height * scale) & ~(size_t)1;
    if (w < 2 || h < 2) {
        return;
    }

    CVPixelBufferRef pixelBuffer = [self pixelBufferOfWidth:w height:h];
    if (!pixelBuffer) {
        return;
    }

    if (![self drawView:view image:image intoBuffer:pixelBuffer pointSize:points]) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    [self emitPixelBuffer:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);
}

// MARK: Rasterise

// Draw the view's current on-screen content (or the still image, aspect-fit) into a BGRA pixel
// buffer. UIKit draws into whatever context is on the UIGraphics stack, so we push a CGContext
// backed by the locked pixel buffer and flip it into UIKit's top-left origin.
- (BOOL)drawView:(nullable UIView *)view
           image:(nullable UIImage *)image
      intoBuffer:(CVPixelBufferRef)pixelBuffer
       pointSize:(CGSize)points {
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bpr = CVPixelBufferGetBytesPerRow(pixelBuffer);
    size_t w = CVPixelBufferGetWidth(pixelBuffer);
    size_t h = CVPixelBufferGetHeight(pixelBuffer);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    // 32BGRA: premultiplied-first + little-endian is the layout the pool below allocates. The
    // two flags are different enum types, so OR them as their underlying uint32 to keep clang's
    // -Wenum-enum-conversion quiet; CGBitmapContextCreate takes a uint32 bitmapInfo anyway.
    uint32_t bitmapInfo = (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little;
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, bitmapInfo);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return NO;
    }

    // White ground: a whiteboard is white, and a view with a transparent background would
    // otherwise stream whatever garbage is in the freshly-allocated buffer.
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));

    // The buffer is in pixels, UIKit draws in points: scale so the point-sized draw fills it.
    CGContextScaleCTM(ctx, (CGFloat)w / points.width, (CGFloat)h / points.height);
    // Flip into UIKit's top-left origin.
    CGContextTranslateCTM(ctx, 0, points.height);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    UIGraphicsPushContext(ctx);
    BOOL ok = YES;
    if (image) {
        [image drawInRect:CGRectMake(0, 0, points.width, points.height)];
    } else {
        // afterScreenUpdates:NO — snapshot what is already composited, which includes GPU layers
        // and does not force (and wait on) a fresh render pass every tick.
        ok = [view drawViewHierarchyInRect:CGRectMake(0, 0, points.width, points.height)
                        afterScreenUpdates:NO];
    }
    UIGraphicsPopContext();

    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return ok;
}

// MARK: Emit

- (void)emitPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    int64_t now = mach_absolute_time() * _timebaseInfo.numer / _timebaseInfo.denom;
    if (_startTimeStampNs < 0) {
        _startTimeStampNs = now;
    }
    RTCCVPixelBuffer *rtcBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:rtcBuffer
                                                        rotation:RTCVideoRotation_0
                                                     timeStampNs:now - _startTimeStampNs];
    [self.delegate capturer:self didCaptureVideoFrame:frame];
}

// MARK: Pixel buffer pool

- (CVPixelBufferRef)pixelBufferOfWidth:(size_t)w height:(size_t)h {
    if (_pixelBufferPool == NULL || _poolWidth != w || _poolHeight != h) {
        [self teardownPool];
        NSDictionary *attrs = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (NSString *)kCVPixelBufferWidthKey : @(w),
            (NSString *)kCVPixelBufferHeightKey : @(h),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
        };
        CVReturn status =
            CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &_pixelBufferPool);
        if (status != kCVReturnSuccess) {
            _pixelBufferPool = NULL;
            return NULL;
        }
        _poolWidth = w;
        _poolHeight = h;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool, &pixelBuffer);
    if (status != kCVReturnSuccess) {
        return NULL;
    }
    return pixelBuffer;
}

- (void)teardownPool {
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    _poolWidth = 0;
    _poolHeight = 0;
}

@end

#endif
