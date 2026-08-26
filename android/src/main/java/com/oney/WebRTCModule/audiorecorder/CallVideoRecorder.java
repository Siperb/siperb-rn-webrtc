package com.oney.WebRTCModule.audiorecorder;

import android.graphics.Matrix;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import com.oney.WebRTCModule.EglUtils;

import org.webrtc.EglBase;
import org.webrtc.GlRectDrawer;
import org.webrtc.RendererCommon;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.Map;
import java.util.Queue;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The video half of a call recording: composites the local and remote video tracks at a fixed
 * frame rate, encodes H.264 through MediaCodec, and muxes it with the audio recorder's mixed
 * PCM into an mp4.
 *
 * ONE MIXER, TWO CONSUMERS. Nothing here mixes audio. CallAudioRecorder's 10 ms tick already
 * produces the interleaved int16 mix it streams to the WAV, and that same buffer arrives here
 * through {@link CallAudioRecorder.PcmTap}. A second tap on the same tracks would be a second
 * mix, and two mixes of one call drift.
 *
 * WHY THE WAV STILL EXISTS ALONGSIDE THIS. An mp4's index is written at stop, so a process
 * killed mid-recording leaves an unplayable file. The WAV keeps streaming, so a crashed video
 * segment still salvages as audio. A deliberate double-write: the only crash-recoverable copy
 * is the one nobody has to finalize.
 *
 * DEGRADES, NEVER FAILS THE SEGMENT. Any failure here disables the video leg and lets the audio
 * recorder finish a normal .m4a. Losing the picture is a worse recording; losing the call is a
 * lost recording.
 *
 * THREADING. Everything that touches MediaCodec, the muxer or GL happens on this class's own
 * HandlerThread. Frames arrive on WebRTC delivery threads and are COPIED into slots under a
 * lock — copied, not retained, for the reason spelled out on submitFrame: holding a texture
 * frame stalls the capturer that produced it and freezes the recording on its first picture.
 * Audio arrives on the audio recorder's writer thread and is copied into a queue for the same
 * class of reason. One thread owns the codecs, which is the only portable arrangement.
 */
class CallVideoRecorder implements CallAudioRecorder.PcmTap {
    private static final String TAG = CallAudioRecordingManager.TAG;

    private static final String VIDEO_MIME = MediaFormat.MIMETYPE_VIDEO_AVC;
    private static final String AUDIO_MIME = MediaFormat.MIMETYPE_AUDIO_AAC;
    private static final int SAMPLE_RATE = WavFileWriter.SAMPLE_RATE;
    private static final int AUDIO_BIT_RATE = 64000;
    private static final long CODEC_TIMEOUT_US = 0; // non-blocking: the tick must not stall
    /** Slot index for the local/presentation source. Negative so it cannot collide with a remote. */
    static final int LOCAL_SLOT = -1;
    /**
     * ~2 seconds of 10 ms ticks. A bound rather than an unbounded queue because a stalled
     * encoder must drop audio rather than grow the heap until the app dies — and 2 s of drift
     * is already a broken recording, so there is nothing to protect past that.
     */
    private static final int MAX_QUEUED_AUDIO_TICKS = 200;

    /** What the compositor draws. Mirrors CallRecordingLayout in CallRecorder.ts. */
    enum Layout {
        THEM_PNP,
        SIDE_BY_SIDE,
        US_ONLY,
        THEM_ONLY;

        /**
         * Unknown strings fall back to THEM_PNP, the web's default. JS maps the two talker
         * layouts here before calling, so an unrecognised value means a version skew rather
         * than a typo, and the default is the honest answer.
         */
        static Layout from(String name) {
            if ("side-by-side".equals(name)) {
                return SIDE_BY_SIDE;
            }
            if ("us-only".equals(name)) {
                return US_ONLY;
            }
            if ("them-only".equals(name)) {
                return THEM_ONLY;
            }
            return THEM_PNP;
        }
    }

