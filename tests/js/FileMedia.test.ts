import AudioContext from '../../src/AudioContext';
import { auxHolderCount, isAuxAttached } from '../../src/AuxBinding';
import { setupNativeEvents } from '../../src/EventEmitter';
import FileAudioTrack from '../../src/FileAudioTrack';
import FileVideoTrack from '../../src/FileVideoTrack';
import mediaDevices from '../../src/MediaDevices';
import RTCPeerConnection from '../../src/RTCPeerConnection';
import RTCRtpSender from '../../src/RTCRtpSender';
import { compileRecordingRequest } from '../../src/RecordingRequest';
import { FileMediaStream, getFileMedia } from '../../src/getFileMedia';

import { fakeTrack, flush, streamOf } from './helpers';
import { emitNative, NativeModules } from './mocks/react-native';

const native = NativeModules.WebRTCModule;

setupNativeEvents();

const RTP_PARAMS = {
    codecs: [], headerExtensions: [], rtcp: { cname: '', reducedSize: false }, encodings: [],
    transactionId: 't1', degradationPreference: null
} as any;

/** A peer connection plus an audio sender carrying a real microphone track, as after addTrack. */
function callLeg() {
    const pc = new RTCPeerConnection({});
    const mic = fakeTrack(`mic-${pc._pcId}`, 'audio', false);
    const sender = new RTCRtpSender({
        peerConnectionId: pc._pcId, id: `s${pc._pcId}`, track: mic, rtpParameters: RTP_PARAMS
    });

    return { pc, mic, sender };
}

/**
 * The SDK's conference graph for one leg — the shape PhoneCore/ConferenceManager.js builds:
 * local source → gain → masterGain → destination. Returns the pieces the SDK later reaches for.
 */
function conferenceGraph(ctx: AudioContext) {
    const master = ctx.createGain();
    const destination = ctx.createMediaStreamDestination();

    master.connect(destination);
    ctx.createMediaStreamSource(streamOf(fakeTrack('local', 'audio', false))).connect(ctx.createGain()).connect(master);

    return { master, mix: destination.stream.getAudioTracks()[0] as any };
}

/** AddStreamToAudioContext(session, stream, "presentation"): source → gain → masterGain. */
function addPresentation(ctx: AudioContext, master: any, stream: FileMediaStream) {
    const source = ctx.createMediaStreamSource(stream);
    const gain = ctx.createGain();

    source.connect(gain);
    gain.connect(master);

    return { source, gain };
}

let counter = 0;

/** A fresh file stream per test; native ids are unique so the reconciler's per-id state is fresh. */
async function fileStream(): Promise<FileMediaStream> {
    counter += 1;
    const id = `file-video-${counter}`;

    native.getFileMedia.mockImplementationOnce(() => Promise.resolve({
        streamId: `file-stream-${counter}`,
        track: {
            id, kind: 'video', remote: false, constraints: {}, enabled: true,
            settings: { width: 640, height: 360, frameRate: 25 }, peerConnectionId: -1, readyState: 'live'
        },
        audio: { auxId: id, sampleRate: 48000, channels: 1 },
        duration: 12.5, width: 640, height: 360, playing: false
    }));

    return getFileMedia({ uri: 'file:///tmp/clip.mp4' });
}

beforeEach(() => {
    jest.clearAllMocks();
});

