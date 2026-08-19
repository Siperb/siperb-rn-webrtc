package com.oney.WebRTCModule.audiorecorder;

import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.util.Log;
import android.util.Pair;

import com.facebook.react.bridge.Promise;

import com.oney.WebRTCModule.audio.AudioSource;

import org.webrtc.AudioTrack;
import org.webrtc.AudioTrackSink;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * One recording segment: mixes an optional mic source and one source per remote audio
 * track into a 48 kHz 16-bit WAV, then encodes it to .m4a on stop.
 *
 * Stereo recordings are CHANNEL-SPLIT, not true stereo — there is no stereo material in a
 * SIP call to capture. Left carries us (the mic), right carries every remote party summed
 * together, matching the web recorder's CHANNEL_LOCAL / CHANNEL_REMOTE split so a recording
 * means the same thing whichever client made it. On a conference the far side is one mixed
 * channel, not one channel per participant. Mono sums everything into a single channel.
 *
 * Audio callbacks (mic dispatcher / track sinks) only copy into per-source ring buffers;
 * all file IO happens on this recorder's writer HandlerThread and the manager's encode
 * executor. Control methods (attach/detach/start/stop) run on the WebRTCModule executor.
 */
class CallAudioRecorder {
    private static final String TAG = CallAudioRecordingManager.TAG;

    private static final int SAMPLE_RATE = WavFileWriter.SAMPLE_RATE;
    private static final int TICK_MS = 10;
    private static final int SAMPLES_PER_TICK = SAMPLE_RATE / 1000 * TICK_MS; // 480
    // Before this, ticks with no data at all are skipped so a recording never opens with
    // a stretch of padded silence while the first frames are still in flight.
    private static final int WARMUP_MS = 200;
    // ~500 ms per source; overflow drops oldest so a stalled writer can't grow memory.
    private static final int RING_CAPACITY = SAMPLE_RATE / 2;

    private final CallAudioRecordingManager manager;
    final String recordingId;
    private final File wavFile;
    private final File m4aFile;
    private final MicSource micSource; // null when mic capture is not part of this recording
    private final List<RemoteSource> remoteSources = new ArrayList<>();
    private final boolean stereo;
    private final WavFileWriter wav;
    private final HandlerThread writerThread;
    private final Runnable tickRunnable = this::tick;
    private Handler handler;
    private long startUptimeMs;
    private long nextTickUptimeMs;
    private volatile boolean stopping;
    private boolean writeFailed; // writer thread only

    // Mix scratch, writer thread only. mixRight stays unused in mono.
    private final int[] mixAccum = new int[SAMPLES_PER_TICK];
    private final int[] mixRight;
    private final short[] pullScratch = new short[SAMPLES_PER_TICK];
    private final short[] mixOut;

    CallAudioRecorder(CallAudioRecordingManager manager, String recordingId, String wavPath, String m4aPath,
            boolean includeMic, boolean stereo, List<Pair<AudioTrack, Integer>> remoteTracks) throws IOException {
        this.manager = manager;
        this.stereo = stereo;
        this.mixRight = stereo ? new int[SAMPLES_PER_TICK] : null;
        this.mixOut = new short[stereo ? SAMPLES_PER_TICK * 2 : SAMPLES_PER_TICK];
        this.recordingId = recordingId;
        this.wavFile = new File(wavPath);
        this.m4aFile = new File(m4aPath);
        File parent = wavFile.getParentFile();
        if (parent != null) {
            parent.mkdirs();
        }
        this.wav = new WavFileWriter(wavFile, stereo ? 2 : 1);
        this.micSource = includeMic ? new MicSource() : null;
        for (Pair<AudioTrack, Integer> entry : remoteTracks) {
            remoteSources.add(new RemoteSource(entry.first, entry.second));
        }
        this.writerThread = new HandlerThread("CallAudioRecorder-" + recordingId);
    }

    boolean wantsMic() {
        return micSource != null;
    }

    void attachSinks() {
        for (RemoteSource source : remoteSources) {
            source.attach();
        }
    }

