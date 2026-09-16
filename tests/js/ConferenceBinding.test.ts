import AudioContext from '../../src/AudioContext';
import { boundLegId } from '../../src/ConferenceLegBinding';
import { setupNativeEvents } from '../../src/EventEmitter';
import type MixedAudioTrack from '../../src/MixedAudioTrack';
import RTCPeerConnection from '../../src/RTCPeerConnection';
import RTCRtpSender from '../../src/RTCRtpSender';

import { fakeTrack, flush, streamOf } from './helpers';
import { emitNative, NativeModules } from './mocks/react-native';

const native = NativeModules.WebRTCModule;

setupNativeEvents();

const RTP_PARAMS = {
    codecs: [],
    headerExtensions: [],
    rtcp: { cname: '', reducedSize: false },
    encodings: [],
    transactionId: 't1',
    degradationPreference: null
} as any;

/** A peer connection plus an audio sender carrying a real microphone track, as after addTrack. */
function callLeg(configuration: any = {}) {
    const pc = new RTCPeerConnection(configuration);
    const mic = fakeTrack(`mic-${pc._pcId}`, 'audio', false);
    const sender = new RTCRtpSender({
        peerConnectionId: pc._pcId, id: `s${pc._pcId}`, track: mic, rtpParameters: RTP_PARAMS
    });

    return { pc, mic, sender };
}

/** The SDK's conference graph for one leg: local source → gain → masterGain → destination. */
function conferenceMix(ctx: AudioContext, localStream = streamOf(fakeTrack('local', 'audio', false))) {
    const master = ctx.createGain();
    const destination = ctx.createMediaStreamDestination();

    master.connect(destination);
    ctx.createMediaStreamSource(localStream).connect(ctx.createGain()).connect(master);

    return destination.stream.getAudioTracks()[0] as MixedAudioTrack;
}

beforeEach(() => {
    jest.clearAllMocks();
});

describe('conference binding via replaceTrack', () => {
    test('the host leg attaches under pc-<id> and no native track is swapped', async () => {
        const { pc, mic, sender } = callLeg();
        const ctx = new AudioContext();
        const mix = conferenceMix(ctx);

        await sender.replaceTrack(mix);

        expect(native.conferenceAttachLeg).toHaveBeenCalledWith(pc._pcId, `pc-${pc._pcId}`, true);
        expect(native.senderReplaceTrack).not.toHaveBeenCalled();
        expect(sender.track).toBe(mix);
        expect(boundLegId(mix)).toBe(`pc-${pc._pcId}`);
        expect(ctx._liveSinks).toBe(1);

        await ctx.close();
        expect(sender.track).toBe(mic);
    });

    test('a child leg attaches under the siperbConferenceLegId its connection was born with', async () => {
        const { pc, sender } = callLeg({ siperbConferenceLegId: 'S2' });
        const ctx = new AudioContext();

        expect(pc._conferenceLegId).toBe('S2');
        expect(native.peerConnectionInit).toHaveBeenCalledWith(expect.anything(), pc._pcId, 'S2');

        await sender.replaceTrack(conferenceMix(ctx));

        expect(native.conferenceAttachLeg).toHaveBeenCalledWith(pc._pcId, 'S2', false);
        await ctx.close();
    });

    test('republishing the same mix is idempotent — one native attach', async () => {
        const { sender } = callLeg();
        const ctx = new AudioContext();
        const mix = conferenceMix(ctx);

        await Promise.all([ sender.replaceTrack(mix), sender.replaceTrack(mix) ]);
        await sender.replaceTrack(mix);

        expect(native.conferenceAttachLeg).toHaveBeenCalledTimes(1);
        await ctx.close();
    });

    test('close() detaches synchronously and gives the sender its real track back', async () => {
        const { pc, mic, sender } = callLeg();
        const ctx = new AudioContext();
        const mix = conferenceMix(ctx);

        await sender.replaceTrack(mix);

        const closing = ctx.close();

        // Before any await: the SDK fires and forgets close() and then reads sender.track.
        expect(native.conferenceDetachLeg).toHaveBeenCalledWith(`pc-${pc._pcId}`);
        expect(sender.track).toBe(mic);
        expect(boundLegId(mix)).toBeNull();
        expect(ctx._liveSinks).toBe(0);
        await closing;
        await ctx.close();
        expect(native.conferenceDetachLeg).toHaveBeenCalledTimes(1);
    });

    test('replaceTrack(realTrack) after a mix detaches, then swaps natively', async () => {
        const { pc, mic, sender } = callLeg();
        const ctx = new AudioContext();

        await sender.replaceTrack(conferenceMix(ctx));
        await sender.replaceTrack(mic);

        expect(native.conferenceDetachLeg).toHaveBeenCalledWith(`pc-${pc._pcId}`);
        expect(native.senderReplaceTrack).toHaveBeenCalledWith(pc._pcId, `s${pc._pcId}`, mic.id);
        expect(sender.track).toBe(mic);
    });

    test('a native attach failure rejects replaceTrack and binds nothing', async () => {
        native.conferenceAttachLeg.mockImplementationOnce(() =>
            Promise.reject(Object.assign(new Error('No peer connection 9'), { code: 'no_peerconnection' })));

        const { mic, sender } = callLeg();
        const ctx = new AudioContext();
        const mix = conferenceMix(ctx);

        await expect(sender.replaceTrack(mix)).rejects.toThrow('No peer connection 9');
        expect(sender.track).toBe(mic);
        expect(boundLegId(mix)).toBeNull();
        expect(ctx._liveSinks).toBe(0);
    });

    test('the peer connection closing takes its leg off the bus', async () => {
        const { pc, mic, sender } = callLeg();
        const ctx = new AudioContext();
        const mix = conferenceMix(ctx);

        await sender.replaceTrack(mix);
        emitNative('peerConnectionSignalingStateChanged', { pcId: pc._pcId, signalingState: 'closed' });
        await flush();

        expect(native.conferenceDetachLeg).toHaveBeenCalledWith(`pc-${pc._pcId}`);
        expect(native.peerConnectionDispose).toHaveBeenCalledWith(pc._pcId);
        expect(sender.track).toBe(mic);
    });

    test('stopping the mixed track detaches it', async () => {
        const { pc, sender } = callLeg();
        const ctx = new AudioContext();
        const mix = conferenceMix(ctx);

        await sender.replaceTrack(mix);
        mix.stop();

        expect(mix.readyState).toBe('ended');
        expect(native.conferenceDetachLeg).toHaveBeenCalledWith(`pc-${pc._pcId}`);
        await ctx.close();
    });

    test('a mix needs a sender that already carries a real audio track', async () => {
        const pc = new RTCPeerConnection({});
        const empty = new RTCRtpSender({ peerConnectionId: pc._pcId, id: 'e', rtpParameters: RTP_PARAMS });
        const video = new RTCRtpSender({
            peerConnectionId: pc._pcId, id: 'v', track: fakeTrack('cam', 'video', false), rtpParameters: RTP_PARAMS
        });
        const ctx = new AudioContext();
        const mix = conferenceMix(ctx);

        await expect(empty.replaceTrack(mix)).rejects.toMatchObject({ name: 'InvalidStateError' });
        await expect(video.replaceTrack(mix)).rejects.toThrow(TypeError);
        expect(native.conferenceAttachLeg).not.toHaveBeenCalled();
    });

    test('a mix bound to one sender refuses another; a closed connection is refused', async () => {
        const a = callLeg();
        const b = callLeg();
        const ctx = new AudioContext();
        const mix = conferenceMix(ctx);

        await a.sender.replaceTrack(mix);
        await expect(b.sender.replaceTrack(mix)).rejects.toMatchObject({ name: 'InvalidStateError' });

        const orphan = new RTCRtpSender({
            peerConnectionId: 9999, id: 'o', track: fakeTrack('m9', 'audio', false), rtpParameters: RTP_PARAMS
        });

        await expect(orphan.replaceTrack(conferenceMix(new AudioContext())))
            .rejects.toMatchObject({ name: 'InvalidStateError' });
        await ctx.close();
    });

    test('addTrack refuses a mixed track', () => {
        const pc = new RTCPeerConnection({});
        const mix = conferenceMix(new AudioContext());

        expect(() => pc.addTrack(mix)).toThrow(expect.objectContaining({ name: 'NotSupportedError' }));
    });
});

