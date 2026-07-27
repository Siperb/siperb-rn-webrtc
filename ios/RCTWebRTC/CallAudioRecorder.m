#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <stdio.h>

#import <React/RCTLog.h>

#import "CallAudioRecorder.h"

NSString *const kCallRecordingErrorDomain = @"CallRecording";

static const double kTargetSampleRate = 48000;
static const NSUInteger kSamplesPerTick = 480;  // 10 ms @ 48 kHz
static const NSUInteger kRingCapacity = 24000;  // ~500 ms per source, drop-oldest on overflow
static const uint64_t kTickIntervalNs = 10 * NSEC_PER_MSEC;
static const NSUInteger kWarmupTicks = 20;  // 200 ms: skip all-empty ticks while sources spin up
static const NSUInteger kMaxDrainTicks = 256;
// enum (not static const) so these can size stack arrays without a VLA warning
enum {
    kWavHeaderSize = 44,
    kResampleChunkCapacity = 4096,  // stack scratch for one resampled slice
};

static NSError *CallRecordingError(CallRecordingErrorCode code, NSString *message) {
    return [NSError errorWithDomain:kCallRecordingErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

#pragma mark - Ring buffer source

/**
 * One audio source feeding the mix: a drop-oldest ring of mono int16 samples already
 * resampled to 48 kHz. Pushed from a real-time audio thread, pulled by the writer clock,
 * so all state is guarded by a small unfair lock (never held across file IO).
 */
@interface CallRecorderAudioSource : NSObject {
  @public
    os_unfair_lock _lock;
    int16_t *_ring;
    NSUInteger _head;
    NSUInteger _count;
    // Linear-resampler carry state: fractional read position ahead of the previous block's
    // last sample, so interpolation stays continuous across push boundaries.
    double _resamplePos;
    int16_t _lastSample;
}
@end

@implementation CallRecorderAudioSource

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _ring = malloc(kRingCapacity * sizeof(int16_t));
        _resamplePos = 1.0;  // start exactly on the first real input sample
    }
    return self;
}

- (void)dealloc {
    free(_ring);
}

- (void)appendSamples:(const int16_t *)samples count:(NSUInteger)count {
    if (_ring == NULL || count == 0) {
        return;
    }
    if (count > kRingCapacity) {  // keep only the newest full window
        samples += count - kRingCapacity;
        count = kRingCapacity;
    }
    os_unfair_lock_lock(&_lock);
    NSUInteger overflow = (_count + count > kRingCapacity) ? (_count + count - kRingCapacity) : 0;
    if (overflow > 0) {  // drop-oldest
        _head = (_head + overflow) % kRingCapacity;
        _count -= overflow;
    }
    NSUInteger tail = (_head + _count) % kRingCapacity;
    NSUInteger firstSegment = MIN(count, kRingCapacity - tail);
    memcpy(_ring + tail, samples, firstSegment * sizeof(int16_t));
    if (count > firstSegment) {
        memcpy(_ring, samples + firstSegment, (count - firstSegment) * sizeof(int16_t));
    }
    _count += count;
    os_unfair_lock_unlock(&_lock);
}

- (NSUInteger)pullSamples:(int16_t *)out count:(NSUInteger)want {
    os_unfair_lock_lock(&_lock);
    NSUInteger take = MIN(_count, want);
    NSUInteger firstSegment = MIN(take, kRingCapacity - _head);
    memcpy(out, _ring + _head, firstSegment * sizeof(int16_t));
    if (take > firstSegment) {
        memcpy(out + firstSegment, _ring, (take - firstSegment) * sizeof(int16_t));
    }
    _head = (_head + take) % kRingCapacity;
    _count -= take;
    os_unfair_lock_unlock(&_lock);
    return take;
}

- (BOOL)hasSamples {
    os_unfair_lock_lock(&_lock);
    BOOL any = _count > 0;
    os_unfair_lock_unlock(&_lock);
    return any;
}

