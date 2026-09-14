import com.oney.WebRTCModule.audio.ConferenceAudioBus;

/**
 * ConferenceAudioBus assertions. Plain Java, no framework - see run.sh.
 *
 * The bar for adding a case here: it should be something that would ship broken and be hard
 * to attribute from a bug report. "The other party cannot hear me" and "I can hear myself"
 * are both in that class, and both are covered below.
 */
public class BusTest {
    static int pass = 0, fail = 0;

    static void t(String name, boolean ok) {
        System.out.println((ok ? "  PASS " : "  FAIL ") + name);
        if (ok) pass++; else fail++;
    }

    static final int N = 480;
    static final int[] acc = new int[N];
    static final short[] out = new short[N];
    static final short[] scratch = new short[N];

    /** One frame of a constant value at the bus rate, so sums are predictable. */
    static void mic(ConferenceAudioBus bus, int value) {
        short[] f = new short[N];
        java.util.Arrays.fill(f, (short) value);
        bus.pushMicrophone(f, N, ConferenceAudioBus.SAMPLE_RATE, 1);
    }

    static void leg(ConferenceAudioBus bus, String id, int value) {
        short[] f = new short[N];
        java.util.Arrays.fill(f, (short) value);
        bus.pushLeg(id, f, N, ConferenceAudioBus.SAMPLE_RATE, 1);
    }

    public static void main(String[] args) {
        ConferenceAudioBus bus = ConferenceAudioBus.getInstance();

        // --- the reason the class exists -------------------------------------
        bus.clear();
        bus.addLeg("A");
        bus.addLeg("B");
        mic(bus, 100); leg(bus, "A", 1000); leg(bus, "B", 3000);

        bus.pull("A", acc, out, N, scratch);
        t("leg A is sent mic + B, and NOT its own audio (expect 3100)", out[0] == 3100);
        bus.pull("B", acc, out, N, scratch);
        t("leg B is sent mic + A, and NOT its own audio (expect 1100)", out[0] == 1100);

        // --- THE REGRESSION. One frame in, two outbound mixes out, as a real
        // three-way tick does. With a single ring per source the second mix got a
        // drained buffer and shipped without the microphone - which sounds exactly
        // like "they cannot hear me" and is invisible in review.
        bus.clear();
        bus.addLeg("host"); bus.addLeg("child");
        mic(bus, 100); leg(bus, "host", 1000); leg(bus, "child", 3000);
        bus.pull("host", acc, out, N, scratch);
        int hostMix = out[0];
        bus.pull("child", acc, out, N, scratch);
        int childMix = out[0];
        t("TWO mixes drawn from ONE frame both carry the mic (3100 / 1100)",
                hostMix == 3100 && childMix == 1100);

        // ...and the recording is a third reader of those same frames.
        bus.pullRemoteSum(acc, out, N, scratch);
        t("the recording is a third reader and still sees both legs (expect 4000)", out[0] == 4000);

        // --- mute is a property of the mix, not of the track ------------------
        bus.clear();
        bus.addLeg("A"); bus.addLeg("B");
        mic(bus, 100); leg(bus, "A", 1000); leg(bus, "B", 3000);
        bus.setMicMuted(true);
        bus.pull("A", acc, out, N, scratch);
        t("muting drops only US from the mix; B still reaches A (expect 3000)", out[0] == 3000);
        bus.setMicMuted(false);

        // --- MUTE MUST NOT RECORD YOU AND REPLAY IT ----------------------------
        // Regression, and it was measured rather than theorised: muting only skipped the
        // accumulate, so nothing drained the mic's rings while pushMicrophone kept filling
        // them. The ring saturated and HELD the last half second of audio captured while
        // muted, which unmute then shipped to the far end -- with every later word running
        // ~490 ms late for the rest of the call.
        bus.clear();
        bus.addLeg("A");
        bus.setMicMuted(true);
        for (int i = 0; i < 60; i++) mic(bus, 111);   // said while muted; must never be heard
        for (int i = 0; i < 60; i++) bus.pull("A", acc, out, N, scratch);
        bus.setMicMuted(false);
        mic(bus, 222);                                 // said after unmute
        leg(bus, "A", 0);
        bus.pull("A", acc, out, N, scratch);
        t("unmuting sends LIVE audio, not what was captured while muted (expect 222)", out[0] == 222);

        // --- saturating, not wrapping ------------------------------------------
        bus.clear();
        bus.addLeg("X"); bus.addLeg("Y");
        leg(bus, "X", 30000); leg(bus, "Y", 30000);
        bus.pullRemoteSum(acc, out, N, scratch);
        t("a sum past full scale CLIPS rather than wrapping (expect 32767)", out[0] == Short.MAX_VALUE);

        // --- underrun is silence, not a repeat ---------------------------------
        bus.clear();
        bus.addLeg("Z");
        java.util.Arrays.fill(out, (short) 999);
        boolean any = bus.pull("Z", acc, out, N, scratch);
        t("an empty bus reports nothing mixed", !any);
        t("an underrun zero-fills instead of repeating stale audio", out[0] == 0);

        // --- audio must not survive its own conference -------------------------
        // Regression: clear() dropped the legs but left the PROCESS-WIDE microphone
        // ring full, so the next conference opened by transmitting the previous
        // call's audio to someone who was never on it.
        bus.clear();
        bus.addLeg("PREV");
        mic(bus, 4242);
        bus.clear();
        bus.addLeg("NEXT");
        boolean leaked = bus.pull("NEXT", acc, out, N, scratch);
        t("clear() drains the mic, so no audio crosses into the next conference",
                !leaked && out[0] == 0);

        // --- idempotent registration -------------------------------------------
        bus.clear();
        bus.addLeg("L");
        leg(bus, "L", 500);
        bus.addLeg("L"); // a re-join must patch, never replace
        bus.pullRemoteSum(acc, out, N, scratch);
        t("re-adding a leg keeps its buffered audio (expect 500)", out[0] == 500);

        // --- removal -------------------------------------------------------------
        bus.clear();
        bus.addLeg("K"); bus.addLeg("G");
        leg(bus, "K", 700); leg(bus, "G", 900);
        bus.removeLeg("G");
        bus.pullRemoteSum(acc, out, N, scratch);
        t("a removed leg is out of the sum immediately (expect 700)", out[0] == 700);
        bus.removeLeg("never-added");
        t("removing a leg that was never on the bus is a no-op", true);
        bus.clear();
        bus.addLeg("H"); bus.addLeg("C");
        bus.setMicMuted(true);
        bus.removeLeg("C");
        boolean stillMutedWithHostLeft = bus.isMicMuted();
        bus.removeLeg("H");
        t("the last leg leaving un-mutes, so the next conference does not start muted",
                stillMutedWithHostLeft && !bus.isMicMuted());

        // --- a late joiner needs no plumbing -------------------------------------
        // This is what removes the attach-track-to-a-running-recording API: the
        // recorder's right channel is pullRemoteSum, so a leg added mid-call simply
        // starts appearing in it.
        bus.clear();
        bus.addLeg("first");
        leg(bus, "first", 600);
        bus.pullRemoteSum(acc, out, N, scratch);
        boolean before = out[0] == 600;
        bus.addLeg("late");
        leg(bus, "first", 600); leg(bus, "late", 400);
        bus.pullRemoteSum(acc, out, N, scratch);
        t("a leg joining mid-recording appears in the sum with no re-attach (600 then 1000)",
                before && out[0] == 1000);

        System.out.println("\n  " + pass + " passed, " + fail + " failed");
        System.exit(fail == 0 ? 0 : 1);
    }
}
