#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <os/lock.h>

#import <React/RCTLog.h>

#import "CallAudioRecorder.h"  // kCallRecordingErrorDomain / CallRecordingErrorCode
#import "CallVideoRecorder.h"
#import "I420Converter.h"

// The audio the mixer produces. Fixed by CallAudioRecorder, not configurable here — this file
// re-declares them rather than importing private headers, and a mismatch would be audible.
static const int32_t kAudioSampleRate = 48000;

// Slot index for the local camera / presentation source. Negative so it cannot collide with a
// remote index, and named because "-1" at six call sites says nothing.
static const NSInteger kLocalSlot = -1;

CallVideoLayout CallVideoLayoutFromString(NSString *name) {
    if ([name isEqualToString:@"side-by-side"]) {
        return CallVideoLayoutSideBySide;
    }
    if ([name isEqualToString:@"us-only"]) {
        return CallVideoLayoutUsOnly;
    }
    if ([name isEqualToString:@"them-only"]) {
        return CallVideoLayoutThemOnly;
    }
    // them-pnp for the default AND for anything unrecognised. JS maps the two talker layouts
    // here before calling, so an unknown string means a version skew, not a typo — and the
    // web's default is the honest thing to fall back to.
    return CallVideoLayoutThemPnp;
}

@implementation CallVideoRecordingConfig
- (instancetype)init {
    self = [super init];
    if (self) {
        _remoteTracks = @[];
    }
    return self;
}
@end

/** One source's most recent picture, plus what it takes to draw it upright. */
@interface CallVideoSlot : NSObject
@property(nonatomic, assign) CVPixelBufferRef buffer;
@property(nonatomic, assign) RTCVideoRotation rotation;
@end

@implementation CallVideoSlot
- (void)setBuffer:(CVPixelBufferRef)buffer {
    if (_buffer == buffer) {
        return;
    }
    if (_buffer) {
        CVPixelBufferRelease(_buffer);
    }
    _buffer = buffer ? CVPixelBufferRetain(buffer) : NULL;
}
- (void)dealloc {
    if (_buffer) {
        CVPixelBufferRelease(_buffer);
    }
}
@end

@implementation CallVideoRecorder {
    NSInteger _width;
    NSInteger _height;
    NSInteger _fps;
    CallVideoLayout _layout;
    NSInteger _pnpSize;
    BOOL _stereo;

    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInputPixelBufferAdaptor *_videoAdaptor;
    AVAssetWriterInput *_audioInput;
    CVPixelBufferPoolRef _pool;
    CIContext *_ciContext;

    dispatch_queue_t _queue;       // serialises every append and the composite tick
    dispatch_source_t _tickTimer;
    I420Converter *_i420;          // _queue-confined; only the tick converts

    os_unfair_lock _slotLock;
    NSMutableDictionary<NSNumber *, CallVideoSlot *> *_slots;

    // THE ONE CLOCK ORIGIN. Both tracks start at zero and advance by their own natural rate —
    // video by the frame it is, audio by the samples it has written — so neither is derived
    // from wall time and they cannot drift apart. Reading a host clock per frame is what makes
    // a recording that is fine for twenty seconds and half a second out after ten minutes.
    int64_t _videoFrameIndex;
    int64_t _audioSamplesWritten;

    BOOL _started;      // _queue-confined
    BOOL _finished;     // _queue-confined
    BOOL _videoUsable;  // atomic-ish: written on _queue, read from anywhere
    BOOL _loggedVideoDrop;
    BOOL _loggedAudioDrop;
}

- (instancetype)initWithOutputPath:(NSString *)outputPath
                            config:(CallVideoRecordingConfig *)config
                            stereo:(BOOL)stereo {
    self = [super init];
    if (self) {
        _outputPath = [outputPath copy];
        // Even dimensions: H.264 cannot encode an odd width or height, and a caller that asks
        // for one gets a writer that fails at the first append rather than at start.
        _width = MAX(2, (config.width / 2) * 2);
        _height = MAX(2, (config.height / 2) * 2);
        _fps = MAX(1, config.fps);
        _layout = config.layout;
        _pnpSize = MAX(0, config.pnpSize);
        _stereo = stereo;
        _slotLock = OS_UNFAIR_LOCK_INIT;
        _slots = [NSMutableDictionary new];
        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -1);
        _queue = dispatch_queue_create("CallVideoRecorder.writer", attributes);
    }
    return self;
}

- (void)dealloc {
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
    }
}

- (BOOL)videoUsable {
    return _videoUsable;
}

#pragma mark - Start

