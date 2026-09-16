import CallRecorder, { CallRecordingLayout, CallVideoRecordingOptions } from './CallRecorder';
import type MediaStream from './MediaStream';
import { compileMixRecipe, MixSource } from './MixRecipe';
import MixedAudioTrack from './MixedAudioTrack';
import { makeDOMException } from './RTCUtil';

/**
 * Non-standard extension of MediaRecorderOptions: the compositor geometry for a recording that
 * carries video. The web gets these from the canvas it composites on; native needs to be told.
 */
export interface MediaRecorderVideoOptions {
    width?: number;
    height?: number;
    fps?: number;
    layout?: CallRecordingLayout;
    pnpSize?: number;
}

export interface MediaRecorderOptions {
    mimeType?: string;
    video?: MediaRecorderVideoOptions;
}

/** Geometry when the caller gives none — the web compositor's HD preset. */
export const RECORDING_VIDEO_DEFAULTS = {
    width: 1280,
    height: 720,
    fps: 12,
    layout: 'them-pnp' as CallRecordingLayout,
    pnpSize: 144
};

/** What the native recorder is asked to record, compiled from a MediaStream and its graph. */
export interface RecordingRequest {
    includeMic: boolean;
    stereo: boolean;
    remoteTrackIds: string[];
    peerConnectionIds: number[];
    video?: CallVideoRecordingOptions;
    mimeType: 'audio/mp4' | 'video/mp4';
    /** Things the graph asked for that native cannot honour; logged once by the recorder. */
    warnings: string[];
}

/** What `startNative` hands back so `stopNative` can find the recording again. */
export interface NativeRecordingHandle {
    recordingId: string;
}

/**
 * Turns the stream given to a MediaRecorder into a native recording request.
 *
 * A real audio track is a source in its own right; a virtual one (a MediaStreamAudioDestinationNode's
 * output) stands for everything wired to it, read off the graph. Local sources mean the
 * microphone, remote ones name the tracks to tap. A merger with sources on two inputs means the
 * SDK asked for channel-split output, which native records as stereo (mic left, remotes right).
 */
export function compileRecordingRequest(stream: MediaStream, options: MediaRecorderOptions): RecordingRequest {
    const warnings: string[] = [];
    let sources: MixSource[] = [];
    let usesMerger = false;
    let hasAux = false;

    for (const track of stream.getAudioTracks()) {
        if (typeof (track as any)._auxId === 'string') {
            // A presented file's soundtrack. The native recorder sums every aux on the bus
            // onto the near side by itself, so it is not a source to name here — and it is
            // not a second "local" either, which the warning below would otherwise call it.
            hasAux = true;
            continue;
        }

        if (track instanceof MixedAudioTrack) {
            const recipe = compileMixRecipe(track._destination);

            sources = sources.concat(recipe.sources);
            usesMerger = usesMerger || recipe.usesMerger;
        } else {
            sources.push({ track, channel: null, gain: 1 });
        }
    }

    for (const source of sources) {
        if (source.gain !== 0 && source.gain !== 1) {
            warnings.push(
                `gain ${source.gain} on ${source.track.id} is not applied: the native mixer has no per-source gain`);
        }
    }

    const kept = sources.filter(source => source.gain !== 0 && source.track.readyState === 'live');
    const locals = unique(kept.filter(source => !source.track.remote).map(source => source.track));
    const remotes = unique(kept.filter(source => source.track.remote).map(source => source.track));

    if (locals.length > 1) {
        warnings.push('more than one local audio track feeds the mix; native captures the microphone once');
    }

    for (const source of kept) {
        if (source.channel !== null && source.channel !== (source.track.remote ? 1 : 0)) {
            warnings.push(`${source.track.id} is routed to merger input ${source.channel}; `
                + 'native fixes local on input 0 and remote on input 1');
        }
    }

    const channels = new Set(kept.map(source => source.channel).filter(channel => channel !== null));
    const video = compileVideo(stream, options, warnings);

    if (locals.length === 0 && remotes.length === 0 && !video && !hasAux) {
        throw makeDOMException('InvalidStateError', 'MediaRecorder: the stream has no live track to record');
    }

    return {
        includeMic: locals.length > 0,
        stereo: usesMerger && channels.size >= 2,
        remoteTrackIds: remotes.map(track => track.id),
        peerConnectionIds: unique(remotes.map(track => track._peerConnectionId).filter(id => id >= 0)),
        video,
        mimeType: video ? 'video/mp4' : 'audio/mp4',
        warnings
    };
}

function compileVideo(
    stream: MediaStream,
    options: MediaRecorderOptions,
    warnings: string[]
): CallVideoRecordingOptions | undefined {
    const videoTracks = stream.getVideoTracks().filter(track => track.readyState === 'live');

    if (videoTracks.length === 0) {
        return undefined;
    }

    if (!CallRecorder.supportsVideo) {
        warnings.push('the stream carries video but this build cannot record it; recording audio only');

        return undefined;
    }

    const local = videoTracks.find(track => !track.remote);
    const remotes = videoTracks.filter(track => track.remote);
    const geometry = { ...RECORDING_VIDEO_DEFAULTS, ...(options.video ?? {}) };

    return {
        localTrackId: local?.id,
        remoteTrackIds: remotes.map(track => track.id),
        peerConnectionIds: unique(remotes.map(track => track._peerConnectionId).filter(id => id >= 0)),
        width: geometry.width,
        height: geometry.height,
        fps: geometry.fps,
        layout: geometry.layout,
        pnpSize: geometry.pnpSize
    };
}

function unique<T>(items: T[]): T[] {
    return items.filter((item, index) => items.indexOf(item) === index);
}
