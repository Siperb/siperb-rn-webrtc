package com.oney.WebRTCModule.audio;

import android.content.Context;
import android.util.Log;

import org.webrtc.AudioTrack;
import org.webrtc.AudioTrackSink;
import org.webrtc.ExternalAudioProcessingFactory;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.VideoDecoderFactory;
import org.webrtc.VideoEncoderFactory;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.ShortBuffer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Wires the {@link ConferenceAudioBus} into WebRTC's actual audio paths.
 *
 * THE SHAPE, and why it is asymmetric. An AudioDeviceModule is set per
 * PeerConnectionFactory and feeds every sender on it, and a PeerConnection belongs to its
 * factory for life. One factory therefore means one outbound signal shared by every leg,
 * while a three-way call needs two different ones. So:
 *
 *   - The HOST leg stays on the app's existing factory, and its outbound is written by
 *     overwriting that factory's capture buffer. Safe only because it is the sole leg
 *     there -- the moment two legs share a factory they share an outbound and one of them
 *     hears itself.
 *   - Each further leg is born on a factory of its own, whose capture buffer we overwrite
 *     with that leg's mix.
 *
 * CAPTURE-POST, NOT THE PRE-APM HOOK, on the host factory. Anything written pre-APM is fed
 * to the echo canceller as if the microphone had heard it, and because the other party is
 * also in the render reference the AEC would subtract it straight back out.
 *
 * A REAL AudioRecord RUNS ON EVERY FACTORY, including the synthesised ones, and that is a
 * device finding rather than a design choice: setUseAudioRecord(false) is inert on
 * webrtc-sdk 125.6422.07 -- the buffer callback never fires at all, so nothing can be
 * injected. Leaving the capture running and overwriting its buffer works. The cost is a
 * microphone stream per leg that nobody listens to.
 *
 * IDLE-COST IS THE FIRST THING TO PROTECT. Both hooks sit in the path of every ordinary
 * 1:1 call, so each returns on its first line when no conference is up, and the processing
 * factory ships with both bypass flags set.
 */
public final class ConferenceMixManager {
    private static final String TAG = "ConferenceMix";

    private final Context context;
    private final ConferenceAudioBus bus = ConferenceAudioBus.getInstance();

    /** The leg carried by the app's main factory. Null when no conference is up. */
    private volatile String hostLegId;

    private ExternalAudioProcessingFactory mainAudioProcessing;

    /** Per synthesised leg: its own factory, ADM, and the buffers its capture callback uses. */
    private final Map<String, SyntheticLeg> synthetic = new LinkedHashMap<>();
    /** Remote taps, by leg. */
    private final Map<String, List<RemoteTap>> taps = new LinkedHashMap<>();
    private final Object legLock = new Object();

    public ConferenceMixManager(Context context) {
        this.context = context;
    }

    // =====================================================================
    // The main factory's hooks
    // =====================================================================

    /**
     * The processing factory to hand the app's own PeerConnectionFactory.
     *
     * Must be installed at construction: a factory's processing is fixed when it is built,
     * which is the same per-factory constraint that forces a second factory in the first
     * place. Both paths start BYPASSED, so installing this changes nothing until a
     * conference starts.
     */
    public ExternalAudioProcessingFactory buildMainAudioProcessing() {
        mainAudioProcessing = new ExternalAudioProcessingFactory();
        mainAudioProcessing.setBypassFlagForCapturePost(true);
        mainAudioProcessing.setBypassFlagForRenderPre(true);
        mainAudioProcessing.setCapturePostProcessing(new HostCaptureMixer());
        mainAudioProcessing.setRenderPreProcessing(new HostRenderMixer());
        return mainAudioProcessing;
    }

