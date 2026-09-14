import type AudioContext from './AudioContext';
import AudioNode from './AudioNode';

/**
 * `context.destination` — the device speakers. Nothing routes there natively (WebRTC plays
 * remote audio itself), so connecting to it records an edge and has no effect. It exists so
 * spec-shaped code that connects a monitor path does not throw.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/AudioDestinationNode MDN}
 */
export default class AudioDestinationNode extends AudioNode {
    readonly maxChannelCount = 2;

    constructor(context: AudioContext) {
        super(context, 1, 0);
    }
}
