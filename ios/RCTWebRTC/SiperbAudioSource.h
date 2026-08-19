#import <Foundation/Foundation.h>
#import <os/lock.h>

/** Everything on a mix runs at this rate; sources resample on the way in. */
extern const double SiperbAudioTargetSampleRate;
/** ~500 ms per source. Overflow drops OLDEST, so a stalled consumer cannot grow memory. */
extern const NSUInteger SiperbAudioRingCapacity;

/**
 * One audio source feeding a mix: a drop-oldest ring of mono int16 already resampled to
 * 48 kHz, with linear-resampler carry state so interpolation stays continuous across push
 * boundaries.
 *
 * Pushed from real-time audio threads and pulled by a writer clock, so all state is guarded
 * by a small unfair lock which is NEVER held across file IO.
 *
 * SHARED, because a conference mix needs exactly the same producer side as a recording does
 * and the alternative was a second copy of the resampler. Extracted verbatim from
 * CallAudioRecorder, where it began life as CallRecorderAudioSource.
 */
@interface SiperbAudioSource : NSObject {
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

- (void)appendSamples:(const int16_t *)samples count:(NSUInteger)count;
- (NSUInteger)pullSamples:(int16_t *)out count:(NSUInteger)want;
- (BOOL)hasSamples;
- (void)pushSamples:(const int16_t *)samples count:(NSUInteger)count sampleRate:(double)sampleRate;

@end
