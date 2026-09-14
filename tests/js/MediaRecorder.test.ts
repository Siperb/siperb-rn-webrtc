
import AudioContext from '../../src/AudioContext';
import { setupNativeEvents } from '../../src/EventEmitter';
import MediaRecorder from '../../src/MediaRecorder';
import RecordingBlob from '../../src/RecordingBlob';
import type { NativeRecordingHandle, RecordingRequest } from '../../src/RecordingRequest';

import { fakeTrack, flush, streamOf } from './helpers';
import { emitNative, NativeModules } from './mocks/react-native';

const native = NativeModules.WebRTCModule;

// index.ts does this at import time in the app; here the recorder is loaded on its own.
setupNativeEvents();

function sdkMixStream() {
    const ctx = new AudioContext();
    const destination = ctx.createMediaStreamDestination();
    const merger = ctx.createChannelMerger(2);

    merger.connect(destination);
    ctx.createMediaStreamSource(streamOf(fakeTrack('mic', 'audio', false))).connect(merger, 0, 0);
    ctx.createMediaStreamSource(streamOf(fakeTrack('rx', 'audio', true, 4))).connect(merger, 0, 1);

    return { ctx, stream: streamOf(destination.stream.getAudioTracks()[0]) };
}

function record(recorder: MediaRecorder) {
    const events: string[] = [];
    let blob: RecordingBlob | null = null;
    let error: Error | null = null;

    recorder.onstart = () => events.push('start');

    recorder.ondataavailable = e => {
        events.push('dataavailable');
        blob = e.data;
    };

    recorder.onerror = e => {
        events.push('error');
        error = e.error;
    };

    recorder.onstop = () => events.push('stop');

    return { events, get blob() {
        return blob;
    }, get error() {
        return error;
    } };
}

beforeEach(() => {
    jest.clearAllMocks();
});

