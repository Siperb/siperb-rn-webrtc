#import "RemoteAudioSink.h"

#import "CallAudioRecorder.h"

@implementation RemoteAudioSink {
    // Weak: the recorder (via the manager) owns this sink; a strong back-reference would
    // cycle recorder -> sink -> recorder and keep both alive after stop.
    __weak CallAudioRecorder *_recorder;
    NSUInteger _sourceIndex;
    // Reusable downmix buffer; only touched on this track's audio delivery thread.
    int16_t *_monoBuffer;
    NSUInteger _monoCapacity;
}

- (instancetype)initWithTrack:(RTCAudioTrack *)track
                     recorder:(CallAudioRecorder *)recorder
                  sourceIndex:(NSUInteger)sourceIndex {
    self = [super init];
    if (self) {
        _track = track;
        _recorder = recorder;
        _sourceIndex = sourceIndex;
    }
    return self;
}

- (void)dealloc {
    free(_monoBuffer);
}

- (void)renderPCMBuffer:(AVAudioPCMBuffer *)pcmBuffer {
    CallAudioRecorder *recorder = _recorder;
    if (recorder == nil) {
        return;
    }
    AVAudioFormat *format = pcmBuffer.format;
    NSUInteger frames = pcmBuffer.frameLength;
    NSUInteger channels = format.channelCount;
    double sampleRate = format.sampleRate;
    if (frames == 0 || channels == 0 || sampleRate <= 0) {
        return;
    }
    if (frames > _monoCapacity) {
        int16_t *grown = realloc(_monoBuffer, frames * sizeof(int16_t));
        if (grown == NULL) {
            return;
        }
        _monoBuffer = grown;
        _monoCapacity = frames;
    }
    // The buffer may be float32 or int16, interleaved or not, at any rate — handle all four
    // shapes and downmix by averaging channels.
    if (format.commonFormat == AVAudioPCMFormatFloat32 && pcmBuffer.floatChannelData != NULL) {
        float *const *data = pcmBuffer.floatChannelData;
        const float scale = 32767.0f / (float)channels;
        if (format.isInterleaved) {
            const float *interleaved = data[0];
            for (NSUInteger i = 0; i < frames; i++) {
                float acc = 0;
                for (NSUInteger c = 0; c < channels; c++) {
                    acc += interleaved[i * channels + c];
                }
                float sample = acc * scale;
                if (sample > 32767.0f) {
                    sample = 32767.0f;
                } else if (sample < -32768.0f) {
                    sample = -32768.0f;
                }
                _monoBuffer[i] = (int16_t)sample;
            }
        } else {
            for (NSUInteger i = 0; i < frames; i++) {
                float acc = 0;
                for (NSUInteger c = 0; c < channels; c++) {
                    acc += data[c][i];
                }
                float sample = acc * scale;
                if (sample > 32767.0f) {
                    sample = 32767.0f;
                } else if (sample < -32768.0f) {
                    sample = -32768.0f;
                }
                _monoBuffer[i] = (int16_t)sample;
            }
        }
    } else if (format.commonFormat == AVAudioPCMFormatInt16 && pcmBuffer.int16ChannelData != NULL) {
        int16_t *const *data = pcmBuffer.int16ChannelData;
        if (format.isInterleaved) {
            const int16_t *interleaved = data[0];
            for (NSUInteger i = 0; i < frames; i++) {
                int32_t acc = 0;
                for (NSUInteger c = 0; c < channels; c++) {
                    acc += interleaved[i * channels + c];
                }
                // An average of int16 samples always fits int16 — no clamp needed.
                _monoBuffer[i] = (int16_t)(acc / (int32_t)channels);
            }
        } else {
            for (NSUInteger i = 0; i < frames; i++) {
                int32_t acc = 0;
                for (NSUInteger c = 0; c < channels; c++) {
                    acc += data[c][i];
                }
                _monoBuffer[i] = (int16_t)(acc / (int32_t)channels);
            }
        }
    } else {
        return;  // webrtc-sdk only delivers float32/int16 PCM; anything else is unrecordable
    }
    [recorder pushRemoteSamples:_monoBuffer count:frames sampleRate:sampleRate sourceIndex:_sourceIndex];
}

@end
