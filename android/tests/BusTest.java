import com.oney.WebRTCModule.audio.AudioSource;
import com.oney.WebRTCModule.audio.ConferenceAudioBus;

public class BusTest {
    static int pass = 0, fail = 0;
    static void t(String name, boolean ok) {
        System.out.println((ok ? "  PASS " : "  FAIL ") + name);
        if (ok) pass++; else fail++;
    }

    /** Fill a source with a constant value at the bus rate so sums are predictable. */
    static void feed(AudioSource s, short value, int frames) {
        short[] buf = new short[frames];
        java.util.Arrays.fill(buf, value);
        s.push(buf, frames, ConferenceAudioBus.SAMPLE_RATE, 1);
    }

    public static void main(String[] args) {
        final int N = 480;
        int[] acc = new int[N];
        short[] out = new short[N];
        short[] scratch = new short[N];

        ConferenceAudioBus bus = ConferenceAudioBus.getInstance();

        // --- exclusion: the whole reason the class exists --------------------
        bus.clear();
        AudioSource a = bus.addLeg("A");
        AudioSource b = bus.addLeg("B");
        feed(bus.microphone(), (short) 100, N);
        feed(a, (short) 1000, N);
        feed(b, (short) 3000, N);

        bus.pull("A", acc, out, N, scratch);
        t("leg A is sent mic + B, and NOT its own audio (expect 3100)", out[0] == 3100);

        feed(bus.microphone(), (short) 100, N);
        feed(a, (short) 1000, N);
        feed(b, (short) 3000, N);
        bus.pull("B", acc, out, N, scratch);
        t("leg B is sent mic + A, and NOT its own audio (expect 1100)", out[0] == 1100);

        // --- mute is a property of the mix, not the track --------------------
        feed(bus.microphone(), (short) 100, N);
        feed(a, (short) 1000, N);
        feed(b, (short) 3000, N);
        bus.setMicMuted(true);
        bus.pull("A", acc, out, N, scratch);
        t("muting drops only US from the mix; B still reaches A (expect 3000)", out[0] == 3000);
        bus.setMicMuted(false);

        // --- the recording's right channel -----------------------------------
        feed(bus.microphone(), (short) 100, N);
        feed(a, (short) 1000, N);
        feed(b, (short) 3000, N);
        bus.pullRemoteSum(acc, out, N, scratch);
        t("pullRemoteSum is every remote and no mic (expect 4000)", out[0] == 4000);

        // --- saturating, not wrapping ----------------------------------------
        bus.clear();
        AudioSource x = bus.addLeg("X");
        AudioSource y = bus.addLeg("Y");
        feed(x, (short) 30000, N);
        feed(y, (short) 30000, N);
        bus.pullRemoteSum(acc, out, N, scratch);
        t("a sum past full scale CLIPS rather than wrapping (expect 32767)", out[0] == Short.MAX_VALUE);

        // --- underrun is silence, not a repeat of the last frame -------------
        bus.clear();
        bus.addLeg("Z");
        java.util.Arrays.fill(out, (short) 999);
        boolean any = bus.pull("Z", acc, out, N, scratch);
        t("an empty bus reports nothing mixed", !any);
        t("an underrun zero-fills instead of repeating stale audio", out[0] == 0);

        // --- audio must not survive its own conference ------------------------
        // Regression: clear() dropped the legs but left the PROCESS-WIDE microphone ring
        // full, so the next conference opened by transmitting the previous one's audio.
        bus.clear();
        feed(bus.microphone(), (short) 4242, N);
        bus.setMicMuted(true);
        bus.pull(null, acc, out, N, scratch);   // muted: mic stays buffered
        bus.setMicMuted(false);
        bus.clear();                            // conference ends with audio still buffered
        bus.addLeg("NEXT");
        boolean leaked = bus.pull("NEXT", acc, out, N, scratch);
        t("clear() drains the mic, so no audio crosses into the next conference", !leaked && out[0] == 0);

        // --- idempotent registration ------------------------------------------
        bus.clear();
        AudioSource first = bus.addLeg("L");
        feed(first, (short) 500, N);
        AudioSource again = bus.addLeg("L");
        t("re-adding a leg returns the SAME ring, so a re-join cannot drop it", first == again);
        bus.pullRemoteSum(acc, out, N, scratch);
        t("...and its buffered audio survives the second addLeg (expect 500)", out[0] == 500);

        // --- removal ----------------------------------------------------------
        bus.clear();
        AudioSource keep = bus.addLeg("K");
        AudioSource go = bus.addLeg("G");
        feed(keep, (short) 700, N);
        feed(go, (short) 900, N);
        bus.removeLeg("G");
        bus.pullRemoteSum(acc, out, N, scratch);
        t("a removed leg is out of the sum immediately (expect 700)", out[0] == 700);
        bus.removeLeg("nonexistent");
        t("removing a leg that was never on the bus is a no-op", true);

        System.out.println("\n  " + pass + " passed, " + fail + " failed");
        System.exit(fail == 0 ? 0 : 1);
    }
}
