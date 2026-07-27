#import "CallRecordingAudioProcessingDelegate.h"

#import "CallAudioRecorder.h"

// RTCAudioBuffer channel pointers stay well under this; stack array avoids per-callback
// allocation. enum (not static const) so it can size a stack array without a VLA warning.
enum { kMaxCaptureChannels = 8 };

@implementation CallRecordingAudioProcessingDelegate {
    // Written by audioProcessingInitialize..., read in audioProcessingProcess:. Aligned 32-bit
    // loads/stores are atomic on Apple silicon, so a plain ivar is race-safe here.
    int32_t _sampleRate;
    // Reusable float->int16 conversion buffer; grown on demand, only touched on the APM
    // capture thread, so no lock is needed.
    int16_t *_monoBuffer;
    size_t _monoCapacity;
}

- (void)dealloc {
    free(_monoBuffer);
}

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz channels:(size_t)channels {
    _sampleRate = (int32_t)sampleRateHz;
}

- (void)audioProcessingProcess:(RTCAudioBuffer *)audioBuffer {
    NSArray<CallAudioRecorder *> *recorders = self.micRecorders;
    if (recorders.count == 0) {
        return;  // fast no-op whenever nothing is recording the mic
    }
    size_t frames = audioBuffer.frames;
    size_t channels = MIN(audioBuffer.channels, kMaxCaptureChannels);
    if (frames == 0 || channels == 0) {
        return;
    }
    double sampleRate = (double)_sampleRate;
    if (sampleRate <= 0) {
        sampleRate = (double)frames * 100.0;  // APM processes 10 ms chunks; derive if init never fired
    }
    if (frames > _monoCapacity) {
        int16_t *grown = realloc(_monoBuffer, frames * sizeof(int16_t));
        if (grown == NULL) {
            return;
        }
        _monoBuffer = grown;
        _monoCapacity = frames;
    }
    // The RTCAudioBuffer float pointers are only valid inside this callback — copy synchronously.
    float *channelData[kMaxCaptureChannels];
    for (size_t c = 0; c < channels; c++) {
        channelData[c] = [audioBuffer rawBufferForChannel:c];
    }
    const float scale = 32767.0f / (float)channels;  // downmix by averaging, then float [-1,1] -> int16
    for (size_t i = 0; i < frames; i++) {
        float acc = 0;
        for (size_t c = 0; c < channels; c++) {
            acc += channelData[c][i];
        }
        float sample = acc * scale;
        if (sample > 32767.0f) {
            sample = 32767.0f;
        } else if (sample < -32768.0f) {
            sample = -32768.0f;
        }
        _monoBuffer[i] = (int16_t)sample;
    }
    for (CallAudioRecorder *recorder in recorders) {
        [recorder pushMicSamples:_monoBuffer count:frames sampleRate:sampleRate];
    }
}

- (void)audioProcessingRelease {
    // Nothing held per-stream; the conversion buffer is reused across sessions.
}

@end
