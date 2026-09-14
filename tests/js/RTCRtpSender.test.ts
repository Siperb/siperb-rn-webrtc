
import AudioContext from '../../src/AudioContext';
import RTCRtpSender from '../../src/RTCRtpSender';

import { fakeTrack } from './helpers';
import { NativeModules } from './mocks/react-native';

const native = NativeModules.WebRTCModule;

/** The shape native serializes for a sender's parameters; empty but iterable. */
const RTP_PARAMS = {
    codecs: [],
    headerExtensions: [],
    rtcp: { cname: '', reducedSize: false },
    encodings: [],
    transactionId: 't1',
    degradationPreference: null
} as any;

beforeEach(() => {
    jest.clearAllMocks();
});

describe('RTCRtpSender.replaceTrack', () => {
    test('rethrows a native failure and keeps the previous track', async () => {
        const mic = fakeTrack('mic', 'audio', false);
        const other = fakeTrack('mic2', 'audio', false);
        const sender = new RTCRtpSender({ peerConnectionId: 1, id: 's1', track: mic, rtpParameters: RTP_PARAMS });

        native.senderReplaceTrack.mockImplementationOnce(() => Promise.reject(new Error('Could not get transceiver')));

        await expect(sender.replaceTrack(other)).rejects.toThrow('Could not get transceiver');
        expect(sender.track).toBe(mic);
    });

    test('swaps on success', async () => {
        const mic = fakeTrack('mic', 'audio', false);
        const other = fakeTrack('mic2', 'audio', false);
        const sender = new RTCRtpSender({ peerConnectionId: 1, id: 's1', track: mic, rtpParameters: RTP_PARAMS });

        await sender.replaceTrack(other);
        expect(native.senderReplaceTrack).toHaveBeenCalledWith(1, 's1', 'mic2');
        expect(sender.track).toBe(other);
    });

    test('refuses a virtual mix track until the conference binding exists', async () => {
        const mic = fakeTrack('mic', 'audio', false);
        const sender = new RTCRtpSender({ peerConnectionId: 1, id: 's1', track: mic, rtpParameters: RTP_PARAMS });
        const mix = new AudioContext().createMediaStreamDestination().stream.getAudioTracks()[0];

        await expect(sender.replaceTrack(mix)).rejects.toMatchObject({ name: 'NotSupportedError' });
        expect(native.senderReplaceTrack).not.toHaveBeenCalled();
        expect(sender.track).toBe(mic);
    });
});