    private final File outputFile;
    private final int width;
    private final int height;
    private final int fps;
    private final Layout layout;
    private final int pnpSize;
    private final boolean stereo;

    private final HandlerThread thread;
    private Handler handler;

    private MediaCodec videoEncoder;
    private MediaCodec audioEncoder;
    private MediaMuxer muxer;
    private Surface inputSurface;
    private EglBase eglBase;
    private VideoFrameDrawer frameDrawer;
    private GlRectDrawer glDrawer;

    private int videoTrackIndex = -1;
    private int audioTrackIndex = -1;
    private boolean muxerStarted;

    private final Object slotLock = new Object();
    private final Map<Integer, VideoFrame> slots = new HashMap<>();
    /** Per-slot arrival throttle — see submitFrame. Delivery-thread only, one thread per slot. */
    private final Map<Integer, Long> lastAcceptedNs = new ConcurrentHashMap<>();
    private final long frameIntervalNs;

    private final Queue<short[]> audioQueue = new ArrayDeque<>();
    private final Object audioLock = new Object();

    // THE ONE CLOCK ORIGIN. Both tracks start at zero and advance by their own natural rate —
    // video by the frame it is, audio by the samples it has written — so neither is derived
    // from wall time and they cannot drift apart. Reading a host clock per frame is what makes
    // a recording that is fine for twenty seconds and half a second out after ten minutes.
    private long videoFrameIndex;
    private long audioSamplesWritten;

    private volatile boolean videoUsable;
    private boolean stopped;
    private boolean loggedPreMuxerDrop;
    private boolean loggedAudioOverflow;

    CallVideoRecorder(String outputPath, int width, int height, int fps, String layoutName, int pnpSize,
            boolean stereo) {
        this.outputFile = new File(outputPath);
        // Even dimensions: H.264 cannot encode an odd width or height. Rounded here rather than
        // validated, because a caller that asked for 1081 wants a recording, not a refusal.
        this.width = Math.max(2, (width / 2) * 2);
        this.height = Math.max(2, (height / 2) * 2);
        this.fps = Math.max(1, fps);
        this.layout = Layout.from(layoutName);
        this.pnpSize = Math.max(0, pnpSize);
        this.stereo = stereo;
        this.frameIntervalNs = 1_000_000_000L / this.fps;
        this.thread = new HandlerThread("CallVideoRecorder");
    }

    boolean isVideoUsable() {
        return videoUsable;
    }

    String getOutputPath() {
        return outputFile.getAbsolutePath();
    }

    // ── Start ────────────────────────────────────────────────────────────────

    /** Opens the codecs, the muxer and the GL surface. Throws with the WAV path untouched. */
    void start() throws IOException {
        File parent = outputFile.getParentFile();
        if (parent != null) {
            parent.mkdirs();
        }
        if (outputFile.exists() && !outputFile.delete()) {
            throw new IOException("Cannot replace existing output file: " + outputFile);
        }

        // ~0.1 bits per pixel per frame: 1280x720@12 lands near 1.1 Mbps. Capped deliberately —
        // this file is written alongside a WAV of comparable size and then uploaded, so the
        // codec's idea of a good bitrate is the wrong trade for a phone on a metered network.
        int videoBitRate = (int) (width * (long) height * fps * 0.1);
        MediaFormat videoFormat = MediaFormat.createVideoFormat(VIDEO_MIME, width, height);
        videoFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        videoFormat.setInteger(MediaFormat.KEY_BIT_RATE, videoBitRate);
        videoFormat.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
        videoFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);