    void detachSinks() {
        for (RemoteSource source : remoteSources) {
            source.detach();
        }
    }

    void detachSinksForPeerConnection(int peerConnectionId) {
        for (RemoteSource source : remoteSources) {
            if (source.peerConnectionId == peerConnectionId) {
                source.detach();
            }
        }
    }

    void start() {
        writerThread.start();
        handler = new Handler(writerThread.getLooper());
        startUptimeMs = SystemClock.uptimeMillis();
        nextTickUptimeMs = startUptimeMs + TICK_MS;
        handler.postAtTime(tickRunnable, nextTickUptimeMs);
    }

    /** Called by the manager's mic dispatcher on the WebRTC audio record thread. */
    void pushMicSamples(short[] interleaved, int totalSamples, int sampleRate, int channels) {
        if (micSource != null && !stopping) {
            micSource.push(interleaved, totalSamples, sampleRate, channels);
        }
    }

    /**
     * Stops ticking, flushes whatever the rings still hold, finalizes the WAV and encodes
     * it to .m4a on the manager's encode executor. The promise resolves only after the
     * .m4a is complete; on encode failure the WAV is kept on disk for later salvage.
     */
    void stopAndFinalize(String reason, Promise promise) {
        stopping = true;
        handler.post(() -> {
            handler.removeCallbacks(tickRunnable);
            try {
                // Bounded by ring capacity: sources are already detached, so the rings
                // only drain.
                int guard = (RING_CAPACITY / SAMPLES_PER_TICK + 1) * 2;
                int available;
                while (!writeFailed && guard-- > 0 && (available = maxAvailable()) > 0) {
                    mixAndAppend(Math.min(SAMPLES_PER_TICK, available));
                }
            } catch (IOException e) {
                Log.e(TAG, "Final flush failed for " + recordingId, e);
            }
            try {
                wav.finalizeHeader();
            } catch (IOException e) {
                // Encode still works: it sizes the PCM from file length, and salvage can
                // re-patch the header later.
                Log.e(TAG, "WAV finalize failed for " + recordingId, e);
            }
            writerThread.quitSafely();
            manager.getEncodeExecutor().execute(() -> encodeAndComplete(reason, promise));
        });
    }

    private void encodeAndComplete(String reason, Promise promise) {
        try {
            AacEncoder.Result result = AacEncoder.encode(wavFile, m4aFile);
            if (!wavFile.delete()) {
                Log.w(TAG, "Could not delete WAV " + wavFile);
            }
            manager.finishStop(promise, recordingId, m4aFile.getAbsolutePath(), result.durationMs, result.sizeBytes,
                    reason);
        } catch (IOException e) {
            // Keep the WAV on disk so finalizeOrphanRecording can salvage it later.
            Log.e(TAG, "AAC encode failed for " + recordingId, e);
            manager.failStop(promise, recordingId, "AAC encode failed: " + e.getMessage());
        }
    }

    private void tick() {
        if (stopping || writeFailed) {
            return;
        }
        boolean warmingUp = SystemClock.uptimeMillis() - startUptimeMs <= WARMUP_MS;
        if (warmingUp && maxAvailable() == 0) {
            scheduleNextTick();
            return;
        }
        try {
            mixAndAppend(SAMPLES_PER_TICK);
        } catch (IOException e) {
            // Writer is dead but the recording stays registered: JS decides when to stop,
            // and the finalize path will still salvage what reached the disk.
            writeFailed = true;
            Log.e(TAG, "WAV append failed for " + recordingId, e);
            manager.emitError(recordingId, "wav_write_failed: " + e.getMessage());
            return;
        }
        scheduleNextTick();
    }

    private void scheduleNextTick() {
        // Absolute schedule: late ticks catch up back-to-back instead of drifting, keeping
        // written duration locked to wall clock over long recordings.
        nextTickUptimeMs += TICK_MS;
        long now = SystemClock.uptimeMillis();
        if (nextTickUptimeMs < now - 500) {
            // After a long stall the rings dropped that audio anyway; re-base instead of
            // burst-writing a backlog of near-silence.
            nextTickUptimeMs = now + TICK_MS;
        }
        handler.postAtTime(tickRunnable, nextTickUptimeMs);
    }