describe('the microphone while the host leg is on the bus', () => {
    test('mic.enabled=false goes to the bus mute, never to the native track', async () => {
        const { mic, sender } = callLeg();
        const ctx = new AudioContext();

        await sender.replaceTrack(conferenceMix(ctx));
        native.mediaStreamTrackSetEnabled.mockClear();
        native.conferenceSetMicMuted.mockClear();

        mic.enabled = false;
        expect(native.conferenceSetMicMuted).toHaveBeenCalledWith(true);
        expect(native.mediaStreamTrackSetEnabled).not.toHaveBeenCalled();

        mic.enabled = true;
        expect(native.conferenceSetMicMuted).toHaveBeenCalledWith(false);
        expect(native.mediaStreamTrackSetEnabled).not.toHaveBeenCalled();
        expect(mic.enabled).toBe(true);

        await ctx.close();
    });

    test('a mic already disabled at bind is re-enabled natively and muted on the bus instead', async () => {
        const { mic, sender } = callLeg();
        const ctx = new AudioContext();

        mic.enabled = false;
        native.mediaStreamTrackSetEnabled.mockClear();

        await sender.replaceTrack(conferenceMix(ctx));

        expect(native.mediaStreamTrackSetEnabled).toHaveBeenCalledWith(-1, mic.id, true);
        expect(native.conferenceSetMicMuted).toHaveBeenCalledWith(true);
        expect(mic.enabled).toBe(false);          // the flag is still the truth for the SDK

        await ctx.close();
    });

    test('unbinding hands the mic back to native with the flag it carries', async () => {
        const { mic, sender } = callLeg();
        const ctx = new AudioContext();

        await sender.replaceTrack(conferenceMix(ctx));
        mic.enabled = false;                       // routed to the bus while bound
        native.mediaStreamTrackSetEnabled.mockClear();

        await ctx.close();

        expect(native.mediaStreamTrackSetEnabled).toHaveBeenCalledWith(-1, mic.id, false);

        // And after the unbind a toggle is native again.
        native.mediaStreamTrackSetEnabled.mockClear();
        mic.enabled = true;
        expect(native.mediaStreamTrackSetEnabled).toHaveBeenCalledWith(-1, mic.id, true);
    });

    test(
        'a bind always sets the bus mute from the mic\'s real state (a leftover cannot silence a new conference)',
        async () => {
            const { sender } = callLeg();
            const ctx = new AudioContext();

            await sender.replaceTrack(conferenceMix(ctx));

            expect(native.conferenceSetMicMuted).toHaveBeenCalledWith(false);
            await ctx.close();
        });

    test('a child leg\'s own track is untouched: its enabled still goes native', async () => {
        const { mic, sender } = callLeg({ siperbConferenceLegId: 'S9' });
        const ctx = new AudioContext();

        await sender.replaceTrack(conferenceMix(ctx));
        native.mediaStreamTrackSetEnabled.mockClear();

        mic.enabled = false;
        expect(native.mediaStreamTrackSetEnabled).toHaveBeenCalledWith(-1, mic.id, false);
        await ctx.close();
    });
});
