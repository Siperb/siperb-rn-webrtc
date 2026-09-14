import BlobEvent from './BlobEvent';
import CallRecorder, { CallRecordingOptions } from './CallRecorder';
import { addListener, removeListener } from './EventEmitter';
import Logger from './Logger';
import MediaRecorderErrorEvent from './MediaRecorderErrorEvent';
import type MediaStream from './MediaStream';
import MixedAudioTrack from './MixedAudioTrack';
import { makeDOMException, uniqueID } from './RTCUtil';
import RecordingBlob from './RecordingBlob';
import {
    compileRecordingRequest,
    MediaRecorderOptions,
    NativeRecordingHandle,
    RecordingRequest
} from './RecordingRequest';
import { Event, EventTarget, getEventAttributeValue, setEventAttributeValue } from './vendor/event-target-shim';

const log = new Logger('recorder');

type RecordingState = 'inactive' | 'recording' | 'paused';

type MediaRecorderEventMap = {
    start: Event<'start'>;
    stop: Event<'stop'>;
    dataavailable: BlobEvent;
    error: MediaRecorderErrorEvent;
}

type Handler<TEvent extends Event> = EventTarget.CallbackFunction<MediaRecorder, TEvent> | null;

/** One start()..stop() cycle. Kept separate from the recorder so a stale continuation can be told apart. */
interface RecordingSession {
    request: RecordingRequest;
    handle: NativeRecordingHandle | null;
    startPromise: Promise<void>;
    startFailed: boolean;
    finished: boolean;
    /** A mid-recording native failure, reported ahead of the data it still produced. */
    nativeError: Error | null;
}

/** Native rejection codes → the DOMException name web code would expect. */
const ERROR_NAMES: Record<string, string> = {
    duplicate_id: 'InvalidStateError',
    not_found: 'InvalidStateError',
    io_error: 'InvalidStateError',
    no_sources: 'NotFoundError',
    encode_error: 'EncodingError',
    video_unavailable: 'NotSupportedError'
};

/**
 * W3C MediaRecorder over the native call recorder.
 *
 * `new MediaRecorder(stream)` records what the stream holds: real tracks directly, and the
 * virtual track of an AudioContext destination as everything the graph wires into it (local
 * sources → microphone, remote sources → tapped remote tracks, a two-input merger →
 * channel-split stereo). Audio never crosses the JS bridge; `dataavailable` carries a
 * {@link RecordingBlob} — a reference to the file, not its bytes.
 *
 * ONE CHUNK, AT STOP. The native writer produces a single file, so `timeslice`, `pause()`,
 * `resume()` and `requestData()` are refused with `NotSupportedError` instead of being
 * quietly accepted and never honoured.
 *
 * THE HOST SEAM is two protected methods. `startNative` / `stopNative` default to
 * {@link CallRecorder} with a generated id and native default paths; a host that owns
 * recording ids, paths, rows or crash salvage subclasses and overrides them, keeping the
 * state machine and events here. The compiled request is passed through so the override can
 * use the graph's answer instead of collecting sources itself.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder MDN}
 */
export default class MediaRecorder extends EventTarget<MediaRecorderEventMap> {
    readonly stream: MediaStream;

    _options: MediaRecorderOptions;
    _mimeType: string;
    _state: RecordingState = 'inactive';
    _session: RecordingSession | null = null;

    /**
     * `audio/mp4` (AAC in an .m4a) always; `video/mp4` when the build composites video. A
     * `;codecs=` parameter is accepted and ignored.
     */
    static isTypeSupported(type: string): boolean {
        const essence = String(type ?? '').split(';')[0].trim().toLowerCase();

        if (essence === '' || essence === 'audio/mp4') {
            return true;
        }

        if (essence === 'video/mp4') {
            return CallRecorder.supportsVideo;
        }

        return false;
    }

    constructor(stream: MediaStream, options: MediaRecorderOptions = {}) {
        super();

        if (!stream || typeof stream.getTracks !== 'function') {
            throw new TypeError('MediaRecorder: argument 1 is not a MediaStream');
        }

        if (options.mimeType !== undefined && !MediaRecorder.isTypeSupported(options.mimeType)) {
            throw makeDOMException('NotSupportedError', `MediaRecorder: mimeType ${options.mimeType} is not supported`);
        }

        this.stream = stream;
        this._options = options;
        this._mimeType = options.mimeType ? options.mimeType.split(';')[0].trim().toLowerCase() : '';
    }

