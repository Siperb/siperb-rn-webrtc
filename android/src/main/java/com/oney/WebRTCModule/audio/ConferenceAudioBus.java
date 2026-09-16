package com.oney.WebRTCModule.audio;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The one place a conference's audio is summed.
 *
 * Holds the microphone and one source per remote leg, and answers a single question:
 * "what should leg X be sent?" - the microphone plus every OTHER leg, never itself. That
 * exclusion is the whole reason this class exists; sending a leg its own audio back is the
 * failure a three-way call has to avoid, and it cannot be fixed downstream because by then
 * the legs are indistinguishable.
 *
 * ONE RING PER CONSUMER, AND THAT IS THE LOAD-BEARING DETAIL. A ring read is destructive,
 * and in a three-way call the microphone is read TWICE per tick - once for the mix going to
 * the host and once for the mix going to the child - plus a third time by a recording. A
 * single ring per source silently gave the second reader an empty buffer: the first mix was
 * correct and every one after it was missing the mic, which sounds like "the other party
 * cannot hear me" and is invisible in review. So each source fans its samples out into one
 * ring per consumer at PUSH time, and every consumer drains its own.
 *
 * The consumers are the legs themselves (each excluding itself) plus CONSUMER_RECORDING,
 * and - for AUX sources only - CONSUMER_RENDER. Fanning out at push also means consumers
 * need not be aligned in time - the two capture callbacks that drive the outbound mixes run
 * on different threads with different clocks, and nothing here requires them to agree.
 *
 * AUX SOURCES are the third kind of input: audio that is neither the microphone nor a remote
 * party - a presented video file's soundtrack. An aux is summed into EVERY leg's mix beside
 * the microphone (every far end hears it, a conference too), it is never muted by micMuted
 * (mute silences the presenter, not the file), it joins the recording on the NEAR side with
 * the mic (the web records presentation audio on the local channel), and it is the only kind
 * of source that fans into CONSUMER_RENDER - the local playout the presenter hears, drained
 * by the APM render hook so the file sits in the echo canceller's reference. It is NOT a
 * leg: it has no mix of its own, and isActive() does not count it.
 *
 * THREADING. Producers are real-time audio threads - the capture callbacks and the remote
 * track sinks. Consumers are whichever threads fill outbound buffers. Rings carry their own
 * lock and are the only synchronisation on the hot path; the source map is copy-on-write so
 * a leg removed mid-mix cannot invalidate an iteration. NOTHING HERE ALLOCATES OR LOGS once
 * it is warm, because all of it runs under a 10 ms deadline.
 *
 * IDLE-CHEAP BY CONTRACT. With no conference up isActive() is false and callers are expected
 * to return before touching anything else - the hooks this feeds sit in the path of every
 * ordinary 1:1 call.
 */
public final class ConferenceAudioBus {

    /** Everything on the bus is at this rate; sources resample on the way in. */
    public static final int SAMPLE_RATE = 48000;
    /**
     * The recording's consumer id. Not a leg, so it excludes nothing.
     *
     * Double-underscored because it shares a namespace with session ids, and a leg that
     * happened to be called "recording" would otherwise quietly drain the recorder's rings.
     */
    public static final String CONSUMER_RECORDING = "__recording__";
    /**
     * The local-playout consumer, drained by the render hook. Only AUX sources fan into it -
     * the mic and the legs already reach the speaker through WebRTC's own playout, and
     * fanning them here would double the per-push cost for a ring nothing drains.
     */
    public static final String CONSUMER_RENDER = "__render__";
    /** ~500 ms of slack per ring. Overflow drops oldest, so a stalled consumer cannot grow memory. */
    private static final int RING_CAPACITY = SAMPLE_RATE / 2;

    private static final ConferenceAudioBus INSTANCE = new ConferenceAudioBus();

    public static ConferenceAudioBus getInstance() {
        return INSTANCE;
    }

    /**
     * One input, fanned out to every consumer.
     *
     * Extends the shared AudioSource for the downmix and resample it already does, then
     * copies the resampled frame into each consumer's ring rather than the single inherited
     * one - see the class note on why one ring cannot serve two readers.
     */
    public static final class BusSource extends AudioSource {
        private volatile Map<String, ShortRingBuffer> rings = Collections.emptyMap();
        private final Object ringLock = new Object();
        /**
         * Applied to the RENDER consumer only - the presenter's local volume for an aux
         * source. The legs and the recording always get it at unity; turning the local copy
         * down must not turn the far end down.
         */
        volatile float renderGain = 1f;