- (BOOL)start:(NSError **)error {
    NSURL *url = [NSURL fileURLWithPath:_outputPath];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];  // AVAssetWriter refuses an existing file

    NSError *writerError = nil;
    _writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:&writerError];
    if (_writer == nil) {
        if (error) {
            *error = [NSError errorWithDomain:kCallRecordingErrorDomain
                                         code:CallRecordingErrorIO
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : writerError.localizedDescription
                                             ?: @"Cannot create mp4 writer"
                                     }];
        }
        return NO;
    }

    // ~0.1 bits per pixel per frame: 1280x720@12 lands near 1.1 Mbps. Capped deliberately —
    // this file is written alongside a WAV of comparable size and then uploaded, so the
    // default "looks best" bitrate is the wrong trade for a phone on a metered connection.
    NSInteger bitrate = (NSInteger)(_width * _height * _fps * 0.1);
    NSDictionary *videoSettings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @(_width),
        AVVideoHeightKey : @(_height),
        AVVideoCompressionPropertiesKey : @{
            AVVideoAverageBitRateKey : @(bitrate),
            AVVideoMaxKeyFrameIntervalKey : @(_fps * 2),
            AVVideoProfileLevelKey : AVVideoProfileLevelH264BaselineAutoLevel,
        },
    };
    _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    _videoInput.expectsMediaDataInRealTime = YES;
    _videoAdaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoInput
                                   sourcePixelBufferAttributes:@{
                                       (id)kCVPixelBufferPixelFormatTypeKey :
                                           @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferWidthKey : @(_width),
                                       (id)kCVPixelBufferHeightKey : @(_height),
                                   }];

    NSDictionary *audioSettings = @{
        AVFormatIDKey : @(kAudioFormatMPEG4AAC),
        AVSampleRateKey : @(kAudioSampleRate),
        AVNumberOfChannelsKey : @(_stereo ? 2 : 1),
        AVEncoderBitRateKey : @(_stereo ? 64000 : 32000),
    };
    _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
    _audioInput.expectsMediaDataInRealTime = YES;

    if (![_writer canAddInput:_videoInput] || ![_writer canAddInput:_audioInput]) {
        if (error) {
            *error = [NSError errorWithDomain:kCallRecordingErrorDomain
                                         code:CallRecordingErrorEncode
                                     userInfo:@{NSLocalizedDescriptionKey : @"Writer refused an input"}];
        }
        return NO;
    }
    [_writer addInput:_videoInput];
    [_writer addInput:_audioInput];

    if (![_writer startWriting]) {
        if (error) {
            *error = [NSError errorWithDomain:kCallRecordingErrorDomain
                                         code:CallRecordingErrorEncode
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : _writer.error.localizedDescription
                                             ?: @"startWriting failed"
                                     }];
        }
        return NO;
    }
    [_writer startSessionAtSourceTime:kCMTimeZero];

    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @(_width),
        (id)kCVPixelBufferHeightKey : @(_height),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)poolAttributes, &_pool) !=
        kCVReturnSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:kCallRecordingErrorDomain
                                         code:CallRecordingErrorIO
                                     userInfo:@{NSLocalizedDescriptionKey : @"Cannot create pixel buffer pool"}];
        }
        return NO;
    }

    // Metal where there is one; CIContext falls back on its own otherwise. Software CoreImage
    // at 12 fps on a 720p frame is survivable, which is why this is not a hard requirement.
    id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
    _ciContext = metal ? [CIContext contextWithMTLDevice:metal] : [CIContext context];

    _started = YES;
    _videoUsable = YES;

    __weak CallVideoRecorder *weakSelf = self;
    _tickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t intervalNs = (uint64_t)(NSEC_PER_SEC / (uint64_t)_fps);
    dispatch_source_set_timer(_tickTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNs), intervalNs,
                              intervalNs / 10);
    dispatch_source_set_event_handler(_tickTimer, ^{
        [weakSelf compositeTick];
    });
    dispatch_resume(_tickTimer);

    RCTLogInfo(@"[CallVideoRecorder] started %ldx%ld @%ldfps layout=%ld -> %@", (long)_width, (long)_height,
               (long)_fps, (long)_layout, _outputPath.lastPathComponent);
    return YES;
}

#pragma mark - Sources

