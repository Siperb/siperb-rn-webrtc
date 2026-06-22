import { Event } from './vendor/event-target-shim';


interface IRTCDTMFToneChangeEventInitDict extends Event.EventInit {
    tone: string;
}

/**
 * @eventClass
 * Fired by an RTCDTMFSender each time a tone begins playing, and once with an
 * empty `tone` when the tone buffer has been fully played out.
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/RTCDTMFToneChangeEvent MDN} for details.
 */
export default class RTCDTMFToneChangeEvent<
    TEventType extends string = 'tonechange'
> extends Event<TEventType> {
    /** @eventProperty The tone that just started playing, or '' when playout finished. */
    tone: string;

    constructor(type: TEventType, eventInitDict: IRTCDTMFToneChangeEventInitDict) {
        super(type, eventInitDict);
        this.tone = eventInitDict.tone;
    }
}