    /**
     * An aux source (a presented file's soundtrack) joins the bus, and the render hook wakes
     * up so the presenter hears it through WebRTC's own playout.
     *
     * THROUGH THE PLAYOUT, NOT A SECOND PLAYER, and that is the whole point: what APM's
     * render stage plays is what the echo canceller uses as its reference, so the file that
     * leaves the loudspeaker is subtracted from the microphone by construction - by AEC3 and
     * by a hardware AEC alike, on any route. A MediaPlayer playing the same file beside
     * WebRTC would be outside that reference and come straight back in through the mic.
     */
    public void attachAux(String auxId) {
        bus.addAux(auxId);
        if (mainAudioProcessing != null) mainAudioProcessing.setBypassFlagForRenderPre(false);
    }

    /** The aux leaves; the render hook goes back to bypass once nothing is left to play. */
    public void detachAux(String auxId) {
        bus.removeAux(auxId);
        if (!bus.hasAux() && mainAudioProcessing != null) mainAudioProcessing.setBypassFlagForRenderPre(true);
    }

    /**
     * Reads the post-AEC microphone onto the bus, then overwrites the same buffer with what
     * the host leg should be sent.
     *
     * ONE CALLBACK, BOTH DIRECTIONS, and the order matters: the mic has to reach the bus
     * before the mix is drawn, or the host's outbound is a frame behind and the first frame
     * of every conference is missing us entirely.
     */
    private final class HostCaptureMixer implements ExternalAudioProcessingFactory.AudioProcessing {
        private int sampleRate;
        private int channels = 1;
        private short[] io = new short[0];
        private short[] scratch = new short[0];
        private int[] accumulator = new int[0];
        private boolean warnedRate;

        @Override
        public void initialize(int sampleRateHz, int numChannels) {
            sampleRate = sampleRateHz;
            channels = Math.max(1, numChannels);
        }

        @Override
        public void reset(int newRate) {
            sampleRate = newRate;
        }

        @Override
        public void process(int numBands, int numFrames, ByteBuffer buffer) {
            final String legId = hostLegId;
            if (legId == null || sampleRate <= 0 || numFrames <= 0) return;
            // numBands IS A PROPERTY OF THE SAMPLE RATE, not a "currently split" flag:
            // AudioBuffer::num_bands() is 1/2/3 at 16/32/48 kHz. Measured on a Galaxy A52s:
            //
            //     APM SHAPE numBands=3 numFrames=480 channels=1 sampleRate=48000
            //
            // The previous guard was `if (numBands != 1) return;`, so on every 48 kHz device
            // the HOST leg returned before it ever mixed -- it sent the bare microphone and
            // its far end never heard the third party, while synthetic legs worked fine. It
            // would have looked correct on a 16 kHz emulator.
            //
            // BAND 0 ONLY is the right answer, not "all bands": in a split-band buffer the
            // lowest band carries the audible content and the upper bands are the high-
            // frequency remainder. `buffer` is the band-0 plane, `numFrames` its length, so
            // reading it directly is both correct and what the single-band case already did.

            final int total = numFrames * channels;
            if (io.length < total) io = new short[total];
            if (scratch.length < numFrames) scratch = new short[numFrames];
            if (accumulator.length < numFrames) accumulator = new int[numFrames];

            // FLOAT, NOT SHORT, and the samples are FloatS16 -- floats ALREADY in int16 range
            // (+/-32768), not normalised to +/-1. WebRTC's APM works in float on both
            // platforms; iOS's RTCAudioBuffer hands back `float *` for exactly this reason.
            // Reading it as int16 reinterprets the bytes of a float as two samples, which is
            // precisely what static sounds like. Measured on a Galaxy A52s:
            //
            //     APM buffer: bytes=1920 floats=480 numFrames=480 channels=1 bands=3
            //
            // 1920/4 == 480 == numFrames*channels, which also settles the band question: the
            // buffer holds ONE band's worth of data, so it is full-band and overwriting it is
            // correct. bands=3 is informational -- num_bands() of the 48 kHz rate.
            final FloatBuffer pcm = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer();
            final int got = Math.min(total, pcm.remaining());
            for (int i = 0; i < got; i++) {
                final float v = pcm.get(i);
                io[i] = (short) (v > 32767f ? 32767f : (v < -32768f ? -32768f : v));
            }

            // PUSH WHAT WAS ACTUALLY READ, not what was asked for: a short buffer would
            // otherwise push the tail of the previous frame as if it were microphone.
            bus.pushMicrophone(io, got, sampleRate, channels);

            if (!bus.pull(legId, accumulator, scratch, numFrames, io)) {
                // Nothing was summed. The buffer already holds the microphone, so leaving it
                // alone is right -- UNLESS WE ARE MUTED, in which case leaving it alone
                // transmits the live mic. "Nothing summed" is exactly the state a muted host
                // reaches once the other legs underrun or hang up, so this is a real leak.
                if (bus.isMicMuted()) {
                    for (int i = 0; i < got; i++) pcm.put(i, 0f);
                }
                return;
            }

            for (int f = 0; f < numFrames; f++) {
                final float v = scratch[f];
                for (int c = 0; c < channels; c++) {
                    pcm.put(f * channels + c, v);
                }
            }
        }
    }