- (void)submitFrame:(RTCVideoFrame *)frame forSlot:(NSInteger)slot {
    if (!_videoUsable || frame == nil) {
        return;
    }
    // Converted on the DECODER thread, not the composite tick, and this is deliberate: an I420
    // frame costs a full vImage conversion, and doing it per tick would redo that work for every
    // frame the compositor skips. Here it happens once per delivered frame, and only the newest
    // survives to be drawn.
    CVPixelBufferRef pixels = [self copyPixelBufferFromFrame:frame];
    if (pixels == NULL) {
        return;
    }
    os_unfair_lock_lock(&_slotLock);
    CallVideoSlot *entry = _slots[@(slot)];
    if (entry == nil) {
        entry = [CallVideoSlot new];
        _slots[@(slot)] = entry;
    }
    entry.buffer = pixels;
    entry.rotation = frame.rotation;
    os_unfair_lock_unlock(&_slotLock);
    CVPixelBufferRelease(pixels);
}

- (void)clearSlot:(NSInteger)slot {
    os_unfair_lock_lock(&_slotLock);
    [_slots removeObjectForKey:@(slot)];
    os_unfair_lock_unlock(&_slotLock);
}

/** Retained buffer, or NULL. Mirrors SampleBufferVideoCallView's conversion. */
- (CVPixelBufferRef)copyPixelBufferFromFrame:(RTCVideoFrame *)frame {
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        CVPixelBufferRef pixels = ((RTCCVPixelBuffer *)frame.buffer).pixelBuffer;
        return pixels ? CVPixelBufferRetain(pixels) : NULL;
    }
    @synchronized(self) {
        if (_i420 == nil) {
            I420Converter *converter = [I420Converter new];
            if ([converter prepareForAccelerateConversion] != kvImageNoError) {
                return NULL;
            }
            _i420 = converter;
        }
        return [_i420 convertI420ToPixelBuffer:[frame.buffer toI420]];
    }
}

#pragma mark - Composite

/**
 * One output frame. Reads the latest picture per slot, draws the layout, appends.
 *
 * Linear on purpose. Each layout is three or four lines of rect arithmetic, and splitting them
 * into per-layout methods would mean four one-caller functions and a dispatch to read instead of
 * a switch you can see all of at once.
 */
- (void)compositeTick {
    if (_finished || !_videoUsable) {
        return;
    }
    if (_writer.status == AVAssetWriterStatusFailed) {
        // THE BACKGROUNDING CASE. iOS revokes hardware video encode when the app leaves the
        // foreground, and the writer lands here mid-call. Tear down the video leg and let the
        // audio recorder finish a normal .m4a rather than losing the segment.
        RCTLogWarn(@"[CallVideoRecorder] writer failed mid-recording (%@) — continuing audio-only",
                   _writer.error.localizedDescription ?: @"unknown");
        [self disableVideoLeg];
        return;
    }
    if (!_videoInput.isReadyForMoreMediaData) {
        if (!_loggedVideoDrop) {
            _loggedVideoDrop = YES;  // once: a struggling encoder would otherwise log at fps
            RCTLogInfo(@"[CallVideoRecorder] encoder behind — dropping composite frames");
        }
        return;  // DROP VIDEO, NEVER AUDIO. A dropped tick is a stutter; a dropped audio tick desyncs.
    }

    CVPixelBufferRef out = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &out) != kCVReturnSuccess || out == NULL) {
        return;
    }

    // Snapshot under the lock, draw outside it: CoreImage on a decoder thread's buffer while that
    // thread replaces it is the one race this design has to avoid.
    CVPixelBufferRef localBuf = NULL, remoteBuf = NULL;
    RTCVideoRotation localRot = RTCVideoRotation_0, remoteRot = RTCVideoRotation_0;
    os_unfair_lock_lock(&_slotLock);
    CallVideoSlot *local = _slots[@(kLocalSlot)];
    CallVideoSlot *remote = _slots[@(0)];
    if (local.buffer) {
        localBuf = CVPixelBufferRetain(local.buffer);
        localRot = local.rotation;
    }
    if (remote.buffer) {
        remoteBuf = CVPixelBufferRetain(remote.buffer);
        remoteRot = remote.rotation;
    }
    os_unfair_lock_unlock(&_slotLock);

    CIImage *canvas = [CIImage imageWithColor:[CIColor blackColor]];
    canvas = [canvas imageByCroppingToRect:CGRectMake(0, 0, _width, _height)];

    switch (_layout) {
        case CallVideoLayoutUsOnly:
            canvas = [self draw:localBuf rotation:localRot cover:CGRectMake(0, 0, _width, _height) over:canvas];
            break;
        case CallVideoLayoutThemOnly:
            canvas = [self draw:remoteBuf rotation:remoteRot cover:CGRectMake(0, 0, _width, _height) over:canvas];
            break;
        case CallVideoLayoutSideBySide: {
            // The caller sends the ALREADY-DOUBLED width, matching the web compositor's canvas,
            // so the split is simply this frame's own halves. Us left, them right — the same
            // order the web draws, so a recording reads the same whichever client made it.
            CGFloat half = _width / 2.0;
            canvas = [self draw:localBuf rotation:localRot cover:CGRectMake(0, 0, half, _height) over:canvas];
            canvas = [self draw:remoteBuf rotation:remoteRot cover:CGRectMake(half, 0, half, _height) over:canvas];
            break;
        }
        case CallVideoLayoutThemPnp:
        default:
            canvas = [self draw:remoteBuf rotation:remoteRot cover:CGRectMake(0, 0, _width, _height) over:canvas];
            if (localBuf && _pnpSize > 0) {
                // Top-left, 10pt in, as the web draws it. CoreImage's origin is bottom-left, so
                // "10 from the top" is height - size - 10.
                CGRect inset = CGRectMake(10, _height - _pnpSize - 10, _pnpSize, _pnpSize);
                canvas = [self draw:localBuf rotation:localRot cover:inset over:canvas];
            }
            break;
    }

    [_ciContext render:canvas toCVPixelBuffer:out];

    CMTime pts = CMTimeMake(_videoFrameIndex, (int32_t)_fps);
    if (![_videoAdaptor appendPixelBuffer:out withPresentationTime:pts]) {
        RCTLogWarn(@"[CallVideoRecorder] appendPixelBuffer failed (%@)",
                   _writer.error.localizedDescription ?: @"unknown");
    }
    _videoFrameIndex++;

    CVPixelBufferRelease(out);
    if (localBuf) {
        CVPixelBufferRelease(localBuf);
    }
    if (remoteBuf) {
        CVPixelBufferRelease(remoteBuf);
    }
}

