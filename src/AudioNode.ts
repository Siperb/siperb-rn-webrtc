import type AudioContext from './AudioContext';
import { makeDOMException } from './RTCUtil';
import { EventTarget } from './vendor/event-target-shim';

/** One `source.connect(destination, output, input)` edge, referenced from both ends. */
export interface AudioConnection {
    source: AudioNode;
    destination: AudioNode;
    output: number;
    input: number;
}

/**
 * Base of every node in the library's AudioContext.
 *
 * THE GRAPH IS DECLARATIVE. A node records the edges made through it and processes nothing:
 * the consumers of a MediaStreamAudioDestinationNode (MediaRecorder, RTCRtpSender) walk these
 * edges to learn what to mix natively. That is also why `connect`/`disconnect` validate as the
 * spec does — a graph the SDK builds wrongly should fail here, loudly, not compile to silence.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/AudioNode MDN}
 */
export default class AudioNode extends EventTarget {
    readonly context: AudioContext;
    readonly numberOfInputs: number;
    readonly numberOfOutputs: number;

    _incoming: AudioConnection[] = [];
    _outgoing: AudioConnection[] = [];

    constructor(context: AudioContext, numberOfInputs: number, numberOfOutputs: number) {
        super();

        this.context = context;
        this.numberOfInputs = numberOfInputs;
        this.numberOfOutputs = numberOfOutputs;
    }

    connect(destination: AudioNode, output = 0, input = 0): AudioNode {
        if (!(destination instanceof AudioNode)) {
            throw new TypeError('AudioNode.connect: destination is not an AudioNode');
        }

        if (destination.context !== this.context) {
            throw makeDOMException('InvalidAccessError', 'AudioNode.connect: nodes belong to different AudioContexts');
        }

        if (!Number.isInteger(output) || output < 0 || output >= this.numberOfOutputs) {
            throw makeDOMException('IndexSizeError', `AudioNode.connect: output index ${output} out of range`);
        }

        if (!Number.isInteger(input) || input < 0 || input >= destination.numberOfInputs) {
            throw makeDOMException('IndexSizeError', `AudioNode.connect: input index ${input} out of range`);
        }

        const exists = this._outgoing.some(
            c => c.destination === destination && c.output === output && c.input === input
        );

        if (!exists) {
            const connection: AudioConnection = { source: this, destination, output, input };

            this._outgoing.push(connection);
            destination._incoming.push(connection);
        }

        return destination;
    }

    /**
     * All spec forms: `()`, `(output)`, `(destination)`, `(destination, output)`,
     * `(destination, output, input)`.
     */
    disconnect(destinationOrOutput?: AudioNode | number, output?: number, input?: number): void {
        let matches: AudioConnection[];

        if (destinationOrOutput === undefined) {
            matches = this._outgoing.slice();
        } else if (typeof destinationOrOutput === 'number') {
            if (!Number.isInteger(destinationOrOutput) || destinationOrOutput < 0
                || destinationOrOutput >= this.numberOfOutputs) {
                throw makeDOMException('IndexSizeError',
                    `AudioNode.disconnect: output index ${destinationOrOutput} out of range`);
            }

            matches = this._outgoing.filter(c => c.output === destinationOrOutput);
        } else if (destinationOrOutput instanceof AudioNode) {
            matches = this._outgoing.filter(c => c.destination === destinationOrOutput
                && (output === undefined || c.output === output)
                && (input === undefined || c.input === input));

            if (matches.length === 0) {
                throw makeDOMException('InvalidAccessError', 'AudioNode.disconnect: the nodes are not connected');
            }
        } else {
            throw new TypeError('AudioNode.disconnect: argument is neither an AudioNode nor an output index');
        }

        for (const connection of matches) {
            this._outgoing.splice(this._outgoing.indexOf(connection), 1);
            connection.destination._incoming.splice(connection.destination._incoming.indexOf(connection), 1);
        }
    }
}
