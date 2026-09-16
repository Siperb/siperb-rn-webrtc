import type AudioContext from './AudioContext';
import AudioNode from './AudioNode';
import { holdAux, releaseAux } from './AuxBinding';
import type FileAudioTrack from './FileAudioTrack';
import type MediaStream from './MediaStream';
import { makeDOMException } from './RTCUtil';

/**
 * Brings a MediaStream's audio into the graph. It has no output signal of its own here; the
 * consumer that compiles the graph reads `mediaStream.getAudioTracks()` and decides, per track,
 * whether that means the microphone (local) or a remote party (remote).
 *
 * ONE KIND OF SOURCE IS LIVE, NOT DECLARATIVE: a FileAudioTrack (a presented file's soundtrack)
 * is mixed natively the moment a graph holds it, so the first `connect` out of this node puts
 * the file on the native bus and the disconnect that empties it takes the file off again —
 * which is exactly the SDK's `sourceNode.connect(gain)` on present and `source.disconnect()` on
 * stop. The consumers' compile step never has to know about it.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/MediaStreamAudioSourceNode MDN}
 */
export default class MediaStreamAudioSourceNode extends AudioNode {
    readonly mediaStream: MediaStream;

    constructor(context: AudioContext, mediaStream: MediaStream) {
        if (!mediaStream || typeof mediaStream.getAudioTracks !== 'function') {
            throw new TypeError('MediaStreamAudioSourceNode: mediaStream is not a MediaStream');
        }

        // Spec: a stream with no audio track cannot be a source.
        if (mediaStream.getAudioTracks().length === 0) {
            throw makeDOMException('InvalidStateError',
                'MediaStreamAudioSourceNode: the MediaStream has no audio track');
        }

        super(context, 0, 1);

        this.mediaStream = mediaStream;
    }

    override connect(destination: AudioNode, output = 0, input = 0): AudioNode {
        const wasWired = this._outgoing.length > 0;
        const result = super.connect(destination, output, input);

        if (!wasWired && this._outgoing.length > 0) {
            for (const track of this._auxTracks()) {
                holdAux(track, this);
            }

            if (this._auxTracks().length > 0) {
                this.context._auxSources.add(this);
            }
        }

        return result;
    }

    override disconnect(destinationOrOutput?: AudioNode | number, output?: number, input?: number): void {
        super.disconnect(destinationOrOutput, output, input);

        if (this._outgoing.length === 0) {
            this._releaseAux();
        }
    }

    /** Let go of every aux this node holds — on the last disconnect, or the context closing. */
    _releaseAux(): void {
        for (const track of this._auxTracks()) {
            releaseAux(track, this);
        }

        this.context._auxSources.delete(this);
    }

    private _auxTracks(): FileAudioTrack[] {
        return this.mediaStream.getAudioTracks()
            .filter(track => typeof (track as any)._auxId === 'string') as FileAudioTrack[];
    }
}
