package com.oney.WebRTCModule.audiorecorder;

import android.graphics.Bitmap;
import android.media.AudioFormat;
import android.media.MediaMetadataRetriever;
import android.util.Base64;
import android.util.Log;
import android.util.Pair;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.WritableMap;
import com.oney.WebRTCModule.WebRTCModule;

import org.webrtc.AudioTrack;
import org.webrtc.VideoTrack;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Registry of active call recordings, owned by WebRTCModule. Owns the single mic PCM
 * dispatcher installed on the default JavaAudioDeviceModule and fans mic frames out to
 * every recorder that wants them.
 *
 * Unless noted otherwise the public entry points run on the WebRTCModule ThreadUtils
 * executor, which also serializes them against peer connection close/dispose.
 */
public class CallAudioRecordingManager {
    static final String TAG = "CallAudioRecording";

    /**
     * The `video` block from JS, with its track ids already resolved to tracks.
     *
     * Built by WebRTCModule (which owns the peer connections) and read by this class, so it
     * lives here rather than in the module: the manager is what has to be told, and a parsed
     * request is a smaller thing to be told than seven more parameters.
     *
     * `width` is the FINAL frame width, already doubled by the caller for side-by-side. The
     * SD/HD/FHD table lives in JS next to the settings it reads; nothing here re-derives it.
     */
    public static final class VideoRecordingRequest {
        public int width;
        public int height;
        public int fps;
        public int pnpSize;
        public String layout;
        /** null is a legitimate remote-only composite — the camera may simply be off. */
        public VideoTrack localTrack;
        public List<VideoTrack> remoteTracks = new ArrayList<>();
    }

    /**
     * What a finished video leg produced, parked between stopping the mp4 and finishing the
     * audio leg that resolves the promise.
     *
     * It exists because the two legs finalize in sequence but only ONE result goes back, and
     * the video's is the one that wins when there is one. Keyed by recordingId in a map rather
     * than threaded through stopAndFinalize's signature, which is on the audio path and has no
     * business knowing what an mp4 is.
     */
    private static final class VideoOutcome {
        final String filePath;
        final long durationMs;
        final long sizeBytes;

        VideoOutcome(String filePath, long durationMs, long sizeBytes) {
            this.filePath = filePath;
            this.durationMs = durationMs;
            this.sizeBytes = sizeBytes;
        }
    }

    private final WebRTCModule module;
    private final Object lock = new Object();
    private final Map<String, CallAudioRecorder> recorders = new HashMap<>();
    // Video is a PARALLEL registry keyed by the same id rather than fields on the audio
    // recorder: most segments have no video, and an audio recorder that knew what an mp4 was
    // would carry the concept into every audio-only call for nothing.
    private final Map<String, CallVideoRecorder> videoRecorders = new HashMap<>();
    private final Map<String, List<CallVideoSink>> videoSinks = new HashMap<>();
    private final Map<String, VideoOutcome> pendingVideoResults = new HashMap<>();
    // Snapshot for the mic fast path: with no active recorders the audio thread must
    // return immediately, without locking or allocating.
    private volatile CallAudioRecorder[] micRecorders = new CallAudioRecorder[0];
    private volatile boolean micCaptureAvailable;
    private final ExecutorService encodeExecutor =
            Executors.newSingleThreadExecutor(r -> new Thread(r, "CallRecordingEncoder"));
    private short[] micScratch = new short[0]; // mic dispatcher thread only
    private boolean warnedBadMicFormat;

    /** Runs on the WebRTC audio record thread. Copy only; no IO, no heavy allocation. */
    private final JavaAudioDeviceModule.SamplesReadyCallback micDispatcher = samples -> {
        CallAudioRecorder[] targets = micRecorders;
        if (targets.length == 0) {
            return;
        }
        if (samples.getAudioFormat() != AudioFormat.ENCODING_PCM_16BIT) {
            if (!warnedBadMicFormat) {
                warnedBadMicFormat = true;
                Log.w(TAG, "Unsupported mic audio format " + samples.getAudioFormat() + "; mic leg skipped");
            }
            return;
        }
        byte[] data = samples.getData();
        int totalSamples = data.length / 2;
        if (totalSamples == 0) {
            return;
        }
        if (micScratch.length < totalSamples) {
            micScratch = new short[totalSamples];
        }
        for (int i = 0; i < totalSamples; i++) {
            micScratch[i] = (short) ((data[i * 2] & 0xff) | (data[i * 2 + 1] << 8));
        }
        for (CallAudioRecorder recorder : targets) {
            recorder.pushMicSamples(micScratch, totalSamples, samples.getSampleRate(), samples.getChannelCount());
        }
    };

