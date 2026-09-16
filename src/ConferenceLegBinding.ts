import { NativeModules } from 'react-native';

import ConferenceMixer from './ConferenceMixer';
import Logger from './Logger';
import type MediaStreamTrack from './MediaStreamTrack';
import type MixedAudioTrack from './MixedAudioTrack';
import { getPeerConnection } from './PeerConnectionRegistry';
import type RTCRtpSender from './RTCRtpSender';
import { makeDOMException } from './RTCUtil';

const { WebRTCModule } = NativeModules;
const log = new Logger('conference');

interface LegBinding {
    legId: string;
    pcId: number;
    host: boolean;
    sender: RTCRtpSender;
    /** What the sender carried before the mix — restored on unbind, see below. */
    previousTrack: MediaStreamTrack | null;
}

const bindings = new Map<MixedAudioTrack, LegBinding>();
const pending = new Map<MixedAudioTrack, Promise<void>>();
let hostLegId: string | null = null;

/**
 * What `sender.replaceTrack(mixTrack)` means on this platform: put the sender's peer
 * connection on the native conference bus as a leg.
 *
 * THE LEG ID IS NOT FREE. A child leg's peer connection was born on its own native factory
 * under `siperbConferenceLegId`, and that factory's capture mixer pulls the bus by exactly
 * that key — so the child is attached under it. The host (a connection on the app factory,
 * no leg id) gets `pc-<id>`; the bus only needs it unique.
 *
 * IDEMPOTENT PER (track, sender), AND SERIALISED. The SDK republishes the mix on every join,
 * so the same replaceTrack arrives once per participant; native `attachLeg` appends taps and
 * would double each remote party's level on the second call. One attach per binding, and a
 * second caller waits for the first rather than racing it.
 *
 * NOTHING NATIVE IS SWAPPED. The sender keeps sending its real track; the bus overwrites that
 * capture with the mix below the encoder. `sender.track` is pointed at the mix so
 * `getSenders().find(audio)` keeps working, and the real track is remembered for unbind:
 * after a host-owned release the SDK never swaps the microphone back itself, and a sender
 * left pointing at a dead virtual track would make every later hold/mute toggle nothing.
 */
export async function bindMixedTrackToSender(track: MixedAudioTrack, sender: RTCRtpSender): Promise<void> {
    const inFlight = pending.get(track);

    if (inFlight) {
        await inFlight.catch(() => undefined);
    }

    const existing = bindings.get(track);

    if (existing) {
        if (existing.sender === sender) {
            return;
        }

        throw makeDOMException('InvalidStateError', 'replaceTrack: this mixed track already drives another sender');
    }

    const peerConnection = getPeerConnection(sender._peerConnectionId);

    if (!peerConnection) {
        throw makeDOMException('InvalidStateError', 'replaceTrack: the peer connection is closed');
    }

    const current = sender._track;

    if (current === null) {
        throw makeDOMException('InvalidStateError',
            'replaceTrack: attach a real audio track first; the conference bus overwrites the sender\'s capture, '
            + 'it does not create one');
    }

    if (current.kind !== 'audio') {
        throw new TypeError('replaceTrack: a mixed audio track can only replace an audio track');
    }

    if (current._isVirtual) {
        // Swapping one mix for another on the same sender: release the old leg first.
        await unbindMixedTrack(current as MixedAudioTrack);
    }

    const legId = peerConnection._conferenceLegId ?? `pc-${peerConnection._pcId}`;
    const host = peerConnection._conferenceLegId === null;

    if (host && hostLegId !== null && hostLegId !== legId) {
        // Two connections on the app factory share ONE outbound capture, so one of them will
        // send the wrong audio. The cause is a child that was not born on its own factory
        // (no siperbConferenceLegId in its configuration); attaching anyway is what the old
        // shim did, and loud beats silent.
        log.warn(`${legId} attached as a second host leg (${hostLegId} already is): the child leg was not `
            + 'created with siperbConferenceLegId and will share the host\'s outbound audio');
    }

    const work = (async () => {
        await ConferenceMixer.attachLeg(peerConnection._pcId, legId, host);

        // close() or stop() raced the attach: nothing may stay on the bus for a dead graph.
        if (track.readyState === 'ended' || track.context.state === 'closed') {
            await ConferenceMixer.detachLeg(legId);

            return;
        }

        bindings.set(track, { legId, pcId: peerConnection._pcId, host, sender, previousTrack: sender._track });

        if (host) {
            hostLegId = legId;

            // THE MICROPHONE'S ENABLED FLAG CHANGES MEANING WHILE THE HOST LEG IS ON THE BUS.
            // Natively, `AudioTrack.setEnabled(false)` is applied in the send pipeline AFTER
            // the capture hook where the bus overwrites the buffer — so it mutes the WHOLE
            // outbound mix: the other participants and a presented file's soundtrack, not
            // just us. The bus's own micMuted is what mutes just us. So while bound, the mic
            // track's `enabled` is routed to the bus (MediaStreamTrack.enabled), and the
            // native track is kept enabled; a mic already disabled at bind is re-enabled
            // natively and muted on the bus instead, and the bus flag is set from the mic's
            // real state either way (a leftover from a previous conference must not silence
            // this one).
            const mic = sender._track === track ? null : sender._track;
            const previous = bindings.get(track)?.previousTrack ?? mic;

            if (previous && !previous._isVirtual) {
                if (!previous._enabled) {
                    WebRTCModule.mediaStreamTrackSetEnabled(-1, previous.id, true);
                }

                ConferenceMixer.setMicMuted(!previous._enabled).catch(
                    error => log.error(`${peerConnection._pcId} setMicMuted at bind failed`, error as Error));
            }
        }

        track.context._liveSinks += 1;
        sender._track = track;
        log.debug(`${peerConnection._pcId} sends mix ${track.id} as leg ${legId}${host ? ' (host)' : ''}`);
    })();

    pending.set(track, work);

    try {
        await work;
    } catch (error) {
        log.error(`${peerConnection._pcId} attachLeg ${legId} failed`, error as Error);
        throw error;
    } finally {
        if (pending.get(track) === work) {
            pending.delete(track);
        }
    }
}

