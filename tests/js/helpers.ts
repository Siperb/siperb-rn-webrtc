import MediaStream from '../../src/MediaStream';
import MediaStreamTrack from '../../src/MediaStreamTrack';

/** A local or remote audio/video track as native would describe it. */
export function fakeTrack(id: string, kind: 'audio' | 'video', remote: boolean, pcId = -1): MediaStreamTrack {
    return new MediaStreamTrack({
        id,
        kind,
        remote,
        constraints: {},
        enabled: true,
        settings: {},
        peerConnectionId: pcId,
        readyState: 'live'
    });
}

export function streamOf(...tracks: MediaStreamTrack[]): MediaStream {
    return new MediaStream(tracks);
}

/** Let every pending promise continuation run. */
export async function flush(): Promise<void> {
    for (let i = 0; i < 5; i++) {
        await new Promise(resolve => setImmediate(resolve));
    }
}