        videoEncoder = MediaCodec.createEncoderByType(VIDEO_MIME);
        videoEncoder.configure(videoFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        inputSurface = videoEncoder.createInputSurface();
        videoEncoder.start();

        MediaFormat audioFormat = MediaFormat.createAudioFormat(AUDIO_MIME, SAMPLE_RATE, stereo ? 2 : 1);
        audioFormat.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
        audioFormat.setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE);
        audioEncoder = MediaCodec.createEncoderByType(AUDIO_MIME);
        audioEncoder.configure(audioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        audioEncoder.start();

        muxer = new MediaMuxer(outputFile.getAbsolutePath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);

        thread.start();
        handler = new Handler(thread.getLooper());
        videoUsable = true;

        // GL setup must happen ON the thread that will draw: an EGL context is current to one
        // thread, and making it current here would leave the tick unable to use it.
        handler.post(() -> {
            try {
                EglBase.Context sharedContext = EglUtils.getRootEglBaseContext();
                eglBase = sharedContext != null ? EglBase.create(sharedContext, EglBase.CONFIG_RECORDABLE)
                                                : EglBase.create(null, EglBase.CONFIG_RECORDABLE);
                eglBase.createSurface(inputSurface);
                eglBase.makeCurrent();
                frameDrawer = new VideoFrameDrawer();
                glDrawer = new GlRectDrawer();
            } catch (RuntimeException e) {
                Log.w(TAG, "video: GL setup failed — continuing audio-only", e);
                videoUsable = false;
            }
        });
        scheduleTick();
        Log.i(TAG, "video: started " + width + "x" + height + " @" + fps + "fps layout=" + layout + " -> "
                + outputFile.getName());
    }

    private void scheduleTick() {
        if (handler == null) {
            return;
        }
        handler.postDelayed(this::tick, Math.max(1, 1000 / fps));
    }

    // ── Sources ──────────────────────────────────────────────────────────────

    /**
     * Latest frame for a slot, called on the delivering thread (a capturer's or decoder's
     * SurfaceTextureHelper thread, with its EGL context current).
     *
     * COPIES THE PIXELS AND HOLDS THE COPY. NEVER RETAINS THE FRAME IT WAS GIVEN. That is not
     * a style choice — it is the difference between a recording and a still image.
     *
     * SurfaceTextureHelper owns exactly ONE texture and a single `isTextureInUse` flag: it
     * will not call updateTexImage for the next frame until the current one is released. A
     * "latest frame wins" slot that retains its frame therefore holds that flag forever — the
     * replacement it is waiting for can never arrive, because it is the thing blocking it.
     * The first frame of the call is then composited for the whole recording, which plays as
     * a perfectly valid video of a single motionless picture.
     *
     * toI420() is the escape: on a texture buffer it reads the pixels back (legal here, and
     * only here, because this thread holds the right EGL context) and frees the texture; on a
     * software buffer it is a cheap retain of the same memory. One code path, correct for
     * both, and it makes this platform match iOS — which converts at submit time for the same
     * reason and has never shown the bug.
     */
    void submitFrame(VideoFrame frame, int slot) {
        if (!videoUsable || frame == null) {
            return;
        }
        // THROTTLED TO THE COMPOSITE RATE. A source delivering at 30fps into a 12fps
        // recording would otherwise pay for a full-frame readback on two frames out of every
        // three that are never drawn. Per slot, because sources arrive independently.
        long now = System.nanoTime();
        Long last = lastAcceptedNs.get(slot);
        if (last != null && now - last < frameIntervalNs) {
            return;
        }
        lastAcceptedNs.put(slot, now);

        VideoFrame.Buffer copied;
        try {
            copied = frame.getBuffer().toI420();
        } catch (RuntimeException e) {
            // A readback can fail while a context is being torn down. Skipping one frame is
            // a dropped frame; letting it throw would take the delivery thread with it.
            return;
        }
        if (copied == null) {
            return;
        }
        // The VideoFrame takes ownership of the buffer's reference, so releasing the frame
        // below releases the pixels with it.
        VideoFrame owned = new VideoFrame(copied, frame.getRotation(), frame.getTimestampNs());

        VideoFrame previous;
        synchronized (slotLock) {
            previous = slots.put(slot, owned);
        }
        if (previous != null) {
            previous.release();
        }
    }

