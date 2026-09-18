#if TARGET_OS_IOS

#import "FileFrameSource.h"

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

/** Audio feeder cadence + windows (seconds), the iOS twins of the Android AudioFeeder's. */
static const NSTimeInterval kAudioTickSeconds = 0.02;   // 20 ms, matches the Android tick
static const Float64 kAudioLeadSeconds = 0.30;          // decode this far ahead of the player clock
static const Float64 kAudioLateSeconds = 0.25;          // behind by more than this: drop (resync)

#pragma mark - One decoded soundtrack chunk

/**
 * A slice of the file's soundtrack: int16 MONO PCM plus the presentation time it is due at,
 * against the player's clock. The audio feeder decodes these ahead into a FIFO and pushes each
 * onto the conference bus as it comes due — the same shape as the Android feeder's `Chunk`.
 */
@interface SiperbFileAudioChunk : NSObject
@property(nonatomic, assign) Float64 pts;   // seconds, presentation time
@property(nonatomic, assign) double rate;   // sample rate the PCM is at
@property(nonatomic, strong) NSData *pcm;   // int16 mono samples
@property(nonatomic, assign) NSUInteger count;   // frames
@end

@implementation SiperbFileAudioChunk
@end

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

    // Audio: an independent AVAssetReader decode paced by the player's clock. Replaces the old
    // MTAudioProcessingTap — a muted AVPlayer under WebRTC's audio session does not reliably
    // clock the tap, so the soundtrack never reached the far end. The reader is offline decode,
    // independent of the audio session and of playback, exactly like the Android MediaCodec
    // feeder. Everything under _audioQueue.
    AVAsset *_audioAsset;
    AVAssetTrack *_audioTrack;
    AVAssetReader *_audioReader;
    AVAssetReaderTrackOutput *_audioOutput;
    dispatch_queue_t _audioQueue;
    dispatch_source_t _audioTimer;
    NSMutableArray<SiperbFileAudioChunk *> *_audioFifo;
    Float64 _audioSeekTarget;   // >= 0 → rebuild the reader from here on the next tick
    BOOL _audioRunning;         // push only while the player is playing
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
        _audioQueue = dispatch_queue_create("FileFrameSource.audio", DISPATCH_QUEUE_SERIAL);
        _audioFifo = [NSMutableArray array];
        _audioSeekTarget = -1;
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

    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.automaticallyWaitsToMinimizeStalling = NO;
    player.allowsExternalPlayback = NO;
    player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    // MUTED ON PURPOSE: the presenter hears the file through WebRTC's render hook (see the
    // header). The player's own audio is never used — the soundtrack reaches both the far end
    // and the presenter's monitor via the audio feeder → conference bus, not this AVPlayer.
    player.muted = YES;

    _item = item;
    _output = output;
    _player = player;
    _loaded = YES;

    if (audio != nil) {
        _audioAsset = asset;
        _audioTrack = audio;
        [self startAudioFeeder];
    }

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
        // The soundtrack follows picture: pushed only while playing (topping-up continues so a
        // chunk is always ready the moment play resumes).
        dispatch_async(self->_audioQueue, ^{
            self->_audioRunning = playing;
        });
    });
}

- (void)play {
    if (_ended) {
        // play() after the end means from the top, as the web's <video> does.
        _ended = NO;
        [_player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        [self requestAudioSeek:0];
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
    [self requestAudioSeek:MAX(0, seconds)];
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

#pragma mark Audio (the feeder, on its own serial queue)

/**
 * Start the soundtrack feeder: open an AVAssetReader on the audio track and tick it. Runs on
 * _audioQueue. If the reader will not open the far end simply gets picture only, exactly as the
 * Android feeder logs and returns. The player's clock (_player.currentTime) is the reference
 * both halves pace against, so picture and sound stay together.
 */
- (void)startAudioFeeder {
    dispatch_async(_audioQueue, ^{
        if (self->_torn || self->_audioTrack == nil || self->_audioAsset == nil) {
            return;
        }
        if (![self buildAudioReaderFrom:0]) {
            NSLog(@"[FileFrameSource] audio feeder could not open — the far end gets picture only");
            return;
        }
        [self startAudioTimer];
    });
}

/** (Re)build the reader from a start position. On _audioQueue. Clears the FIFO. */
- (BOOL)buildAudioReaderFrom:(Float64)startSeconds {
    if (_audioReader) {
        [_audioReader cancelReading];
        _audioReader = nil;
        _audioOutput = nil;
    }
    if (_audioAsset == nil || _audioTrack == nil) {
        return NO;
    }
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:_audioAsset error:&error];
    if (reader == nil) {
        return NO;
    }
    // Interleaved signed 16-bit PCM at the track's native rate/channels; we down-mix to mono
    // below, matching what pushAux: expects (the bus resamples per consumer).
    NSDictionary *settings = @{
        AVFormatIDKey : @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey : @16,
        AVLinearPCMIsFloatKey : @NO,
        AVLinearPCMIsBigEndianKey : @NO,
        AVLinearPCMIsNonInterleaved : @NO,
    };
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:_audioTrack outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        return NO;
    }
    [reader addOutput:output];
    if (startSeconds > 0) {
        reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(startSeconds, 600), kCMTimePositiveInfinity);
    }
    if (![reader startReading]) {
        return NO;
    }
    _audioReader = reader;
    _audioOutput = output;
    [_audioFifo removeAllObjects];
    return YES;
}

