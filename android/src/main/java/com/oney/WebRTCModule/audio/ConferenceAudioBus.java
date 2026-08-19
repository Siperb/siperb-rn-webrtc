package com.oney.WebRTCModule.audio;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The one place a conference's audio is summed.
 *
 * Holds the microphone and one ring per remote leg, and answers a single question:
 * "what should leg X be sent?" — which is the microphone plus every OTHER leg, never
 * itself. That exclusion is the whole reason this class exists; sending a leg its own
 * audio back is the failure a three-way call has to avoid, and it cannot be avoided
 * downstream because by then the legs are indistinguishable.
 *
 * WHY A SHARED BUS AND NOT A MIX PER LEG. Each remote leg's audio is needed by every
 * other leg and by the recording, so the alternative is N copies of the same ring and N
 * taps on the same track. One producer per source, many consumers, each excluding what it
 * must.
 *
 * THREADING. Producers are real-time audio threads — the capture callback, the remote
 * track sinks, and (on a synthesised leg) the playout pull. The consumer is whichever
 * thread is filling an outbound buffer. Rings carry their own lock and are the only
 * synchronisation on the hot path; the leg map is copy-on-write so a leg removed
 * mid-{@link #pull} cannot invalidate an iteration. NOTHING HERE ALLOCATES OR LOGS once
 * it is warm, because all of it runs under a 10 ms deadline.
 *
 * IDLE-CHEAP BY CONTRACT. With no conference up, {@link #isActive()} is false and every
 * caller is expected to return before touching anything else — the capture and render
 * hooks this feeds sit in the path of every ordinary 1:1 call.
 */
public final class ConferenceAudioBus {

    /** Everything on the bus is at this rate; sources resample on the way in. */
    public static final int SAMPLE_RATE = 48000;
    /** ~500 ms of slack per source. Overflow drops oldest, so a stalled consumer cannot grow memory. */
    private static final int RING_CAPACITY = SAMPLE_RATE / 2;

    private static final ConferenceAudioBus INSTANCE = new ConferenceAudioBus();

    public static ConferenceAudioBus getInstance() {
        return INSTANCE;
    }

    /** A source with no transport of its own — fed by whoever taps the audio. */
    public static final class BusSource extends AudioSource {
        BusSource() {
            super(SAMPLE_RATE, RING_CAPACITY);
        }
    }

    private final BusSource mic = new BusSource();

    /**
     * Remote legs by id. COPY-ON-WRITE: replaced wholesale under {@code legLock}, never
     * mutated in place, so {@link #pull} can read it without a lock and without risking a
     * concurrent modification on an audio thread.
     */
    private volatile Map<String, BusSource> legs = Collections.emptyMap();
    private final Object legLock = new Object();

    /**
     * Mute is a property of the MIX, not of the sender track.
     *
     * On mobile the outbound track is no longer the microphone — it is whatever we
     * assemble — so muting the track would mute the whole conference. Leaving the mic out
     * of the sum is the only thing that mutes just us, and it is why mobile can do
     * mute-in-conference at all where the web recorder documents it as not implemented.
     */
    private volatile boolean micMuted = false;

    private ConferenceAudioBus() {}

    // =====================================================================
    // Producers
    // =====================================================================

    /** The microphone leg. Fed post-AEC by the capture hook. */
    public AudioSource microphone() {
        return mic;
    }

    /**
     * Register a remote leg, or return the one already registered.
     *
     * Idempotent because the SDK's JoinConference builds the mix once per leg and is
     * called again for every leg that joins — a second call for a leg already on the bus
     * must patch, never replace, or its ring is discarded mid-call and the party it
     * carries drops out.
     */
    public AudioSource addLeg(String legId) {
        if (legId == null) return null;
        synchronized (legLock) {
            BusSource existing = legs.get(legId);
            if (existing != null) return existing;

            BusSource source = new BusSource();
            Map<String, BusSource> next = new LinkedHashMap<>(legs);
            next.put(legId, source);
            legs = Collections.unmodifiableMap(next);
            return source;
        }
    }

    /** Take a leg off the bus. Safe to call for a leg that was never on it. */
    public void removeLeg(String legId) {
        if (legId == null) return;
        synchronized (legLock) {
            if (!legs.containsKey(legId)) return;
            Map<String, BusSource> next = new LinkedHashMap<>(legs);
            next.remove(legId);
            legs = Collections.unmodifiableMap(next);
        }
    }

    /**
     * The conference is over: drop every leg, un-mute, and DRAIN THE MICROPHONE.
     *
     * The drain is not tidiness. Leg rings die with their legs, but the microphone source
     * is process-wide and survives — so whatever it still held would be the first thing
     * mixed into the NEXT conference, sending up to half a second of one call's audio to
     * someone who was never on it.
     */
    public void clear() {
        synchronized (legLock) {
            legs = Collections.emptyMap();
        }
        micMuted = false;
        mic.ring.clear();
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
     * What leg {@code excludeLegId} should be sent: the microphone plus every other leg.
     *
     * @param excludeLegId the leg being fed, whose own audio must never be in its own mix.
     *                     Null mixes everything, which is what a local monitor wants.
     * @param out          destination, overwritten in full — a short read is zero-padded
     *                     rather than left holding the previous frame, because stale audio
     *                     repeating is far more noticeable than a gap.
     * @param frames       samples requested
     * @param scratch      caller-owned buffer of at least {@code frames}; passed in so the
     *                     real-time path never allocates
     * @return true if anything was mixed in; false means the frame is silence
     */
    public boolean pull(String excludeLegId, int[] accumulator, short[] out, int frames, short[] scratch) {
        if (accumulator == null || out == null || scratch == null || frames <= 0) return false;

        java.util.Arrays.fill(accumulator, 0, frames, 0);
        boolean any = false;

        if (!micMuted) {
            any |= accumulate(mic, accumulator, frames, scratch);
        }

        // Reads the volatile ONCE. Re-reading per leg would let the map change mid-mix and
        // is the sort of thing that produces a fault nobody can reproduce.
        final Map<String, BusSource> snapshot = legs;
        for (Map.Entry<String, BusSource> entry : snapshot.entrySet()) {
            if (excludeLegId != null && excludeLegId.equals(entry.getKey())) continue;
            any |= accumulate(entry.getValue(), accumulator, frames, scratch);
        }

        clampInto(accumulator, out, frames);
        return any;
    }

    /**
     * Every remote leg summed, with no exclusion and no microphone — the far side of a
     * recording, which is one mixed channel however many parties are on the call.
     *
     * This is what lets a conference recording have exactly TWO sources for its whole life:
     * the mic on the left and this on the right. A participant joining later changes what
     * this sums and the recorder never has to be told, which is what removes the need for
     * an attach-track-to-a-running-recording API.
     */
    public boolean pullRemoteSum(int[] accumulator, short[] out, int frames, short[] scratch) {
        if (accumulator == null || out == null || scratch == null || frames <= 0) return false;

        java.util.Arrays.fill(accumulator, 0, frames, 0);
        boolean any = false;

        final Map<String, BusSource> snapshot = legs;
        for (BusSource leg : snapshot.values()) {
            any |= accumulate(leg, accumulator, frames, scratch);
        }

        clampInto(accumulator, out, frames);
        return any;
    }

    // =====================================================================

    /** Adds one source's next frame into the accumulator, zero-padding an underrun. */
    private static boolean accumulate(AudioSource source, int[] accumulator, int frames, short[] scratch) {
        final int n = source.ring.read(scratch, 0, frames);
        if (n <= 0) return false;
        for (int i = 0; i < n; i++) {
            accumulator[i] += scratch[i];
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
