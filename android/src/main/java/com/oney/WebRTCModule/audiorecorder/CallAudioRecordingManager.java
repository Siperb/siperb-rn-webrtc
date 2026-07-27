package com.oney.WebRTCModule.audiorecorder;

import android.media.AudioFormat;
import android.util.Log;
import android.util.Pair;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.WritableMap;
import com.oney.WebRTCModule.WebRTCModule;

import org.webrtc.AudioTrack;
import org.webrtc.audio.JavaAudioDeviceModule;

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

    private final WebRTCModule module;
    private final Object lock = new Object();
    private final Map<String, CallAudioRecorder> recorders = new HashMap<>();
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

    public void startRecording(String recordingId, String wavPath, String m4aPath, boolean includeMic,
            List<Pair<AudioTrack, Integer>> remoteTracks, Promise promise) {
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
        CallAudioRecorder recorder;
        try {
            recorder = new CallAudioRecorder(this, recordingId, wavPath, m4aPath, micWanted, remoteTracks);
        } catch (IOException e) {
            Log.e(TAG, "Failed to open WAV for " + recordingId, e);
            promise.reject("io_error", "Cannot open recording file: " + e.getMessage());
            return;
        }
        recorder.attachSinks();
        recorder.start();
        synchronized (lock) {
            recorders.put(recordingId, recorder);
            if (recorder.wantsMic()) {
                rebuildMicRecorders();
            }
        }
        emitStarted(recordingId);
        promise.resolve(null);
    }

    public void stopRecording(String recordingId, Promise promise) {
        CallAudioRecorder recorder;
        synchronized (lock) {
            recorder = recorders.remove(recordingId);
            if (recorder != null && recorder.wantsMic()) {
                rebuildMicRecorders();
            }
        }
        if (recorder == null) {
            promise.reject("not_found", "No active recording: " + recordingId);
            return;
        }
        recorder.detachSinks();
        recorder.stopAndFinalize("user", promise);
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

    ExecutorService getEncodeExecutor() {
        return encodeExecutor;
    }

    void finishStop(Promise promise, String recordingId, String filePath, long durationMs, long sizeBytes,
            String reason) {
        WritableMap result = Arguments.createMap();
        result.putString("recordingId", recordingId);
        result.putString("filePath", filePath);
        result.putDouble("durationMs", durationMs);
        result.putDouble("size", sizeBytes);
        promise.resolve(result);

        WritableMap event = Arguments.createMap();
        event.putString("recordingId", recordingId);
        event.putString("filePath", filePath);
        event.putDouble("durationMs", durationMs);
        event.putDouble("size", sizeBytes);
        event.putString("reason", reason);
        module.sendEvent("audioRecordingStopped", event);
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

    private void emitStarted(String recordingId) {
        WritableMap event = Arguments.createMap();
        event.putString("recordingId", recordingId);
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
