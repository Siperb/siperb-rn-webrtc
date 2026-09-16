#if TARGET_OS_IOS

#import "FileFrameSource.h"

#import <MediaToolbox/MediaToolbox.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCVideoFrameBuffer.h>
#import <mach/mach_time.h>
#import <os/lock.h>

#import "SiperbConferenceAudioBus.h"

/** Re-emit rate for the held frame while paused / ended: enough to keep the far end painted. */
static const NSInteger kHoldFps = 2;
/** `progress` event cadence, seconds. */
static const NSTimeInterval kProgressInterval = 1.0;

#pragma mark - The tap's context

/**
 * What the MTAudioProcessingTap callbacks see. Retained BY THE TAP (bridge-retained in
 * `clientInfo`, released in `finalize`), because the tap's callbacks can outlive the player
 * item that carried them; it holds the source only weakly, so a torn-down source is a no-op
 * `process`, never a use-after-free. The scratch buffer is allocated in `prepare`, so `process`
 * — a real-time callback — allocates nothing.
 */
@interface SiperbFileTapContext : NSObject
@property(nonatomic, weak) FileFrameSource *source;
@property(nonatomic, assign) AudioStreamBasicDescription format;
@property(nonatomic, assign) int16_t *mono;
@property(nonatomic, assign) CMItemCount monoCapacity;
@end

@implementation SiperbFileTapContext
- (void)dealloc {
    free(_mono);
}
@end

static void SiperbTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    *tapStorageOut = clientInfo;
}

static void SiperbTapFinalize(MTAudioProcessingTapRef tap) {
    SiperbFileTapContext *context = (__bridge_transfer SiperbFileTapContext *)MTAudioProcessingTapGetStorage(tap);
    context = nil;
}

static void SiperbTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *format) {
    SiperbFileTapContext *context = (__bridge SiperbFileTapContext *)MTAudioProcessingTapGetStorage(tap);
    context.format = *format;
    free(context.mono);
    context.mono = calloc((size_t)maxFrames, sizeof(int16_t));
    context.monoCapacity = maxFrames;
}

static void SiperbTapUnprepare(MTAudioProcessingTapRef tap) {
}

/** Float (interleaved or planar, any channel count) → int16 mono, onto the bus. */
static void SiperbTapProcess(MTAudioProcessingTapRef tap,
                             CMItemCount numberFrames,
                             MTAudioProcessingTapFlags flags,
                             AudioBufferList *bufferListInOut,
                             CMItemCount *numberFramesOut,
                             MTAudioProcessingTapFlags *flagsOut) {
    // Pull the source audio through; the player still needs the buffers even though it is muted.
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (status != noErr) {
        return;
    }
    SiperbFileTapContext *context = (__bridge SiperbFileTapContext *)MTAudioProcessingTapGetStorage(tap);
    FileFrameSource *source = context.source;
    NSString *auxId = source.auxId;
    if (source == nil || auxId == nil || context.mono == NULL) {
        return;
    }
    const CMItemCount frames = MIN(*numberFramesOut, context.monoCapacity);
    if (frames <= 0) {
        return;
    }
    const AudioStreamBasicDescription fmt = context.format;
    const BOOL isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const BOOL planar = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 channels = MAX(1u, fmt.mChannelsPerFrame);
    int16_t *mono = context.mono;

    if (!isFloat) {
        // Not expected from an AVPlayer tap (it hands out Float32), but do not misread int16
        // bytes as floats — that is what static sounds like.
        return;
    }
    if (planar) {
        const UInt32 bufferCount = bufferListInOut->mNumberBuffers;
        for (CMItemCount i = 0; i < frames; i++) {
            float sum = 0.f;
            for (UInt32 c = 0; c < bufferCount; c++) {
                const float *plane = (const float *)bufferListInOut->mBuffers[c].mData;
                if (plane) {
                    sum += plane[i];
                }
            }
            const float v = (sum / (float)MAX(1u, bufferCount)) * 32767.f;
            mono[i] = (int16_t)(v > 32767.f ? 32767.f : (v < -32768.f ? -32768.f : v));
        }
    } else {
        const float *interleaved = (const float *)bufferListInOut->mBuffers[0].mData;
        if (interleaved == NULL) {
            return;
        }
        for (CMItemCount i = 0; i < frames; i++) {
            float sum = 0.f;
            for (UInt32 c = 0; c < channels; c++) {
                sum += interleaved[i * channels + c];
            }
            const float v = (sum / (float)channels) * 32767.f;
            mono[i] = (int16_t)(v > 32767.f ? 32767.f : (v < -32768.f ? -32768.f : v));
        }
    }
    [[SiperbConferenceAudioBus sharedBus] pushAux:auxId samples:mono count:(NSUInteger)frames sampleRate:fmt.mSampleRate];
}

