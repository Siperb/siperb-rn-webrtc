package com.oney.WebRTCModule;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Rect;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;
import android.view.View;

import org.webrtc.CapturerObserver;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoCapturer;
import org.webrtc.VideoFrame;

import java.lang.ref.WeakReference;

/**
 * A {@link VideoCapturer} whose frames are a native VIEW (or a still Bitmap), sampled on a timer —
 * the Android half of the "canvas that streams", the mirror of iOS's ViewFrameCapturer. It is the
 * in-process sibling of ScreenCapturerAndroid: the same SurfaceTextureHelper → CapturerObserver
 * machinery, but the pixels come from drawing a View to the helper's Surface with a software
 * Canvas rather than from a MediaProjection VirtualDisplay. So there is NO MediaProjection, no
 * foreground service, no runtime permission — it just works, which is why supportsFrameSource is
 * a plain true.
 *
 * The draw runs on the MAIN (UI) thread, because {@link View#draw(Canvas)} must; the resulting
 * frame reaches WebRTC through the SurfaceTextureHelper's own capture thread. Keep fps modest — a
 * whiteboard is near-static.
 *
 * A software {@code lockCanvas} does not capture GPU-only layers (Metal/Skia hardware surfaces),
 * but react-native-svg — the whiteboard renderer — draws through the ordinary Canvas, so it
 * captures exactly.
 */
public class ViewFrameCapturer implements VideoCapturer {
    private static final String TAG = "ViewFrameCapturer";
    private static final int DEFAULT_FPS = 10;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final WeakReference<View> targetView;
    private final Bitmap stillImage;

    private SurfaceTextureHelper surfaceTextureHelper;
    private CapturerObserver capturerObserver;
    private Surface surface;

    private int width;
    private int height;
    private int fps = DEFAULT_FPS;
    private volatile boolean capturing;

    /** Sample {@code view}'s layer on a timer. Held weakly; if it deallocates the tick stops. */
    ViewFrameCapturer(View view) {
        this.targetView = new WeakReference<>(view);
        this.stillImage = null;
    }

    /** Re-emit one still image on a timer (a "present a picture" source). */
    ViewFrameCapturer(Bitmap image) {
        this.targetView = null;
        this.stillImage = image;
    }

    // MARK: VideoCapturer

    @Override
    public void initialize(SurfaceTextureHelper helper, Context ctx, CapturerObserver observer) {
        this.surfaceTextureHelper = helper;
        this.capturerObserver = observer;
    }

    @Override
    public void startCapture(int captureWidth, int captureHeight, int frameRate) {
        this.width = captureWidth;
        this.height = captureHeight;
        this.fps = frameRate > 0 ? Math.min(frameRate, 30) : DEFAULT_FPS;

        surfaceTextureHelper.setTextureSize(width, height);
        surface = new Surface(surfaceTextureHelper.getSurfaceTexture());

        capturerObserver.onCapturerStarted(true);
        // The helper delivers a texture frame each time we post to the Surface below; forward it.
        surfaceTextureHelper.startListening(frame -> capturerObserver.onFrameCaptured(frame));

        capturing = true;
        mainHandler.post(drawTick);
    }

    private final Runnable drawTick = new Runnable() {
        @Override
        public void run() {
            if (!capturing) {
                return;
            }
            drawFrame();
            if (capturing) {
                mainHandler.postDelayed(this, Math.max(1, 1000 / fps));
            }
        }
    };

    private void drawFrame() {
        Surface s = surface;
        if (s == null || !s.isValid()) {
            return;
        }
        View view = targetView != null ? targetView.get() : null;

        // The target view was torn down (its screen unmounted). Stop cleanly; the SDK's stop path
        // handles the ended track.
        if (view == null && stillImage == null) {
            capturing = false;
            mainHandler.removeCallbacks(drawTick);
            return;
        }

        Canvas canvas = null;
        try {
            canvas = s.lockCanvas(null);
            canvas.drawColor(Color.WHITE);
            if (view != null) {
                int vw = view.getWidth();
                int vh = view.getHeight();
                if (vw > 0 && vh > 0 && (vw != width || vh != height)) {
                    canvas.scale((float) width / vw, (float) height / vh);
                }
                view.draw(canvas);
            } else {
                canvas.drawBitmap(stillImage, null, new Rect(0, 0, width, height), null);
            }
        } catch (Exception e) {
            Log.w(TAG, "drawFrame failed", e);
        } finally {
            if (canvas != null) {
                try {
                    s.unlockCanvasAndPost(canvas);
                } catch (Exception ignored) {
                    // Surface released mid-draw; the next tick re-checks isValid().
                }
            }
        }
    }

    @Override
    public void stopCapture() {
        capturing = false;
        mainHandler.removeCallbacks(drawTick);
        if (surfaceTextureHelper != null) {
            surfaceTextureHelper.stopListening();
        }
        if (capturerObserver != null) {
            capturerObserver.onCapturerStopped();
        }
        if (surface != null) {
            surface.release();
            surface = null;
        }
    }

    @Override
    public void changeCaptureFormat(int captureWidth, int captureHeight, int frameRate) {
        this.width = captureWidth;
        this.height = captureHeight;
        if (frameRate > 0) {
            this.fps = Math.min(frameRate, 30);
        }
        if (surfaceTextureHelper != null) {
            surfaceTextureHelper.setTextureSize(width, height);
        }
    }

    @Override
    public void dispose() {
        stopCapture();
    }

    @Override
    public boolean isScreencast() {
        // A whiteboard is screen-like content, so the encoder's detail-over-framerate bias is what
        // we want — same as the screen capturer.
        return true;
    }
}
