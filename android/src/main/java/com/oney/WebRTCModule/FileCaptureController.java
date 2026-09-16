package com.oney.WebRTCModule;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;
import com.oney.WebRTCModule.filesource.FileSource;

import org.webrtc.VideoCapturer;

/**
 * The {@link AbstractVideoCaptureController} for a {@link FileVideoCapturer} — the file-source
 * sibling of ViewCaptureController. Owns the FileSource, forwards its playback events to the
 * module (JS's `fileMediaEvent`) and its fatal error to the track-ended emitter, and exposes the
 * transport controls `fileMediaControl` drives. GetUserMediaImpl.createVideoTrack does the rest.
 */
public class FileCaptureController extends AbstractVideoCaptureController {
    /** Sink for playback events, wired by GetUserMediaImpl to WebRTCModule.sendEvent. */
    public interface EventSink {
        void onFileMediaEvent(WritableMap body);
    }

    private final FileSource source;
    private final boolean autoplay;
    private EventSink eventSink;

    /** {@code width}/{@code height} are the DECODED size; rotation travels in the frame. */
    private final int targetWidth;
    private final int targetHeight;

    /** {@code width}/{@code height} are the file's; the capturer emits at {@code targetWidth}x{@code targetHeight}. */
    public FileCaptureController(int width, int height, int fps, FileSource source, boolean autoplay,
            int targetWidth, int targetHeight) {
        super(width, height, fps);
        this.source = source;
        this.autoplay = autoplay;
        this.targetWidth = targetWidth;
        this.targetHeight = targetHeight;
    }

    public FileSource getSource() {
        return source;
    }

    public void setEventSink(EventSink sink) {
        this.eventSink = sink;
        source.setListener(new FileSource.Listener() {
            @Override
            public void onEvent(String type, double position, double duration, boolean playing, boolean ended,
                    String extraKey, String extraValue) {
                EventSink s = eventSink;
                if (s == null) {
                    return;
                }
                WritableMap body = state();
                body.putString("type", type);
                if (extraKey != null) {
                    body.putString(extraKey, extraValue);
                }
                s.onFileMediaEvent(body);
            }

            @Override
            public void onFatal() {
                if (capturerEventsListener != null) {
                    capturerEventsListener.onCapturerEnded();
                }
            }
        });
    }

    /** The playback state, the shape every control reply and event carries. */
    public WritableMap state() {
        WritableMap map = Arguments.createMap();
        map.putBoolean("playing", source.isPlaying());
        map.putDouble("position", source.getPositionSeconds());
        map.putDouble("duration", source.getDurationSeconds());
        map.putBoolean("ended", source.isEnded());
        return map;
    }

    @Override
    public String getDeviceId() {
        return "file";
    }

    @Override
    protected VideoCapturer createVideoCapturer() {
        return new FileVideoCapturer(source, autoplay, targetWidth, targetHeight);
    }
}
