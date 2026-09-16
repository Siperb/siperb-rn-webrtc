import { NativeModules } from 'react-native';

import { addListener, removeListener } from './EventEmitter';
import type FileAudioTrack from './FileAudioTrack';
import type FilePlayback from './FilePlayback';
import MediaStreamTrack, { MediaStreamTrackInfo } from './MediaStreamTrack';

const { WebRTCModule } = NativeModules;

/**
 * The video track of a presented file — a REAL native track (the file player renders into the
 * same capturer pipeline the camera and the screen use), with two rules the base class does
 * not have.
 *
 * `enabled = false` PAUSES the file, audio and video together. The SDK disables every sender
 * track on hold, and a paused file is what a held call should mean: the far end hears nothing
 * from it and the presenter is not left sitting through content nobody saw. Native maps it to
 * the controller's stopCapture/startCapture, which the file controller treats as suspend/resume.
 *
 * `stop()` DISPOSES. On this platform a stop is normally a pause the track can come back from,
 * and release() is separate — but the SDK stops the presented track and never releases it, a
 * file cannot be re-enabled after stop() (the base class returns before the bridge once ended),
 * and a paused-forever player is a leak of a scarce decoder. So stop() also releases, once, and
 * takes the soundtrack down with it.
 */
export default class FileVideoTrack extends MediaStreamTrack {
    _audio: FileAudioTrack | null = null;
    _playback: FilePlayback | null = null;
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
        this._audio?.stop();
        this._playback?._dispose();
        removeListener(this);
        WebRTCModule.mediaStreamTrackRelease(this.id);
    }

    override _registerEvents(): void {
        super._registerEvents();

        // The player died natively (a decode error, a URI that stopped resolving): the
        // soundtrack goes with it, so nothing keeps an aux on the bus for a file that is gone.
        addListener(this, 'mediaStreamTrackEnded', (ev: any) => {
            if (ev.trackId === this.id) {
                this._audio?.stop();
                this._playback?._dispose();
            }
        });
    }
}
