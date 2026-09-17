import { NativeModules } from 'react-native';

import { removeListener } from './EventEmitter';
import MediaStreamTrack, { MediaStreamTrackInfo } from './MediaStreamTrack';

const { WebRTCModule } = NativeModules;

/**
 * The video track getDisplayMedia hands back, with the one rule the base class does not have:
 * `stop()` RELEASES.
 *
 * On this platform a stop is normally a pause the track can come back from and release() is
 * separate — but a screen capture cannot come back from a stop (Android 14 makes the
 * MediaProjection token single-use, and iOS's broadcast has to be started again from the
 * picker), the SDK stops the presented track and never releases it (release() is not a web
 * API), and an un-released screen track is a leak with a face: on Android the MediaProjection
 * foreground service and its "screen sharing" notification stay up for the life of the process
 * — MediaProjectionService.abort() runs only from the controller's dispose() — plus one
 * VideoSource, SurfaceTextureHelper and OrientationEventListener per share. So stop() also
 * releases, once. Same shape, same reason, as FileVideoTrack.
 */
export default class ScreenVideoTrack extends MediaStreamTrack {
    _released = false;

    constructor(info: MediaStreamTrackInfo) {
        super(info);
    }

    override stop(): void {
        super.stop();
        this.release();
    }

    override release(): void {
        if (this._released) {
            return;
        }

        this._released = true;
        removeListener(this);
        WebRTCModule.mediaStreamTrackRelease(this.id);
    }
}