        BusSource() {
            super(SAMPLE_RATE, RING_CAPACITY);
        }

        void ensureConsumer(String consumerId) {
            synchronized (ringLock) {
                if (rings.containsKey(consumerId)) return;
                Map<String, ShortRingBuffer> next = new LinkedHashMap<>(rings);
                next.put(consumerId, new ShortRingBuffer(RING_CAPACITY));
                rings = Collections.unmodifiableMap(next);
            }
        }

        void removeConsumer(String consumerId) {
            synchronized (ringLock) {
                if (!rings.containsKey(consumerId)) return;
                Map<String, ShortRingBuffer> next = new LinkedHashMap<>(rings);
                next.remove(consumerId);
                rings = Collections.unmodifiableMap(next);
            }
        }

        void clearRings() {
            for (ShortRingBuffer ring : rings.values()) ring.clear();
        }

        /** Drop one consumer's buffered audio and keep the ring. No-op for an unknown consumer. */
        void clearRing(String consumerId) {
            final ShortRingBuffer ring = rings.get(consumerId);
            if (ring != null) ring.clear();
        }

        /**
         * Drain this source's frame for one consumer.
         *
         * @return samples read; 0 means underrun, which the caller zero-pads.
         */
        int drain(String consumerId, short[] scratch, int frames) {
            final ShortRingBuffer ring = rings.get(consumerId);
            return ring == null ? 0 : ring.read(scratch, 0, frames);
        }

        /** Fan the inherited (downmixed, resampled) frame out to every consumer. */
        void fanOut(short[] staging) {
            final int n = super.ring.read(staging, 0, staging.length);
            if (n <= 0) return;
            for (ShortRingBuffer ring : rings.values()) {
                ring.write(staging, 0, n);
            }
        }
    }

    private final BusSource mic = new BusSource();

    /** Remote legs by id. COPY-ON-WRITE - replaced wholesale, never mutated in place. */
    private volatile Map<String, BusSource> legs = Collections.emptyMap();
    /**
     * Aux sources by id (a presented file's soundtrack, keyed by its video track id). COPY-ON-
     * WRITE like legs. Membership OUTLIVES a conference - clear() prunes their leg rings and
     * keeps them, because a presentation is not over when the third party leaves.
     */
    private volatile Map<String, BusSource> aux = Collections.emptyMap();
    /** Every consumer currently drawing from the bus: one per leg, plus the recording. */
    private volatile Set<String> consumers = Collections.singleton(CONSUMER_RECORDING);
    private final Object legLock = new Object();

    /**
     * Mute is a property of the MIX, not of the sender track.
     *
     * On mobile the outbound track is no longer the microphone - it is whatever we assemble -
     * so muting the track would mute the whole conference. Leaving the mic out of the sum is
     * the only thing that mutes just us, and it is why mobile can do mute-in-conference at
     * all where the web recorder documents it as not implemented.
     */
    private volatile boolean micMuted = false;

    /** Staging for the push-time fan-out. Guarded by fanLock, never touched on a mix path. */
    private final Object fanLock = new Object();
    private final short[] fanStaging = new short[SAMPLE_RATE / 10];

    private ConferenceAudioBus() {
        mic.ensureConsumer(CONSUMER_RECORDING);
    }

    // =====================================================================
    // Producers
    // =====================================================================

    /**
     * Feed the microphone. Post-AEC samples only - this is what every leg hears as "us".
     *
     * The fan-out happens HERE rather than inside AudioSource.push so the shared producer
     * class stays exactly what the recorder needs it to be.
     */
    public void pushMicrophone(short[] interleaved, int totalSamples, int sampleRate, int channels) {
        mic.push(interleaved, totalSamples, sampleRate, channels);
        fanOut(mic);
    }

    /** Feed one remote leg. No-op for a leg that is not on the bus. */
    public void pushLeg(String legId, short[] interleaved, int totalSamples, int sampleRate, int channels) {
        final BusSource source = legs.get(legId);
        if (source == null) return;
        source.push(interleaved, totalSamples, sampleRate, channels);
        fanOut(source);
    }

