import type AudioNode from './AudioNode';
import ChannelMergerNode from './ChannelMergerNode';
import GainNode from './GainNode';
import MediaStreamAudioDestinationNode from './MediaStreamAudioDestinationNode';
import MediaStreamAudioSourceNode from './MediaStreamAudioSourceNode';
import type MediaStreamTrack from './MediaStreamTrack';

/** One real track feeding the mix, with what the graph says about it. */
export interface MixSource {
    track: MediaStreamTrack;
    /** Merger input the track reaches the destination through, or null when no merger is on its path. */
    channel: number | null;
    /** Product of every GainNode on its path; 0 means "connected but silenced". */
    gain: number;
}

export interface MixRecipe {
    sources: MixSource[];
    usesMerger: boolean;
}

/**
 * What a destination's mix is made of, read off the graph.
 *
 * Walks upstream from the destination. The channel a source lands on is the input index of the
 * merger CLOSEST to the destination on its path — the last one the signal would enter going
 * downstream — which is what turns the SDK's "local → input 0, remote → input 1" into
 * channel-split stereo. Gains multiply along the path. Graphs are a handful of nodes, so a
 * per-path visited set is enough of a cycle guard.
 */
export function compileMixRecipe(destination: MediaStreamAudioDestinationNode): MixRecipe {
    const sources: MixSource[] = [];
    let usesMerger = false;

    const walk = (node: AudioNode, gain: number, channel: number | null, path: Set<AudioNode>) => {
        if (path.has(node)) {
            return;
        }

        path.add(node);

        if (node instanceof MediaStreamAudioSourceNode) {
            for (const track of node.mediaStream.getAudioTracks()) {
                sources.push({ track, channel, gain });
            }
        }

        for (const connection of node._incoming) {
            const upstream = connection.source;
            let nextChannel = channel;
            let nextGain = gain;

            if (node instanceof ChannelMergerNode) {
                usesMerger = true;

                if (channel === null) {
                    nextChannel = connection.input;
                }
            }

            if (upstream instanceof GainNode) {
                nextGain = gain * upstream.gain.value;
            }

            walk(upstream, nextGain, nextChannel, path);
        }

        path.delete(node);
    };

    walk(destination, 1, null, new Set());

    return { sources, usesMerger };
}