    /** Forget a slot's picture — its area draws black from the next tick. */
    void clearSlot(int slot) {
        VideoFrame previous;
        synchronized (slotLock) {
            previous = slots.remove(slot);
        }
        // Dropped with the picture so a track re-attached to this slot is not throttled by
        // the departed one's timestamp — worth at most one frame, but the stale entry would
        // otherwise outlive everything it describes.
        lastAcceptedNs.remove(slot);
        if (previous != null) {
            previous.release();
        }
    }

    // ── Audio, from CallAudioRecorder's mixer ────────────────────────────────

    @Override
    public void onMixedTick(short[] interleaved, int totalSamples) {
        if (!videoUsable || stopped || totalSamples <= 0) {
            return;
        }
        // COPIED because the caller's array is its per-tick scratch and is overwritten 100
        // times a second; queueing the reference would encode whatever the mixer wrote next.
        short[] copy = new short[totalSamples];
        System.arraycopy(interleaved, 0, copy, 0, totalSamples);
        synchronized (audioLock) {
            if (audioQueue.size() >= MAX_QUEUED_AUDIO_TICKS) {
                if (!loggedAudioOverflow) {
                    loggedAudioOverflow = true;
                    Log.w(TAG, "video: audio queue full — mp4 audio will have a gap");
                }
                return;
            }
            audioQueue.add(copy);
        }
    }

    // ── The tick ─────────────────────────────────────────────────────────────

    /** Draws one output frame, feeds the audio encoder, and drains both codecs. */
    private void tick() {
        if (stopped) {
            return;
        }
        try {
            if (videoUsable && eglBase != null) {
                drawComposite();
            }
            feedAudioEncoder();
            drainEncoder(videoEncoder, true);
            drainEncoder(audioEncoder, false);
        } catch (RuntimeException e) {
            // ANY codec/GL failure disables video and leaves the audio recorder running: the
            // .m4a it is already writing becomes the artifact, and stop reports withVideo false.
            Log.w(TAG, "video: tick failed — continuing audio-only", e);
            videoUsable = false;
        }
        scheduleTick();
    }

    /**
     * One composited frame.
     *
     * Linear on purpose: each layout is two or three lines of viewport arithmetic, and splitting
     * them into per-layout methods would be four one-caller functions and a dispatch to read
     * instead of a switch you can see all of at once.
     *
     * GL's origin is BOTTOM-LEFT, so a "top-left" inset sits at height - size - margin.
     */
    private void drawComposite() {
        VideoFrame local;
        VideoFrame remote;
        synchronized (slotLock) {
            local = slots.get(LOCAL_SLOT);
            remote = slots.get(0);
            if (local != null) {
                local.retain();
            }
            if (remote != null) {
                remote.retain();
            }
        }

        GLES20.glClearColor(0f, 0f, 0f, 1f);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);

        switch (layout) {
            case US_ONLY:
                drawCover(local, 0, 0, width, height);
                break;
            case THEM_ONLY:
                drawCover(remote, 0, 0, width, height);
                break;
            case SIDE_BY_SIDE: {
                // The caller sends the ALREADY-DOUBLED width, matching the web compositor's
                // canvas, so the split is this frame's own halves. Us left, them right — the
                // same order the web draws, so a recording reads the same whichever client
                // made it.
                int half = width / 2;
                drawCover(local, 0, 0, half, height);
                drawCover(remote, half, 0, half, height);
                break;
            }
            case THEM_PNP:
            default:
                drawCover(remote, 0, 0, width, height);
                if (local != null && pnpSize > 0) {
                    drawCover(local, 10, height - pnpSize - 10, pnpSize, pnpSize);
                }
                break;
        }

        // PTS from the frame index, never from a host clock — see the clock note above.
        long presentationNs = videoFrameIndex * 1_000_000_000L / fps;
        eglBase.swapBuffers(presentationNs);
        videoFrameIndex++;

