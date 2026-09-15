import { NativeModules } from 'react-native';

import MediaStream from './MediaStream';
import MediaStreamError from './MediaStreamError';

const { WebRTCModule } = NativeModules;

/**
 * The React Native analogue of the web's `canvas.captureStream(fps)`: a native VIEW is
 * rasterised into a video track and sampled on a timer, so the pixels never cross the bridge.
 * Unlike getDisplayMedia there is no picker, consent or born-muted wait — the track delivers from
 * the first tick — so this is a thin resolve, the getDisplayMedia shape minus the error mapping's
 * only real job.
 */

export interface WhiteboardConstraints {
    /** React tag of the mounted view to sample (its `findNodeHandle`). */
    sourceTag: number;
    /** Frames per second; a drawing is near-static, so keep it low. Default 10 on native. */
    fps?: number;
}

export interface PictureConstraints {
    /** A local file / file:// / data: URI for the still image. */
    uri: string;
    /** Re-emit rate to keep the track flowing. Default 2 on native. */
    fps?: number;
}

// `data` is the native module's return, untyped at the bridge exactly as getDisplayMedia treats
// it; MediaStream validates the track info at runtime.
function toStream(data: any): MediaStream {
    return new MediaStream({
        streamId: data.streamId,
        streamReactTag: data.streamId,
        tracks: [ data.track ]
    });
}

/** Present a live drawing surface (whiteboard). */
export function getWhiteboardMedia(constraints: WhiteboardConstraints): Promise<MediaStream> {
    return new Promise((resolve, reject) => {
        WebRTCModule.getWhiteboardMedia(constraints).then(
            data => resolve(toStream(data)),
            error => reject(new MediaStreamError(error))
        );
    });
}

/** Present a still image as a video track. */
export function getPictureMedia(constraints: PictureConstraints): Promise<MediaStream> {
    return new Promise((resolve, reject) => {
        WebRTCModule.getPictureMedia(constraints).then(
            data => resolve(toStream(data)),
            error => reject(new MediaStreamError(error))
        );
    });
}
