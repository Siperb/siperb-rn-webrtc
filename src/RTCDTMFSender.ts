import { NativeModules } from 'react-native';

import Logger from './Logger';
import RTCDTMFToneChangeEvent from './RTCDTMFToneChangeEvent';
import { EventTarget, getEventAttributeValue, setEventAttributeValue } from './vendor/event-target-shim';

const { WebRTCModule } = NativeModules;
const log = new Logger('dtmf');

// W3C defaults and clamps for insertDTMF():
// https://www.w3.org/TR/webrtc/#dom-rtcdtmfsender-insertdtmf
const DEFAULT_DURATION = 100;
const DEFAULT_INTER_TONE_GAP = 70;
const MIN_DURATION = 40;
const MAX_DURATION = 6000;
const MIN_INTER_TONE_GAP = 30;
const VALID_TONES = /^[0-9A-D#*,]*$/;

type DTMFSenderEventMap = {
    tonechange: RTCDTMFToneChangeEvent;
};

/**
 * Sends RFC 4733 in-band DTMF (telephone-event) on an audio RTCRtpSender.
 *
 * The actual RTP telephone-event packets and their timing are produced by the
 * native WebRTC engine (libwebrtc) — `insertDTMF` simply hands the full tone
 * string to it. The `tonechange` event and `toneBuffer` are reconstructed in JS
 * on a timer because neither the Android (`org.webrtc.DtmfSender`) nor the iOS
 * (`RTCDtmfSender`) SDK exposes a per-tone callback. They are therefore a
 * best-effort approximation of playout, not sample-accurate.
 */
export default class RTCDTMFSender extends EventTarget<DTMFSenderEventMap> {
    _peerConnectionId: number;
    _senderId: string;
    _toneBuffer = '';
    _duration = DEFAULT_DURATION;
    _interToneGap = DEFAULT_INTER_TONE_GAP;
    _timer: ReturnType<typeof setTimeout> | null = null;

    constructor(info: { peerConnectionId: number, senderId: string }) {
        super();

        this._peerConnectionId = info.peerConnectionId;
        this._senderId = info.senderId;
    }

    get ontonechange() {
        return getEventAttributeValue(this, 'tonechange');
    }

    set ontonechange(value) {
        setEventAttributeValue(this, 'tonechange', value);
    }

    get toneBuffer(): string {
        return this._toneBuffer;
    }

    get canInsertDTMF(): boolean {
        // Blocking-sync bridge call (mirrors RTCRtpSender.getCapabilities). It
        // reflects whether the audio m-line has negotiated telephone-event, so
        // it is false until negotiation completes. Read once per send, not in a
        // hot path. Guarded so a debugger that disables sync calls can't break it.
        try {
            return WebRTCModule.senderCanInsertDtmf(this._peerConnectionId, this._senderId);
        } catch (e) {
            log.error('canInsertDTMF query failed', e as Error);

            return false;
        }
    }

    insertDTMF(tones: string, duration = DEFAULT_DURATION, interToneGap = DEFAULT_INTER_TONE_GAP): void {
        const normalized = String(tones).toUpperCase();

        if (!VALID_TONES.test(normalized)) {
            const error = new Error(`Invalid DTMF tones: "${tones}". Allowed characters are 0-9, A-D, #, *, and ,.`);

            error.name = 'InvalidCharacterError';
            throw error;
        }

        this._duration = Math.min(MAX_DURATION, Math.max(MIN_DURATION, duration));
        this._interToneGap = Math.max(MIN_INTER_TONE_GAP, interToneGap);
        this._toneBuffer = normalized;

        // A new insertDTMF call replaces the current buffer, so stop any pending
        // playout chain before starting (or clearing, when tones === '').
        this._stopPlayout();

        // Hand the whole string to the engine once; it owns the real RFC 4733
        // RTP playout/timing. We ignore the result but surface failures.
        WebRTCModule
            .senderInsertDtmf(this._peerConnectionId, this._senderId, normalized, this._duration, this._interToneGap)
            .catch((e: Error) => log.error('senderInsertDtmf failed', e));

        if (normalized.length > 0) {
            this._playNextTone();
        }
    }

    /**
     * Dispatch a `tonechange` for the next buffered tone and schedule the one
     * after it. When the buffer is empty, dispatch the final empty `tonechange`.
     */
    _playNextTone(): void {
        if (this._toneBuffer.length === 0) {
            this._timer = null;
            this.dispatchEvent(new RTCDTMFToneChangeEvent('tonechange', { tone: '' }));

            return;
        }

        const tone = this._toneBuffer[0];

        this._toneBuffer = this._toneBuffer.slice(1);
        this.dispatchEvent(new RTCDTMFToneChangeEvent('tonechange', { tone }));

        this._timer = setTimeout(() => this._playNextTone(), this._duration + this._interToneGap);
    }

    /** Cancel any in-flight playout timer. Safe to call when none is pending. */
    _stopPlayout(): void {
        if (this._timer !== null) {
            clearTimeout(this._timer);
            this._timer = null;
        }
    }
}
