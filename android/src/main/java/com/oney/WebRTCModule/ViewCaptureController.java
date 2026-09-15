package com.oney.WebRTCModule;

import android.graphics.Bitmap;
import android.view.View;

import org.webrtc.VideoCapturer;

/**
 * The {@link AbstractVideoCaptureController} for a {@link ViewFrameCapturer} — the sibling of
 * ScreenCaptureController, owning the view/image frame source the same way that one owns the
 * MediaProjection capturer. GetUserMediaImpl.createVideoTrack does the rest (SurfaceTextureHelper,
 * VideoSource, track, startCapture), exactly as it does for screen and camera.
 */
public class ViewCaptureController extends AbstractVideoCaptureController {
    private final View view;
    private final Bitmap image;
    private final String deviceId;

    /** Stream a live view: whiteboard. Dimensions are the view's pixel size, already capped/even. */
    public ViewCaptureController(int width, int height, int fps, View view) {
        super(width, height, fps);
        this.view = view;
        this.image = null;
        this.deviceId = "view-capture";
    }

    /** Stream a still image: picture. */
    public ViewCaptureController(int width, int height, int fps, Bitmap image) {
        super(width, height, fps);
        this.view = null;
        this.image = image;
        this.deviceId = "picture";
    }

    @Override
    public String getDeviceId() {
        return deviceId;
    }

    @Override
    protected VideoCapturer createVideoCapturer() {
        return view != null ? new ViewFrameCapturer(view) : new ViewFrameCapturer(image);
    }
}