/** Resamples to 48 kHz (linear interpolation) and appends. Runs on the pushing audio thread. */
- (void)pushSamples:(const int16_t *)samples count:(NSUInteger)count sampleRate:(double)sampleRate {
    if (count == 0 || sampleRate <= 0) {
        return;
    }
    if (sampleRate == kTargetSampleRate) {
        [self appendSamples:samples count:count];
        // Keep carry state coherent in case the rate changes on the next push.
        _lastSample = samples[count - 1];
        _resamplePos = 1.0;
        return;
    }
    // Virtual input stream: v[0] = _lastSample, v[1..count] = samples[0..count-1].
    // Emit output at fractional positions pos, pos+step, ... while pos < count.
    const double step = sampleRate / kTargetSampleRate;
    double pos = _resamplePos;
    int16_t scratch[kResampleChunkCapacity];  // bounded stack slice; loop re-fills for long inputs
    while (pos < (double)count) {
        NSUInteger produced = 0;
        while (pos < (double)count && produced < kResampleChunkCapacity) {
            NSUInteger index = (NSUInteger)pos;
            double frac = pos - (double)index;
            int16_t s0 = (index == 0) ? _lastSample : samples[index - 1];
            int16_t s1 = samples[index];
            scratch[produced++] = (int16_t)(s0 + (double)(s1 - s0) * frac);
            pos += step;
        }
        [self appendSamples:scratch count:produced];
    }
    _resamplePos = pos - (double)count;
    _lastSample = samples[count - 1];
}

@end

#pragma mark - WAV helpers

static void WriteLE32(uint8_t *bytes, uint32_t value) {
    bytes[0] = value & 0xFF;
    bytes[1] = (value >> 8) & 0xFF;
    bytes[2] = (value >> 16) & 0xFF;
    bytes[3] = (value >> 24) & 0xFF;
}

static void WriteLE16(uint8_t *bytes, uint16_t value) {
    bytes[0] = value & 0xFF;
    bytes[1] = (value >> 8) & 0xFF;
}

/** Canonical 44-byte PCM header (mono, 48 kHz, 16-bit) with placeholder sizes. */
static BOOL WriteWavHeader(FILE *file) {
    uint8_t header[kWavHeaderSize];
    memcpy(header, "RIFF", 4);
    WriteLE32(header + 4, 0);  // placeholder, patched on finalize
    memcpy(header + 8, "WAVE", 4);
    memcpy(header + 12, "fmt ", 4);
    WriteLE32(header + 16, 16);
    WriteLE16(header + 20, 1);  // PCM
    WriteLE16(header + 22, 1);  // mono
    WriteLE32(header + 24, (uint32_t)kTargetSampleRate);
    WriteLE32(header + 28, (uint32_t)kTargetSampleRate * 2);  // byte rate
    WriteLE16(header + 32, 2);                                // block align
    WriteLE16(header + 34, 16);                               // bits per sample
    memcpy(header + 36, "data", 4);
    WriteLE32(header + 40, 0);  // placeholder, patched on finalize
    return fwrite(header, 1, kWavHeaderSize, file) == kWavHeaderSize;
}

/**
 * Patches the RIFF/data sizes from the actual file length. Length-derived on purpose: it is
 * correct both for a clean stop and for an orphan whose placeholders were never patched.
 */