    public CallAudioRecordingManager(WebRTCModule module) {
        this.module = module;
    }

    public JavaAudioDeviceModule.SamplesReadyCallback getMicDispatcher() {
        return micDispatcher;
    }

    /** True only when the default ADM was built with our samples-ready callback chained in. */
    public void setMicCaptureAvailable(boolean available) {
        micCaptureAvailable = available;
    }

    public void startRecording(String recordingId, String wavPath, String outputPath, boolean includeMic,
            boolean stereo, List<Pair<AudioTrack, Integer>> remoteTracks, VideoRecordingRequest video,
            Promise promise) {
        synchronized (lock) {
            if (recorders.containsKey(recordingId)) {
                promise.reject("duplicate_id", "Recording already active: " + recordingId);
                return;
            }
        }
        boolean micWanted = includeMic;
        if (micWanted && !micCaptureAvailable) {
            Log.w(TAG, "Mic capture unavailable (custom AudioDeviceModule injected); recording remote audio only");
            micWanted = false;
        }
        if (!micWanted && remoteTracks.isEmpty()) {
            promise.reject("no_sources", "No mic capture and no resolvable remote audio tracks");
            return;
        }

        // The WAV is written for every segment, video or not — it is the only crash-recoverable
        // copy, because an mp4's index is not written until stop. On a video segment the audio
        // is therefore written twice, deliberately.
        //
        // audioPath is the AUDIO output. On a video segment the mp4 is the artifact and this
        // .m4a is deleted at stop — but it is exactly what the fallback needs when the video
        // leg dies mid-call, so it is derived here rather than left null.
        String audioPath = video != null ? outputPath.replaceAll("\\.[^.]+$", "") + ".m4a" : outputPath;

        CallAudioRecorder recorder;
        try {
            recorder = new CallAudioRecorder(this, recordingId, wavPath, audioPath, micWanted, stereo, remoteTracks);
        } catch (IOException e) {
            Log.e(TAG, "Failed to open WAV for " + recordingId, e);
            promise.reject("io_error", "Cannot open recording file: " + e.getMessage());
            return;
        }

        // Started BEFORE the audio recorder, so the PcmTap is in place before the first 10 ms
        // tick fires and the mp4 does not open with a hole where its first audio should be.
        CallVideoRecorder videoRecorder = null;
        List<CallVideoSink> sinks = new ArrayList<>();
        if (video != null) {
            CallVideoRecorder candidate = new CallVideoRecorder(outputPath, video.width, video.height, video.fps,
                    video.layout, video.pnpSize, stereo);
            try {
                candidate.start();
                videoRecorder = candidate;
                recorder.setPcmTap(candidate);
                if (video.localTrack != null) {
                    sinks.add(new CallVideoSink(video.localTrack, candidate, CallVideoRecorder.LOCAL_SLOT));
                }
                for (int i = 0; i < video.remoteTracks.size(); i++) {
                    sinks.add(new CallVideoSink(video.remoteTracks.get(i), candidate, i));
                }
            } catch (IOException | RuntimeException e) {
                // DEGRADE, DO NOT FAIL. The caller asked for video and is getting audio; stop
                // reports withVideo false and hands back the .m4a. Failing here would throw
                // away a perfectly recordable call because its picture could not be encoded.
                Log.w(TAG, "video leg failed to start for " + recordingId + " — recording audio only", e);
                sinks.clear();
            }
        }

        recorder.attachSinks();
        recorder.start();
        synchronized (lock) {
            recorders.put(recordingId, recorder);
            if (videoRecorder != null) {
                videoRecorders.put(recordingId, videoRecorder);
                videoSinks.put(recordingId, sinks);
            }
            if (recorder.wantsMic()) {
                rebuildMicRecorders();
            }
        }
        for (CallVideoSink sink : sinks) {
            sink.track.addSink(sink);
        }
        emitStarted(recordingId, videoRecorder != null);
        promise.resolve(null);
    }

