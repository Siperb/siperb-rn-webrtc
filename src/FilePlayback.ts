import { NativeModules } from 'react-native';

import { addListener, removeListener } from './EventEmitter';
import Logger from './Logger';
import { Event, EventTarget, getEventAttributeValue, setEventAttributeValue } from './vendor/event-target-shim';

const { WebRTCModule } = NativeModules;
const log = new Logger('file');

/** What native reports after every control call and inside every event. */
export interface FilePlaybackState {
    playing: boolean;
    position: number;
    duration: number;
    ended: boolean;
}

export type FileMediaEventType = 'playing' | 'paused' | 'ended' | 'progress' | 'error';

type FilePlaybackEventMap = {
    play: Event<'play'>;
    pause: Event<'pause'>;
    ended: Event<'ended'>;
    timeupdate: Event<'timeupdate'>;
    error: Event<'error'>;
}

/**
 * The transport controls of a presented video file, in HTMLMediaElement vocabulary — because
 * that is what the web's `<video controls>` gives its presenter, and an overlay player written
 * against `play()` / `pause()` / `currentTime` / `duration` / `paused` / `ended` and the
 * `play` / `pause` / `ended` / `timeupdate` events reads the same on both hosts.
 *
 * Every mutation goes to native (`fileMediaControl`), which owns the clock; the properties
 * here are the last state native reported, refreshed by each control call's reply and by the
 * `fileMediaEvent` stream (`progress` at ~1 Hz). `volume` is the presenter's LOCAL copy only —
 * it scales what the render hook plays out and never what the far end receives.
 */
export default class FilePlayback extends EventTarget<FilePlaybackEventMap> {
    readonly trackId: string;

    private _state: FilePlaybackState;
    private _volume = 1;
    private _disposed = false;

    constructor(trackId: string, initial: Partial<FilePlaybackState> = {}) {
        super();

        this.trackId = trackId;
        this._state = {
            playing: initial.playing === true,
            position: initial.position ?? 0,
            duration: initial.duration ?? 0,
            ended: initial.ended === true
        };

        addListener(this, 'fileMediaEvent', (ev: any) => {
            if (!ev || ev.trackId !== this.trackId || this._disposed) {
                return;
            }

            this._absorb(ev);

            switch (ev.type as FileMediaEventType) {
                case 'playing':
                    this.dispatchEvent(new Event('play'));
                    break;
                case 'paused':
                    this.dispatchEvent(new Event('pause'));
                    break;
                case 'ended':
                    this.dispatchEvent(new Event('ended'));
                    break;
                case 'progress':
                    this.dispatchEvent(new Event('timeupdate'));
                    break;
                case 'error':
                    log.warn(`${this.trackId} playback error: ${ev.message ?? 'unknown'}`);
                    this.dispatchEvent(new Event('error'));
                    break;
            }
        });
    }

    get currentTime(): number {
        return this._state.position;
    }

    set currentTime(seconds: number) {
        this.seek(seconds).catch(() => undefined);
    }

    get duration(): number {
        return this._state.duration;
    }

    get paused(): boolean {
        return !this._state.playing;
    }

    get ended(): boolean {
        return this._state.ended;
    }

    get volume(): number {
        return this._volume;
    }

    set volume(value: number) {
        const clamped = Math.max(0, Math.min(1, Number(value) || 0));

        this._volume = clamped;
        this._control({ action: 'volume', value: clamped }).catch(() => undefined);
    }

    get onplay() {
        return getEventAttributeValue(this, 'play');
    }
    set onplay(value) {
        setEventAttributeValue(this, 'play', value);
    }
    get onpause() {
        return getEventAttributeValue(this, 'pause');
    }
    set onpause(value) {
        setEventAttributeValue(this, 'pause', value);
    }
    get onended() {
        return getEventAttributeValue(this, 'ended');
    }
    set onended(value) {
        setEventAttributeValue(this, 'ended', value);
    }
    get ontimeupdate() {
        return getEventAttributeValue(this, 'timeupdate');
    }
    set ontimeupdate(value) {
        setEventAttributeValue(this, 'timeupdate', value);
    }

    /** After `ended`, play() means seek to 0 and play — the web's `<video>` does the same. */
    play(): Promise<FilePlaybackState> {
        return this._control({ action: 'play' });
    }

    pause(): Promise<FilePlaybackState> {
        return this._control({ action: 'pause' });
    }

    seek(seconds: number): Promise<FilePlaybackState> {
        return this._control({ action: 'seek', position: Math.max(0, Number(seconds) || 0) });
    }

    /** The last state native reported. */
    get state(): FilePlaybackState {
        return { ...this._state };
    }

    /** Called by the owning track when the file source is gone; further controls reject. */
    _dispose(): void {
        if (this._disposed) {
            return;
        }

        this._disposed = true;
        removeListener(this);
    }

    private _absorb(state: Partial<FilePlaybackState>): void {
        if (typeof state.playing === 'boolean') {
            this._state.playing = state.playing;
        }

        if (typeof state.position === 'number') {
            this._state.position = state.position;
        }

        if (typeof state.duration === 'number') {
            this._state.duration = state.duration;
        }

        if (typeof state.ended === 'boolean') {
            this._state.ended = state.ended;
        }
    }

    private async _control(command: { action: string; position?: number; value?: number }): Promise<FilePlaybackState> {
        if (this._disposed) {
            throw new Error('FilePlayback: the file source has been released');
        }

        const state = await WebRTCModule.fileMediaControl(this.trackId, command);

        if (state && typeof state === 'object') {
            this._absorb(state);
        }

        return this.state;
    }
}
