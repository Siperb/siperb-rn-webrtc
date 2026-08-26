package com.oney.WebRTCModule.audiorecorder;

import org.webrtc.VideoFrame;
import org.webrtc.VideoSink;
import org.webrtc.VideoTrack;

/**
 * Taps one VideoTrack and hands each frame to its recorder's slot. The video counterpart of
 * CallAudioRecorder's RemoteSource, attached and detached by CallAudioRecordingManager.
 *
 * Deliberately thin: the retain/release discipline that makes frame handling safe lives in
 * {@link CallVideoRecorder#submitFrame}, so there is one place that gets it right rather than
 * one per sink.
 */
class CallVideoSink implements VideoSink {
    final VideoTrack track;
    /** -1 for the local/presentation source, 0..n for remotes. Read when clearing on detach. */
    final int slot;
    private final CallVideoRecorder recorder;

    CallVideoSink(VideoTrack track, CallVideoRecorder recorder, int slot) {
        this.track = track;
        this.recorder = recorder;
        this.slot = slot;
    }

    @Override
    public void onFrame(VideoFrame frame) {
        recorder.submitFrame(frame, slot);
    }
}
