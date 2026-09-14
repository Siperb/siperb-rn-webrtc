import { NativeModules } from 'react-native';

import Logger from './Logger';
import MediaStreamTrack from './MediaStreamTrack';
import RTCDTMFSender from './RTCDTMFSender';
import RTCRtpCapabilities from './RTCRtpCapabilities';
import RTCRtpSendParameters, { RTCRtpSendParametersInit } from './RTCRtpSendParameters';
import { makeDOMException } from './RTCUtil';

const log = new Logger('pc');
const { WebRTCModule } = NativeModules;


export default class RTCRtpSender {
    _id: string;
    _track: MediaStreamTrack | null = null;
    _peerConnectionId: number;
    _rtpParameters: RTCRtpSendParameters;
    _dtmf: RTCDTMFSender | null = null;

    constructor(info: {
        peerConnectionId: number,
        id: string,
        track?: MediaStreamTrack,
        rtpParameters: RTCRtpSendParametersInit
    }) {
        this._peerConnectionId = info.peerConnectionId;
        this._id = info.id;
        this._rtpParameters = new RTCRtpSendParameters(info.rtpParameters);

        if (info.track) {
            this._track = info.track;
        }
    }

    async replaceTrack(track: MediaStreamTrack | null): Promise<void> {
        if (track?._isVirtual) {
            // An AudioContext mix has no native track to hand the sender. Sending it means
            // attaching this peer connection to the native conference bus, which lands with
            // the conference binding; until then refuse loudly rather than swap in nothing.
            throw makeDOMException('NotSupportedError',
                'RTCRtpSender.replaceTrack: a mixed audio track cannot be sent yet (conference binding pending)');
        }

        try {
            await WebRTCModule.senderReplaceTrack(this._peerConnectionId, this._id, track ? track.id : null);
        } catch (e) {
            // Rethrown rather than swallowed: resolving here left `track` pointing at a track
            // the sender never took, and every later hold/mute toggled the wrong one.
            log.error(`${this._peerConnectionId} replaceTrack failed`, e as Error);
            throw e;
        }

        this._track = track;
    }

    static getCapabilities(kind: 'audio' | 'video'): RTCRtpCapabilities {
        return WebRTCModule.senderGetCapabilities(kind);
    }

    getParameters(): RTCRtpSendParameters {
        return this._rtpParameters;
    }

    async setParameters(parameters: RTCRtpSendParameters): Promise<void> {
        // This allows us to get rid of private "underscore properties"
        const _params = JSON.parse(JSON.stringify(parameters));
        const newParameters = await WebRTCModule.senderSetParameters(this._peerConnectionId, this._id, _params);

        this._rtpParameters = new RTCRtpSendParameters(newParameters);
    }

    getStats() {
        return WebRTCModule.senderGetStats(this._peerConnectionId, this._id).then(data =>
            /* On both Android and iOS it is faster to construct a single
            JSON string representing the Map of StatsReports and have it
            pass through the React Native bridge rather than the Map of
            StatsReports. While the implementations do try to be faster in
            general, the stress is on being faster to pass through the React
            Native bridge which is a bottleneck that tends to be visible in
            the UI when there is congestion involving UI-related passing.
            */
            new Map(JSON.parse(data))
        );
    }

    /**
     * RFC 4733 in-band DTMF. Per the W3C spec this is non-null only for audio
     * senders; we gate on the attached track's kind, which matches how callers
     * locate the DTMF-capable sender (an audio track must be present to send).
     */
    get dtmf(): RTCDTMFSender | null {
        if (this._track?.kind !== 'audio') {
            return null;
        }

        if (!this._dtmf) {
            this._dtmf = new RTCDTMFSender({ peerConnectionId: this._peerConnectionId, senderId: this._id });
        }

        return this._dtmf;
    }

    get track() {
        return this._track;
    }

    get id() {
        return this._id;
    }
}