    /**
     * Swap the composited video sources mid-segment — the presentation case, where the local
     * slot must follow a screen-share track rather than the camera.
     *
     * A NO-OP on an unknown id or an audio-only segment: the caller is reporting a source
     * change, not asserting that a compositor exists to hear it.
     */
    public void updateVideoSources(String recordingId, VideoTrack localTrack, List<VideoTrack> remoteTracks) {
        CallVideoRecorder videoRecorder;
        List<CallVideoSink> previous;
        synchronized (lock) {
            videoRecorder = videoRecorders.get(recordingId);
            previous = videoSinks.get(recordingId);
        }
        if (videoRecorder == null) {
            return;
        }

        List<CallVideoSink> replacements = new ArrayList<>();
        if (localTrack != null) {
            replacements.add(new CallVideoSink(localTrack, videoRecorder, CallVideoRecorder.LOCAL_SLOT));
        }
        for (int i = 0; i < remoteTracks.size(); i++) {
            replacements.add(new CallVideoSink(remoteTracks.get(i), videoRecorder, i));
        }
        synchronized (lock) {
            videoSinks.put(recordingId, replacements);
        }

        int previousCount = previous == null ? 0 : previous.size();
        if (previous != null) {
            for (CallVideoSink sink : previous) {
                sink.track.removeSink(sink);
            }
        }
        // CLEARING MATTERS: a slot keeps its last frame forever otherwise, so dropping the
        // camera would freeze its final picture into the recording rather than going black.
        if (localTrack == null) {
            videoRecorder.clearSlot(CallVideoRecorder.LOCAL_SLOT);
        }
        for (int slot = remoteTracks.size(); slot < previousCount; slot++) {
            videoRecorder.clearSlot(slot);
        }
        for (CallVideoSink sink : replacements) {
            sink.track.addSink(sink);
        }
    }

    public void stopRecording(String recordingId, Promise promise) {
        CallAudioRecorder recorder;
        CallVideoRecorder videoRecorder;
        List<CallVideoSink> sinks;
        synchronized (lock) {
            recorder = recorders.remove(recordingId);
            videoRecorder = videoRecorders.remove(recordingId);
            sinks = videoSinks.remove(recordingId);
            if (recorder != null && recorder.wantsMic()) {
                rebuildMicRecorders();
            }
        }
        if (recorder == null) {
            promise.reject("not_found", "No active recording: " + recordingId);
            return;
        }
        recorder.detachSinks();
        if (sinks != null) {
            for (CallVideoSink sink : sinks) {
                sink.track.removeSink(sink);
            }
        }
        if (videoRecorder == null) {
            recorder.stopAndFinalize("user", promise);
            return;
        }

        // VIDEO: finish the mp4 FIRST, because whether it produced anything decides which file
        // this segment is. stopAndFinalize blocks on draining the codecs, so it has to be off
        // the module executor; the audio leg is then finalized from the same worker and is what
        // resolves the promise, through finishStop below.
        final CallVideoRecorder video = videoRecorder;
        encodeExecutor.execute(() -> {
            AacEncoder.Result videoResult = null;
            try {
                videoResult = video.stopAndFinalize();
            } catch (RuntimeException e) {
                Log.w(TAG, "video: finalize failed for " + recordingId + " — falling back to audio", e);
            }
            if (videoResult != null) {
                synchronized (lock) {
                    pendingVideoResults.put(recordingId,
                            new VideoOutcome(video.getOutputPath(), videoResult.durationMs, videoResult.sizeBytes));
                }
            } else {
                Log.w(TAG, "video: " + recordingId + " requested video and produced none — reporting the audio file");
            }
            recorder.stopAndFinalize("user", promise);
        });
    }

    public List<String> getActiveRecordingIds() {
        synchronized (lock) {
            return new ArrayList<>(recorders.keySet());
        }
    }

