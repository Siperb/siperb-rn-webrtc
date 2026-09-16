package com.oney.WebRTCModule;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;

import com.oney.WebRTCModule.filesource.FileSource;

import org.webrtc.CapturerObserver;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoCapturer;
import org.webrtc.VideoFrame;

import java.io.IOException;

/**
 * A {@link VideoCapturer} whose frames are a video FILE — the mirror of iOS's FileFrameSource and
 * the sibling of ViewFrameCapturer: the same SurfaceTextureHelper → CapturerObserver machinery,
 * with a {@link FileSource} (MediaPlayer) rendering into the helper's Surface instead of a View
 * being drawn to it. Each posted buffer arrives as a texture VideoFrame; nothing crosses the bridge.
 *
 * START/STOP ARE RESUME/SUSPEND, not create/destroy. GetUserMediaImpl.createVideoTrack calls
 * startCapture once, and mediaStreamTrackSetEnabled calls startCapture/stopCapture on every
 * enable/disable — which the SDK does on hold. A suspended file pauses picture and sound; it must
 * NOT release the Surface (ViewFrameCapturer does, and a file could not come back from it).
 * {@link #dispose()} is the teardown, reached from the track's release.
 *
 * HOLD FRAME: while paused or ended, the far end must keep the picture, but a paused MediaPlayer
 * posts nothing to the Surface. So on hold the last delivered frame is kept as an I420 copy
 * (never a retained TextureBuffer — the helper has ONE texture and stalls while it is in use) and
 * re-emitted at a low rate until playback resumes.
 *
 * EVERY FRAME LEAVES AS I420, AT THE TARGET SIZE, STAMPED WITH ARRIVAL TIME. Not textures.
 * Handing the encoder MediaPlayer-fed textures wedged the Qualcomm encoder on device (c2.qti.avc
 * "returned error 0xffffffff" on the first input after the camera→file swap; every frame dropped
 * until WebRTC's quality scaler reset it ~30 s later), and HardwareVideoEncoder also resets the
 * codec whenever the buffer TYPE flips — which the I420 hold frames would have done on every pause.
 * So the texture is scaled on the GPU to the size the caller asked for (one readback, at the
 * OUTPUT size, not the file's), and the clock is ours, monotonic: a MediaPlayer's SurfaceTexture
 * timestamps are the player's scheduled presentation times, not capture times.
 */
public class FileVideoCapturer implements VideoCapturer {
    private static final String TAG = "FileVideoCapturer";
    private static final int HOLD_FPS = 2;

    private final FileSource source;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    /** Output size (0 = the file's own); every frame is scaled to it before it leaves. */
    private final int targetWidth;
    private final int targetHeight;

    private SurfaceTextureHelper surfaceTextureHelper;
    private CapturerObserver capturerObserver;
    private Surface surface;
    private boolean started;
    private boolean disposed;
    private final boolean autoplay;

    private volatile boolean holding;
    private VideoFrame.I420Buffer heldFrame;      // capture thread + main hold tick, under `this`
    private int heldRotation;

    FileVideoCapturer(FileSource source, boolean autoplay, int targetWidth, int targetHeight) {
        this.source = source;
        this.autoplay = autoplay;
        this.targetWidth = targetWidth;
        this.targetHeight = targetHeight;
    }

    // MARK: VideoCapturer

    @Override
    public void initialize(SurfaceTextureHelper helper, Context ctx, CapturerObserver observer) {
        this.surfaceTextureHelper = helper;
        this.capturerObserver = observer;
    }

    @Override
    public void startCapture(int captureWidth, int captureHeight, int frameRate) {
        if (disposed) {
            return;
        }
        if (started) {
            source.setSuspended(false);   // re-enabled after a hold
            return;
        }
        started = true;
        // Texture size is the DECODED size; the container's rotation travels in the frame
        // (setFrameRotation) so WebRTC signals it, as a camera frame does. Whether the
        // SurfaceTexture transform MediaPlayer sets already rotates the content as well is a
        // device check — if a portrait file arrives doubly rotated, drop the setFrameRotation.
        surfaceTextureHelper.setTextureSize(captureWidth, captureHeight);
        surfaceTextureHelper.setFrameRotation(source.getRotation());
        surface = new Surface(surfaceTextureHelper.getSurfaceTexture());

        capturerObserver.onCapturerStarted(true);
        surfaceTextureHelper.startListening(this::onFrame);

        source.setHoldListener(this::setHolding);
        try {
            source.start(surface, autoplay);
        } catch (IOException e) {
            Log.e(TAG, "start failed", e);
            capturerObserver.onCapturerStarted(false);
            return;
        }
        source.setSuspended(false);
    }