/**
 * Draws one source into `rect`, scaled to FILL and cropped — no letterbox bars, matching the
 * web compositor's drawCover. Rotation is applied here because the frame carries it and nothing
 * else will: the display path rotates at the layer, which a file has no equivalent of, so a
 * portrait camera records sideways unless this does it.
 */
- (CIImage *)draw:(CVPixelBufferRef)pixels
         rotation:(RTCVideoRotation)rotation
            cover:(CGRect)rect
             over:(CIImage *)canvas {
    if (pixels == NULL || rect.size.width <= 0 || rect.size.height <= 0) {
        return canvas;  // no picture for this slot — the black canvas shows through
    }
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixels];
    switch (rotation) {
        case RTCVideoRotation_90:
            image = [image imageByApplyingCGOrientation:kCGImagePropertyOrientationRight];
            break;
        case RTCVideoRotation_180:
            image = [image imageByApplyingCGOrientation:kCGImagePropertyOrientationDown];
            break;
        case RTCVideoRotation_270:
            image = [image imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
            break;
        case RTCVideoRotation_0:
        default:
            break;
    }

    CGRect extent = image.extent;
    if (extent.size.width <= 0 || extent.size.height <= 0) {
        return canvas;
    }
    CGFloat scale = MAX(rect.size.width / extent.size.width, rect.size.height / extent.size.height);
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    // Centre the scaled image on the rect, then clip to it — the overflow is the crop.
    CGRect scaled = image.extent;
    CGFloat dx = CGRectGetMinX(rect) + (rect.size.width - scaled.size.width) / 2.0 - CGRectGetMinX(scaled);
    CGFloat dy = CGRectGetMinY(rect) + (rect.size.height - scaled.size.height) / 2.0 - CGRectGetMinY(scaled);
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
    image = [image imageByCroppingToRect:rect];
    return [image imageByCompositingOverImage:canvas];
}

- (void)disableVideoLeg {
    _videoUsable = NO;
    if (_tickTimer) {
        dispatch_source_cancel(_tickTimer);
        _tickTimer = nil;
    }
    os_unfair_lock_lock(&_slotLock);
    [_slots removeAllObjects];
    os_unfair_lock_unlock(&_slotLock);
}

#pragma mark - Audio

- (void)appendAudioTick:(const int16_t *)samples count:(NSUInteger)count {
    if (samples == NULL || count == 0 || _finished) {
        return;
    }
    // COPIED before hopping queues. The caller's buffer is its per-tick scratch and is
    // overwritten 100 times a second; handing the pointer to another queue would encode
    // whatever the mixer happened to be writing.
    NSData *copy = [NSData dataWithBytes:samples length:count * sizeof(int16_t)];
    const NSUInteger channels = _stereo ? 2 : 1;
    const NSUInteger frames = count / channels;
    if (frames == 0) {
        return;
    }
    dispatch_async(_queue, ^{
        [self appendAudioFrames:copy frames:frames];
    });
}

