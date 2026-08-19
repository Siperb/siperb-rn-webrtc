package com.oney.WebRTCModule.audio;

/**
 * Stateful linear-interpolation resampler to 48 kHz. Keeps the previous input sample
 * for continuity across pushes and resets when the input rate changes (e.g. the mic
 * dropping to 16 kHz on a Bluetooth SCO route).
 */
public final class LinearResampler {
    private final int outRate;
    private int inRate = -1;
    private short prev;
    private boolean hasPrev;
    private double pos; // next output position on the input timeline; 0 == prev sample

    public LinearResampler(int outRate) {
        this.outRate = outRate;
    }

    public int maxOutput(int frames, int sampleRate) {
        return (int) ((long) (frames + 1) * outRate / sampleRate) + 2;
    }

    public int resample(short[] in, int frames, int sampleRate, short[] out) {
        if (frames <= 0) {
            return 0;
        }
        if (sampleRate != inRate) {
            inRate = sampleRate;
            hasPrev = false;
        }
        if (!hasPrev) {
            prev = in[0];
            hasPrev = true;
            pos = 0;
        }
        double step = (double) inRate / outRate;
        int produced = 0;
        // Input timeline: index 0 is prev, indices 1..frames are in[0..frames-1].
        while (pos < frames) {
            int i = (int) pos;
            double frac = pos - i;
            int s0 = (i == 0) ? prev : in[i - 1];
            int s1 = in[i];
            out[produced++] = (short) (s0 + frac * (s1 - s0));
            pos += step;
        }
        pos -= frames;
        prev = in[frames - 1];
        return produced;
    }
}
