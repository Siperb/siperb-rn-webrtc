import type AudioContext from './AudioContext';
import AudioNode from './AudioNode';
import type MediaStream from './MediaStream';
import { makeDOMException } from './RTCUtil';

/**
 * Brings a MediaStream's audio into the graph. It has no output signal of its own here; the
 * consumer that compiles the graph reads `mediaStream.getAudioTracks()` and decides, per track,
 * whether that means the microphone (local) or a remote party (remote).
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
}