/** _queue only. */
- (void)appendAudioFrames:(NSData *)pcm frames:(NSUInteger)frames {
    if (_finished || !_started || _writer.status != AVAssetWriterStatusWriting) {
        return;
    }
    if (!_audioInput.isReadyForMoreMediaData) {
        if (!_loggedAudioDrop) {
            _loggedAudioDrop = YES;
            RCTLogWarn(@"[CallVideoRecorder] audio input not ready — mp4 audio will have a gap");
        }
        return;
    }

    const NSUInteger channels = _stereo ? 2 : 1;
    AudioStreamBasicDescription asbd = {
        .mSampleRate = kAudioSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = (UInt32)(sizeof(int16_t) * channels),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = (UInt32)(sizeof(int16_t) * channels),
        .mChannelsPerFrame = (UInt32)channels,
        .mBitsPerChannel = 16,
    };

    CMAudioFormatDescriptionRef format = NULL;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &format) != noErr) {
        return;
    }

    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, pcm.length, kCFAllocatorDefault, NULL, 0,
                                           pcm.length, 0, &block) != noErr) {
        CFRelease(format);
        return;
    }
    if (CMBlockBufferReplaceDataBytes(pcm.bytes, block, 0, pcm.length) != noErr) {
        CFRelease(block);
        CFRelease(format);
        return;
    }

    // Derived from samples already written, never from a host clock — see the clock note above.
    CMTime pts = CMTimeMake(_audioSamplesWritten, kAudioSampleRate);
    CMSampleBufferRef sample = NULL;
    if (CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, format, (CMItemCount)frames,
                                                             pts, NULL, &sample) == noErr &&
        sample != NULL) {
        [_audioInput appendSampleBuffer:sample];
        _audioSamplesWritten += (int64_t)frames;
        CFRelease(sample);
    }
    CFRelease(block);
    CFRelease(format);
}

#pragma mark - Stop

- (void)stopWithCompletion:(void (^)(NSDictionary *result, NSError *error))completion {
    dispatch_async(_queue, ^{
        if (self->_finished) {
            completion(nil, [NSError errorWithDomain:kCallRecordingErrorDomain
                                                code:CallRecordingErrorIO
                                            userInfo:@{NSLocalizedDescriptionKey : @"Already stopped"}]);
            return;
        }
        self->_finished = YES;
        if (self->_tickTimer) {
            dispatch_source_cancel(self->_tickTimer);
            self->_tickTimer = nil;
        }

        // Nothing usable: the writer died early, or no frame was ever composited. Say so rather
        // than finishing a file with an empty video track, which plays as a black rectangle and
        // looks like a compositor bug instead of a backgrounded app.
        if (self->_writer.status != AVAssetWriterStatusWriting || self->_videoFrameIndex == 0) {
            NSString *reason = self->_writer.error.localizedDescription ?: @"no frames composited";
            [self->_writer cancelWriting];
            [[NSFileManager defaultManager] removeItemAtPath:self->_outputPath error:nil];
            self->_videoUsable = NO;
            completion(nil, [NSError errorWithDomain:kCallRecordingErrorDomain
                                                code:CallRecordingErrorEncode
                                            userInfo:@{NSLocalizedDescriptionKey : reason}]);
            return;
        }

        [self->_videoInput markAsFinished];
        [self->_audioInput markAsFinished];
        // The mp4's duration is the video timeline's, so end the session where the frames end.
        [self->_writer endSessionAtSourceTime:CMTimeMake(self->_videoFrameIndex, (int32_t)self->_fps)];

        [self->_writer finishWritingWithCompletionHandler:^{
            if (self->_writer.status != AVAssetWriterStatusCompleted) {
                self->_videoUsable = NO;
                completion(nil, [NSError errorWithDomain:kCallRecordingErrorDomain
                                                    code:CallRecordingErrorEncode
                                                userInfo:@{
                                                    NSLocalizedDescriptionKey :
                                                        self->_writer.error.localizedDescription ?: @"finish failed"
                                                }]);
                return;
            }
            NSDictionary *attributes =
                [[NSFileManager defaultManager] attributesOfItemAtPath:self->_outputPath error:nil];
            double durationMs = (double)self->_videoFrameIndex * 1000.0 / (double)self->_fps;
            completion(@{
                @"filePath" : self->_outputPath,
                @"durationMs" : @((int64_t)durationMs),
                @"size" : attributes[NSFileSize] ?: @0,
            },
                       nil);
        }];
    });
}

@end
