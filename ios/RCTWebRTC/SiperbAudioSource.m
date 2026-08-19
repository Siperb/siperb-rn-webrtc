#import "SiperbAudioSource.h"

const double SiperbAudioTargetSampleRate = 48000;
const NSUInteger SiperbAudioRingCapacity = 24000;

/** Stack scratch for one resampled slice. Moved with the class it belongs to. */
enum {
    kResampleChunkCapacity = 4096,
};

@implementation SiperbAudioSource

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _ring = malloc(SiperbAudioRingCapacity * sizeof(int16_t));
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
    if (count > SiperbAudioRingCapacity) {  // keep only the newest full window
        samples += count - SiperbAudioRingCapacity;
        count = SiperbAudioRingCapacity;
    }
    os_unfair_lock_lock(&_lock);
    NSUInteger overflow = (_count + count > SiperbAudioRingCapacity) ? (_count + count - SiperbAudioRingCapacity) : 0;
    if (overflow > 0) {  // drop-oldest
        _head = (_head + overflow) % SiperbAudioRingCapacity;
        _count -= overflow;
    }
    NSUInteger tail = (_head + _count) % SiperbAudioRingCapacity;
    NSUInteger firstSegment = MIN(count, SiperbAudioRingCapacity - tail);
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
    NSUInteger firstSegment = MIN(take, SiperbAudioRingCapacity - _head);
    memcpy(out, _ring + _head, firstSegment * sizeof(int16_t));
    if (take > firstSegment) {
        memcpy(out + firstSegment, _ring, (take - firstSegment) * sizeof(int16_t));
    }
    _head = (_head + take) % SiperbAudioRingCapacity;
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
    if (sampleRate == SiperbAudioTargetSampleRate) {
        [self appendSamples:samples count:count];
        // Keep carry state coherent in case the rate changes on the next push.
        _lastSample = samples[count - 1];
        _resamplePos = 1.0;
        return;
    }
    // Virtual input stream: v[0] = _lastSample, v[1..count] = samples[0..count-1].
    // Emit output at fractional positions pos, pos+step, ... while pos < count.
    const double step = sampleRate / SiperbAudioTargetSampleRate;
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