    /**
     * Adds the aux sources' local copy INTO the playout frame. Additive - the far end's audio
     * in the buffer is untouched - and a pass-through when nothing is attached.
     *
     * Same buffer shape as HostCaptureMixer (FloatS16, band 0, see the notes there). Only at
     * the bus rate: the bus drains 48 kHz frames, and a playout running at another rate would
     * need a resampler this hook does not have, so it does nothing there rather than play
     * the file at the wrong pitch - on that route the presenter does not hear the local copy,
     * which is the lesser fault (the far end still gets it through the capture path).
     */
    private final class HostRenderMixer implements ExternalAudioProcessingFactory.AudioProcessing {
        private int sampleRate;
        private int channels = 1;
        private short[] out = new short[0];
        private short[] scratch = new short[0];
        private int[] accumulator = new int[0];
        private boolean warnedRate;

        @Override
        public void initialize(int sampleRateHz, int numChannels) {
            sampleRate = sampleRateHz;
            channels = Math.max(1, numChannels);
        }

        @Override
        public void reset(int newRate) {
            sampleRate = newRate;
        }

        @Override
        public void process(int numBands, int numFrames, ByteBuffer buffer) {
            if (numFrames <= 0 || !bus.hasAux()) return;
            if (sampleRate != ConferenceAudioBus.SAMPLE_RATE) {
                if (!warnedRate) {
                    warnedRate = true;
                    Log.w(TAG, "render hook at " + sampleRate + " Hz, bus is " + ConferenceAudioBus.SAMPLE_RATE
                            + " - the presenter's local copy of the file is not played on this route");
                }
                return;
            }
            if (out.length < numFrames) out = new short[numFrames];
            if (scratch.length < numFrames) scratch = new short[numFrames];
            if (accumulator.length < numFrames) accumulator = new int[numFrames];

            if (!bus.pullAuxSum(ConferenceAudioBus.CONSUMER_RENDER, accumulator, out, numFrames, scratch)) return;

            final FloatBuffer pcm = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer();
            final int total = Math.min(numFrames * channels, pcm.remaining());
            for (int i = 0; i < total; i++) {
                final float v = pcm.get(i) + out[i / channels];
                pcm.put(i, v > 32767f ? 32767f : (v < -32768f ? -32768f : v));
            }
        }
    }

    // =====================================================================
    // Synthesised legs
    // =====================================================================

    private final class SyntheticLeg implements JavaAudioDeviceModule.AudioBufferCallback {
        final String legId;
        /**
         * Set AFTER construction, because the ADM needs this object as its callback before
         * the factory that owns the ADM can exist. One instance serves both roles - two
         * would mean the ADM calling back into an object the registry never sees.
         */
        PeerConnectionFactory factory;
        private short[] frame = new short[0];
        private short[] scratch = new short[0];
        private int[] accumulator = new int[0];

        SyntheticLeg(String legId) {
            this.legId = legId;
        }