    private int maxAvailable() {
        int max = micSource != null ? micSource.ring.available() : 0;
        for (RemoteSource source : remoteSources) {
            int available = source.ring.available();
            if (available > max) {
                max = available;
            }
        }
        return max;
    }

    /** {@code samples} is a per-source frame count; stereo writes twice that many shorts. */
    private void mixAndAppend(int samples) throws IOException {
        Arrays.fill(mixAccum, 0, samples, 0);
        if (stereo) {
            Arrays.fill(mixRight, 0, samples, 0);
            accumulate(micSource, samples, mixAccum);
            for (RemoteSource source : remoteSources) {
                accumulate(source, samples, mixRight);
            }
            for (int i = 0; i < samples; i++) {
                mixOut[i * 2] = clamp(mixAccum[i]);
                mixOut[i * 2 + 1] = clamp(mixRight[i]);
            }
            wav.append(mixOut, samples * 2);
            return;
        }
        accumulate(micSource, samples, mixAccum);
        for (RemoteSource source : remoteSources) {
            accumulate(source, samples, mixAccum);
        }
        for (int i = 0; i < samples; i++) {
            mixOut[i] = clamp(mixAccum[i]);
        }
        wav.append(mixOut, samples);
    }

    /** Saturating: overlapping loud sources clip rather than wrap. */
    private static short clamp(int v) {
        return v > Short.MAX_VALUE ? Short.MAX_VALUE : (v < Short.MIN_VALUE ? Short.MIN_VALUE : (short) v);
    }

    private void accumulate(AudioSource source, int samples, int[] target) {
        if (source == null) {
            return;
        }
        int n = source.ring.read(pullScratch, 0, samples);
        // Samples beyond n stay zero: sources with insufficient data are zero-padded.
        for (int i = 0; i < n; i++) {
            target[i] += pullScratch[i];
        }
    }



    static final class MicSource extends AudioSource {
        MicSource() {
            super(SAMPLE_RATE, RING_CAPACITY);
        }
    }

    /**
     * One remote-track tap. onData runs on a WebRTC audio thread and the buffer is only
     * valid during the callback, so it is copied out immediately.
     */
    static final class RemoteSource extends AudioSource implements AudioTrackSink {
        private final AudioTrack track;
        final int peerConnectionId;
        private boolean attached; // WebRTCModule executor only
        private short[] copyScratch = new short[0];
        private boolean warnedBadFormat;

        RemoteSource(AudioTrack track, int peerConnectionId) {
            super(SAMPLE_RATE, RING_CAPACITY);
            this.track = track;
            this.peerConnectionId = peerConnectionId;
        }

        void attach() {
            if (!attached) {
                track.addSink(this);
                attached = true;
            }
        }

        /** Must run before the track is disposed: removeSink on a disposed track throws. */
        void detach() {
            if (attached) {
                attached = false;
                try {
                    track.removeSink(this);
                } catch (Exception e) {
                    Log.w(TAG, "removeSink failed", e);
                }
            }
        }

        @Override
        public void onData(ByteBuffer audioData, int bitsPerSample, int sampleRate, int numberOfChannels,
                int numberOfFrames, long absoluteCaptureTimestampMs) {
            if (bitsPerSample != 16) {
                if (!warnedBadFormat) {
                    warnedBadFormat = true;
                    Log.w(TAG, "Unsupported remote sample size " + bitsPerSample + " bits; source skipped");
                }
                return;
            }
            ShortBuffer shorts = audioData.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer();
            int total = Math.min(numberOfFrames * numberOfChannels, shorts.remaining());
            if (total <= 0) {
                return;
            }
            if (copyScratch.length < total) {
                copyScratch = new short[total];
            }
            shorts.get(copyScratch, 0, total);
            push(copyScratch, total, sampleRate, numberOfChannels);
        }
    }




}
