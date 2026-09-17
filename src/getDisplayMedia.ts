
import { NativeModules } from 'react-native';

import MediaStream from './MediaStream';
import MediaStreamError from './MediaStreamError';
import ScreenVideoTrack from './ScreenVideoTrack';

const { WebRTCModule } = NativeModules;

export interface Constraints {
    android?: {
        createConfigForDefaultDisplay?: boolean;
        resolutionScale?: number;
    }
}

export default function getDisplayMedia(constraints: Constraints = {}): Promise<MediaStream> {
    return new Promise((resolve, reject) => {
        WebRTCModule.getDisplayMedia(constraints).then(
            data => {
                const { streamId, track } = data;

                const stream = new MediaStream({
                    streamId: streamId,
                    streamReactTag: streamId,
                    tracks: []
                });

                // The track is already part of the native stream — pushed rather than addTrack'd,
                // as MediaStream's own constructor does for the tracks native hands it. A
                // ScreenVideoTrack so that stop() releases; see that class.
                stream._tracks.push(new ScreenVideoTrack(track));

                resolve(stream);
            },
            error => {
                reject(new MediaStreamError(error));
            }
        );
    });
}