/**
 * Take the leg a mixed track stands for off the bus and give its sender its real track back.
 *
 * The bookkeeping (binding removed, `sender.track` restored) is SYNCHRONOUS and the native
 * detach is issued in the same tick, so an AudioContext.close() the SDK fires and forgets
 * is enough. A bind still in flight is waited for, then undone.
 */
export function unbindMixedTrack(track: MixedAudioTrack): Promise<void> {
    const inFlight = pending.get(track);

    if (inFlight) {
        return inFlight.catch(() => undefined).then(() => unbindMixedTrack(track));
    }

    const binding = bindings.get(track);

    if (!binding) {
        return Promise.resolve();
    }

    bindings.delete(track);

    if (binding.sender._track === track) {
        binding.sender._track = binding.previousTrack;
    }

    if (hostLegId === binding.legId) {
        hostLegId = null;

        // The mic goes back under native control: apply the flag it carries, which the bus
        // was honouring while the leg was bound. (The bus clears its own mute when the last
        // leg leaves, and the next host bind sets it from the mic's state regardless.)
        const previous = binding.previousTrack;

        if (previous && !previous._isVirtual && previous._readyState !== 'ended') {
            WebRTCModule.mediaStreamTrackSetEnabled(-1, previous.id, previous._enabled);
        }
    }

    track.context._liveSinks -= 1;
    log.debug(`${binding.pcId} leg ${binding.legId} detached`);

    return ConferenceMixer.detachLeg(binding.legId).then(
        () => undefined,
        error => log.error(`${binding.pcId} detachLeg ${binding.legId} failed`, error as Error)
    );
}

/** A peer connection closed: whatever it had on the bus goes with it. */
export function unbindForPeerConnection(pcId: number): Promise<void> {
    const tracks = Array.from(bindings.entries())
        .filter(([ , binding ]) => binding.pcId === pcId)
        .map(([ track ]) => track);

    return Promise.all(tracks.map(track => unbindMixedTrack(track))).then(() => undefined);
}

/** The leg a mixed track is currently attached as, if any. Diagnostics and tests. */
export function boundLegId(track: MixedAudioTrack): string | null {
    return bindings.get(track)?.legId ?? null;
}

/**
 * The real microphone track the HOST leg's sender carried before the mix, while that leg is on
 * the bus — the one track whose `enabled` must go to the bus rather than to native (see the
 * note in bindMixedTrackToSender). Null when no host leg is bound.
 */
export function boundHostMicrophone(): MediaStreamTrack | null {
    if (hostLegId === null) {
        return null;
    }

    for (const binding of bindings.values()) {
        if (binding.host) {
            return binding.previousTrack;
        }
    }

    return null;
}
