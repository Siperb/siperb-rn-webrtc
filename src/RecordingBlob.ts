export interface RecordingBlobInit {
    size: number;
    type: string;
    /** Absolute path of the finalized file; empty when nothing was written. */
    path: string;
    recordingId: string;
    durationMs: number;
    withVideo: boolean;
    /** Data-URL poster (`data:image/jpeg;base64,…`) for a video recording; absent otherwise. */
    thumbnail?: string;
}

/**
 * What a MediaRecorder hands out in `dataavailable`: a Blob-shaped REFERENCE to the file the
 * native recorder wrote.
 *
 * NOT an in-memory Blob, on purpose. React Native cannot build a file-backed Blob without
 * reading the whole recording into memory (a long call is tens of megabytes), and `fetch` of a
 * `file://` URI is unreliable on Android — so `size` and `type` are here, as web code reads
 * them, and the bytes stay on disk at `path`/`uri` for a filesystem module to move or upload.
 * `slice`/`arrayBuffer`/`text` are absent rather than throwing, so duck-typing stays honest.
 */
export default class RecordingBlob {
    readonly size: number;
    readonly type: string;
    readonly path: string;
    readonly uri: string;
    readonly recordingId: string;
    readonly durationMs: number;
    readonly withVideo: boolean;
    /** A `data:image/jpeg;base64,…` poster for a video recording, or `''`. Small enough to ride
     *  on the recording row (which is synced), unlike `uri`, which is this device's path. */
    readonly thumbnail: string;

    constructor(init: RecordingBlobInit) {
        this.size = init.size;
        this.type = init.type;
        this.path = init.path;
        this.uri = init.path ? `file://${init.path}` : '';
        this.recordingId = init.recordingId;
        this.durationMs = init.durationMs;
        this.withVideo = init.withVideo;
        this.thumbnail = init.thumbnail || '';
    }
}