#pragma mark - The source

@interface FileFrameSource ()
@property(nonatomic, strong, nullable) AVPlayer *player;
@property(nonatomic, strong, nullable) AVPlayerItem *item;
@property(nonatomic, strong, nullable) AVPlayerItemVideoOutput *output;
@property(nonatomic, strong, nullable) id timeObserver;
@property(nonatomic, strong, nullable) dispatch_source_t timer;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FileFrameSource {
    MTAudioProcessingTapRef _tap;
    /** The last delivered frame, re-emitted while paused/ended. Guarded by _heldLock: the frame
     *  queue writes it, a seek completion (any queue) and teardown clear it. */
    CVPixelBufferRef _heldBuffer;
    os_unfair_lock _heldLock;
    RTCVideoRotation _rotation;
    CGSize _frameSize;
    NSInteger _fps;
    BOOL _hasAudio;
    Float64 _duration;
    BOOL _userPaused;
    BOOL _suspended;
    BOOL _ended;
    BOOL _loaded;
    BOOL _torn;
    BOOL _holdMode;   // timer runs at kHoldFps re-emitting _heldBuffer
    mach_timebase_info_data_t _timebaseInfo;
    int64_t _startTimeStampNs;
    NSTimeInterval _lastProgress;
}

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate {
    self = [super initWithDelegate:delegate];
    if (self) {
        mach_timebase_info(&_timebaseInfo);
        _startTimeStampNs = -1;
        _heldLock = OS_UNFAIR_LOCK_INIT;
        _userPaused = YES;   // nothing plays until play (or autoplay) says so
        _suspended = YES;    // and no frames until the track's first startCapture
        _queue = dispatch_queue_create("FileFrameSource.frames", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self teardown];
}

- (CGSize)frameSize { return _frameSize; }
- (NSInteger)fps { return _fps; }
- (BOOL)hasAudio { return _hasAudio; }
- (Float64)duration { return _duration; }

#pragma mark Load

- (void)loadURL:(NSURL *)url fps:(NSInteger)fps autoplay:(BOOL)autoplay completion:(void (^)(NSError *_Nullable))completion {
    _fps = fps > 0 ? fps : 25;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
    __weak __typeof__(self) weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration", @"playable" ] completionHandler:^{
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_torn) {
            completion([NSError errorWithDomain:@"FileFrameSource" code:1 userInfo:@{NSLocalizedDescriptionKey : @"released"}]);
            return;
        }
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded || !asset.playable) {
            completion(error ?: [NSError errorWithDomain:@"FileFrameSource" code:2 userInfo:@{NSLocalizedDescriptionKey : @"not playable"}]);
            return;
        }
        AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (video == nil) {
            completion([NSError errorWithDomain:@"FileFrameSource" code:3 userInfo:@{NSLocalizedDescriptionKey : @"no video track"}]);
            return;
        }
        AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        [strongSelf configureWithAsset:asset video:video audio:audio autoplay:autoplay];
        completion(nil);
    }];
}

/** Rotation from the track's preferredTransform: the output hands buffers UNROTATED, so the
 *  frame carries the rotation and WebRTC applies/signals it, exactly as a camera frame does. */
static RTCVideoRotation RotationForTransform(CGAffineTransform t) {
    const double angle = atan2(t.b, t.a) * 180.0 / M_PI;
    const long deg = ((long)llround(angle) % 360 + 360) % 360;
    switch (deg) {
        case 90: return RTCVideoRotation_90;
        case 180: return RTCVideoRotation_180;
        case 270: return RTCVideoRotation_270;
        default: return RTCVideoRotation_0;
    }
}

