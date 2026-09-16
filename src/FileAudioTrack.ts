import { syncAux } from './AuxBinding';
import type FileVideoTrack from './FileVideoTrack';
import MediaStreamTrack from './MediaStreamTrack';
import { makeDOMException } from './RTCUtil';

/**
 * The soundtrack of a presented video file.
 *
 * VIRTUAL, like MixedAudioTrack: there is no native audio track behind it. The file's PCM is
 * pushed onto the native conference bus as an AUX source by the file player itself, so this
 * track is the handle an AudioContext graph holds to say "mix that in" — connecting a source
 * node that carries it attaches the aux, disconnecting the last one detaches it (AuxBinding).
 * Everything that would cross the bridge with its id is intercepted here.
 *
 * `_auxId` IS THE VIDEO TRACK'S ID: one native object (the file source) owns both halves, and
 * the bus, the controls and the events all key on it.
 */
export default class FileAudioTrack extends MediaStreamTrack {
    override readonly label: string = 'File audio';

    readonly _auxId: string;
    readonly _video: FileVideoTrack;

    constructor(auxId: string, video: FileVideoTrack) {
        super({
            id: `file-audio-${auxId}`,
            kind: 'audio',
            remote: false,
            constraints: {},
            enabled: true,
            settings: {},
            peerConnectionId: -1,
            readyState: 'live'
        });

        this._isVirtual = true;
        this._auxId = auxId;
        this._video = video;
    }

    override get enabled(): boolean {
        return this._enabled;
    }

    /** Stored, then reconciled: disabled means off the bus, re-enabled means back on it. */
    override set enabled(enabled: boolean) {
        this._enabled = Boolean(enabled);
        syncAux(this);
    }

    override stop(): void {
        this._enabled = false;
        this._readyState = 'ended';
        // A stopped track must not keep an aux on the bus, whoever still holds it.
        syncAux(this);
    }

    override release(): void {
        this.stop();
    }

    override _setVolume(): void {
        throw makeDOMException('NotSupportedError',
            'A file audio track has no native volume; the local copy is playback.volume');
    }

    override _registerEvents(): void {
        // No native events can ever name this id.
    }
}