    get mimeType(): string {
        return this._mimeType;
    }

    get state(): RecordingState {
        return this._state;
    }

    // Typed per event (not the shim's inferred generic Event) so `recorder.ondataavailable =
    // e => e.data` type-checks for callers the way it does in a browser.
    get onstart(): Handler<Event<'start'>> {
        return getEventAttributeValue<MediaRecorder, Event<'start'>>(this as MediaRecorder, 'start');
    }

    set onstart(value: Handler<Event<'start'>>) {
        setEventAttributeValue(this, 'start', value);
    }

    get onstop(): Handler<Event<'stop'>> {
        return getEventAttributeValue<MediaRecorder, Event<'stop'>>(this as MediaRecorder, 'stop');
    }

    set onstop(value: Handler<Event<'stop'>>) {
        setEventAttributeValue(this, 'stop', value);
    }

    get ondataavailable(): Handler<BlobEvent> {
        return getEventAttributeValue<MediaRecorder, BlobEvent>(this as MediaRecorder, 'dataavailable');
    }

    set ondataavailable(value: Handler<BlobEvent>) {
        setEventAttributeValue(this, 'dataavailable', value);
    }

    get onerror(): Handler<MediaRecorderErrorEvent> {
        return getEventAttributeValue<MediaRecorder, MediaRecorderErrorEvent>(this as MediaRecorder, 'error');
    }

    set onerror(value: Handler<MediaRecorderErrorEvent>) {
        setEventAttributeValue(this, 'error', value);
    }

    start(timeslice?: number): void {
        if (this._state !== 'inactive') {
            throw makeDOMException('InvalidStateError', 'MediaRecorder.start: already recording');
        }

        if (timeslice !== undefined) {
            throw makeDOMException('NotSupportedError',
                'MediaRecorder.start: timeslice is not supported, the native recorder writes one file per segment');
        }

        const request = compileRecordingRequest(this.stream, this._options);

        for (const warning of request.warnings) {
            log.warn(warning);
        }

        // Recording SYNCHRONOUSLY, before the native call resolves: a stop() arriving while the
        // start is in flight must find state 'recording' or it is a spec no-op and the native
        // recording it should have ended runs on.
        this._mimeType = request.mimeType;
        this._state = 'recording';
        this._adjustLiveSinks(1);

        const session: RecordingSession = {
            request,
            handle: null,
            startPromise: Promise.resolve(),
            startFailed: false,
            finished: false,
            nativeError: null
        };

        this._session = session;

        session.startPromise = this.startNative(request).then(
            handle => {
                session.handle = handle;

                if (this._session === session && this._state === 'recording') {
                    this._listenForNativeErrors(session);
                    this.dispatchEvent(new Event('start'));
                }
            },
            error => {
                if (this._session !== session) {
                    return;
                }

                session.startFailed = true;
                this._state = 'inactive';
                this._finish(session, null, toDOMException(error));
            }
        );
    }

    stop(): void {
        const session = this._session;

        if (this._state === 'inactive' || session === null) {
            return;
        }

        this._state = 'inactive';
        this._stopSession(session, 'user');
    }

    pause(): void {
        this._assertRecording('pause');
        throw makeDOMException('NotSupportedError', 'MediaRecorder.pause: the native recorder cannot pause a segment');
    }

    resume(): void {
        this._assertRecording('resume');
        throw makeDOMException('NotSupportedError', 'MediaRecorder.resume: the native recorder cannot pause a segment');
    }

    requestData(): void {
        this._assertRecording('requestData');
        throw makeDOMException('NotSupportedError',
            'MediaRecorder.requestData: the native recorder delivers one chunk, at stop');
    }

    /**
     * Start the native recording for a compiled request and return what identifies it.
     * Default: {@link CallRecorder.start} with a generated id and native default paths.
     */
    protected startNative(request: RecordingRequest): Promise<NativeRecordingHandle> {
        const recordingId = `rec-${uniqueID()}`;
        const options: CallRecordingOptions = {
            recordingId,
            includeMic: request.includeMic,
            stereo: request.stereo,
            remoteTrackIds: request.remoteTrackIds,
            peerConnectionIds: request.peerConnectionIds
        };

        // Added only when present: an explicit `video: undefined` can reach native as null,
        // where "the key exists" is read as "record video".
        if (request.video) {
            options.video = request.video;
        }

        return CallRecorder.start(options).then(() => {
            return { recordingId };
        });
    }

