import { NativeModules } from 'react-native';

import { addListener, removeListener } from './EventEmitter';

const { WebRTCModule } = NativeModules;

/**
 * The layouts the native compositor implements.
 *
 * A CLOSED SET, deliberately. The web compositor also offers `talker-them` and
 * `talker-grid`, which follow whoever is speaking and therefore need voice-activity
 * detection that no layer here ships. Rather than accept them and quietly substitute
 * something else, they are absent: a caller maps them to `them-pnp` before calling, and
 * this type stops it forgetting. A native contract with a member it cannot honour is
 * how "it recorded, just not the way you asked" becomes untraceable.
 */
export type CallRecordingLayout = 'them-pnp' | 'side-by-side' | 'us-only' | 'them-only';

/**
 * Which tracks feed the compositor. Also the payload of `updateVideoSources`, so a mid-call
 * source change speaks the same vocabulary as the start options rather than a parallel one.
 */
export interface CallVideoSources {
    /**
     * Local camera or presentation track. Omitted means a remote-only composite — which is
     * a legitimate recording, not an error: the camera may simply be off.
     */
    localTrackId?: string;
    /** Remote video MediaStreamTrack ids to composite. */
    remoteTrackIds: string[];
    /** Peer connection ids owning the remote tracks (parallel lookup aid, as for audio). */
    peerConnectionIds: number[];
}

export interface CallVideoRecordingOptions extends CallVideoSources {
    /**
     * Output frame size in pixels.
     *
     * NUMBERS, NOT "HD". The SD/HD/FHD table lives in the caller, next to the settings it
     * reads, and a second copy down here is a second thing to keep in step. Native encodes
     * what it is told to encode.
     */
    width: number;
    height: number;
    /** Composite frame rate. The web compositor's default is 12. */
    fps: number;
    layout: CallRecordingLayout;
    /** Edge length of the picture-in-picture inset. `them-pnp` only; ignored otherwise. */
    pnpSize: number;
}

export interface CallRecordingOptions {
    /** Unique id for this recording segment; duplicate ids are rejected. */
    recordingId: string;
    /**
     * Absolute path the live PCM WAV is streamed to while recording. Written for EVERY
     * segment, audio or video, because it is the only crash-recoverable copy — an mp4's
     * moov atom is written at stop, so a killed process leaves the mp4 unplayable and this
     * is what `finalizeOrphan` salvages.
     *
     * OPTIONAL TOGETHER WITH `outputPath`: give both, or neither. With neither, native writes
     * `<recordingId>.wav` and `<recordingId>.m4a|.mp4` under {@link CallRecorder.recordingsDirectory}
     * and creates that directory. One without the other is rejected with `io_error`.
     */
    wavPath?: string;
    /**
     * Absolute path of the finalized container written on stop: AAC `.m4a` for an audio-only
     * segment, H.264 + AAC `.mp4` when `video` is present. The caller picks the extension to
     * match what it asked for; native writes to the path it is given and never rewrites it.
     * Optional together with `wavPath`, see there.
     *
     * WAS `m4aPath`. Renamed when the container stopped being fixed — native rejects an
     * options object carrying the old key and not this one, loudly, rather than accepting it
     * and writing mp4 bytes to a path called `.m4a`.
     */
    outputPath?: string;
    /** Mix the local microphone into the recording. */
    includeMic: boolean;
    /**
     * Write a channel-SPLIT stereo file — left the microphone, right every remote party
     * summed into one side — instead of summing everything to mono. Not true stereo: a SIP
     * call carries no stereo material. Omitted/false keeps the mono layout.
     */
    stereo?: boolean;
    /** Remote audio MediaStreamTrack ids to mix in. */
    remoteTrackIds: string[];
    /** Peer connection ids owning the remote tracks (parallel lookup aid). */
    peerConnectionIds: number[];
    /**
     * PRESENCE IS THE REQUEST. Supply this block to record video; omit it for an audio-only
     * segment, which behaves exactly as it did before video existed.
     *
     * There is deliberately no `withVideo: boolean` beside it — two fields that can disagree
     * about the same question is how a recording ends up claiming something the file does
     * not contain.
     *
     * Check {@link CallRecorder.supportsVideo} before setting this. Supplying it to a build
     * that cannot encode video is rejected with `video_unavailable`, not silently downgraded.
     */
    video?: CallVideoRecordingOptions;
}

export interface CallRecordingResult {
    recordingId: string;
    filePath: string;
    durationMs: number;
    size: number;
    /**
     * Whether the file actually carries a video track.
     *
     * READ THIS; NEVER INFER IT FROM THE REQUEST. A video segment degrades to audio when no
     * video track resolves (camera off, remote not yet sending) or when the writer fails
     * mid-recording — both keep the audio, and both report `false` here. The alternative is
     * a row that claims video over an audio file, which is a defect this contract exists to
     * make impossible.
     */
    withVideo: boolean;
    /** The container actually written — `"audio/mp4"` or `"video/mp4"`. */
    mimeType: string;
}

