import type AudioContext from './AudioContext';
import AudioNode from './AudioNode';
import MediaStream from './MediaStream';
import MixedAudioTrack from './MixedAudioTrack';

/**
 * The graph's output as a MediaStream: one virtual audio track (MixedAudioTrack) that
 * consumers recognise and compile the graph from — MediaRecorder records what feeds it,
 * RTCRtpSender.replaceTrack sends it as a conference mix.
 *
 * The stream is built eagerly with one native `mediaStreamCreate` and no add-track call (the
 * track is virtual), so the SDK's `destination.stream.getAudioTracks()[0]` is stable from the
 * moment the node exists.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/MediaStreamAudioDestinationNode MDN}
 */
export default class MediaStreamAudioDestinationNode extends AudioNode {
    readonly stream: MediaStream;
    readonly _track: MixedAudioTrack;

    constructor(context: AudioContext) {
        super(context, 1, 0);

        this._track = new MixedAudioTrack(this);
        this.stream = new MediaStream([ this._track ]);
    }
}