        if (local != null) {
            local.release();
        }
        if (remote != null) {
            remote.release();
        }
    }

    /**
     * Draws one source scaled to FILL its viewport and cropped — no letterbox bars, matching the
     * web compositor's drawCover.
     *
     * getLayoutMatrix is what produces the crop, and it is also why rotation needs no handling
     * here: drawFrame applies the frame's own rotation, and getRotatedWidth/Height give the
     * aspect AFTER it. Feed it the unrotated aspect and a portrait camera records stretched.
     */
    private void drawCover(VideoFrame frame, int x, int y, int w, int h) {
        if (frame == null || w <= 0 || h <= 0) {
            return; // no picture for this slot — the cleared black surface shows through
        }
        int rotatedWidth = frame.getRotatedWidth();
        int rotatedHeight = frame.getRotatedHeight();
        if (rotatedWidth <= 0 || rotatedHeight <= 0) {
            return;
        }
        Matrix crop = RendererCommon.convertMatrixToAndroidGraphicsMatrix(RendererCommon.getLayoutMatrix(
                false, (float) rotatedWidth / rotatedHeight, (float) w / h));
        frameDrawer.drawFrame(frame, glDrawer, crop, x, y, w, h);
    }

    private void feedAudioEncoder() {
        while (true) {
            short[] pcm;
            synchronized (audioLock) {
                pcm = audioQueue.poll();
            }
            if (pcm == null) {
                return;
            }
            int index = audioEncoder.dequeueInputBuffer(CODEC_TIMEOUT_US);
            if (index < 0) {
                return; // encoder full; the tick will try again in 1/fps
            }
            ByteBuffer buffer = audioEncoder.getInputBuffer(index);
            if (buffer == null) {
                return;
            }
            buffer.clear();
            for (short sample : pcm) {
                buffer.putShort(sample);
            }
            int channels = stereo ? 2 : 1;
            long frames = pcm.length / channels;
            long ptsUs = audioSamplesWritten * 1_000_000L / SAMPLE_RATE;
            audioEncoder.queueInputBuffer(index, 0, pcm.length * 2, ptsUs, 0);
            audioSamplesWritten += frames;
        }
    }

    /**
     * Moves whatever each encoder has ready into the muxer.
     *
     * THE MUXER CANNOT START UNTIL BOTH TRACKS ARE ADDED, and a track's format only exists once
     * its encoder has emitted INFO_OUTPUT_FORMAT_CHANGED. So encoded buffers that arrive before
     * the second format does are DROPPED rather than written. This is the classic MediaMuxer
     * trap: write before start and it throws; add a track after start and it throws. Both
     * encoders emit their format within the first few frames, and both are dropped over the
     * same window, so the file simply begins a few tens of milliseconds in with no A/V offset.
     */
    private void drainEncoder(MediaCodec encoder, boolean isVideo) {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (true) {
            int index = encoder.dequeueOutputBuffer(info, CODEC_TIMEOUT_US);
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                return;
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                MediaFormat format = encoder.getOutputFormat();
                if (isVideo) {
                    videoTrackIndex = muxer.addTrack(format);
                } else {
                    audioTrackIndex = muxer.addTrack(format);
                }
                if (!muxerStarted && videoTrackIndex >= 0 && audioTrackIndex >= 0) {
                    muxer.start();
                    muxerStarted = true;
                }
                continue;
            }
            if (index < 0) {
                continue;
            }

            ByteBuffer encoded = encoder.getOutputBuffer(index);
            // The codec-config buffer carries SPS/PPS, which addTrack already took from the
            // output format. Writing it as a sample corrupts the track on some devices.
            boolean isConfig = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
            if (encoded != null && info.size > 0 && !isConfig) {
                if (muxerStarted) {
                    encoded.position(info.offset);
                    encoded.limit(info.offset + info.size);
                    muxer.writeSampleData(isVideo ? videoTrackIndex : audioTrackIndex, encoded, info);
                } else if (!loggedPreMuxerDrop) {
                    loggedPreMuxerDrop = true;
                    Log.i(TAG, "video: dropping encoded data until both tracks have a format");
                }
            }
            encoder.releaseOutputBuffer(index, false);
            if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                return;
            }
        }
    }

    // ── Stop ─────────────────────────────────────────────────────────────────

    /**
     * Finishes the mp4. Returns the file's stats, or null when nothing usable was written — in
     * which case the caller falls back to the audio recorder's .m4a.
     *
     * BLOCKING, and expected on a background executor: it drains both encoders and closes the
     * muxer, which for a long segment is not instant. The JS side's finalize timeout is sized
     * for exactly this.
     */
    AacEncoder.Result stopAndFinalize() {
        if (stopped) {
            return null;
        }
        stopped = true;

        // Everything below touches the codecs, so it has to run on their thread. The caller is
        // already off the main thread and waits, which keeps the ordering obvious.
        final Object done = new Object();
        final boolean[] finished = {false};
        if (handler != null) {
            handler.post(() -> {
                try {
                    if (videoUsable && videoEncoder != null) {
                        videoEncoder.signalEndOfInputStream();
                        drainEncoder(videoEncoder, true);
                    }
                    feedAudioEncoder();
                    drainEncoder(audioEncoder, false);
                } catch (RuntimeException e) {
                    Log.w(TAG, "video: drain on stop failed", e);
                    videoUsable = false;
                }
                synchronized (done) {
                    finished[0] = true;
                    done.notifyAll();
                }
            });
            synchronized (done) {
                long deadline = System.currentTimeMillis() + 5000;
                while (!finished[0] && System.currentTimeMillis() < deadline) {
                    try {
                        done.wait(250);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            }
        }

        boolean wroteAnything = muxerStarted && videoFrameIndex > 0 && videoUsable;
        releaseEverything();

        if (!wroteAnything) {
            // Say nothing was produced rather than leave a file with an empty video track: that
            // plays as a black rectangle and reads as a compositor bug instead of a codec that
            // never came up.
            videoUsable = false;
            if (outputFile.exists() && !outputFile.delete()) {
                Log.w(TAG, "video: could not delete unusable " + outputFile);
            }
            return null;
        }
        long durationMs = videoFrameIndex * 1000L / fps;
        return new AacEncoder.Result(durationMs, outputFile.length());
    }

    private void releaseEverything() {
        if (handler != null) {
            // GL teardown must run on the thread that made the context current.
            final Object done = new Object();
            final boolean[] finished = {false};
            handler.post(() -> {
                try {
                    if (frameDrawer != null) {
                        frameDrawer.release();
                    }
                    if (glDrawer != null) {
                        glDrawer.release();
                    }
                    if (eglBase != null) {
                        eglBase.release();
                    }
                } catch (RuntimeException e) {
                    Log.w(TAG, "video: GL teardown failed", e);
                }
                synchronized (done) {
                    finished[0] = true;
                    done.notifyAll();
                }
            });
            synchronized (done) {
                try {
                    if (!finished[0]) {
                        done.wait(2000);
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        }
        frameDrawer = null;
        glDrawer = null;
        eglBase = null;

        synchronized (slotLock) {
            for (VideoFrame frame : slots.values()) {
                frame.release();
            }
            slots.clear();
        }
        synchronized (audioLock) {
            audioQueue.clear();
        }

        // Each release is guarded on its own: one throwing must not skip the rest, or the
        // codec stays claimed and the NEXT recording on this device cannot start.
        try {
            if (videoEncoder != null) {
                videoEncoder.stop();
                videoEncoder.release();
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "video: video encoder release failed", e);
        }
        try {
            if (audioEncoder != null) {
                audioEncoder.stop();
                audioEncoder.release();
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "video: audio encoder release failed", e);
        }
        try {
            if (inputSurface != null) {
                inputSurface.release();
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "video: surface release failed", e);
        }
        try {
            if (muxer != null) {
                if (muxerStarted) {
                    muxer.stop();
                }
                muxer.release();
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "video: muxer release failed", e);
        }
        videoEncoder = null;
        audioEncoder = null;
        inputSurface = null;
        muxer = null;
        thread.quitSafely();
        handler = null;
    }
}