describe('getFileMedia — the stream shape', () => {
    test('one real video track, one virtual audio track keyed by the video id, controls on playback', async () => {
        const stream = await fileStream();
        const [ video ] = stream.getVideoTracks();
        const [ audio ] = stream.getAudioTracks();

        expect(native.getFileMedia).toHaveBeenCalledWith(
            { uri: 'file:///tmp/clip.mp4', fps: 25, maxSide: 360, autoplay: false });
        expect(video).toBeInstanceOf(FileVideoTrack);
        expect(audio).toBeInstanceOf(FileAudioTrack);
        expect((audio as FileAudioTrack)._auxId).toBe(video.id);
        expect(audio._isVirtual).toBe(true);
        // The virtual track never crosses the bridge; the video one was native-born.
        expect(native.mediaStreamAddTrack).not.toHaveBeenCalled();
        expect(stream.playback.duration).toBe(12.5);
        expect(stream.playback.paused).toBe(true);
    });

    test('a file with no audio track yields a video-only stream', async () => {
        native.getFileMedia.mockImplementationOnce(() => Promise.resolve({
            streamId: 'silent', track: {
                id: 'silent-v', kind: 'video', remote: false, constraints: {}, enabled: true,
                settings: {}, peerConnectionId: -1, readyState: 'live'
            }, audio: null, duration: 3
        }));

        const stream = await getFileMedia({ uri: 'file:///tmp/silent.mp4' });

        expect(stream.getAudioTracks()).toHaveLength(0);
        expect(stream.getVideoTracks()).toHaveLength(1);
    });

    test('a missing uri rejects before the bridge', async () => {
        await expect(getFileMedia({ uri: '' } as any)).rejects.toBeInstanceOf(TypeError);
        expect(native.getFileMedia).not.toHaveBeenCalled();
    });

    test('supportsFileSource needs the constant AND the three methods', () => {
        expect(mediaDevices.supportsFileSource).toBe(true);

        const saved = native.conferenceAttachAux;

        native.conferenceAttachAux = undefined;
        expect(mediaDevices.supportsFileSource).toBe(false);
        native.conferenceAttachAux = saved;

        native.supportsFileSource = false;
        expect(mediaDevices.supportsFileSource).toBe(false);
        native.supportsFileSource = true;
    });
});

