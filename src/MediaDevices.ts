import { NativeModules } from 'react-native';

import getDisplayMedia, { Constraints as DisplayMediaConstraints } from './getDisplayMedia';
import getUserMedia, { Constraints as UserMediaConstraints } from './getUserMedia';
import {
    getPictureMedia,
    getWhiteboardMedia,
    PictureConstraints,
    WhiteboardConstraints
} from './getViewMedia';
import { Event, EventTarget, getEventAttributeValue, setEventAttributeValue } from './vendor/event-target-shim';

const { WebRTCModule } = NativeModules;

type MediaDevicesEventMap = {
    devicechange: Event<'devicechange'>
}

class MediaDevices extends EventTarget<MediaDevicesEventMap> {
    /**
     * Whether {@link getDisplayMedia} on THIS build can deliver a frame.
     *
     * Not a W3C member - a host fact, like CallRecorder.supportsVideo, and answered the same
     * way: a native constant, synchronous, that cannot lie about the binary it came from.
     * getDisplayMedia() itself always constructs a track, so its presence proves nothing; what
     * decides it is packaging the JS cannot see - on iOS a bundled Broadcast Upload Extension,
     * an App Group and two Info.plist keys; on Android the foreground service Android 10+
     * demands and, on 14+, its permission. `undefined` on a binary predating this reads as
     * false. A host that gates a feature on `typeof mediaDevices.getDisplayMedia` should delete
     * the method where this is false, so the probe reads "not supported" rather than presenting
     * a black screen.
     */
    get supportsDisplayMedia(): boolean {
        return WebRTCModule?.displayMediaSupported === true;
    }

    /**
     * Whether {@link getWhiteboardMedia} / {@link getPictureMedia} exist on THIS build. In-process
     * view capture needs no extension, App Group or entitlement, so this is simply true wherever
     * the native code is present; the point is version skew — an OTA JS bundle reaching an older
     * binary reads the absent constant as false, and a host that gates on
     * `typeof mediaDevices.getWhiteboardMedia` should delete those methods where this is false.
     */
    get supportsFrameSource(): boolean {
        return WebRTCModule?.supportsFrameSource === true;
    }

    get ondevicechange() {
        return getEventAttributeValue(this, 'devicechange');
    }

    set ondevicechange(value) {
        setEventAttributeValue(this, 'devicechange', value);
    }

    /**
     * W3C "Media Capture and Streams" compatible {@code enumerateDevices}
     * implementation.
     */
    enumerateDevices() {
        return new Promise(resolve => WebRTCModule.enumerateDevices(resolve));
    }

    /**
     * W3C "Screen Capture" compatible {@code getDisplayMedia} implementation.
     * See: https://w3c.github.io/mediacapture-screen-share/
     *
     * @param {*} constraints
     * @returns {Promise}
     */
    getDisplayMedia(constraints: DisplayMediaConstraints) {
        return getDisplayMedia(constraints);
    }

    /**
     * W3C "Media Capture and Streams" compatible {@code getUserMedia}
     * implementation.
     * See: https://www.w3.org/TR/mediacapture-streams/#dom-mediadevices-enumeratedevices
     *
     * @param {*} constraints
     * @returns {Promise}
     */
    getUserMedia(constraints: UserMediaConstraints) {
        return getUserMedia(constraints);
    }

    /**
     * The native `canvas.captureStream(fps)`: sample a mounted view (by its React tag) into a
     * video track. Present a live drawing surface as a whiteboard.
     *
     * @param {WhiteboardConstraints} constraints `{ sourceTag, fps? }`
     * @returns {Promise<MediaStream>}
     */
    getWhiteboardMedia(constraints: WhiteboardConstraints) {
        return getWhiteboardMedia(constraints);
    }

    /**
     * Present a still image (a local/data URI) as a video track.
     *
     * @param {PictureConstraints} constraints `{ uri, fps? }`
     * @returns {Promise<MediaStream>}
     */
    getPictureMedia(constraints: PictureConstraints) {
        return getPictureMedia(constraints);
    }
}

export default new MediaDevices();