        /**
         * Overwrite this leg's capture with its own mix.
         *
         * The buffer handed here is the SAME memory passed on to the encoder, which is what
         * makes the write meaningful. Its contents on arrival are a real microphone we do
         * not want and simply discard - see the class note on why the capture still runs.
         */
        @Override
        public long onBuffer(ByteBuffer buffer, int audioFormat, int channelCount,
                int sampleRate, int bytesRead, long captureTimeNs) {
            if (channelCount <= 0 || sampleRate <= 0 || bytesRead <= 0) return captureTimeNs;

            final int frames = bytesRead / (2 * channelCount);
            if (frames <= 0) return captureTimeNs;
            if (frame.length < frames) frame = new short[frames];
            if (scratch.length < frames) scratch = new short[frames];
            if (accumulator.length < frames) accumulator = new int[frames];

            if (!bus.pull(legId, accumulator, frame, frames, scratch)) {
                // Silence rather than the live microphone: this leg must never hear the room
                // directly, only what the bus says it should.
                java.util.Arrays.fill(frame, 0, frames, (short) 0);
            }

            final ShortBuffer pcm = buffer.order(ByteOrder.nativeOrder()).asShortBuffer();
            for (int f = 0; f < frames; f++) {
                for (int c = 0; c < channelCount; c++) {
                    pcm.put(f * channelCount + c, frame[f]);
                }
            }
            return captureTimeNs;
        }
    }

    /**
     * Build (or return) the factory a synthesised leg's PeerConnection must be created on.
     *
     * Called before the leg is dialled, because the factory is fixed at PeerConnection
     * construction and can never be changed afterwards. This works only because a
     * conference child is dialled AFTER the conference is requested; two calls that already
     * exist cannot be merged, and the caller is expected to refuse that with a reason.
     */
    public PeerConnectionFactory factoryForLeg(
            String legId, VideoEncoderFactory encoderFactory, VideoDecoderFactory decoderFactory) {
        if (legId == null) return null;
        synchronized (legLock) {
            SyntheticLeg existing = synthetic.get(legId);
            if (existing != null) return existing.factory;

            bus.addLeg(legId);

            SyntheticLeg leg = new SyntheticLeg(legId);
            JavaAudioDeviceModule adm = JavaAudioDeviceModule.builder(context)
                                                .setEnableVolumeLogger(false)
                                                .setAudioBufferCallback(leg)
                                                .createAudioDeviceModule();

            PeerConnectionFactory factory = PeerConnectionFactory.builder()
                                                    .setAudioDeviceModule(adm)
                                                    .setVideoEncoderFactory(encoderFactory)
                                                    .setVideoDecoderFactory(decoderFactory)
                                                    .createPeerConnectionFactory();
            // The factory owns the native ADM now, as the app's own factory does with its.
            adm.release();

            leg.factory = factory;
            synthetic.put(legId, leg);
            Log.i(TAG, "factoryForLeg: synthesised leg " + legId + " has its own factory");
            return factory;
        }
    }

    // =====================================================================
    // Legs and taps
    // =====================================================================

    /**
     * Put a leg on the bus and start tapping its remote audio.
     *
     * @param host true for the leg carried by the app's main factory. There can be only
     *             one, because that factory has one outbound to overwrite.
     */
    public void attachLeg(String legId, List<AudioTrack> remoteTracks, boolean host) {
        if (legId == null) return;
        synchronized (legLock) {
            bus.addLeg(legId);
            if (host) {
                hostLegId = legId;
                setMainInjectionEnabled(true);
            }

            // RE-ATTACH IS A REFRESH, NOT AN ADDITION. The SDK republishes a leg's mix on every
            // join, so this runs once per participant for the same leg; appending a second tap
            // per remote track summed that party twice into every mix (double level). Drop the
            // previous taps and re-tap from the tracks handed in now.
            List<RemoteTap> existing = taps.get(legId);
            if (existing == null) {
                existing = new ArrayList<>();
                taps.put(legId, existing);
            } else {
                for (RemoteTap tap : existing) tap.detach();
                existing.clear();
            }
            if (remoteTracks != null) {
                for (AudioTrack track : remoteTracks) {
                    if (track == null) continue;
                    RemoteTap tap = new RemoteTap(legId, track);
                    tap.attach();
                    existing.add(tap);
                }
            }
            Log.i(TAG, "attachLeg: " + legId + (host ? " (host)" : "") + " taps=" + existing.size());
        }
    }