static BOOL PatchWavHeaderFromLength(NSString *wavPath, NSError **error) {
    FILE *file = fopen(wavPath.UTF8String, "r+b");
    if (file == NULL) {
        if (error) {
            *error = CallRecordingError(CallRecordingErrorIO,
                                        [NSString stringWithFormat:@"Cannot open WAV file: %@", wavPath]);
        }
        return NO;
    }
    BOOL ok = NO;
    do {
        if (fseek(file, 0, SEEK_END) != 0) {
            break;
        }
        long length = ftell(file);
        if (length < (long)(kWavHeaderSize + sizeof(int16_t))) {
            break;  // no audio data worth salvaging
        }
        uint8_t magic[4];
        if (fseek(file, 0, SEEK_SET) != 0 || fread(magic, 1, 4, file) != 4 || memcmp(magic, "RIFF", 4) != 0) {
            break;
        }
        if (fseek(file, 8, SEEK_SET) != 0 || fread(magic, 1, 4, file) != 4 || memcmp(magic, "WAVE", 4) != 0) {
            break;
        }
        if (fseek(file, 36, SEEK_SET) != 0 || fread(magic, 1, 4, file) != 4 || memcmp(magic, "data", 4) != 0) {
            break;  // not our canonical 44-byte layout
        }
        uint32_t dataBytes = (uint32_t)((length - kWavHeaderSize) & ~1L);  // whole int16 samples only
        uint8_t sizeBytes[4];
        WriteLE32(sizeBytes, 36 + dataBytes);
        if (fseek(file, 4, SEEK_SET) != 0 || fwrite(sizeBytes, 1, 4, file) != 4) {
            break;
        }
        WriteLE32(sizeBytes, dataBytes);
        if (fseek(file, 40, SEEK_SET) != 0 || fwrite(sizeBytes, 1, 4, file) != 4) {
            break;
        }
        ok = YES;
    } while (NO);
    fclose(file);
    if (!ok && error) {
        *error = CallRecordingError(CallRecordingErrorIO,
                                    [NSString stringWithFormat:@"Not a salvageable WAV file: %@", wavPath]);
    }
    return ok;
}

#pragma mark - Recorder

@implementation CallAudioRecorder {
    NSArray<CallRecorderAudioSource *> *_sources;  // remote sources first, mic (if any) last
    NSUInteger _micSourceIndex;                    // NSNotFound when includesMic is NO
    dispatch_queue_t _writerQueue;
    dispatch_source_t _writerTimer;
    FILE *_file;
    NSUInteger _tickCount;
    BOOL _stopped;  // writer-queue confined
    int16_t *_pullBuffer;
    int32_t *_mixBuffer;
    int16_t *_writeBuffer;
    BOOL _writeFailureLogged;
}

- (instancetype)initWithRecordingId:(NSString *)recordingId
                            wavPath:(NSString *)wavPath
                            m4aPath:(NSString *)m4aPath
                        includesMic:(BOOL)includesMic
                  remoteSourceCount:(NSUInteger)remoteSourceCount {
    self = [super init];
    if (self) {
        _recordingId = [recordingId copy];
        _wavPath = [wavPath copy];
        _m4aPath = [m4aPath copy];
        _includesMic = includesMic;
        NSUInteger sourceCount = remoteSourceCount + (includesMic ? 1 : 0);
        NSMutableArray<CallRecorderAudioSource *> *sources = [NSMutableArray arrayWithCapacity:sourceCount];
        for (NSUInteger i = 0; i < sourceCount; i++) {
            [sources addObject:[CallRecorderAudioSource new]];
        }
        _sources = [sources copy];
        _micSourceIndex = includesMic ? remoteSourceCount : NSNotFound;
        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -1);
        _writerQueue = dispatch_queue_create("CallAudioRecorder.writer", attributes);
        _pullBuffer = malloc(kSamplesPerTick * sizeof(int16_t));
        _mixBuffer = malloc(kSamplesPerTick * sizeof(int32_t));
        _writeBuffer = malloc(kSamplesPerTick * sizeof(int16_t));
    }
    return self;
}

- (void)dealloc {
    if (_writerTimer) {
        dispatch_source_cancel(_writerTimer);  // handler holds self weakly, so cancel here is the backstop
    }
    if (_file != NULL) {
        fclose(_file);
    }
    free(_pullBuffer);
    free(_mixBuffer);
    free(_writeBuffer);
}

