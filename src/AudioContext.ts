import AudioDestinationNode from './AudioDestinationNode';
import ChannelMergerNode from './ChannelMergerNode';
import GainNode from './GainNode';
import Logger from './Logger';
import type MediaStream from './MediaStream';
import MediaStreamAudioDestinationNode from './MediaStreamAudioDestinationNode';
import MediaStreamAudioSourceNode from './MediaStreamAudioSourceNode';
import { makeDOMException } from './RTCUtil';
import { Event, EventTarget, getEventAttributeValue, setEventAttributeValue } from './vendor/event-target-shim';

const log = new Logger('audio');

type AudioContextState = 'suspended' | 'running' | 'closed';

type AudioContextEventMap = {
    statechange: Event<'statechange'>;
}

/**
 * A W3C-shaped AudioContext whose graph is DECLARATIVE: nodes record how they are wired and
 * nothing is processed in JS. The mixing happens natively, below the encoder, once a consumer
 * reads the graph — MediaRecorder for a recording, RTCRtpSender.replaceTrack for a conference
 * leg — through the virtual track of a MediaStreamAudioDestinationNode.
 *
 * WHAT IS HERE is exactly the subset stream-mixing code uses: the four `create*` below, node
 * connect/disconnect, `gain.value`, `state`/`resume`/`suspend`/`close`. WHAT IS ABSENT stays
 * absent — `createMediaElementSource`, oscillators, analysers, `decodeAudioData`, worklets,
 * `currentTime`. A present-but-fake member would pass a `typeof` feature probe and then do
 * nothing, which is worse than the probe failing.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/AudioContext MDN}
 */
export default class AudioContext extends EventTarget<AudioContextEventMap> {
    /** The native bus rate; every source is resampled onto it. */
    readonly sampleRate = 48000;
    readonly destination: AudioDestinationNode;

    _state: AudioContextState = 'running';
    _destinations: MediaStreamAudioDestinationNode[] = [];

    /**
     * Number of this context's mixes currently consumed natively (a recording in progress, a
     * leg on the bus). While non-zero the native mix is fixed, so a source added now cannot be
     * heard — which is what the warning in createMediaStreamSource is for.
     */
    _liveSinks = 0;

    constructor() {
        super();

        this.destination = new AudioDestinationNode(this);
    }

    get state(): AudioContextState {
        return this._state;
    }

    get onstatechange() {
        return getEventAttributeValue(this, 'statechange');
    }

    set onstatechange(value) {
        setEventAttributeValue(this, 'statechange', value);
    }

    createGain(): GainNode {
        this._assertOpen('createGain');

        return new GainNode(this);
    }

    createChannelMerger(numberOfInputs = 6): ChannelMergerNode {
        this._assertOpen('createChannelMerger');

        return new ChannelMergerNode(this, numberOfInputs);
    }

    createMediaStreamSource(mediaStream: MediaStream): MediaStreamAudioSourceNode {
        this._assertOpen('createMediaStreamSource');

        const node = new MediaStreamAudioSourceNode(this, mediaStream);

        if (this._liveSinks > 0 && mediaStream.getAudioTracks().some(track => !track.remote)) {
            // The SDK adds presentation audio to a running recording / conference this way. The
            // native recorder and bus take their inputs at start/attach, so this source will
            // not be heard until the consumer is restarted. Said once, loudly, rather than
            // silently recording a file without it.
            log.warn(`${mediaStream.id} added as a source while this context is already being consumed natively; `
                + 'the native mix is fixed at start/attach and will not include it');
        }

        return node;
    }

    createMediaStreamDestination(): MediaStreamAudioDestinationNode {
        this._assertOpen('createMediaStreamDestination');

        const node = new MediaStreamAudioDestinationNode(this);

        this._destinations.push(node);

        return node;
    }

    resume(): Promise<void> {
        return this._transition('running');
    }

    suspend(): Promise<void> {
        return this._transition('suspended');
    }

    /**
     * Idempotent. Everything this context put on the native side is released synchronously
     * (see the binding in slice 2), so the SDK's fire-and-forget `ctx.close()` is enough.
     */
    close(): Promise<void> {
        if (this._state === 'closed') {
            return Promise.resolve();
        }

        this._state = 'closed';
        this.dispatchEvent(new Event('statechange'));

        return Promise.resolve();
    }

    private _transition(state: AudioContextState): Promise<void> {
        if (this._state === 'closed') {
            return Promise.reject(makeDOMException('InvalidStateError', 'AudioContext is closed'));
        }

        if (this._state !== state) {
            this._state = state;
            this.dispatchEvent(new Event('statechange'));
        }

        return Promise.resolve();
    }

    private _assertOpen(method: string): void {
        if (this._state === 'closed') {
            throw makeDOMException('InvalidStateError', `AudioContext.${method}: the context is closed`);
        }
    }
}