    /** Take a leg off the bus, detach its taps, and dispose its factory if it had one. */
    public void detachLeg(String legId) {
        if (legId == null) return;
        synchronized (legLock) {
            List<RemoteTap> legTaps = taps.remove(legId);
            if (legTaps != null) {
                for (RemoteTap tap : legTaps) tap.detach();
            }
            // NOT disposed here. nativeFreeFactory destroys the factory AND stops its
            // signaling/worker/network threads, and any PeerConnection built on it is then
            // holding dangling pointers -- a native crash on hangup, timing-dependent.
            // detachLeg and pc.close() are separate JS calls with no ordering between them,
            // so the factory is retained until teardown, which the contract places after the
            // calls are down. A retained factory is a leak; a disposed one is a crash.
            synthetic.remove(legId);

            bus.removeLeg(legId);
            if (legId.equals(hostLegId)) {
                hostLegId = null;
                setMainInjectionEnabled(false);
            }
            Log.i(TAG, "detachLeg: " + legId);
        }
    }

    /** The conference is over. Idempotent, and safe to call when none was ever up. */
    public void teardown() {
        synchronized (legLock) {
            for (String legId : new ArrayList<>(taps.keySet())) {
                List<RemoteTap> legTaps = taps.get(legId);
                if (legTaps != null) {
                    for (RemoteTap tap : legTaps) tap.detach();
                }
            }
            taps.clear();
            // Same reasoning as detachLeg: teardown can be called while a PeerConnection is
            // still open (the contract even advertises it as safe when none was ever up), so
            // disposing here would be the same dangling-thread crash. Released when the
            // process is.
            synthetic.clear();
            hostLegId = null;
            setMainInjectionEnabled(false);
            bus.clear();
            Log.i(TAG, "teardown: conference audio released");
        }
    }

    public List<String> legIds() {
        return bus.legIds();
    }

    public void setMicMuted(boolean muted) {
        bus.setMicMuted(muted);
    }

    /**
     * Flip the main factory's capture injection.
     *
     * Bypassed means the callback is not invoked at all, which is what keeps an idle
     * conference off the 1:1 path entirely rather than merely making it cheap.
     */
    private void setMainInjectionEnabled(boolean enabled) {
        if (mainAudioProcessing == null) return;
        mainAudioProcessing.setBypassFlagForCapturePost(!enabled);
    }

    /**
     * One remote track feeding one leg's ring.
     *
     * onData runs on a WebRTC audio thread and the buffer is only valid for the duration of
     * the callback, so it is copied out immediately.
     */
    private final class RemoteTap implements AudioTrackSink {
        private final String legId;
        private final AudioTrack track;
        private short[] copy = new short[0];
        private boolean warnedBadFormat;

        RemoteTap(String legId, AudioTrack track) {
            this.legId = legId;
            this.track = track;
        }

        void attach() {
            track.addSink(this);
        }

        void detach() {
            try {
                track.removeSink(this);
            } catch (Throwable t) {
                // A track disposed ahead of us is not an error worth surfacing: teardown
                // ordering between the PeerConnection and this manager is not guaranteed.
                Log.w(TAG, "RemoteTap.detach: " + t);
            }
        }

        @Override
        public void onData(ByteBuffer audioData, int bitsPerSample, int sampleRate,
                int numberOfChannels, int numberOfFrames, long absoluteCaptureTimestampMs) {
            if (bitsPerSample != 16) {
                if (!warnedBadFormat) {
                    warnedBadFormat = true;
                    Log.w(TAG, "Unsupported remote sample size " + bitsPerSample + " bits; leg " + legId + " skipped");
                }
                return;
            }
            final ShortBuffer shorts = audioData.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer();
            final int total = Math.min(numberOfFrames * numberOfChannels, shorts.remaining());
            if (total <= 0) return;
            if (copy.length < total) copy = new short[total];
            shorts.get(copy, 0, total);
            bus.pushLeg(legId, copy, total, sampleRate, numberOfChannels);
        }
    }
}