- (BOOL)start:(NSError **)error {
    _file = fopen(_wavPath.UTF8String, "wb");
    if (_file == NULL || !WriteWavHeader(_file)) {
        if (_file != NULL) {
            fclose(_file);
            _file = NULL;
        }
        if (error) {
            *error = CallRecordingError(CallRecordingErrorIO,
                                        [NSString stringWithFormat:@"Cannot create WAV file: %@", _wavPath]);
        }
        return NO;
    }
    _writerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _writerQueue);
    dispatch_source_set_timer(_writerTimer,
                              dispatch_time(DISPATCH_TIME_NOW, kTickIntervalNs),
                              kTickIntervalNs,
                              2 * NSEC_PER_MSEC);
    __weak CallAudioRecorder *weakSelf = self;
    dispatch_source_set_event_handler(_writerTimer, ^{
        [weakSelf writerTick];
    });
    dispatch_resume(_writerTimer);
    return YES;
}

- (void)pushMicSamples:(const int16_t *)samples count:(NSUInteger)count sampleRate:(double)sampleRate {
    if (_micSourceIndex == NSNotFound) {
        return;
    }
    [_sources[_micSourceIndex] pushSamples:samples count:count sampleRate:sampleRate];
}

- (void)pushRemoteSamples:(const int16_t *)samples
                    count:(NSUInteger)count
               sampleRate:(double)sampleRate
              sourceIndex:(NSUInteger)sourceIndex {
    NSUInteger remoteCount = _sources.count - (_includesMic ? 1 : 0);
    if (sourceIndex >= remoteCount) {
        return;
    }
    [_sources[sourceIndex] pushSamples:samples count:count sampleRate:sampleRate];
}

#pragma mark Writer clock (writer queue only)

- (BOOL)anySourceHasSamples {
    for (CallRecorderAudioSource *source in _sources) {
        if ([source hasSamples]) {
            return YES;
        }
    }
    return NO;
}

/** Pulls one 10 ms frame from every source (zero-padding underruns), mixes and appends. */
- (void)writeOneTickFrame {
    memset(_mixBuffer, 0, kSamplesPerTick * sizeof(int32_t));
    for (CallRecorderAudioSource *source in _sources) {
        NSUInteger pulled = [source pullSamples:_pullBuffer count:kSamplesPerTick];
        for (NSUInteger i = 0; i < pulled; i++) {
            _mixBuffer[i] += _pullBuffer[i];
        }
    }
    for (NSUInteger i = 0; i < kSamplesPerTick; i++) {
        int32_t sample = _mixBuffer[i];  // saturating sum keeps overlapping loud sources clip-safe
        if (sample > INT16_MAX) {
            sample = INT16_MAX;
        } else if (sample < INT16_MIN) {
            sample = INT16_MIN;
        }
        _writeBuffer[i] = (int16_t)sample;
    }
    if (fwrite(_writeBuffer, sizeof(int16_t), kSamplesPerTick, _file) != kSamplesPerTick) {
        if (!_writeFailureLogged) {
            _writeFailureLogged = YES;  // log once; a full disk would otherwise spam every 10 ms
            RCTLogWarn(@"[CallRecording] WAV write failed for %@ (disk full?)", _recordingId);
        }
        return;
    }
    fflush(_file);  // push each frame to the OS so a crash loses at most the buffered tail
}

- (void)writerTick {
    if (_stopped || _file == NULL) {
        return;
    }
    _tickCount++;
    if (_tickCount <= kWarmupTicks && ![self anySourceHasSamples]) {
        return;  // warmup: wait for first audio instead of writing leading silence
    }
    [self writeOneTickFrame];
}

#pragma mark Stop / finalize