    /**
     * Salvages a WAV left behind by a crash: patches its header from the file length,
     * encodes it to .m4a and deletes the WAV. Runs entirely on the encode executor.
     */
    public void finalizeOrphanRecording(String wavPath, String m4aPath, Promise promise) {
        encodeExecutor.execute(() -> {
            File wavFile = new File(wavPath);
            if (!wavFile.isFile()) {
                promise.reject("not_found", "No WAV file at " + wavPath);
                return;
            }
            try {
                WavFileWriter.salvage(wavFile);
                AacEncoder.Result result = AacEncoder.encode(wavFile, new File(m4aPath));
                if (!wavFile.delete()) {
                    Log.w(TAG, "Could not delete salvaged WAV " + wavPath);
                }
                WritableMap map = Arguments.createMap();
                map.putString("filePath", m4aPath);
                map.putDouble("durationMs", result.durationMs);
                map.putDouble("size", result.sizeBytes);
                // ALWAYS audio, by construction: the WAV is the only thing a crash leaves
                // recoverable, so a salvaged video segment comes back as its sound. Stamped
                // rather than left off so the result reads like every other one on this surface.
                map.putBoolean("withVideo", false);
                map.putString("mimeType", "audio/mp4");
                promise.resolve(map);
            } catch (IOException e) {
                Log.e(TAG, "Orphan salvage failed for " + wavPath, e);
                promise.reject("encode_error", "Salvage failed: " + e.getMessage());
            }
        });
    }

    /**
     * Called from PeerConnectionObserver before this connection's remote tracks can be
     * disposed, so no sink callback fires into (or is removed from) a dead track. The
     * affected recorders keep running zero-padded until JS stops them.
     */
    public void detachSinksForPeerConnection(int peerConnectionId) {
        List<CallAudioRecorder> snapshot;
        synchronized (lock) {
            snapshot = new ArrayList<>(recorders.values());
        }
        for (CallAudioRecorder recorder : snapshot) {
            recorder.detachSinksForPeerConnection(peerConnectionId);
        }
    }

    /**
     * The video half of the same safety hook, called before a remote VIDEO track is disposed.
     *
     * Separate from detachSinksForPeerConnection above because video sinks are held here, on
     * the manager, not on the audio recorder — so there is no per-recorder call to delegate to.
     * The slot is cleared as well as detached: left alone it would hold that track's last frame
     * for the rest of the recording, freezing a departed party's final picture into the file
     * instead of going black.
     */
    public void detachVideoSinksForTrack(VideoTrack track) {
        List<CallVideoSink> matches = new ArrayList<>();
        List<CallVideoRecorder> owners = new ArrayList<>();
        synchronized (lock) {
            for (Map.Entry<String, List<CallVideoSink>> entry : videoSinks.entrySet()) {
                for (CallVideoSink sink : entry.getValue()) {
                    if (sink.track == track) {
                        matches.add(sink);
                        owners.add(videoRecorders.get(entry.getKey()));
                    }
                }
            }
        }
        for (int i = 0; i < matches.size(); i++) {
            CallVideoSink sink = matches.get(i);
            sink.track.removeSink(sink);
            CallVideoRecorder owner = owners.get(i);
            if (owner != null) {
                owner.clearSlot(sink.slot);
            }
        }
    }

    ExecutorService getEncodeExecutor() {
        return encodeExecutor;
    }

    /**
     * WHERE THE TWO LEGS BECOME ONE RESULT, and where `withVideo` gets its value.
     *
     * The video leg finished first and left its outcome in pendingVideoResults if it produced
     * anything. When it did, the mp4 IS the recording and the .m4a beside it is redundant — a
     * second copy of every video call on the disk — so it is deleted here.
     *
     * withVideo and mimeType describe THE FILE, never the request. A segment that asked for
     * video and lost it comes through this same path with no pending outcome and reports the
     * audio file it actually produced, which is what stops a caller inferring the contents from
     * what it asked for.
     */
    void finishStop(Promise promise, String recordingId, String filePath, long durationMs, long sizeBytes,
            String reason) {
        VideoOutcome video;
        synchronized (lock) {
            video = pendingVideoResults.remove(recordingId);
        }
        boolean withVideo = video != null;
        if (withVideo) {
            File redundantAudio = new File(filePath);
            if (redundantAudio.isFile() && !redundantAudio.delete()) {
                Log.w(TAG, "Could not delete redundant audio file " + filePath);
            }
            filePath = video.filePath;
            durationMs = video.durationMs;
            sizeBytes = video.sizeBytes;
        }
        String mimeType = withVideo ? "video/mp4" : "audio/mp4";
        // The web builds its poster from the compositor canvas; a DOM-less host has none, so the
        // recording's thumbnail is generated here from the finalized mp4 and handed up in the stop
        // result (JS RecordingBlob.thumbnail -> the SDK's recording.Thumbnail). Video segments only.
        String thumbnail = withVideo ? videoPosterDataUrl(filePath) : null;

        WritableMap result = Arguments.createMap();
        result.putString("recordingId", recordingId);
        result.putString("filePath", filePath);
        result.putDouble("durationMs", durationMs);
        result.putDouble("size", sizeBytes);
        result.putBoolean("withVideo", withVideo);
        result.putString("mimeType", mimeType);
        if (thumbnail != null) {
            result.putString("thumbnail", thumbnail);
        }
        promise.resolve(result);

        WritableMap event = Arguments.createMap();
        event.putString("recordingId", recordingId);
        event.putString("filePath", filePath);
        event.putDouble("durationMs", durationMs);
        event.putDouble("size", sizeBytes);
        event.putBoolean("withVideo", withVideo);
        event.putString("mimeType", mimeType);
        event.putString("reason", reason);
        if (thumbnail != null) {
            event.putString("thumbnail", thumbnail);
        }
        module.sendEvent("audioRecordingStopped", event);
    }

