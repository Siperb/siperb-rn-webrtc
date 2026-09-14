import type RecordingBlob from './RecordingBlob';
import { Event } from './vendor/event-target-shim';

interface IBlobEventInitDict extends Event.EventInit {
    data: RecordingBlob;
    timecode?: number;
}

/**
 * @eventClass
 * Carries a recording's output on `dataavailable`.
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/BlobEvent MDN} for details.
 */
export default class BlobEvent extends Event<'dataavailable'> {
    /** @eventProperty */
    data: RecordingBlob;
    /** @eventProperty Always 0: the native recorder delivers one chunk, at stop. */
    timecode: number;

    constructor(type: 'dataavailable', eventInitDict: IBlobEventInitDict) {
        super(type, eventInitDict);
        this.data = eventInitDict.data;
        this.timecode = eventInitDict.timecode ?? 0;
    }
}