- (void)stopWithCompletion:(void (^)(NSDictionary *result, NSError *error))completion {
    dispatch_async(_writerQueue, ^{
        if (self->_stopped || self->_file == NULL) {
            completion(nil, CallRecordingError(CallRecordingErrorIO, @"Recording already stopped"));
            return;
        }
        self->_stopped = YES;
        if (self->_writerTimer) {
            dispatch_source_cancel(self->_writerTimer);
            self->_writerTimer = nil;
        }
        // Sinks are detached before stop, so the rings only drain; cap defends against a straggler.
        for (NSUInteger i = 0; i < kMaxDrainTicks && [self anySourceHasSamples]; i++) {
            [self writeOneTickFrame];
        }
        fclose(self->_file);
        self->_file = NULL;
        // Encode off the stop path; stopCallRecording resolves only once the .m4a exists.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSError *error = nil;
            NSDictionary *result = [CallAudioRecorder finalizeWavAtPath:self->_wavPath
                                                              toM4aPath:self->_m4aPath
                                                                  error:&error];
            completion(result, result ? nil : error);
        });
    });
}

+ (NSDictionary *)finalizeWavAtPath:(NSString *)wavPath toM4aPath:(NSString *)m4aPath error:(NSError **)error {
    NSError *patchError = nil;
    if (!PatchWavHeaderFromLength(wavPath, &patchError)) {
        if (error) {
            *error = patchError;
        }
        return nil;
    }

    // Encode via ExtAudioFile: we KNOW the WAV layout (we wrote it), so feed the
    // int16 PCM straight into the AAC converter instead of trusting AVAudioFile's
    // format negotiation (which failed opaquely with nil NSErrors on device).
    // Every failure path carries the exact OSStatus for diagnosis.
    uint32_t srcRate = 0;
    uint16_t srcChannels = 0;
    uint16_t srcBits = 0;
    uint32_t dataBytes = 0;
    {
        FILE *header = fopen(wavPath.UTF8String, "rb");
        uint8_t fields[24];
        // fmt chunk fields live at offset 22 (channels u16, rate u32, ..., bits u16 at 34), data size at 40.
        BOOL headerOk = header != NULL && fseek(header, 22, SEEK_SET) == 0 && fread(fields, 1, 22, header) == 22;
        if (header != NULL) {
            fclose(header);
        }
        if (!headerOk) {
            if (error) {
                *error = CallRecordingError(CallRecordingErrorIO,
                                            [NSString stringWithFormat:@"Cannot re-read WAV header: %@", wavPath]);
            }
            return nil;
        }
        srcChannels = (uint16_t)(fields[0] | (fields[1] << 8));
        srcRate = (uint32_t)(fields[2] | (fields[3] << 8) | ((uint32_t)fields[4] << 16) | ((uint32_t)fields[5] << 24));
        srcBits = (uint16_t)(fields[12] | (fields[13] << 8));
        dataBytes = (uint32_t)(fields[18] | (fields[19] << 8) | ((uint32_t)fields[20] << 16) | ((uint32_t)fields[21] << 24));
    }
    if (srcBits != 16 || srcChannels == 0 || srcRate == 0 || dataBytes == 0) {
        if (error) {
            *error = CallRecordingError(
                CallRecordingErrorEncode,
                [NSString stringWithFormat:@"Unexpected WAV format (%u Hz, %u ch, %u bit)", srcRate, srcChannels,
                                           srcBits]);
        }
        return nil;
    }
    const uint32_t bytesPerFrame = (uint32_t)srcChannels * 2;
    long long durationMs = llround((double)(dataBytes / bytesPerFrame) * 1000.0 / srcRate);

    [[NSFileManager defaultManager] removeItemAtPath:m4aPath error:nil];  // clean retry after a failed encode

    AudioStreamBasicDescription srcDesc = {0};
    srcDesc.mSampleRate = srcRate;
    srcDesc.mFormatID = kAudioFormatLinearPCM;
    srcDesc.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    srcDesc.mBitsPerChannel = 16;
    srcDesc.mChannelsPerFrame = srcChannels;
    srcDesc.mBytesPerFrame = bytesPerFrame;
    srcDesc.mFramesPerPacket = 1;
    srcDesc.mBytesPerPacket = bytesPerFrame;

    AudioStreamBasicDescription dstDesc = {0};
    dstDesc.mSampleRate = srcRate;
    dstDesc.mFormatID = kAudioFormatMPEG4AAC;
    dstDesc.mChannelsPerFrame = srcChannels;

    ExtAudioFileRef extFile = NULL;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:m4aPath], kAudioFileM4AType,
                                                &dstDesc, NULL, kAudioFileFlags_EraseFile, &extFile);
    if (status == noErr) {
        status = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat, sizeof(srcDesc), &srcDesc);
    }
    if (status == noErr) {
        // Best-effort 64 kbps; the hardware/software converter's default stands if this fails.
        AudioConverterRef converter = NULL;
        UInt32 size = sizeof(converter);
        if (ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr &&
            converter != NULL) {
            UInt32 bitRate = 64000;
            if (AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, sizeof(bitRate), &bitRate) !=
                noErr) {
                RCTLogWarn(@"[CallRecording] Could not set 64kbps AAC bitrate; using converter default");
            } else {
                CFArrayRef config = NULL;  // flush the converter state after changing properties
                ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ConverterConfig, sizeof(config), &config);
            }
        }
    }

    BOOL encoded = NO;
    if (status == noErr) {
        FILE *pcm = fopen(wavPath.UTF8String, "rb");
        if (pcm == NULL || fseek(pcm, kWavHeaderSize, SEEK_SET) != 0) {
            status = kAudioFileUnspecifiedError;
            if (pcm != NULL) {
                fclose(pcm);
                pcm = NULL;
            }
        } else {
            enum { kEncodeChunkFrames = 16384 };
            int16_t *chunk = malloc((size_t)kEncodeChunkFrames * bytesPerFrame);
            uint32_t framesLeft = dataBytes / bytesPerFrame;
            encoded = chunk != NULL;
            while (encoded && framesLeft > 0) {
                uint32_t frames = framesLeft < kEncodeChunkFrames ? framesLeft : kEncodeChunkFrames;
                size_t readFrames = fread(chunk, bytesPerFrame, frames, pcm);
                if (readFrames == 0) {
                    break;  // truncated file — encode what we had
                }
                AudioBufferList bufferList;
                bufferList.mNumberBuffers = 1;
                bufferList.mBuffers[0].mNumberChannels = srcChannels;
                bufferList.mBuffers[0].mDataByteSize = (UInt32)(readFrames * bytesPerFrame);
                bufferList.mBuffers[0].mData = chunk;
                status = ExtAudioFileWrite(extFile, (UInt32)readFrames, &bufferList);
                if (status != noErr) {
                    encoded = NO;
                    break;
                }
                framesLeft -= (uint32_t)readFrames;
            }
            free(chunk);
            fclose(pcm);
        }
    }
    if (extFile != NULL) {
        OSStatus disposeStatus = ExtAudioFileDispose(extFile);  // flushes + finalizes the .m4a container
        if (encoded && disposeStatus != noErr) {
            status = disposeStatus;
            encoded = NO;
        }
    }

    if (!encoded) {
        [[NSFileManager defaultManager] removeItemAtPath:m4aPath error:nil];  // keep only the WAV for salvage
        if (error) {
            *error = CallRecordingError(
                CallRecordingErrorEncode,
                [NSString stringWithFormat:@"AAC encode failed (OSStatus %d)", (int)status]);
        }
        return nil;
    }

    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:m4aPath error:nil];
    unsigned long long size = [attributes fileSize];
    NSError *removeError = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:wavPath error:&removeError]) {
        RCTLogWarn(@"[CallRecording] Could not delete WAV %@: %@", wavPath, removeError.localizedDescription);
    }
    return @{@"filePath" : m4aPath, @"durationMs" : @(durationMs), @"size" : @(size)};
}

@end
