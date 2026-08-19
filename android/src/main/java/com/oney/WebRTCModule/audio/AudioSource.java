package com.oney.WebRTCModule.audio;

/**
 * Producer-side state for one input: downmix to mono, resample to the mixer's rate, and
 * write into a bounded ring.
 *
 * push() runs on a real-time audio thread, so scratch buffers are reused and the only
 * locking is the ring's own. Nothing here allocates once it is warm.
 *
 * SHARED, because a conference mix needs exactly the same producer side as a recording
 * does and the alternative was a second copy of the resampler. The rate and ring size are
 * constructor arguments rather than constants for the same reason: the two consumers agree
 * on 48 kHz today, and nothing here should quietly assume they always will.
 */
public abstract class AudioSource {
    /** Read by the mixer that owns this source. */
    public final ShortRingBuffer ring;
    private final LinearResampler resampler;
    private final int outputSampleRate;
    private short[] monoScratch = new short[0];
    private short[] resampleScratch = new short[0];

    /**
     * @param outputSampleRate the rate every consumer of {@link #ring} expects
     * @param ringCapacity     samples of slack before the oldest are dropped
     */
    protected AudioSource(int outputSampleRate, int ringCapacity) {
        this.outputSampleRate = outputSampleRate;
        this.ring = new ShortRingBuffer(ringCapacity);
        this.resampler = new LinearResampler(outputSampleRate);
    }

    public final void push(short[] interleaved, int totalSamples, int sampleRate, int channels) {
        if (channels <= 0 || sampleRate <= 0 || totalSamples < channels) {
            return;
        }
        int frames = totalSamples / channels;
        short[] mono;
        if (channels == 1) {
            mono = interleaved;
        } else {
            if (monoScratch.length < frames) {
                monoScratch = new short[frames];
            }
            for (int f = 0; f < frames; f++) {
                int sum = 0;
                int base = f * channels;
                for (int c = 0; c < channels; c++) {
                    sum += interleaved[base + c];
                }
                monoScratch[f] = (short) (sum / channels);
            }
            mono = monoScratch;
        }
        if (sampleRate == outputSampleRate) {
            ring.write(mono, 0, frames);
            return;
        }
        int needed = resampler.maxOutput(frames, sampleRate);
        if (resampleScratch.length < needed) {
            resampleScratch = new short[needed];
        }
        int produced = resampler.resample(mono, frames, sampleRate, resampleScratch);
        ring.write(resampleScratch, 0, produced);
    }
}