- (void)configureWithAsset:(AVURLAsset *)asset video:(AVAssetTrack *)video audio:(AVAssetTrack *_Nullable)audio autoplay:(BOOL)autoplay {
    _rotation = RotationForTransform(video.preferredTransform);
    CGSize natural = video.naturalSize;
    _frameSize = (_rotation == RTCVideoRotation_90 || _rotation == RTCVideoRotation_270)
        ? CGSizeMake(natural.height, natural.width)
        : natural;
    _duration = CMTimeGetSeconds(asset.duration);
    if (!isfinite(_duration) || _duration < 0) {
        _duration = 0;
    }
    _hasAudio = audio != nil;

    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];

    // NV12: RTCCVPixelBuffer takes it natively and the hardware encoder consumes it without a
    // conversion; BGRA would cost a colour-space pass per frame.
    NSDictionary *attrs = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    AVPlayerItemVideoOutput *output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
    [item addOutput:output];

    if (audio != nil) {
        [self installTapOnItem:item track:audio];
    }

    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.automaticallyWaitsToMinimizeStalling = NO;
    player.allowsExternalPlayback = NO;
    player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    // MUTED ON PURPOSE: the presenter hears the file through WebRTC's render hook (see the
    // header). The tap still receives every buffer of a muted player.
    player.muted = YES;

    _item = item;
    _output = output;
    _player = player;
    _loaded = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(itemDidPlayToEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(itemFailed:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:item];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];

    __weak __typeof__(self) weakSelf = self;
    _timeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(kProgressInterval, 600)
                                                         queue:_queue
                                                    usingBlock:^(CMTime time) {
        [weakSelf emitEvent:@"progress"];
    }];

    if (autoplay) {
        _userPaused = NO;
    }
    [self applyPlaybackState];
}

- (void)installTapOnItem:(AVPlayerItem *)item track:(AVAssetTrack *)audio {
    SiperbFileTapContext *context = [SiperbFileTapContext new];
    context.source = self;

    MTAudioProcessingTapCallbacks callbacks;
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = (__bridge_retained void *)context;
    callbacks.init = SiperbTapInit;
    callbacks.finalize = SiperbTapFinalize;
    callbacks.prepare = SiperbTapPrepare;
    callbacks.unprepare = SiperbTapUnprepare;
    callbacks.process = SiperbTapProcess;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap);
    if (status != noErr || tap == NULL) {
        // The context was retained for a tap that never came: give it back.
        CFRelease(callbacks.clientInfo);
        _hasAudio = NO;
        return;
    }
    AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audio];
    params.audioTapProcessor = tap;
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[ params ];
    item.audioMix = mix;
    _tap = tap;
}

#pragma mark Transport

- (BOOL)shouldPlay {
    return _loaded && !_torn && !_userPaused && !_suspended && !_ended;
}

/** The one place the player's rate and the frame timer's mode are decided. */
- (void)applyPlaybackState {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_torn || self->_player == nil) {
            return;
        }
        const BOOL playing = [self shouldPlay];
        if (playing) {
            [self->_player play];
        } else {
            [self->_player pause];
        }
        // Frames: at fps while playing, at the hold rate while paused/ended, nothing while
        // suspended (the track is disabled — a held call sends no picture).
        self->_holdMode = !playing;
        if (self->_suspended || !self->_loaded) {
            [self stopTimer];
        } else {
            [self startTimerAtFps:playing ? self->_fps : kHoldFps];
        }
    });
}

- (void)play {
    if (_ended) {
        // play() after the end means from the top, as the web's <video> does.
        _ended = NO;
        [_player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
    _userPaused = NO;
    [self applyPlaybackState];
    [self emitEvent:@"playing"];
}

- (void)pause {
    _userPaused = YES;
    [self applyPlaybackState];
    [self emitEvent:@"paused" extra:@{@"reason" : @"user"}];
}

- (void)seekToSeconds:(Float64)seconds {
    if (_player == nil) {
        return;
    }
    const BOOL wasEnded = _ended;
    _ended = NO;
    CMTime target = CMTimeMakeWithSeconds(MAX(0, seconds), 600);
    __weak __typeof__(self) weakSelf = self;
    [_player seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf == nil || !finished) {
            return;
        }
        // A seek while paused must still show the new frame; drop the held one so the next
        // tick pulls a fresh buffer for the new position.
        [strongSelf releaseHeldBuffer];
        if (wasEnded) {
            [strongSelf applyPlaybackState];
        }
        [strongSelf emitEvent:@"progress"];
    }];
}

- (void)setLocalVolume:(float)volume {
    if (self.auxId) {
        [[SiperbConferenceAudioBus sharedBus] setAuxRenderGain:self.auxId gain:volume];
    }
}

- (void)setSuspended:(BOOL)suspended {
    if (_suspended == suspended) {
        return;
    }
    _suspended = suspended;
    [self applyPlaybackState];
    if (suspended && !_userPaused) {
        [self emitEvent:@"paused" extra:@{@"reason" : @"suspended"}];
    } else if (!suspended && !_userPaused && !_ended) {
        [self emitEvent:@"playing"];
    }
}

- (NSDictionary *)state {
    Float64 position = 0;
    if (_player) {
        position = CMTimeGetSeconds(_player.currentTime);
        if (!isfinite(position) || position < 0) {
            position = 0;
        }
    }
    return @{
        @"playing" : @([self shouldPlay]),
        @"position" : @(position),
        @"duration" : @(_duration),
        @"ended" : @(_ended)
    };
}

