import { NativeModules } from 'react-native';

import { addListener, removeListener } from './EventEmitter';

const { WebRTCModule } = NativeModules;

export interface CallRecordingOptions {
    /** Unique id for this recording segment; duplicate ids are rejected. */
    recordingId: string;
    /** Absolute path the live PCM WAV is streamed to while recording. */
    wavPath: string;
    /** Absolute path of the finalized AAC .m4a written on stop. */
    m4aPath: string;
    /** Mix the local microphone into the recording. */
    includeMic: boolean;
    /** Remote audio MediaStreamTrack ids to mix in. */
    remoteTrackIds: string[];
    /** Peer connection ids owning the remote tracks (parallel lookup aid). */
    peerConnectionIds: number[];
}

export interface CallRecordingResult {
    recordingId: string;
    filePath: string;
    durationMs: number;
    size: number;
}

export type CallRecorderEvent = 'audioRecordingStarted' | 'audioRecordingStopped' | 'audioRecordingError';

/**
 * Native call recorder: taps the WebRTC microphone samples and remote audio
 * track sinks inside the native layer, mixes them to mono 48 kHz PCM, streams
 * a crash-safe WAV during the recording and finalizes it to AAC .m4a on stop.
 * Audio data never crosses the JS bridge.
 */
export default class CallRecorder {
    /**
     * Start recording. Resolves once the native recorder is attached and the
     * WAV file is open; rejects on duplicate recordingId, no resolvable
     * sources, or file IO errors.
     */
    static start(options: CallRecordingOptions): Promise<void> {
        return WebRTCModule.startCallRecording(options);
    }

    /**
     * Stop recording. Resolves after the .m4a has been fully finalized (the
     * WAV is deleted on success), so the returned filePath is ready for use.
     */
    static stop(recordingId: string): Promise<CallRecordingResult> {
        return WebRTCModule.stopCallRecording(recordingId);
    }

    /** Ids of recordings currently active in the native layer. */
    static getActive(): Promise<string[]> {
        return WebRTCModule.getActiveCallRecordings();
    }

    /**
     * Finalize a WAV left behind by a crash/kill mid-recording into a playable
     * .m4a (the WAV header sizes are recovered from file length).
     */
    static finalizeOrphan(wavPath: string, m4aPath: string): Promise<Omit<CallRecordingResult, 'recordingId'>> {
        return WebRTCModule.finalizeOrphanRecording(wavPath, m4aPath);
    }

    /**
     * Subscribe to recorder events. The same listener key must be passed to
     * removeEventListener to unsubscribe (fork EventEmitter convention).
     */
    static addEventListener(listener: unknown, event: CallRecorderEvent, handler: (ev: any) => void): void {
        addListener(listener, event, handler);
    }

    /** Remove every subscription registered under the given listener key. */
    static removeEventListener(listener: unknown): void {
        removeListener(listener);
    }
}
