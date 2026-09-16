#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <stdio.h>

#import <React/RCTLog.h>

#import "CallAudioRecorder.h"
#import "SiperbConferenceAudioBus.h"

NSString *const kCallRecordingErrorDomain = @"CallRecording";

#define kTargetSampleRate SiperbAudioTargetSampleRate
static const NSUInteger kSamplesPerTick = 480;  // 10 ms @ 48 kHz
#define kRingCapacity SiperbAudioRingCapacity
static const uint64_t kTickIntervalNs = 10 * NSEC_PER_MSEC;
static const NSUInteger kWarmupTicks = 20;  // 200 ms: skip all-empty ticks while sources spin up
static const NSUInteger kMaxDrainTicks = 256;
// enum (not static const) so these can size stack arrays without a VLA warning
enum {
    kWavHeaderSize = 44,
    kWavChannelsOffset = 22,  // fmt-chunk channel count, little-endian u16
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
#import "SiperbAudioSource.h"

// CallRecorderAudioSource moved to SiperbAudioSource so the conference mixer can reuse
// the same ring and resampler rather than carrying a second copy. A pure move.
typedef SiperbAudioSource CallRecorderAudioSource;


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

/** Saturating: overlapping loud sources clip rather than wrap. */
static inline int16_t ClampToInt16(int32_t sample) {
    if (sample > INT16_MAX) {
        return INT16_MAX;
    }
    if (sample < INT16_MIN) {
        return INT16_MIN;
    }
    return (int16_t)sample;
}

/** Canonical 44-byte PCM header (48 kHz, 16-bit, given channel count) with placeholder sizes. */
static BOOL WriteWavHeader(FILE *file, uint16_t channels) {
    const uint16_t blockAlign = channels * (uint16_t)sizeof(int16_t);
    uint8_t header[kWavHeaderSize];
    memcpy(header, "RIFF", 4);
    WriteLE32(header + 4, 0);  // placeholder, patched on finalize
    memcpy(header + 8, "WAVE", 4);
    memcpy(header + 12, "fmt ", 4);
    WriteLE32(header + 16, 16);
    WriteLE16(header + 20, 1);  // PCM
    WriteLE16(header + kWavChannelsOffset, channels);
    WriteLE32(header + 24, (uint32_t)kTargetSampleRate);
    WriteLE32(header + 28, (uint32_t)kTargetSampleRate * blockAlign);  // byte rate
    WriteLE16(header + 32, blockAlign);
    WriteLE16(header + 34, 16);  // bits per sample
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
        // Whole FRAMES only. A stereo file cut on a sample boundary keeps a trailing lone
        // sample, which shifts channel parity and swaps left and right for the whole encode.
        // The count comes from the header, so a mono WAV from an older build still salvages.
        uint8_t channelBytes[2];
        if (fseek(file, kWavChannelsOffset, SEEK_SET) != 0 || fread(channelBytes, 1, 2, file) != 2) {
            break;
        }
        const long channels = (long)(channelBytes[0] | (channelBytes[1] << 8));
        if (channels != 1 && channels != 2) {
            break;
        }
        const long frameBytes = channels * (long)sizeof(int16_t);
        uint32_t dataBytes = (uint32_t)((length - kWavHeaderSize) - ((length - kWavHeaderSize) % frameBytes));
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
    int32_t *_mixBuffer;   // left in stereo, the single mix in mono
    int32_t *_mixRight;    // NULL in mono
    int16_t *_writeBuffer;
    // The conference sum's own buffers. Separate from the mix ones because pullRemoteSum
    // ZEROES the accumulator it is given, which would wipe the mic if it shared _mixBuffer.
    int32_t *_busAccum;
    int16_t *_busOut;
    // A presented file's soundtrack (the bus's aux sources), summed onto the NEAR side beside
    // the mic - the web records presentation audio on the local channel. Own buffers for the
    // same reason as _busAccum: the pull zeroes the accumulator it is handed.
    int32_t *_auxAccum;
    int16_t *_auxOut;
    NSUInteger _samplesPerWrite;  // interleaved shorts per tick
    BOOL _writeFailureLogged;
    // Last reported far-side source, so the log fires on CHANGE only and not 100x/sec.
    // -1 = nothing reported yet.
    int _lastFromBus;
}

- (instancetype)initWithRecordingId:(NSString *)recordingId
                            wavPath:(NSString *)wavPath
                            m4aPath:(NSString *)m4aPath
                        includesMic:(BOOL)includesMic
                             stereo:(BOOL)stereo
                  remoteSourceCount:(NSUInteger)remoteSourceCount {
    self = [super init];
    if (self) {
        _recordingId = [recordingId copy];
        _wavPath = [wavPath copy];
        _m4aPath = [m4aPath copy];
        _includesMic = includesMic;
        _stereo = stereo;
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
        _samplesPerWrite = kSamplesPerTick * (stereo ? 2 : 1);
        _pullBuffer = malloc(kSamplesPerTick * sizeof(int16_t));
        _mixBuffer = malloc(kSamplesPerTick * sizeof(int32_t));
        _mixRight = stereo ? malloc(kSamplesPerTick * sizeof(int32_t)) : NULL;
        _writeBuffer = malloc(_samplesPerWrite * sizeof(int16_t));
        _busAccum = malloc(kSamplesPerTick * sizeof(int32_t));
        _busOut = malloc(kSamplesPerTick * sizeof(int16_t));
        _auxAccum = malloc(kSamplesPerTick * sizeof(int32_t));
        _auxOut = malloc(kSamplesPerTick * sizeof(int16_t));
        _lastFromBus = -1;
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
    free(_mixRight);
    free(_writeBuffer);
    free(_busAccum);
    free(_busOut);
    free(_auxAccum);
    free(_auxOut);
}

- (BOOL)start:(NSError **)error {
    // The recording consumer's rings on the bus fill to capacity while nothing records and
    // hold the last half second - drained here so a recording started mid-call does not
    // open with stale audio.
    [[SiperbConferenceAudioBus sharedBus] clearRecordingRings];
    _file = fopen(_wavPath.UTF8String, "wb");
    if (_file == NULL || !WriteWavHeader(_file, _stereo ? 2 : 1)) {
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
    if (_mixRight != NULL) {
        memset(_mixRight, 0, kSamplesPerTick * sizeof(int32_t));
    }
    // WHERE THE FAR SIDE COMES FROM, decided per tick rather than at construction.
    //
    // A conference is N sessions on N peer connections, so the per-track taps this recorder was
    // handed at start only ever cover the ONE session that was recorded. The bus holds every
    // leg, live: someone joining mid-recording simply starts appearing in the sum and nothing
    // has to be re-attached. That is what pullRemoteSum was written for.
    //
    // EITHER/OR, NEVER BOTH. The recorded session's own remote track is on the bus AND in
    // _sources, so summing the two would carry that party at double amplitude.
    SiperbConferenceAudioBus *bus = [SiperbConferenceAudioBus sharedBus];
    // AND the pull actually produced something, which is what makes this self-healing. A leg
    // that stayed on the bus after its conference ended -- a missed detach -- would otherwise
    // make isActive true forever and silence the far side of every later recording. A leg that
    // never pushes drains nothing, so the taps are used instead.
    const BOOL busActive = [bus isActive];
    const BOOL fromBus = busActive && [bus pullRemoteSumInto:_busOut
                                                      frames:kSamplesPerTick
                                                 accumulator:_busAccum
                                                     scratch:_pullBuffer];
    // ON CHANGE ONLY - this runs 100x a second. busActive and fromBus are reported separately
    // on purpose: "active but not fromBus" means legs are on the bus and none of them
    // delivered a frame, which is a different fault from having no legs at all.
    if (_lastFromBus != (int)fromBus) {
        _lastFromBus = (int)fromBus;
        RCTLogInfo(@"[CallAudioRecorder] recording %@: far side from %@ (busActive=%d taps=%lu)",
                   _recordingId, fromBus ? @"CONFERENCE BUS" : @"per-track taps", (int)busActive,
                   (unsigned long)(_sources.count - (_micSourceIndex == NSNotFound ? 0 : 1)));
    }
    NSUInteger sourceIndex = 0;
    for (CallRecorderAudioSource *source in _sources) {
        // PULLED EITHER WAY. The taps keep filling whatever this recorder reads; stop draining
        // them and they saturate, then ship the held half-second the moment the conference ends
        // and they become the source again. That failure has already been measured once here,
        // on the mute path -- roughly 490 ms replayed on unmute.
        NSUInteger pulled = [source pullSamples:_pullBuffer count:kSamplesPerTick];
        const BOOL isMic = (sourceIndex == _micSourceIndex);
        sourceIndex++;
        if (fromBus && !isMic) {
            continue;  // drained above, and the bus is carrying the far side this tick
        }
        // Mono sums every source into one channel; stereo puts the mic left and sums every
        // remote party onto the right, so the far side is one mixed channel on a conference.
        int32_t *target = (_mixRight != NULL && !isMic) ? _mixRight : _mixBuffer;
        for (NSUInteger i = 0; i < pulled; i++) {
            target[i] += _pullBuffer[i];
        }
    }
    if (fromBus) {
        int32_t *target = (_mixRight != NULL) ? _mixRight : _mixBuffer;
        for (NSUInteger i = 0; i < kSamplesPerTick; i++) {
            target[i] += _busOut[i];
        }
    }
    // The presented file goes on the NEAR side (left in stereo) with the mic, whatever the
    // far side is coming from: it is what we are playing TO the far end, so it is "us" in the
    // recording, exactly as the web files it under the local channel.
    if ([bus hasAux] && [bus pullAuxSumForConsumer:[SiperbConferenceAudioBus recordingConsumer]
                                              into:_auxOut
                                            frames:kSamplesPerTick
                                       accumulator:_auxAccum
                                           scratch:_pullBuffer]) {
        for (NSUInteger i = 0; i < kSamplesPerTick; i++) {
            _mixBuffer[i] += _auxOut[i];
        }
    }
    if (_mixRight != NULL) {
        for (NSUInteger i = 0; i < kSamplesPerTick; i++) {
            _writeBuffer[i * 2] = ClampToInt16(_mixBuffer[i]);
            _writeBuffer[i * 2 + 1] = ClampToInt16(_mixRight[i]);
        }
    } else {
        for (NSUInteger i = 0; i < kSamplesPerTick; i++) {
            _writeBuffer[i] = ClampToInt16(_mixBuffer[i]);
        }
    }
    // BEFORE the fwrite, so a full disk stops the WAV without also silencing the mp4 — the two
    // consumers of this mix fail independently, which is the point of there being one mix.
    if (_pcmTap) {
        _pcmTap(_writeBuffer, _samplesPerWrite);
    }

    if (fwrite(_writeBuffer, sizeof(int16_t), _samplesPerWrite, _file) != _samplesPerWrite) {
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
