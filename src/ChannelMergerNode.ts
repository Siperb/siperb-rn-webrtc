import type AudioContext from './AudioContext';
import AudioNode from './AudioNode';
import { makeDOMException } from './RTCUtil';

/**
 * Combines its inputs into one multi-channel output. The input index a source connects to is
 * how the recorder learns channel placement: the SDK routes local tracks to input 0 and remote
 * tracks to input 1, which the native recorder writes as channel-split stereo.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/ChannelMergerNode MDN}
 */
export default class ChannelMergerNode extends AudioNode {
    constructor(context: AudioContext, numberOfInputs = 6) {
        if (!Number.isInteger(numberOfInputs) || numberOfInputs < 1 || numberOfInputs > 32) {
            throw makeDOMException('IndexSizeError',
                `ChannelMergerNode: numberOfInputs ${numberOfInputs} out of range`);
        }

        super(context, numberOfInputs, 1);
    }
}
