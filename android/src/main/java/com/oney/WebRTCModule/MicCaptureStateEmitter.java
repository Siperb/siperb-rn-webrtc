package com.oney.WebRTCModule;

import android.util.Log;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;

import org.webrtc.audio.JavaAudioDeviceModule;

/**
 * Turns the default AudioDeviceModule's record-error and record-state callbacks into
 * {@code mute} / {@code unmute} on every LOCAL audio track.
 *
 * WHY: a local audio track otherwise stays {@code live}, {@code enabled}, {@code muted: false}
 * for its whole life whatever the microphone does. WebRTC's AudioRecord can fail to initialise
 * (device busy, permission revoked), fail to start ("incorrect state"), or die mid-call
 * ("AudioRecord.read failed") - and without these callbacks each of those was a logcat line
 * and a silent call the app could not tell from a working one. The W3C meaning of
 * {@code muted} is exactly "temporarily unable to provide data".
 *
 * CONSERVATIVE BY DESIGN. {@code muted} starts false and flips only on a real failure; the
 * next successful record start flips it back. "Recording has not started yet" (no peer
 * connection sending) is deliberately NOT modelled as muted, so an ordinary call sees no
 * events at all.
 *
 * The callbacks arrive on WebRTC's audio threads. The track registry is executor-confined, so
 * the fan-out hops there; the flag itself is volatile so getUserMedia can stamp a track created
 * DURING a failure as born muted (see GetUserMediaImpl.createStream).
 */
final class MicCaptureStateEmitter
        implements JavaAudioDeviceModule.AudioRecordErrorCallback, JavaAudioDeviceModule.AudioRecordStateCallback {
    private static final String TAG = WebRTCModule.TAG;

    private final WebRTCModule module;
    private volatile boolean muted;

    MicCaptureStateEmitter(WebRTCModule module) {
        this.module = module;
    }

    /** True while the microphone is known to be failing. */
    boolean isMuted() {
        return muted;
    }

    @Override
    public void onWebRtcAudioRecordInitError(String errorMessage) {
        fail("init: " + errorMessage);
    }

    @Override
    public void onWebRtcAudioRecordStartError(
            JavaAudioDeviceModule.AudioRecordStartErrorCode errorCode, String errorMessage) {
        fail("start " + errorCode + ": " + errorMessage);
    }

    @Override
    public void onWebRtcAudioRecordError(String errorMessage) {
        fail("runtime: " + errorMessage);
    }

    @Override
    public void onWebRtcAudioRecordStart() {
        setMuted(false);
    }

    @Override
    public void onWebRtcAudioRecordStop() {
        // A normal stop at the end of a call is not a failure; the track is ending anyway.
    }

    private void fail(String reason) {
        Log.e(TAG, "Microphone capture failed (" + reason + "); local audio tracks are muted until it recovers");
        setMuted(true);
    }

    private void setMuted(boolean nowMuted) {
        if (muted == nowMuted) {
            return;
        }
        muted = nowMuted;

        ThreadUtils.runOnExecutor(() -> {
            for (String trackId : module.getLocalAudioTrackIds()) {
                WritableMap params = Arguments.createMap();
                params.putString("trackId", trackId);
                params.putBoolean("muted", nowMuted);
                // No pcId on purpose: that is what marks the event LOCAL. RTCPeerConnection's
                // listener filters on pcId and ignores it; MediaStreamTrack matches trackId.
                module.sendEvent("mediaStreamTrackMuteChanged", params);
            }
        });
    }
}