    /**
     * Finalize the native recording. `null` means nothing was produced (nothing to deliver);
     * the recorder then emits an empty blob so listeners still see `dataavailable` before `stop`.
     * Default: {@link CallRecorder.stop}.
     */
    protected stopNative(handle: NativeRecordingHandle, reason: 'user' | 'error'): Promise<RecordingBlob | null> {
        void reason;

        return CallRecorder.stop(handle.recordingId).then(result => new RecordingBlob({
            size: result.size,
            type: result.mimeType,
            path: result.filePath,
            recordingId: result.recordingId,
            durationMs: result.durationMs,
            withVideo: result.withVideo
        }));
    }

    private _stopSession(session: RecordingSession, reason: 'user' | 'error'): void {
        session.startPromise.then(() => {
            if (session.startFailed || session.finished) {
                return;
            }

            // The handle exists here: startPromise only fulfils after it was stored.
            const handle = session.handle as NativeRecordingHandle;

            return this.stopNative(handle, reason).then(
                blob => this._finish(session, blob ?? this._emptyBlob(handle.recordingId), null),
                error => this._finish(session, this._emptyBlob(handle.recordingId), toDOMException(error))
            );
        });
    }

    /**
     * The one place a session ends: error (if any) → dataavailable (if anything to deliver) →
     * stop, exactly once, in that order.
     */
    private _finish(session: RecordingSession, blob: RecordingBlob | null, error: Error | null): void {
        if (session.finished) {
            return;
        }

        session.finished = true;
        removeListener(this);
        this._adjustLiveSinks(-1);

        if (this._session === session) {
            this._session = null;
        }

        const reported = session.nativeError ?? error;

        if (reported) {
            log.warn(`recording failed: ${reported.name}: ${reported.message}`);
            this.dispatchEvent(new MediaRecorderErrorEvent('error', { error: reported }));
        }

        if (blob) {
            if (blob.type) {
                this._mimeType = blob.type;
            }

            this.dispatchEvent(new BlobEvent('dataavailable', { data: blob }));
        }

        this.dispatchEvent(new Event('stop'));
    }

    /**
     * Android reports a mid-recording writer failure (the recording stays registered, the file
     * so far is kept); iOS reports a finalize failure just before rejecting stop(). Only the
     * former needs acting on: while stopping, the rejection path already handles it.
     */
    private _listenForNativeErrors(session: RecordingSession): void {
        addListener(this, 'audioRecordingError', (ev: any) => {
            const ours = ev?.recordingId === session.handle?.recordingId;

            if (this._session !== session || this._state !== 'recording' || !ours) {
                return;
            }

            session.nativeError = makeDOMException('UnknownError', String(ev?.error ?? 'recording failed'));
            this._state = 'inactive';
            this._stopSession(session, 'error');
        });
    }

    private _adjustLiveSinks(delta: number): void {
        for (const track of this.stream.getAudioTracks()) {
            if (track instanceof MixedAudioTrack) {
                track.context._liveSinks += delta;
            }
        }
    }

    private _emptyBlob(recordingId: string): RecordingBlob {
        return new RecordingBlob({
            size: 0,
            type: this._mimeType || 'audio/mp4',
            path: '',
            recordingId,
            durationMs: 0,
            withVideo: false
        });
    }

    private _assertRecording(method: string): void {
        if (this._state === 'inactive') {
            throw makeDOMException('InvalidStateError', `MediaRecorder.${method}: not recording`);
        }
    }
}

/** A native (or host) rejection as an Error whose name web code can switch on. */
function toDOMException(error: any): Error {
    if (error instanceof Error && error.name !== 'Error') {
        return error;
    }

    const code = typeof error?.code === 'string' ? error.code : '';
    const message = typeof error?.message === 'string' ? error.message : String(error);

    return makeDOMException(ERROR_NAMES[code] ?? 'UnknownError', message);
}
