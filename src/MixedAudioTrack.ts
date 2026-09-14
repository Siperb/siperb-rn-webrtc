import type AudioContext from './AudioContext';
import type MediaStreamAudioDestinationNode from './MediaStreamAudioDestinationNode';
import MediaStreamTrack from './MediaStreamTrack';
import { makeDOMException, uniqueID } from './RTCUtil';

/**
 * The audio track of a MediaStreamAudioDestinationNode's stream.
 *
 * VIRTUAL: it exists only in JS. There is no native track behind it — the mix it stands for is
 * produced below the encoder by the native recorder or the conference bus, once a consumer
 * (MediaRecorder, RTCRtpSender.replaceTrack) compiles the graph it hangs off. Every path that
 * would otherwise cross the bridge with its id (enabled, stop, release, volume, MediaStream
 * add/remove) is therefore intercepted here, and `_isVirtual` is how those callers tell.
 *
 * Spec behaviour the SDK relies on and gets: `kind === 'audio'`, `readyState`, `enabled` as a
 * plain flag, `stop()` ending it for good.
 */
export default class MixedAudioTrack extends MediaStreamTrack {
    override readonly label: string = 'Mixed audio';

    readonly _destination: MediaStreamAudioDestinationNode;

    constructor(destination: MediaStreamAudioDestinationNode) {
        super({
            id: `mixed-${uniqueID()}`,
            kind: 'audio',
            remote: false,
            constraints: {},
            enabled: true,
            settings: {},
            peerConnectionId: -1,
            readyState: 'live'
        });

        this._isVirtual = true;
        this._destination = destination;
    }

    get context(): AudioContext {
        return this._destination.context;
    }

    override get enabled(): boolean {
        return this._enabled;
    }

    override set enabled(enabled: boolean) {
        // Stored only: nothing native to enable. In a conference the mix is applied below the
        // encoder regardless; mute goes through the bus (ConferenceMixer.setMicMuted).
        this._enabled = Boolean(enabled);
    }

    override stop(): void {
        this._enabled = false;
        this._readyState = 'ended';
    }

    override release(): void {
        // Nothing native to release.
    }

    override _setVolume(): void {
        throw makeDOMException('NotSupportedError', 'A mixed audio track has no native volume');
    }

    override _registerEvents(): void {
        // No native events can ever name this id.
    }
}