    /**
     * Feed one aux source. No-op for an aux that is not on the bus - so a file that keeps
     * decoding after detach costs nothing and delivers nothing.
     */
    public void pushAux(String auxId, short[] interleaved, int totalSamples, int sampleRate, int channels) {
        final BusSource source = aux.get(auxId);
        if (source == null) return;
        source.push(interleaved, totalSamples, sampleRate, channels);
        fanOut(source);
    }

    private void fanOut(BusSource source) {
        synchronized (fanLock) {
            source.fanOut(fanStaging);
        }
    }

    /**
     * Register an aux source. Idempotent - a second attach for a live file must not discard
     * the rings it is mid-way through filling.
     *
     * An aux gains a ring for every consumer there is - each leg's mix, the recording, and
     * the render consumer - and every leg added LATER gains one on it (addLeg). So attach
     * order does not matter: the SDK connects the presentation source before it attaches the
     * host leg, and the leg still finds a fresh, empty ring waiting.
     */
    public void addAux(String auxId) {
        if (auxId == null || CONSUMER_RECORDING.equals(auxId) || CONSUMER_RENDER.equals(auxId)) return;
        synchronized (legLock) {
            if (aux.containsKey(auxId)) return;

            final BusSource source = new BusSource();
            for (String consumerId : consumers) source.ensureConsumer(consumerId);
            source.ensureConsumer(CONSUMER_RENDER);

            final Map<String, BusSource> next = new LinkedHashMap<>(aux);
            next.put(auxId, source);
            aux = Collections.unmodifiableMap(next);
        }
    }

    /** Take an aux source off the bus. Safe for one never added, and for a second removal. */
    public void removeAux(String auxId) {
        if (auxId == null) return;
        synchronized (legLock) {
            if (!aux.containsKey(auxId)) return;
            final Map<String, BusSource> next = new LinkedHashMap<>(aux);
            next.remove(auxId);
            aux = Collections.unmodifiableMap(next);
        }
    }

    public boolean hasAux() {
        return !aux.isEmpty();
    }

    /** Local-playout gain for one aux, 0..1. Affects CONSUMER_RENDER only. No-op for an unknown aux. */
    public void setAuxRenderGain(String auxId, float gain) {
        final BusSource source = aux.get(auxId);
        if (source == null) return;
        source.renderGain = gain < 0f ? 0f : (gain > 1f ? 1f : gain);
    }

    /**
     * Register a remote leg, or leave an existing one exactly as it is.
     *
     * Idempotent because the SDK's JoinConference builds the mix once per leg and is called
     * again for every leg that joins - a second call for a leg already on the bus must patch,
     * never replace, or its rings are discarded mid-call and the party it carries drops out.
     *
     * Adding a leg also adds a CONSUMER (that leg's own mix), so every existing source gains
     * a ring for it and the new source gains rings for every existing consumer.
     */
    public void addLeg(String legId) {
        if (legId == null || CONSUMER_RECORDING.equals(legId)) return;
        synchronized (legLock) {
            if (legs.containsKey(legId)) return;

            final BusSource source = new BusSource();

            final Set<String> nextConsumers = new LinkedHashSet<>(consumers);
            nextConsumers.add(legId);

            final Map<String, BusSource> nextLegs = new LinkedHashMap<>(legs);
            nextLegs.put(legId, source);

            for (String consumerId : nextConsumers) {
                source.ensureConsumer(consumerId);
                mic.ensureConsumer(consumerId);
                for (BusSource existing : legs.values()) existing.ensureConsumer(consumerId);
                for (BusSource existing : aux.values()) existing.ensureConsumer(consumerId);
            }

            legs = Collections.unmodifiableMap(nextLegs);
            consumers = Collections.unmodifiableSet(nextConsumers);
        }
    }

    /** Take a leg off the bus, and its consumer with it. Safe for a leg never added. */
    public void removeLeg(String legId) {
        if (legId == null) return;
        synchronized (legLock) {
            if (!legs.containsKey(legId)) return;

            final Map<String, BusSource> nextLegs = new LinkedHashMap<>(legs);
            nextLegs.remove(legId);
            final Set<String> nextConsumers = new LinkedHashSet<>(consumers);
            nextConsumers.remove(legId);

            mic.removeConsumer(legId);
            for (BusSource remaining : nextLegs.values()) remaining.removeConsumer(legId);
            for (BusSource a : aux.values()) a.removeConsumer(legId);

            legs = Collections.unmodifiableMap(nextLegs);
            consumers = Collections.unmodifiableSet(nextConsumers);

            // Mute is a property of the conference, and the last leg leaving IS the end of
            // the conference. The host detaches leg by leg and never calls clear(), so
            // without this a hang-up while muted left micMuted true on the process-wide bus
            // and the NEXT conference opened with the host silently absent from every mix.
            if (nextLegs.isEmpty()) micMuted = false;
        }
    }