describe('the aux binding — the SDK\'s present sequence', () => {
    test('AddStreamToAudioContext then republishMix: aux attaches BEFORE the leg, once each', async () => {
        const { sender } = callLeg();
        const ctx = new AudioContext();
        const { master, mix } = conferenceGraph(ctx);
        const stream = await fileStream();
        const auxId = stream.getVideoTracks()[0].id;

        // The SDK's order: the presentation source is connected first (mixPresentationAudio →
        // AddStreamToAudioContext), the host leg attaches on the republish that follows.
        addPresentation(ctx, master, stream);
        expect(native.conferenceAttachAux).toHaveBeenCalledWith(auxId);   // same tick
        await sender.replaceTrack(mix);
        await flush();

        expect(native.conferenceAttachAux).toHaveBeenCalledTimes(1);
        expect(native.conferenceAttachLeg).toHaveBeenCalledTimes(1);
        expect(native.conferenceAttachAux.mock.invocationCallOrder[0])
            .toBeLessThan(native.conferenceAttachLeg.mock.invocationCallOrder[0]);
        expect(isAuxAttached(auxId)).toBe(true);

        // A second republish (every join re-runs it) adds nothing.
        await sender.replaceTrack(mix);
        expect(native.conferenceAttachAux).toHaveBeenCalledTimes(1);
        expect(native.conferenceAttachLeg).toHaveBeenCalledTimes(1);

        await ctx.close();
    });

    test('RemoveConferenceInput (source.disconnect + gain.disconnect) detaches the aux once', async () => {
        const ctx = new AudioContext();
        const { master } = conferenceGraph(ctx);
        const stream = await fileStream();
        const auxId = stream.getVideoTracks()[0].id;
        const { source, gain } = addPresentation(ctx, master, stream);

        await flush();
        source.disconnect();
        gain.disconnect();
        await flush();

        expect(native.conferenceDetachAux).toHaveBeenCalledWith(auxId);
        expect(native.conferenceDetachAux).toHaveBeenCalledTimes(1);
        expect(isAuxAttached(auxId)).toBe(false);
        expect(auxHolderCount(auxId)).toBe(0);
    });

    test(
        'two graphs hold the same file (conference + recording): one attach, and only the LAST release detaches',
        async () => {
            const ctx = new AudioContext();
            const { master } = conferenceGraph(ctx);
            const stream = await fileStream();
            const auxId = stream.getVideoTracks()[0].id;
            const first = addPresentation(ctx, master, stream);

            // The recorder's graph: MixAudioStreams creates its own source for the same stream.
            const recCtx = new AudioContext();
            const merger = recCtx.createChannelMerger(2);
            const recSource = recCtx.createMediaStreamSource(stream);

            recSource.connect(merger, 0, 0);
            await flush();

            expect(native.conferenceAttachAux).toHaveBeenCalledTimes(1);
            expect(auxHolderCount(auxId)).toBe(2);

            first.source.disconnect();
            await flush();
            expect(native.conferenceDetachAux).not.toHaveBeenCalled();
            expect(auxHolderCount(auxId)).toBe(1);

            recSource.disconnect();
            await flush();
            expect(native.conferenceDetachAux).toHaveBeenCalledTimes(1);
            expect(isAuxAttached(auxId)).toBe(false);
        });

    test(
        'AudioContext.close() releases the holds this context has (CollapseConferenceMix closes without disconnecting)',
        async () => {
            const ctx = new AudioContext();
            const { master } = conferenceGraph(ctx);
            const stream = await fileStream();
            const auxId = stream.getVideoTracks()[0].id;

            addPresentation(ctx, master, stream);
            await flush();
            expect(isAuxAttached(auxId)).toBe(true);

            const closing = ctx.close();

            // Same tick, like the leg detach: the SDK fires and forgets close().
            expect(native.conferenceDetachAux).toHaveBeenCalledWith(auxId);
            await closing;
            expect(isAuxAttached(auxId)).toBe(false);
        });

    test('enabled=false detaches, enabled=true re-attaches, holders untouched', async () => {
        const ctx = new AudioContext();
        const { master } = conferenceGraph(ctx);
        const stream = await fileStream();
        const auxId = stream.getVideoTracks()[0].id;
        const audio = stream.getAudioTracks()[0];

        addPresentation(ctx, master, stream);
        await flush();

        audio.enabled = false;
        await flush();
        expect(native.conferenceDetachAux).toHaveBeenCalledTimes(1);
        expect(auxHolderCount(auxId)).toBe(1);

        audio.enabled = true;
        await flush();
        expect(native.conferenceAttachAux).toHaveBeenCalledTimes(2);
        expect(isAuxAttached(auxId)).toBe(true);

        await ctx.close();
    });

    test('stop() wins over holders: detached, and a later connect attaches nothing', async () => {
        const ctx = new AudioContext();
        const { master } = conferenceGraph(ctx);
        const stream = await fileStream();
        const auxId = stream.getVideoTracks()[0].id;
        const audio = stream.getAudioTracks()[0];

        addPresentation(ctx, master, stream);
        await flush();
        audio.stop();
        await flush();

        expect(audio.readyState).toBe('ended');
        expect(native.conferenceDetachAux).toHaveBeenCalledTimes(1);

        // A fresh graph holding a dead track: no attach.
        const other = new AudioContext();
        const { master: m2 } = conferenceGraph(other);

        addPresentation(other, m2, stream);
        await flush();
        expect(native.conferenceAttachAux).toHaveBeenCalledTimes(1);
        expect(isAuxAttached(auxId)).toBe(false);

        await ctx.close();
        await other.close();
    });

    test('an attach in flight followed by stop(): attach, then detach, in order, one each', async () => {
        let resolveAttach: (v: boolean) => void = () => undefined;

        native.conferenceAttachAux.mockImplementationOnce(() => new Promise(resolve => {
            resolveAttach = resolve;
        }));

        const ctx = new AudioContext();
        const { master } = conferenceGraph(ctx);
        const stream = await fileStream();
        const auxId = stream.getVideoTracks()[0].id;
        const audio = stream.getAudioTracks()[0];

        addPresentation(ctx, master, stream);
        expect(native.conferenceAttachAux).toHaveBeenCalledTimes(1);

        audio.stop();                                   // while the attach is still in flight
        await flush();
        expect(native.conferenceDetachAux).not.toHaveBeenCalled();   // serialised: waits for the attach

        resolveAttach(true);
        await flush();
        expect(native.conferenceDetachAux).toHaveBeenCalledTimes(1);
        expect(native.conferenceAttachAux.mock.invocationCallOrder[0])
            .toBeLessThan(native.conferenceDetachAux.mock.invocationCallOrder[0]);
        expect(isAuxAttached(auxId)).toBe(false);

        await ctx.close();
    });
});