#pragma mark Events

- (void)emitEvent:(NSString *)type {
    [self emitEvent:type extra:nil];
}

- (void)emitEvent:(NSString *)type extra:(NSDictionary *_Nullable)extra {
    FileFrameSourceEventBlock block = self.onEvent;
    if (block == nil || _torn) {
        return;
    }
    NSMutableDictionary *body = [[self state] mutableCopy];
    body[@"type"] = type;
    if (extra) {
        [body addEntriesFromDictionary:extra];
    }
    block(type, body);
}

- (void)itemDidPlayToEnd:(NSNotification *)note {
    _ended = YES;
    [self applyPlaybackState];
    [self emitEvent:@"ended"];
}

- (void)itemFailed:(NSNotification *)note {
    NSError *error = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self failWithMessage:error.localizedDescription ?: @"playback failed"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"status"] && object == _item) {
        if (_item.status == AVPlayerItemStatusFailed) {
            [self failWithMessage:_item.error.localizedDescription ?: @"item failed"];
        }
    }
}

- (void)failWithMessage:(NSString *)message {
    [self emitEvent:@"error" extra:@{@"message" : message ?: @""}];
    id<CapturerEventsDelegate> d = self.eventsDelegate;
    if ([d respondsToSelector:@selector(capturerDidEnd:)]) {
        [d capturerDidEnd:self];
    }
}

#pragma mark Frames (the timer, on the private serial queue)

- (void)startTimerAtFps:(NSInteger)fps {
    [self stopTimer];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    const uint64_t interval = (uint64_t)(NSEC_PER_SEC / (double)MAX(1, fps));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf onTick];
    });
    dispatch_resume(timer);
    _timer = timer;
}

- (void)stopTimer {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)onTick {
    if (_torn || _output == nil) {
        return;
    }
    CMTime itemTime = [_output itemTimeForHostTime:CACurrentMediaTime()];
    if ([_output hasNewPixelBufferForItemTime:itemTime]) {
        CVPixelBufferRef buffer = [_output copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
        if (buffer) {
            [self emitPixelBuffer:buffer];
            os_unfair_lock_lock(&_heldLock);
            if (_heldBuffer) {
                CVPixelBufferRelease(_heldBuffer);
            }
            _heldBuffer = buffer;   // ownership of the copy passes to the hold slot
            os_unfair_lock_unlock(&_heldLock);
            return;
        }
    }
    // No new frame (paused, ended, or the decoder has not caught up): keep the far end painted.
    if (_holdMode) {
        os_unfair_lock_lock(&_heldLock);
        CVPixelBufferRef held = _heldBuffer ? CVPixelBufferRetain(_heldBuffer) : NULL;
        os_unfair_lock_unlock(&_heldLock);
        if (held) {
            [self emitPixelBuffer:held];
            CVPixelBufferRelease(held);
        }
    }
}

- (void)emitPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    int64_t now = mach_absolute_time() * _timebaseInfo.numer / _timebaseInfo.denom;
    if (_startTimeStampNs < 0) {
        _startTimeStampNs = now;
    }
    RTCCVPixelBuffer *rtcBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:rtcBuffer rotation:_rotation timeStampNs:now - _startTimeStampNs];
    [self.delegate capturer:self didCaptureVideoFrame:frame];
}

- (void)releaseHeldBuffer {
    os_unfair_lock_lock(&_heldLock);
    if (_heldBuffer) {
        CVPixelBufferRelease(_heldBuffer);
        _heldBuffer = NULL;
    }
    os_unfair_lock_unlock(&_heldLock);
}

#pragma mark Teardown

- (void)teardown {
    if (_torn) {
        return;
    }
    _torn = YES;
    [self stopTimer];
    if (_player && _timeObserver) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
    if (_item) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:_item];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:_item];
        @try {
            [_item removeObserver:self forKeyPath:@"status"];
        } @catch (NSException *ignored) {
        }
    }
    [_player pause];
    // The mix goes before the item, the item before the tap: after this no callback can fire.
    _item.audioMix = nil;
    [_player replaceCurrentItemWithPlayerItem:nil];
    if (_tap) {
        CFRelease(_tap);
        _tap = NULL;
    }
    if (self.auxId) {
        [[SiperbConferenceAudioBus sharedBus] removeAux:self.auxId];
    }
    [self releaseHeldBuffer];
    _output = nil;
    _item = nil;
    _player = nil;
}

@end

#endif