- (void)startAudioTimer {
    [self stopAudioTimer];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _audioQueue);
    const uint64_t interval = (uint64_t)(kAudioTickSeconds * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 5);
    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf audioTick];
    });
    dispatch_resume(timer);
    _audioTimer = timer;
}

- (void)stopAudioTimer {
    if (_audioTimer) {
        dispatch_source_cancel(_audioTimer);
        _audioTimer = nil;
    }
}

/** Ask the feeder to rebuild from `seconds` on its next tick. Any thread. */
- (void)requestAudioSeek:(Float64)seconds {
    dispatch_async(_audioQueue, ^{
        self->_audioSeekTarget = MAX(0, seconds);
    });
}

/** One feeder tick, on _audioQueue: honour a pending seek, decode ahead, push what is due. */
- (void)audioTick {
    if (_torn || _audioReader == nil) {
        return;
    }
    [self audioApplySeekIfNeeded];
    [self audioTopUp];
    [self audioPushDue];
}

- (void)audioApplySeekIfNeeded {
    if (_audioSeekTarget < 0) {
        return;
    }
    const Float64 target = _audioSeekTarget;
    _audioSeekTarget = -1;
    [self buildAudioReaderFrom:target];
}

- (Float64)playerPositionSeconds {
    AVPlayer *player = _player;
    if (player == nil) {
        return 0;
    }
    const Float64 t = CMTimeGetSeconds(player.currentTime);
    return (isfinite(t) && t > 0) ? t : 0;
}

/** Decode until the FIFO reaches kAudioLeadSeconds past the player's position (or the track ends). */
- (void)audioTopUp {
    const Float64 horizon = [self playerPositionSeconds] + kAudioLeadSeconds;
    int guard = 0;
    while (_audioReader.status == AVAssetReaderStatusReading && guard++ < 64) {
        SiperbFileAudioChunk *last = _audioFifo.lastObject;
        if (last != nil && last.pts >= horizon) {
            return;
        }
        CMSampleBufferRef sample = [_audioOutput copyNextSampleBuffer];
        if (sample == NULL) {
            return;   // stalled this tick, or the track finished
        }
        SiperbFileAudioChunk *chunk = [self chunkFromSample:sample];
        CFRelease(sample);
        if (chunk) {
            [_audioFifo addObject:chunk];
        }
    }
}

/** int16 interleaved (any channel count) → int16 MONO, wrapped as a chunk with its PTS. */
- (SiperbFileAudioChunk *)chunkFromSample:(CMSampleBufferRef)sample {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    if (format == NULL) {
        return nil;
    }
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (asbd == NULL) {
        return nil;
    }
    const UInt32 channels = MAX(1u, asbd->mChannelsPerFrame);
    const double rate = asbd->mSampleRate > 0 ? asbd->mSampleRate : 48000;

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    if (block == NULL) {
        return nil;
    }
    size_t length = 0;
    char *data = NULL;
    if (CMBlockBufferGetDataPointer(block, 0, NULL, &length, &data) != kCMBlockBufferNoErr || data == NULL) {
        return nil;
    }
    const NSUInteger frames = (length / sizeof(int16_t)) / channels;
    if (frames == 0) {
        return nil;
    }
    const int16_t *interleaved = (const int16_t *)data;
    NSMutableData *mono = [NSMutableData dataWithLength:frames * sizeof(int16_t)];
    int16_t *out = (int16_t *)mono.mutableBytes;
    if (channels == 1) {
        memcpy(out, interleaved, frames * sizeof(int16_t));
    } else {
        for (NSUInteger i = 0; i < frames; i++) {
            int32_t sum = 0;
            for (UInt32 c = 0; c < channels; c++) {
                sum += interleaved[i * channels + c];
            }
            out[i] = (int16_t)(sum / (int32_t)channels);
        }
    }

    Float64 pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
    if (!isfinite(pts) || pts < 0) {
        pts = 0;
    }
    SiperbFileAudioChunk *chunk = [SiperbFileAudioChunk new];
    chunk.pts = pts;
    chunk.rate = rate;
    chunk.pcm = mono;
    chunk.count = frames;
    return chunk;
}

/** Push every chunk that is due against the player's clock; drop what is hopelessly late. */
- (void)audioPushDue {
    if (!_audioRunning) {
        return;
    }
    NSString *auxId = self.auxId;
    if (auxId == nil) {
        return;
    }
    const Float64 now = [self playerPositionSeconds];
    while (_audioFifo.count > 0) {
        SiperbFileAudioChunk *chunk = _audioFifo.firstObject;
        if (chunk.pts > now + kAudioTickSeconds) {
            return;   // not due yet
        }
        [_audioFifo removeObjectAtIndex:0];
        if (chunk.pts < now - kAudioLateSeconds) {
            continue;   // behind after a seek/stall: drop rather than smear old audio
        }
        [[SiperbConferenceAudioBus sharedBus] pushAux:auxId
                                              samples:(const int16_t *)chunk.pcm.bytes
                                                count:chunk.count
                                           sampleRate:chunk.rate];
    }
}

#pragma mark Teardown

- (void)teardown {
    if (_torn) {
        return;
    }
    _torn = YES;
    [self stopTimer];
    // Bring the audio feeder down on its own queue so no tick runs after the reader is gone.
    dispatch_sync(_audioQueue, ^{
        [self stopAudioTimer];
        if (self->_audioReader) {
            [self->_audioReader cancelReading];
            self->_audioReader = nil;
        }
        self->_audioOutput = nil;
        [self->_audioFifo removeAllObjects];
    });
    _audioAsset = nil;
    _audioTrack = nil;
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
    [_player replaceCurrentItemWithPlayerItem:nil];
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
