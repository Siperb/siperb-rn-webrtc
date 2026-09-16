import { NativeModules } from 'react-native';

import FileAudioTrack from './FileAudioTrack';
import FilePlayback from './FilePlayback';
import FileVideoTrack from './FileVideoTrack';
import MediaStream from './MediaStream';
import MediaStreamError from './MediaStreamError';

const { WebRTCModule } = NativeModules;

/**
 * The React Native analogue of the web's "load a file into `<video>`, then `captureStream()`":
 * a native player decodes the file, its frames go into a video track through the same capturer
 * pipeline the camera and the screen use, and its soundtrack goes onto the native conference
 * bus as an AUX source — so the far end hears it mixed with the microphone and the presenter
 * hears their own copy through WebRTC's playout (which is what keeps it out of the echo).
 *
 * One stream comes back carrying BOTH halves: a real video track and a virtual audio track,
 * exactly the shape a `<video>` element's `captureStream()` has, so a host assigns it to both
 * `PresentVideoMediaStream` and `PresentAudioMediaStream` and the SDK's existing present path
 * needs no glue. Transport controls hang off `stream.playback`.
 */

export interface FileMediaConstraints {
    /** A `file://` or `content://` URI the native player can read for the whole playback. */
    uri: string;
    /** Frames per second delivered to the track. Default 25 (the web's canvas rate). */
    fps?: number;
    /** Cap on the SHORTER side of the frame, as the web's VideoResampleSize does. Default 360. */
    maxSide?: number;
    /**
     * Start playing as soon as the source is ready. Default false: a host that presents the
     * stream first and calls `playback.play()` once the mix is up loses none of the opening
     * second of audio to the attach.
     */
    autoplay?: boolean;
}

export class FileMediaStream extends MediaStream {
    readonly playback: FilePlayback;

    constructor(data: any) {
        super({ streamId: data.streamId, streamReactTag: data.streamId, tracks: [] });

        // The video track is already part of the native stream — pushed rather than addTrack'd,
        // as MediaStream's own constructor does for the tracks native hands it.
        const video = new FileVideoTrack(data.track);

        this._tracks.push(video);

        if (data.audio && typeof data.audio.auxId === 'string') {
            // Virtual: addTrack skips the bridge for it.
            const audio = new FileAudioTrack(data.audio.auxId, video);

            video._audio = audio;
            this.addTrack(audio);
        }

        this.playback = new FilePlayback(video.id, {
            duration: typeof data.duration === 'number' ? data.duration : 0,
            playing: data.playing === true
        });
        // The track owns the handle's lifetime: stop()/release() and a native `ended` both
        // dispose it, so a control after the source is gone rejects instead of hanging.
        video._playback = this.playback;
    }
}

export function getFileMedia(constraints: FileMediaConstraints): Promise<FileMediaStream> {
    if (!constraints || typeof constraints.uri !== 'string' || constraints.uri.length === 0) {
        return Promise.reject(new TypeError('getFileMedia: constraints.uri is required'));
    }

    const request = {
        uri: constraints.uri,
        fps: constraints.fps ?? 25,
        maxSide: constraints.maxSide ?? 360,
        autoplay: constraints.autoplay === true
    };

    return new Promise((resolve, reject) => {
        WebRTCModule.getFileMedia(request).then(
            data => resolve(new FileMediaStream(data)),
            error => reject(new MediaStreamError(error))
        );
    });
}
