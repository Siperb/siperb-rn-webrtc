import ConferenceMixer from './ConferenceMixer';
import type FileAudioTrack from './FileAudioTrack';
import Logger from './Logger';
import type MediaStreamAudioSourceNode from './MediaStreamAudioSourceNode';

const log = new Logger('conference');

/**
 * What connecting a file's audio into an AudioContext graph means on this platform: put the
 * file's soundtrack on the native conference bus as an AUX source, and take it off again when
 * the last graph lets go of it.
 *
 * ONE RECONCILER, NOT TWO CALLS. A FileAudioTrack can be held by more than one graph at once —
 * the SDK's conference mix AND a recording's mix both create a source node for the presented
 * stream — and it can be disabled or stopped underneath either of them. So the native state is
 * derived, never commanded: `desired = live && enabled && someone holds it`, and the bridge is
 * crossed only when desired differs from what native has. Serialised per aux id, bookkeeping
 * synchronous and the native call issued in the same tick — the ConferenceLegBinding shape, and
 * for the same reason: an AudioContext.close() the SDK fires and forgets must still detach.
 *
 * Native attach is idempotent and native detach is safe on an absent aux, and the file source
 * itself removes its aux when it is disposed — so a JS detach arriving after native teardown is
 * a harmless no-op rather than an error to guard.
 */
const holders = new Map<string, Set<MediaStreamAudioSourceNode>>();
const attached = new Set<string>();
const pending = new Map<string, Promise<void>>();

function wants(track: FileAudioTrack): boolean {
    return track.readyState === 'live' && track.enabled && (holders.get(track._auxId)?.size ?? 0) > 0;
}

/** A graph node now reads this track. */
export function holdAux(track: FileAudioTrack, node: MediaStreamAudioSourceNode): Promise<void> {
    let set = holders.get(track._auxId);

    if (!set) {
        set = new Set();
        holders.set(track._auxId, set);
    }

    set.add(node);

    return syncAux(track);
}

/** A graph node let go of this track. */
export function releaseAux(track: FileAudioTrack, node: MediaStreamAudioSourceNode): Promise<void> {
    const set = holders.get(track._auxId);

    if (set) {
        set.delete(node);

        if (set.size === 0) {
            holders.delete(track._auxId);
        }
    }

    return syncAux(track);
}

/**
 * Bring native into line with the JS state. Re-evaluated after every bridge round trip, so a
 * stop() that lands while an attach is in flight is followed by the detach it implies.
 */
export function syncAux(track: FileAudioTrack): Promise<void> {
    const id = track._auxId;
    const previous = pending.get(id);

    // SAME TICK when nothing is in flight: an async function runs synchronously up to its first
    // await, so the bookkeeping and the bridge call below happen before this returns — which
    // is what lets the SDK's fire-and-forget close() and disconnect() detach without being
    // awaited. Only a call that must wait for an in-flight one is chained.
    const work = previous
        ? previous.catch(() => undefined).then(() => reconcile(track))
        : reconcile(track);

    pending.set(id, work);

    return work.finally(() => {
        if (pending.get(id) === work) {
            pending.delete(id);
        }
    });
}

async function reconcile(track: FileAudioTrack): Promise<void> {
    const id = track._auxId;

    // Loop: each pass flips one state and re-reads, so a change made while a call was in
    // flight is acted on rather than lost. Terminates once native matches.
    for (;;) {
        const desired = wants(track);

        if (desired === attached.has(id)) {
            return;
        }

        if (desired) {
            attached.add(id);

            try {
                await ConferenceMixer.attachAux(id);
                log.debug(`aux ${id} attached`);
            } catch (error) {
                attached.delete(id);
                log.error(`attachAux ${id} failed`, error as Error);

                return;
            }
        } else {
            attached.delete(id);

            try {
                await ConferenceMixer.detachAux(id);
                log.debug(`aux ${id} detached`);
            } catch (error) {
                log.error(`detachAux ${id} failed`, error as Error);

                return;
            }
        }
    }
}

/** Diagnostics and tests. */
export function auxHolderCount(auxId: string): number {
    return holders.get(auxId)?.size ?? 0;
}

export function isAuxAttached(auxId: string): boolean {
    return attached.has(auxId);
}