    /**
     * The conference is over: drop every leg, un-mute, and DRAIN THE MICROPHONE.
     *
     * The drain is not tidiness. Leg rings die with their legs, but the microphone source is
     * process-wide and survives - so whatever it still held would be the first thing mixed
     * into the NEXT conference, sending up to half a second of one call's audio to someone
     * who was never on it.
     */
    public void clear() {
        synchronized (legLock) {
            // PRUNE, don't just empty. clearRings() drops ring CONTENTS but leaves the mic
            // holding a ring per leg id forever — only removeLeg prunes, and teardown does not
            // go through it. Leg ids are per-call, so the map grew for the life of the process
            // and fanOut writes EVERY ring on EVERY mic push: the real-time cost grew with the
            // number of conferences the app had ever held.
            for (String consumerId : consumers) {
                if (!CONSUMER_RECORDING.equals(consumerId)) {
                    mic.removeConsumer(consumerId);
                    // Aux MEMBERSHIP survives the conference (the presentation is still
                    // running); only the rings for the legs that just left are pruned.
                    for (BusSource a : aux.values()) a.removeConsumer(consumerId);
                }
            }
            legs = Collections.emptyMap();
            consumers = Collections.singleton(CONSUMER_RECORDING);

            // Inside the lock: these were outside it, so a concurrent addLeg could interleave.
            mic.clearRings();
            mic.ensureConsumer(CONSUMER_RECORDING);
        }
        micMuted = false;
    }

    public boolean isActive() {
        return !legs.isEmpty();
    }

    public List<String> legIds() {
        return new ArrayList<>(legs.keySet());
    }

    public void setMicMuted(boolean muted) {
        micMuted = muted;
    }

    public boolean isMicMuted() {
        return micMuted;
    }

    // =====================================================================
    // Consumers
    // =====================================================================

    /**
     * What leg legId should be sent: the microphone plus every other leg.
     *
     * @param legId       the leg being fed. It is both the consumer identity and the
     *                    exclusion - a leg drains its own rings and never its own audio.
     * @param accumulator caller-owned, at least frames wide
     * @param out         destination, overwritten in full. A short read is zero-padded rather
     *                    than left holding the previous frame: stale audio repeating is far
     *                    more noticeable than a gap.
     * @param scratch     caller-owned, at least frames - passed in so the real-time path
     *                    never allocates.
     * @return true if anything was mixed in; false means this frame is silence
     */
    public boolean pull(String legId, int[] accumulator, short[] out, int frames, short[] scratch) {
        if (legId == null || accumulator == null || out == null || scratch == null || frames <= 0) {
            return false;
        }

        Arrays.fill(accumulator, 0, frames, 0);
        boolean any = false;

        // DRAINED UNCONDITIONALLY, ADDED CONDITIONALLY. Muting only skipped the accumulate,
        // so nothing consumed the mic's rings while pushMicrophone kept filling them — the
        // ring saturated at its 500 ms capacity and HELD the last half second of audio
        // captured while muted. Unmuting then shipped it to the far end, and every word after
        // ran ~490 ms late for the rest of the call. Measured, not theorised.
        final int micSamples = mic.drain(legId, scratch, frames);
        if (!micMuted && micSamples > 0) {
            for (int i = 0; i < micSamples; i++) {
                accumulator[i] += scratch[i];
            }
            any = true;
        }

        // Read the volatile ONCE. Re-reading per leg would let the map change mid-mix, which
        // is the sort of thing that produces a fault nobody can reproduce.
        final Map<String, BusSource> snapshot = legs;
        for (Map.Entry<String, BusSource> entry : snapshot.entrySet()) {
            if (legId.equals(entry.getKey())) continue;
            any |= accumulate(entry.getValue(), legId, accumulator, frames, scratch);
        }

        // Aux sources go to EVERY leg, and they are deliberately outside the micMuted test:
        // mute silences the presenter, never the file they are presenting.
        final Map<String, BusSource> auxSnapshot = aux;
        for (BusSource a : auxSnapshot.values()) {
            any |= accumulate(a, legId, accumulator, frames, scratch);
        }

        clampInto(accumulator, out, frames);
        return any;
    }

