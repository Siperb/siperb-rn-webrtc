import type AudioContext from './AudioContext';
import AudioNode from './AudioNode';
import AudioParam from './AudioParam';

/**
 * Scales what passes through it. In this declarative graph only `gain.value` at the time a
 * consumer compiles the graph matters (0 excludes a source; anything else passes it through —
 * the native mixer has no per-source gain).
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/GainNode MDN}
 */
export default class GainNode extends AudioNode {
    readonly gain: AudioParam;

    constructor(context: AudioContext, gain = 1) {
        super(context, 1, 1);

        this.gain = new AudioParam(1);
        this.gain.value = gain;
    }
}