    /**
     * Every frame the helper delivers (on its thread, which is where a texture may be read):
     * scale to the target size, convert to I420, forward with an arrival timestamp, and keep it
     * while holding. See the header for why never the texture itself.
     */
    private void onFrame(VideoFrame frame) {
        VideoFrame.Buffer buffer = frame.getBuffer();
        VideoFrame.Buffer scaled = buffer;
        if (targetWidth > 0 && targetHeight > 0
                && (buffer.getWidth() != targetWidth || buffer.getHeight() != targetHeight)) {
            // On a TextureBuffer this is a matrix change; the GPU does the scaling in toI420().
            scaled = buffer.cropAndScale(0, 0, buffer.getWidth(), buffer.getHeight(), targetWidth, targetHeight);
        }
        VideoFrame.I420Buffer i420 = scaled.toI420();
        if (scaled != buffer) {
            scaled.release();
        }
        if (i420 == null) {
            return;
        }
        VideoFrame out = new VideoFrame(i420, frame.getRotation(), System.nanoTime());
        capturerObserver.onFrameCaptured(out);
        if (holding) {
            synchronized (this) {
                if (heldFrame != null) {
                    heldFrame.release();
                }
                i420.retain();
                heldFrame = i420;
                heldRotation = frame.getRotation();
            }
        }
        out.release();
    }

    private void setHolding(boolean hold) {
        if (holding == hold) {
            return;
        }
        holding = hold;
        if (hold) {
            // A paused player posts nothing, so the next tick would have nothing to copy: nudge
            // one frame out by seeking to where we are, then re-emit it on the hold timer.
            source.nudgeFrame();
            mainHandler.postDelayed(holdTick, 1000 / HOLD_FPS);
        } else {
            mainHandler.removeCallbacks(holdTick);
            synchronized (this) {
                if (heldFrame != null) {
                    heldFrame.release();
                    heldFrame = null;
                }
            }
        }
    }

    private final Runnable holdTick = new Runnable() {
        @Override
        public void run() {
            if (!holding || disposed) {
                return;
            }
            synchronized (FileVideoCapturer.this) {
                if (heldFrame != null && capturerObserver != null) {
                    VideoFrame frame = new VideoFrame(heldFrame, heldRotation, System.nanoTime());
                    heldFrame.retain();
                    capturerObserver.onFrameCaptured(frame);
                    frame.release();
                }
            }
            mainHandler.postDelayed(this, 1000 / HOLD_FPS);
        }
    };

    @Override
    public void stopCapture() {
        // Suspend, never teardown: the SDK disables the sender track on hold and re-enables it.
        source.setSuspended(true);
    }

    @Override
    public void changeCaptureFormat(int captureWidth, int captureHeight, int frameRate) {
        // The file decides its own size; WebRTC's adaptOutputFormat does the scaling.
    }

    @Override
    public void dispose() {
        if (disposed) {
            return;
        }
        disposed = true;
        mainHandler.removeCallbacks(holdTick);
        source.release();
        if (surfaceTextureHelper != null) {
            surfaceTextureHelper.stopListening();
        }
        if (capturerObserver != null) {
            capturerObserver.onCapturerStopped();
        }
        synchronized (this) {
            if (heldFrame != null) {
                heldFrame.release();
                heldFrame = null;
            }
        }
        if (surface != null) {
            surface.release();
            surface = null;
        }
    }

    @Override
    public boolean isScreencast() {
        // A film is motion video; the screencast bias (detail over framerate) is the wrong trade.
        return false;
    }
}
