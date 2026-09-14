
import AudioContext from '../../src/AudioContext';
import MediaStreamAudioSourceNode from '../../src/MediaStreamAudioSourceNode';
import { compileMixRecipe } from '../../src/MixRecipe';
import { compileRecordingRequest } from '../../src/RecordingRequest';

import { fakeTrack, streamOf } from './helpers';
import { NativeModules } from './mocks/react-native';

const native = NativeModules.WebRTCModule;

beforeEach(() => {
    jest.clearAllMocks();
});

/** The SDK's MixAudioStreams graph, verbatim: merger(2) → destination; local → input 0, remote → input 1. */
function sdkRecordingGraph(ctx: AudioContext) {
    const mic = fakeTrack('mic', 'audio', false);
    const remote = fakeTrack('rx', 'audio', true, 7);
    const destination = ctx.createMediaStreamDestination();
    const merger = ctx.createChannelMerger(2);

    merger.connect(destination);
    ctx.createMediaStreamSource(streamOf(mic)).connect(merger, 0, 0);
    ctx.createMediaStreamSource(streamOf(remote)).connect(merger, 0, 1);

    return { mic, remote, destination, merger };
}

describe('AudioContext graph', () => {
    test('the SDK recording graph compiles to mic + remote, channel-split stereo', () => {
        const ctx = new AudioContext();
        const { destination } = sdkRecordingGraph(ctx);
        const request = compileRecordingRequest(destination.stream, {});

        expect(request).toMatchObject({
            includeMic: true,
            stereo: true,
            remoteTrackIds: [ 'rx' ],
            peerConnectionIds: [ 7 ],
            mimeType: 'audio/mp4',
            warnings: []
        });
        expect(request.video).toBeUndefined();
    });

    test('the destination stream holds one virtual audio track and never crosses the bridge', () => {
        const ctx = new AudioContext();
        const destination = ctx.createMediaStreamDestination();
        const tracks = destination.stream.getAudioTracks();

        expect(tracks).toHaveLength(1);
        expect(tracks[0]._isVirtual).toBe(true);
        expect(tracks[0].kind).toBe('audio');
        expect(tracks[0].remote).toBe(false);
        expect(native.mediaStreamCreate).toHaveBeenCalledTimes(1);
        expect(native.mediaStreamAddTrack).not.toHaveBeenCalled();

        tracks[0].enabled = false;
        tracks[0].stop();
        expect(native.mediaStreamTrackSetEnabled).not.toHaveBeenCalled();
        expect(tracks[0].readyState).toBe('ended');
    });

    test('a gain of 0 silences a source; other gains pass through with a warning', () => {
        const ctx = new AudioContext();
        const mic = fakeTrack('mic', 'audio', false);
        const remote = fakeTrack('rx', 'audio', true, 3);
        const destination = ctx.createMediaStreamDestination();
        const master = ctx.createGain();
        const quiet = ctx.createGain();
        const loud = ctx.createGain();

        master.connect(destination);
        quiet.gain.value = 0;
        loud.gain.value = 1.5;
        ctx.createMediaStreamSource(streamOf(mic)).connect(quiet).connect(master);
        ctx.createMediaStreamSource(streamOf(remote)).connect(loud).connect(master);

        const recipe = compileMixRecipe(destination);

        expect(recipe.sources.map(s => [ s.track.id, s.gain ])).toEqual([ [ 'rx', 1.5 ], [ 'mic', 0 ] ].sort());
        expect(recipe.usesMerger).toBe(false);

        const request = compileRecordingRequest(destination.stream, {});

        expect(request.includeMic).toBe(false);
        expect(request.remoteTrackIds).toEqual([ 'rx' ]);
        expect(request.stereo).toBe(false);
        expect(request.warnings.join(' ')).toMatch(/gain 1.5/);
    });

    test('disconnect() takes a source out of the mix', () => {
        const ctx = new AudioContext();
        const { destination, merger } = sdkRecordingGraph(ctx);
        const remoteSource = merger._incoming.find(c => c.input === 1)?.source as MediaStreamAudioSourceNode;

        remoteSource.disconnect();

        const request = compileRecordingRequest(destination.stream, {});

        expect(request.remoteTrackIds).toEqual([]);
        expect(request.includeMic).toBe(true);
        expect(request.stereo).toBe(false);
    });

    test('connect validates like the spec', () => {
        const a = new AudioContext();
        const b = new AudioContext();
        const gain = a.createGain();

        expect(() => gain.connect(b.createGain())).toThrow(expect.objectContaining({ name: 'InvalidAccessError' }));
        expect(() => gain.connect(a.createGain(), 1)).toThrow(expect.objectContaining({ name: 'IndexSizeError' }));
        expect(() => gain.connect(a.createChannelMerger(2), 0, 2))
            .toThrow(expect.objectContaining({ name: 'IndexSizeError' }));
        expect(() => gain.connect({} as any)).toThrow(TypeError);
        expect(() => gain.disconnect(a.createGain())).toThrow(expect.objectContaining({ name: 'InvalidAccessError' }));
        expect(() => a.createChannelMerger(0)).toThrow(expect.objectContaining({ name: 'IndexSizeError' }));
        expect(gain.connect(a.destination)).toBe(a.destination);
    });

    test('a source needs an audio track', () => {
        const ctx = new AudioContext();

        expect(() => ctx.createMediaStreamSource(streamOf(fakeTrack('cam', 'video', false))))
            .toThrow(expect.objectContaining({ name: 'InvalidStateError' }));
    });

    test('unsupported factory methods are absent, not stubs', () => {
        const ctx = new AudioContext() as any;

        expect(ctx.createMediaElementSource).toBeUndefined();
        expect(ctx.createOscillator).toBeUndefined();
        expect(ctx.createAnalyser).toBeUndefined();
        expect(ctx.decodeAudioData).toBeUndefined();
    });

    test('state transitions and close() are spec-shaped and idempotent', async () => {
        const ctx = new AudioContext();
        const changes: string[] = [];

        ctx.onstatechange = () => changes.push(ctx.state);
        expect(ctx.state).toBe('running');
        await ctx.suspend();
        await ctx.resume();
        await ctx.close();
        await ctx.close();

        expect(changes).toEqual([ 'suspended', 'running', 'closed' ]);
        expect(() => ctx.createGain()).toThrow(expect.objectContaining({ name: 'InvalidStateError' }));
        await expect(ctx.resume()).rejects.toMatchObject({ name: 'InvalidStateError' });
    });
});
