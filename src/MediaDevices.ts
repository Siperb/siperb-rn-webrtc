import { NativeModules } from 'react-native';

import getDisplayMedia, { Constraints as DisplayMediaConstraints } from './getDisplayMedia';
import getUserMedia, { Constraints as UserMediaConstraints } from './getUserMedia';
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
}

export default new MediaDevices();