    /**
     * Every aux source summed for one non-leg consumer - CONSUMER_RECORDING (the recorder adds
     * it to the NEAR side beside the mic, as the web puts presentation audio on the local
     * channel) or CONSUMER_RENDER (the local playout the presenter hears).
     *
     * Separate from pullRemoteSum on purpose: the far side of a recording stays legs-only, so
     * a transcriber reading the right channel still gets "the others" and nothing we sent.
     */
    public boolean pullAuxSum(String consumerId, int[] accumulator, short[] out, int frames, short[] scratch) {
        if (consumerId == null || accumulator == null || out == null || scratch == null || frames <= 0) return false;

        Arrays.fill(accumulator, 0, frames, 0);
        boolean any = false;

        final boolean render = CONSUMER_RENDER.equals(consumerId);
        final Map<String, BusSource> snapshot = aux;
        for (BusSource a : snapshot.values()) {
            any |= render
                    ? accumulateScaled(a, consumerId, a.renderGain, accumulator, frames, scratch)
                    : accumulate(a, consumerId, accumulator, frames, scratch);
        }

        clampInto(accumulator, out, frames);
        return any;
    }

    /**
     * Empty the recording consumer's rings on every source, mic, legs and aux alike.
     *
     * The recorder drains those rings only while it runs; the rest of the time they fill to
     * capacity and HOLD the last half second, so a recording that started mid-call opened
     * with a burst of stale audio. Called from the recorder's start().
     */
    public void clearRecordingRings() {
        mic.clearRing(CONSUMER_RECORDING);
        for (BusSource leg : legs.values()) leg.clearRing(CONSUMER_RECORDING);
        for (BusSource a : aux.values()) a.clearRing(CONSUMER_RECORDING);
    }

    /**
     * Every remote leg summed, with no exclusion and no microphone - the far side of a
     * recording, which is one mixed channel however many parties are on the call.
     *
     * This is what lets a conference recording have exactly TWO sources for its whole life:
     * the mic on the left and this on the right. A participant joining later changes what
     * this sums and the recorder never has to be told, which removes the need for an
     * attach-a-track-to-a-running-recording API entirely.
     */
    public boolean pullRemoteSum(int[] accumulator, short[] out, int frames, short[] scratch) {
        if (accumulator == null || out == null || scratch == null || frames <= 0) return false;

        Arrays.fill(accumulator, 0, frames, 0);
        boolean any = false;

        final Map<String, BusSource> snapshot = legs;
        for (BusSource leg : snapshot.values()) {
            any |= accumulate(leg, CONSUMER_RECORDING, accumulator, frames, scratch);
        }

        clampInto(accumulator, out, frames);
        return any;
    }

    // =====================================================================

    /** Adds one source's next frame into the accumulator, zero-padding an underrun. */
    private static boolean accumulate(
            BusSource source, String consumerId, int[] accumulator, int frames, short[] scratch) {
        final int n = source.drain(consumerId, scratch, frames);
        if (n <= 0) return false;
        for (int i = 0; i < n; i++) {
            accumulator[i] += scratch[i];
        }
        return true;
    }

    /**
     * As accumulate, with a gain - the render consumer's local volume. The ring is DRAINED
     * even at gain 0, so muting the local copy cannot let the ring saturate and replay half
     * a second of old audio when it is turned back up (the same trap the muted mic had).
     */
    private static boolean accumulateScaled(
            BusSource source, String consumerId, float gain, int[] accumulator, int frames, short[] scratch) {
        final int n = source.drain(consumerId, scratch, frames);
        if (n <= 0) return false;
        if (gain <= 0f) return false;
        for (int i = 0; i < n; i++) {
            accumulator[i] += (int) (scratch[i] * gain);
        }
        return true;
    }

    /**
     * Saturating, NOT wrapping. A sum that overflows a short has to clip: wrapping turns a
     * loud moment into full-scale noise of the opposite sign, which is far worse than the
     * distortion clipping causes. Same rule the recorder's mixer follows.
     */
    private static void clampInto(int[] accumulator, short[] out, int frames) {
        for (int i = 0; i < frames; i++) {
            final int v = accumulator[i];
            out[i] = v > Short.MAX_VALUE ? Short.MAX_VALUE
                    : v < Short.MIN_VALUE ? Short.MIN_VALUE
                    : (short) v;
        }
    }
}
