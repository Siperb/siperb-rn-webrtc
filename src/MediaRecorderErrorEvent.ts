import { Event } from './vendor/event-target-shim';

interface IMediaRecorderErrorEventInitDict extends Event.EventInit {
    error: Error;
}

/**
 * @eventClass
 * Fired when recording cannot start, dies mid-way, or cannot be finalized. `error.name` carries
 * the DOMException name (`InvalidStateError`, `NotFoundError`, `EncodingError`, ...).
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorderErrorEvent MDN} for details.
 */
export default class MediaRecorderErrorEvent extends Event<'error'> {
    /** @eventProperty */
    error: Error;

    constructor(type: 'error', eventInitDict: IMediaRecorderErrorEventInitDict) {
        super(type, eventInitDict);
        this.error = eventInitDict.error;
    }
}