describe('the file video track — stop disposes, enabled pauses', () => {
    test('stop() disables natively, releases natively ONCE, and ends the soundtrack', async () => {
        const stream = await fileStream();
        const video = stream.getVideoTracks()[0];
        const audio = stream.getAudioTracks()[0];

        video.stop();
        video.stop();
        video.release();
        await flush();

        expect(native.mediaStreamTrackSetEnabled).toHaveBeenCalledWith(-1, video.id, false);
        expect(native.mediaStreamTrackRelease).toHaveBeenCalledWith(video.id);
        expect(native.mediaStreamTrackRelease).toHaveBeenCalledTimes(1);
        expect(video.readyState).toBe('ended');
        expect(audio.readyState).toBe('ended');
        await expect(stream.playback.play()).rejects.toThrow(/released/);
    });

    test('enabled=false is a pause (setEnabled only, no release) and enabled=true resumes', async () => {
        const stream = await fileStream();
        const video = stream.getVideoTracks()[0];

        video.enabled = false;
        video.enabled = true;

        expect(native.mediaStreamTrackSetEnabled).toHaveBeenCalledWith(-1, video.id, false);
        expect(native.mediaStreamTrackSetEnabled).toHaveBeenCalledWith(-1, video.id, true);
        expect(native.mediaStreamTrackRelease).not.toHaveBeenCalled();
        expect(video.readyState).toBe('live');
    });

    test('a native mediaStreamTrackEnded (decode error) ends the soundtrack and the controls', async () => {
        const ctx = new AudioContext();
        const { master } = conferenceGraph(ctx);
        const stream = await fileStream();
        const video = stream.getVideoTracks()[0];
        const audio = stream.getAudioTracks()[0];

        addPresentation(ctx, master, stream);
        await flush();

        emitNative('mediaStreamTrackEnded', { trackId: video.id });
        await flush();

        expect(video.readyState).toBe('ended');
        expect(audio.readyState).toBe('ended');
        expect(native.conferenceDetachAux).toHaveBeenCalledWith(video.id);
        await expect(stream.playback.pause()).rejects.toThrow(/released/);
        await ctx.close();
    });
});

describe('FilePlayback — HTMLMediaElement vocabulary over fileMediaControl', () => {
    test('play / pause / seek / volume cross the bridge with the track id, and update the state', async () => {
        const stream = await fileStream();
        const id = stream.getVideoTracks()[0].id;
        const playback = stream.playback;

        await playback.play();
        expect(native.fileMediaControl).toHaveBeenCalledWith(id, { action: 'play' });
        expect(playback.paused).toBe(false);

        await playback.seek(4.5);
        expect(native.fileMediaControl).toHaveBeenCalledWith(id, { action: 'seek', position: 4.5 });
        expect(playback.currentTime).toBe(4.5);

        await playback.pause();
        expect(playback.paused).toBe(true);

        playback.volume = 0;
        expect(native.fileMediaControl).toHaveBeenCalledWith(id, { action: 'volume', value: 0 });
        playback.volume = 7;
        expect(playback.volume).toBe(1);
    });

    test('native events arrive as play / pause / timeupdate / ended, filtered by track id', async () => {
        const stream = await fileStream();
        const id = stream.getVideoTracks()[0].id;
        const seen: string[] = [];

        for (const name of [ 'play', 'pause', 'timeupdate', 'ended', 'error' ] as const) {
            stream.playback.addEventListener(name, () => seen.push(name));
        }

        emitNative('fileMediaEvent', { trackId: 'someone-else', type: 'playing', position: 1, duration: 9 });
        emitNative('fileMediaEvent', { trackId: id, type: 'playing', position: 0, duration: 12.5 });
        emitNative('fileMediaEvent', { trackId: id, type: 'progress', position: 3, duration: 12.5 });
        emitNative('fileMediaEvent', { trackId: id, type: 'paused', position: 3, duration: 12.5 });
        emitNative('fileMediaEvent',
            { trackId: id, type: 'ended', position: 12.5, duration: 12.5, playing: false, ended: true });

        expect(seen).toEqual([ 'play', 'timeupdate', 'pause', 'ended' ]);
        expect(stream.playback.currentTime).toBe(12.5);
        expect(stream.playback.ended).toBe(true);
        expect(stream.playback.paused).toBe(true);
    });
});

describe('the recording compiler', () => {
    test('a presented file\'s soundtrack is not a source to name: summed natively on the near side', async () => {
        const stream = await fileStream();
        const mic = fakeTrack('mic', 'audio', false);
        const request = compileRecordingRequest(streamOf(mic, stream.getAudioTracks()[0]), {});

        expect(request.includeMic).toBe(true);
        expect(request.warnings).toEqual([]);
        expect(request.remoteTrackIds).toEqual([]);
    });

    test('a file as the only source does not throw "no live track"', async () => {
        const stream = await fileStream();

        expect(() => compileRecordingRequest(streamOf(stream.getAudioTracks()[0]), {})).not.toThrow();
    });
});