describe('MediaRecorder', () => {
    test('isTypeSupported', () => {
        expect(MediaRecorder.isTypeSupported('')).toBe(true);
        expect(MediaRecorder.isTypeSupported('audio/mp4')).toBe(true);
        expect(MediaRecorder.isTypeSupported('audio/mp4;codecs=mp4a.40.2')).toBe(true);
        expect(MediaRecorder.isTypeSupported('video/mp4')).toBe(true);
        expect(MediaRecorder.isTypeSupported('audio/webm')).toBe(false);
        expect(() => new MediaRecorder(sdkMixStream().stream, { mimeType: 'audio/webm' }))
            .toThrow(expect.objectContaining({ name: 'NotSupportedError' }));
        expect(() => new MediaRecorder({} as any)).toThrow(TypeError);
    });

    test('records the SDK mix natively, without paths, and delivers a file reference', async () => {
        const recorder = new MediaRecorder(sdkMixStream().stream);
        const seen = record(recorder);

        recorder.start();
        expect(recorder.state).toBe('recording');
        expect(recorder.mimeType).toBe('audio/mp4');
        expect(native.startCallRecording).toHaveBeenCalledTimes(1);

        const options = native.startCallRecording.mock.calls[0][0];

        expect(options).toMatchObject({
            includeMic: true, stereo: true, remoteTrackIds: [ 'rx' ], peerConnectionIds: [ 4 ]
        });
        expect(options.recordingId).toMatch(/^rec-/);
        expect(options).not.toHaveProperty('wavPath');
        expect(options).not.toHaveProperty('outputPath');
        expect(options).not.toHaveProperty('video');

        await flush();
        expect(seen.events).toEqual([ 'start' ]);

        recorder.stop();
        expect(recorder.state).toBe('inactive');
        await flush();

        expect(native.stopCallRecording).toHaveBeenCalledWith(options.recordingId);
        expect(seen.events).toEqual([ 'start', 'dataavailable', 'stop' ]);
        expect(seen.blob).toMatchObject({
            size: 4096, type: 'audio/mp4', path: '/tmp/rec-1.m4a', uri: 'file:///tmp/rec-1.m4a'
        });
    });

    test('stop() during an in-flight start still stops natively exactly once', async () => {
        let resolveStart: () => void = () => undefined;

        native.startCallRecording.mockImplementationOnce(() => new Promise<void>(resolve => {
            resolveStart = resolve;
        }));

        const recorder = new MediaRecorder(sdkMixStream().stream);
        const seen = record(recorder);

        recorder.start();
        recorder.stop();
        expect(recorder.state).toBe('inactive');
        await flush();
        expect(native.stopCallRecording).not.toHaveBeenCalled();

        resolveStart();
        await flush();
        expect(native.stopCallRecording).toHaveBeenCalledTimes(1);
        expect(seen.events).toEqual([ 'dataavailable', 'stop' ]);
    });

    test('a native start failure is error then stop, with the DOMException name mapped', async () => {
        native.startCallRecording.mockImplementationOnce(() =>
            Promise.reject(Object.assign(new Error('No recordable audio sources'), { code: 'no_sources' })));

        const recorder = new MediaRecorder(sdkMixStream().stream);
        const seen = record(recorder);

        recorder.start();
        await flush();

        expect(recorder.state).toBe('inactive');
        expect(seen.events).toEqual([ 'error', 'stop' ]);
        expect(seen.error).toMatchObject({ name: 'NotFoundError', message: 'No recordable audio sources' });
        expect(native.stopCallRecording).not.toHaveBeenCalled();
    });

    test('a native stop failure is error, an empty dataavailable, then stop', async () => {
        native.stopCallRecording.mockImplementationOnce(() =>
            Promise.reject(Object.assign(new Error('finalize failed'), { code: 'encode_error' })));

        const recorder = new MediaRecorder(sdkMixStream().stream);
        const seen = record(recorder);

        recorder.start();
        await flush();
        recorder.stop();
        await flush();

        expect(seen.events).toEqual([ 'start', 'error', 'dataavailable', 'stop' ]);
        expect(seen.error).toMatchObject({ name: 'EncodingError' });
        expect(seen.blob).toMatchObject({ size: 0, path: '', uri: '' });
    });

    test('a mid-recording native error finalizes the segment', async () => {
        const recorder = new MediaRecorder(sdkMixStream().stream);
        const seen = record(recorder);

        recorder.start();
        await flush();

        const recordingId = native.startCallRecording.mock.calls[0][0].recordingId;

        emitNative('audioRecordingError', { recordingId: 'someone-else', error: 'ignored' });
        emitNative('audioRecordingError', { recordingId, error: 'wav_write_failed' });
        expect(recorder.state).toBe('inactive');
        await flush();

        expect(native.stopCallRecording).toHaveBeenCalledWith(recordingId);
        expect(seen.events).toEqual([ 'start', 'error', 'dataavailable', 'stop' ]);
        expect(seen.error).toMatchObject({ name: 'UnknownError', message: 'wav_write_failed' });
    });

    test('a host subclass owns the native calls through the two protected seams', async () => {
        const calls: string[] = [];

        class HostRecorder extends MediaRecorder {
            Data: { SessionId?: string } | null = null;

            protected startNative(request: RecordingRequest): Promise<NativeRecordingHandle> {
                calls.push(`start ${this.Data?.SessionId} mic=${request.includeMic} stereo=${request.stereo}`);

                return Promise.resolve({ recordingId: `${this.Data?.SessionId}_1` });
            }

            protected stopNative(
                handle: NativeRecordingHandle,
                reason: 'user' | 'error'
            ): Promise<RecordingBlob | null> {
                calls.push(`stop ${handle.recordingId} ${reason}`);

                return Promise.resolve(new RecordingBlob({
                    size: 10, type: 'audio/mp4', path: '/docs/rec.m4a', recordingId: handle.recordingId,
                    durationMs: 5, withVideo: false
                }));
            }
        }

        const recorder = new HostRecorder(sdkMixStream().stream);

        // The SDK stamps this after construction, before start().
        recorder.Data = { SessionId: 'S9' };

        const seen = record(recorder);

        recorder.start();
        await flush();
        recorder.stop();
        await flush();

        expect(calls).toEqual([ 'start S9 mic=true stereo=true', 'stop S9_1 user' ]);
        expect(native.startCallRecording).not.toHaveBeenCalled();
        expect(seen.events).toEqual([ 'start', 'dataavailable', 'stop' ]);
        expect(seen.blob).toMatchObject({ recordingId: 'S9_1', path: '/docs/rec.m4a' });
    });

    test('video tracks in the stream engage the compositor with default geometry', () => {
        const stream = streamOf(
            fakeTrack('mic', 'audio', false), fakeTrack('cam', 'video', false), fakeTrack('rv', 'video', true, 2)
        );
        const recorder = new MediaRecorder(stream, { video: { layout: 'side-by-side' } });

        recorder.start();

        expect(recorder.mimeType).toBe('video/mp4');
        expect(native.startCallRecording.mock.calls[0][0]).toMatchObject({
            includeMic: true,
            stereo: false,
            video: {
                localTrackId: 'cam', remoteTrackIds: [ 'rv' ], peerConnectionIds: [ 2 ],
                width: 1280, height: 720, fps: 12, layout: 'side-by-side', pnpSize: 144
            }
        });
    });

    test('state machine guards', () => {
        const recorder = new MediaRecorder(sdkMixStream().stream);

        expect(() => recorder.pause()).toThrow(expect.objectContaining({ name: 'InvalidStateError' }));
        expect(() => recorder.start(1000)).toThrow(expect.objectContaining({ name: 'NotSupportedError' }));
        recorder.start();
        expect(() => recorder.start()).toThrow(expect.objectContaining({ name: 'InvalidStateError' }));
        expect(() => recorder.pause()).toThrow(expect.objectContaining({ name: 'NotSupportedError' }));
        expect(() => recorder.requestData()).toThrow(expect.objectContaining({ name: 'NotSupportedError' }));

        const ended = fakeTrack('dead', 'audio', false);

        ended.stop();
        expect(() => new MediaRecorder(streamOf(ended)).start())
            .toThrow(expect.objectContaining({ name: 'InvalidStateError' }));
    });
});
