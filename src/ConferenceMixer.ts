import { NativeModules } from 'react-native';

const { WebRTCModule } = NativeModules;

/**
 * Native conference audio mixing.
 *
 * WHAT THIS SOLVES. Each remote party in a conference has to be sent the microphone plus
 * every OTHER party, never itself. A PeerConnection's outbound audio comes from its
 * factory's audio device, and a PeerConnection belongs to its factory for life — so one
 * factory can only ever produce one outbound signal, and a three-way call needs two. The
 * host leg keeps the app's existing factory (its capture buffer is overwritten in place);
 * every other leg is born on a factory of its own.
 *
 * THE ORDER IS FIXED, and it is fixed by that constraint:
 *
 *   1. `new RTCPeerConnection({ siperbConferenceLegId })` for the new leg — the factory is
 *      chosen here and can never be changed afterwards.
 *   2. {@link attachLegAudio} to give it a local track from that same factory.
 *   3. Dial, and once it answers {@link attachLeg} for BOTH legs, one of them `host: true`.
 *
 * A conference between two calls that ALREADY EXIST cannot be mixed — both are on the app's
 * single factory, so both would share an outbound and one of them would hear itself. Refuse
 * it with a reason rather than producing a call that sounds broken.
 *
 * Audio never crosses the bridge: everything below is control only.
 */
export default class ConferenceMixer {
    /**
     * Put a leg on the bus and start tapping its remote audio.
     *
     * @param host exactly one leg — the one on the app's main factory, i.e. the call the
     *             conference was started FROM. Passing it for a second leg would point two
     *             mixes at one outbound.
     */
    static attachLeg(peerConnectionId: number, legId: string, host: boolean): Promise<boolean> {
        return WebRTCModule.conferenceAttachLeg(peerConnectionId, legId, host);
    }

    /**
     * Give a synthesised leg a local audio track from its own factory.
     *
     * Deliberately not getUserMedia: that always builds on the app's single factory, and a
     * track from the wrong factory does not fail loudly — it silently sends the wrong audio.
     */
    static attachLegAudio(peerConnectionId: number, legId: string): Promise<boolean> {
        return WebRTCModule.conferenceAttachLegAudio(peerConnectionId, legId);
    }

    /** Take one leg out of the mix. The rest of the conference carries on. */
    static detachLeg(legId: string): Promise<boolean> {
        return WebRTCModule.conferenceDetachLeg(legId);
    }

    /** The conference is over. Idempotent, and safe when none was ever up. */
    static teardown(): Promise<boolean> {
        return WebRTCModule.conferenceTeardown();
    }

    /**
     * Mute inside a conference.
     *
     * Muting the sender track would mute EVERYONE, because in a conference that track is the
     * mix. This leaves the microphone out of the sum instead, which is the only thing that
     * mutes just us — and is why mobile can do mute-in-conference at all, where the web
     * mixer documents it as not implemented.
     */
    static setMicMuted(muted: boolean): Promise<boolean> {
        return WebRTCModule.conferenceSetMicMuted(muted);
    }

    /** Leg ids currently on the bus. Diagnostics. */
    static getLegs(): Promise<string[]> {
        return WebRTCModule.conferenceGetLegs();
    }

    /**
     * Put an AUX source on the bus — a presented file's soundtrack, keyed by its video track id.
     *
     * Not a leg: it has no peer connection and no mix of its own. Every leg's outbound mix
     * sums it beside the microphone, and the native render hook plays the presenter's copy
     * through WebRTC's own playout so it sits in the echo canceller's reference. Bound to the
     * BUS rather than to a leg, so it does not matter whether the host leg attaches before
     * or after it. Idempotent natively.
     */
    static attachAux(auxId: string): Promise<boolean> {
        return WebRTCModule.conferenceAttachAux(auxId);
    }

    /** Take an aux source off the bus. Safe for one never attached, or already gone. */
    static detachAux(auxId: string): Promise<boolean> {
        return WebRTCModule.conferenceDetachAux(auxId);
    }
}