export type CallRecorderEvent = 'audioRecordingStarted' | 'audioRecordingStopped' | 'audioRecordingError';

/**
 * Native call recorder: taps the WebRTC microphone samples and remote audio
 * track sinks inside the native layer, mixes them to 48 kHz PCM (mono, or
 * channel-split stereo with `stereo: true`), streams a crash-safe WAV during
 * the recording and finalizes it on stop. Audio data never crosses the JS bridge.
 *
 * With a {@link CallRecordingOptions.video} block it also attaches a sink to each named
 * video track, composites them at a fixed frame rate, encodes H.264 and muxes the result
 * with the SAME mixed PCM the audio leg produces — one mixer, two consumers — into an mp4.
 *
 * WHAT DEGRADES RATHER THAN FAILS. A video-only problem never fails the segment, because
 * the audio is worth keeping: no resolvable video track, a source that disappears
 * mid-recording, or a writer the OS tears down (iOS suspends hardware video encode in the
 * background) all leave a playable audio recording and report `withVideo: false`. Only a
 * request for video on a build that cannot do it is an error, and only because the caller
 * had `supportsVideo` to check first.
 *
 * The EVENT NAMES still say "audio". They cover both kinds now; renaming three strings
 * across two native platforms and their JS would be churn for cosmetics. Their payloads
 * carry `withVideo`.
 */
export default class CallRecorder {
    /**
     * Whether this native build can record video.
     *
     * A native constant, so it is synchronous and cannot lie about the binary it came from.
     * `undefined` on a build that predates video recording, which reads as `false` — version
     * skew between an OTA JS bundle and an older app binary is handled by construction
     * rather than by a probe that has to remember to be written.
     */
    static readonly supportsVideo: boolean = WebRTCModule?.callRecordingSupportsVideo === true;

    /**
     * Where native writes a recording whose `start()` gave no paths — the app-private files
     * directory plus `siperb-rn-webrtc/recordings`. A native constant like `supportsVideo`, and
     * `null` on a binary that predates default paths (such a binary still requires both paths).
     */
    static readonly recordingsDirectory: string | null =
        typeof WebRTCModule?.recordingsDirectory === 'string' ? WebRTCModule.recordingsDirectory : null;

    /**
     * Start recording. Resolves once the native recorder is attached and the
     * WAV file is open; rejects on duplicate recordingId, no resolvable
     * sources, file IO errors, or `video` supplied to a build without it.
     *
     * Rejection codes: `duplicate_id` | `no_sources` | `encode_error` | `io_error` |
     * `video_unavailable`.
     */
    static start(options: CallRecordingOptions): Promise<void> {
        return WebRTCModule.startCallRecording(options);
    }

    /**
     * Stop recording. Resolves after the container has been fully finalized (the
     * WAV is deleted on success), so the returned filePath is ready for use.
     *
     * Finalizing an mp4 takes materially longer than an AAC-only file — the moov atom is
     * written at the end — so a caller that bounds this wait must leave room for it.
     */
    static stop(recordingId: string): Promise<CallRecordingResult> {
        return WebRTCModule.stopCallRecording(recordingId);
    }

    /**
     * Swap the video sources being composited, mid-segment.
     *
     * The case that needs it is a presentation starting after the recording did: the local
     * slot must follow the screen-share track rather than the camera. Without it that swap
     * is invisible in the file, because the sink set is fixed at start.
     *
     * A NO-OP, NOT AN ERROR, on an audio-only segment or an unknown id — the caller is
     * reporting a source change, not asserting that a compositor exists to hear it.
     */
    static updateVideoSources(recordingId: string, sources: CallVideoSources): Promise<void> {
        return WebRTCModule.updateCallRecordingVideoSources(recordingId, sources);
    }

    /** Ids of recordings currently active in the native layer. */
    static getActive(): Promise<string[]> {
        return WebRTCModule.getActiveCallRecordings();
    }

    /**
     * Finalize a WAV left behind by a crash/kill mid-recording into a playable
     * .m4a (the WAV header sizes are recovered from file length). The channel
     * count comes from the WAV's own header, so orphans written by an earlier
     * mono build still salvage correctly.
     *
     * AUDIO-ONLY BY CONSTRUCTION, and `m4aPath` is the right name here precisely because it
     * cannot vary: the WAV is the only thing a crash leaves recoverable, so a salvaged
     * video segment comes back as its audio. The stranded `.mp4` is the caller's to clean up.
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