    /**
     * A poster frame for a recorded mp4, as a {@code data:image/jpeg;base64,…} data URL, or null.
     *
     * A DATA URL, not a {@code file://} path, because the recording row it ends up on is
     * replicated across the user's devices — a device-local path would render broken everywhere
     * else. Read from the FINALIZED file (off the encoder path) with MediaMetadataRetriever and
     * scaled to 320px so the string stays small enough to ride on the synced row. Best-effort: a
     * null here just means no poster, never a failed recording.
     */
    private static String videoPosterDataUrl(String path) {
        if (path == null || path.isEmpty()) {
            return null;
        }
        MediaMetadataRetriever retriever = new MediaMetadataRetriever();
        Bitmap frame = null;
        Bitmap scaled = null;
        try {
            retriever.setDataSource(path);
            // The nearest sync frame to the start, rather than demanding an exact t=0 keyframe.
            frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
            if (frame == null) {
                return null;
            }
            scaled = scaleBitmapToMax(frame, 320);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            scaled.compress(Bitmap.CompressFormat.JPEG, 60, out);
            byte[] bytes = out.toByteArray();
            if (bytes.length == 0) {
                return null;
            }
            return "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP);
        } catch (Exception e) {
            Log.w(TAG, "poster generation failed: " + e.getMessage());
            return null;
        } finally {
            if (scaled != null && scaled != frame) {
                scaled.recycle();
            }
            if (frame != null) {
                frame.recycle();
            }
            try {
                retriever.release();
            } catch (Exception ignored) {
            }
        }
    }

    private static Bitmap scaleBitmapToMax(Bitmap src, int maxDim) {
        int w = src.getWidth();
        int h = src.getHeight();
        if (w <= maxDim && h <= maxDim) {
            return src;
        }
        float scale = Math.min((float) maxDim / w, (float) maxDim / h);
        int nw = Math.max(1, Math.round(w * scale));
        int nh = Math.max(1, Math.round(h * scale));
        return Bitmap.createScaledBitmap(src, nw, nh, true);
    }

    void failStop(Promise promise, String recordingId, String message) {
        promise.reject("encode_error", message);
        emitError(recordingId, message);
    }

    void emitError(String recordingId, String error) {
        WritableMap event = Arguments.createMap();
        event.putString("recordingId", recordingId);
        event.putString("error", error);
        module.sendEvent("audioRecordingError", event);
    }

    private void emitStarted(String recordingId, boolean withVideo) {
        WritableMap event = Arguments.createMap();
        event.putString("recordingId", recordingId);
        event.putBoolean("withVideo", withVideo);
        module.sendEvent("audioRecordingStarted", event);
    }

    private void rebuildMicRecorders() { // caller holds lock
        List<CallAudioRecorder> wantMic = new ArrayList<>();
        for (CallAudioRecorder recorder : recorders.values()) {
            if (recorder.wantsMic()) {
                wantMic.add(recorder);
            }
        }
        micRecorders = wantMic.toArray(new CallAudioRecorder[0]);
    }
}
