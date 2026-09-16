package com.oney.WebRTCModule.filesource;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMetadataRetriever;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;

import com.oney.WebRTCModule.audio.ConferenceAudioBus;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayDeque;

/**
 * The Android file engine: a video FILE decoded into the capturer's Surface, with its soundtrack
 * pushed onto the native conference bus as an AUX source. The mirror of iOS's FileFrameSource.
 *
 * THE PLAYER IS THE CLOCK. {@link MediaPlayer} renders the video into the SurfaceTextureHelper's
 * Surface (the same seam ScreenCapturerAndroid and ViewFrameCapturer use) and owns play / pause /
 * seek / completion. Its OWN audio output is muted: the presenter hears the file through WebRTC's
 * render hook (ConferenceMixManager.HostRenderMixer), which is what keeps the file inside the echo
 * canceller's reference on a loudspeaker. The soundtrack the far end and the render hook receive
 * comes from a SECOND, audio-only decode ({@link AudioFeeder}: MediaExtractor + MediaCodec → PCM)
 * paced against the player's position — so both halves follow one clock, and decoding the audio
 * twice is the price of not adding a player dependency.
 *
 * TWO PAUSE FLAGS, INDEPENDENT. `userPaused` is the presenter's; `suspended` is the track being
 * disabled (the SDK disables every sender track on hold). Playing ⇔ neither and not ended.
 *
 * Threading: transport calls arrive on the module executor; MediaPlayer is driven from there
 * (its callbacks land on the main looper). The feeder runs on its own HandlerThread. Nothing here
 * touches the SurfaceTextureHelper directly — the capturer owns that.
 */
public final class FileSource {
    private static final String TAG = "FileSource";
    private static final int PROGRESS_MS = 1000;

    /** Playback events for JS: {@code playing} / {@code paused} / {@code ended} / {@code progress} / {@code error}. */
    public interface Listener {
        void onEvent(String type, double positionSeconds, double durationSeconds, boolean playing, boolean ended, String extraKey, String extraValue);
        /** The file is gone for good (decode error): the track must end. */
        void onFatal();
    }

    /** Hold-frame control for the capturer: it re-emits its last frame while {@code hold}. */
    public interface HoldListener {
        void onHoldChanged(boolean hold);
    }

    private final Context context;
    private final Uri uri;
    private final String auxId;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ConferenceAudioBus bus = ConferenceAudioBus.getInstance();

    // Probed metadata
    private int width;
    private int height;
    private int rotation;
    private long durationMs;
    private boolean hasAudio;

    private MediaPlayer player;
    private AudioFeeder feeder;
    private Listener listener;
    private HoldListener holdListener;

    private volatile boolean userPaused = true;   // nothing plays until play (or autoplay)
    private volatile boolean suspended = true;    // no frames until the track's first startCapture
    private volatile boolean ended;
    private volatile boolean released;
    private boolean started;

    public FileSource(Context context, Uri uri, String auxId) {
        this.context = context.getApplicationContext();
        this.uri = uri;
        this.auxId = auxId;
    }

    public void setListener(Listener listener) {
        this.listener = listener;
    }

    public void setHoldListener(HoldListener holdListener) {
        this.holdListener = holdListener;
    }

    // =====================================================================
    // Probe
    // =====================================================================

    /** Read the metadata the caller needs before it can size the track. Throws if unreadable. */
    public void probe() throws IOException {
        MediaMetadataRetriever retriever = new MediaMetadataRetriever();
        try {
            retriever.setDataSource(context, uri);
            width = parseInt(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH));
            height = parseInt(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT));
            rotation = parseInt(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION));
            durationMs = parseInt(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
            hasAudio = "yes".equals(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO));
        } catch (RuntimeException e) {
            throw new IOException("Cannot read " + uri, e);
        } finally {
            try {
                retriever.release();
            } catch (Exception ignored) {
            }
        }
        // Some OEM retrievers (Samsung's SECMPEG4Extractor path, seen on an A52s) answer null for
        // the width/height keys on a content:// document while the file is perfectly decodable —
        // read the track format directly before declaring "no video track".
        if (width <= 0 || height <= 0) {
            probeWithExtractor();
        }
        Log.i(TAG, "probe " + uri + " -> " + width + "x" + height + " rot=" + rotation
                + " dur=" + durationMs + "ms audio=" + hasAudio);
        if (width <= 0 || height <= 0) {
            throw new IOException("No video track in " + uri);
        }
    }

    /** The MediaExtractor fallback for {@link #probe()}: dimensions from the video track's format. */
    private void probeWithExtractor() throws IOException {
        MediaExtractor extractor = new MediaExtractor();
        try {
            extractor.setDataSource(context, uri, null);
            boolean sawAudio = false;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat f = extractor.getTrackFormat(i);
                String mime = f.getString(MediaFormat.KEY_MIME);
                if (mime == null) continue;
                if (mime.startsWith("audio/")) sawAudio = true;
                if (mime.startsWith("video/") && width <= 0) {
                    width = f.containsKey(MediaFormat.KEY_WIDTH) ? f.getInteger(MediaFormat.KEY_WIDTH) : 0;
                    height = f.containsKey(MediaFormat.KEY_HEIGHT) ? f.getInteger(MediaFormat.KEY_HEIGHT) : 0;
                    if (rotation == 0 && f.containsKey(MediaFormat.KEY_ROTATION)) rotation = f.getInteger(MediaFormat.KEY_ROTATION);
                    if (durationMs <= 0 && f.containsKey(MediaFormat.KEY_DURATION)) durationMs = (int) (f.getLong(MediaFormat.KEY_DURATION) / 1000);
                }
            }
            if (!hasAudio) hasAudio = sawAudio;
        } catch (RuntimeException e) {
            throw new IOException("Cannot read " + uri, e);
        } finally {
            extractor.release();
        }
    }

    private static int parseInt(String s) {
        try {
            return s == null ? 0 : Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /** Decoded width, BEFORE rotation. */
    public int getWidth() { return width; }
    public int getHeight() { return height; }
    /** 0 / 90 / 180 / 270 from the container. */
    public int getRotation() { return rotation; }
    public double getDurationSeconds() { return durationMs / 1000.0; }
    public boolean hasAudio() { return hasAudio; }

    // =====================================================================
    // Start / transport
    // =====================================================================

    /**
     * Bind the player to the capturer's Surface and prepare it (synchronously — the caller is on
     * the module executor). Frames flow once {@link #setSuspended(boolean)} lifts the suspend.
     */
    public void start(Surface surface, boolean autoplay) throws IOException {
        if (released || started) {
            return;
        }
        started = true;
        MediaPlayer mp = new MediaPlayer();
        mp.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build());
        mp.setDataSource(context, uri);
        mp.setSurface(surface);
        // MUTED ON PURPOSE: the presenter's copy is played by the render hook (see class note).
        mp.setVolume(0f, 0f);
        mp.setOnCompletionListener(p -> onCompleted());
        mp.setOnErrorListener((p, what, extra) -> {
            onError("MediaPlayer error " + what + "/" + extra);
            return true;
        });
        mp.prepare();
        player = mp;

        if (hasAudio) {
            feeder = new AudioFeeder();
            feeder.start();
        }
        if (autoplay) {
            userPaused = false;
        }
        applyPlaybackState();
        mainHandler.postDelayed(progressTick, PROGRESS_MS);
    }

    private final Runnable progressTick = new Runnable() {
        @Override
        public void run() {
            if (released) {
                return;
            }
            if (shouldPlay()) {
                emit("progress", null, null);
            }
            mainHandler.postDelayed(this, PROGRESS_MS);
        }
    };

    private boolean shouldPlay() {
        return started && !released && !userPaused && !suspended && !ended;
    }

    /** The one place the player's state and the hold-frame mode are decided. */
    private synchronized void applyPlaybackState() {
        MediaPlayer mp = player;
        if (mp == null || released) {
            return;
        }
        final boolean playing = shouldPlay();
        try {
            if (playing && !mp.isPlaying()) {
                mp.start();
            } else if (!playing && mp.isPlaying()) {
                mp.pause();
            }
        } catch (IllegalStateException e) {
            Log.w(TAG, "applyPlaybackState", e);
        }
        if (feeder != null) {
            feeder.setRunning(playing);
        }
        HoldListener h = holdListener;
        if (h != null) {
            // Held (not suspended, not playing): the capturer keeps the last frame going out.
            h.onHoldChanged(!playing && !suspended);
        }
    }

    public void play() {
        if (ended) {
            // play() after the end means from the top, as the web's <video> does.
            ended = false;
            seekInternal(0);
        }
        userPaused = false;
        applyPlaybackState();
        emit("playing", null, null);
    }

    public void pause() {
        userPaused = true;
        applyPlaybackState();
        emit("paused", "reason", "user");
    }

    public void seekTo(double seconds) {
        final boolean wasEnded = ended;
        ended = false;
        seekInternal((long) Math.max(0, seconds * 1000));
        if (wasEnded) {
            applyPlaybackState();
        }
        emit("progress", null, null);
    }

    /**
     * The capturer's hold-frame nudge: make the paused player post one frame by seeking to where it
     * is, WITHOUT touching {@code ended} or {@code userPaused}. It must not be {@link #seekTo}: that
     * is the user's seek, it clears {@code ended}, and at end-of-stream that restarted the player on
     * the last few ms, which completed again, which held again — a ~270 ms restart loop for as long
     * as the file sat at EOF.
     */
    public void nudgeFrame() {
        MediaPlayer mp = player;
        if (mp == null || released) {
            return;
        }
        try {
            seekInternal(mp.getCurrentPosition());
        } catch (IllegalStateException e) {
            Log.w(TAG, "nudgeFrame", e);
        }
    }

    private void seekInternal(long positionMs) {
        MediaPlayer mp = player;
        if (mp == null || released) {
            return;
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                mp.seekTo(positionMs, MediaPlayer.SEEK_CLOSEST);
            } else {
                mp.seekTo((int) positionMs);
            }
        } catch (IllegalStateException e) {
            Log.w(TAG, "seekTo", e);
        }
        if (feeder != null) {
            feeder.seek(positionMs * 1000L);
        }
    }

    /** The presenter's local volume 0..1 — the render hook's gain, never what the far end gets. */
    public void setLocalVolume(float volume) {
        bus.setAuxRenderGain(auxId, volume);
    }

    /** The track was disabled (true) or re-enabled (false): pause/resume without forgetting a user pause. */
    public void setSuspended(boolean suspend) {
        if (suspended == suspend) {
            return;
        }
        suspended = suspend;
        applyPlaybackState();
        if (suspend && !userPaused) {
            emit("paused", "reason", "suspended");
        } else if (!suspend && !userPaused && !ended) {
            emit("playing", null, null);
        }
    }

    public double getPositionSeconds() {
        MediaPlayer mp = player;
        if (mp == null || released) {
            return 0;
        }
        try {
            return mp.getCurrentPosition() / 1000.0;
        } catch (IllegalStateException e) {
            return 0;
        }
    }

    public boolean isPlaying() { return shouldPlay(); }
    public boolean isEnded() { return ended; }

    private void onCompleted() {
        ended = true;
        applyPlaybackState();
        emit("ended", null, null);
    }

    private void onError(String message) {
        emit("error", "message", message);
        Listener l = listener;
        if (l != null) {
            l.onFatal();
        }
    }

    private void emit(String type, String extraKey, String extraValue) {
        Listener l = listener;
        if (l == null || released) {
            return;
        }
        l.onEvent(type, getPositionSeconds(), getDurationSeconds(), shouldPlay(), ended, extraKey, extraValue);
    }

    /** Release everything: the player, the feeder, the aux. Idempotent. */
    public synchronized void release() {
        if (released) {
            return;
        }
        released = true;
        mainHandler.removeCallbacks(progressTick);
        if (feeder != null) {
            feeder.shutdown();
            feeder = null;
        }
        MediaPlayer mp = player;
        player = null;
        if (mp != null) {
            try {
                mp.setOnCompletionListener(null);
                mp.setOnErrorListener(null);
                mp.stop();
            } catch (IllegalStateException ignored) {
            }
            mp.release();
        }
        bus.removeAux(auxId);
    }

    // =====================================================================
    // The audio feeder: a second, audio-only decode paced by the player's clock
    // =====================================================================

    /**
     * MediaExtractor + MediaCodec on the file's audio track → PCM chunks in a small FIFO →
     * pushed onto the bus as they come DUE against MediaPlayer.getCurrentPosition(). Decodes
     * up to {@link #LEAD_US} ahead so a chunk is always ready, drops what falls behind after a
     * seek, and stops pushing while the player is paused.
     */
    private final class AudioFeeder implements Runnable {
        private static final long TICK_MS = 20;
        private static final long LEAD_US = 300_000;      // decode-ahead
        private static final long LATE_US = 250_000;      // behind by more than this: drop (resync)
        private static final long TIMEOUT_US = 5_000;

        private final HandlerThread thread = new HandlerThread("FileSource-audio");
        private Handler handler;
        private MediaExtractor extractor;
        private MediaCodec codec;
        private int sampleRate = 48000;
        private int channels = 1;
        private boolean inputDone;
        private boolean outputDone;
        private volatile boolean running;
        private volatile boolean shutdown;
        private volatile long seekTargetUs = -1;
        private final ArrayDeque<Chunk> fifo = new ArrayDeque<>();
        private short[] scratch = new short[0];

        private final class Chunk {
            final long ptsUs;
            final short[] pcm;
            Chunk(long ptsUs, short[] pcm) { this.ptsUs = ptsUs; this.pcm = pcm; }
        }

        void start() {
            thread.start();
            handler = new Handler(thread.getLooper());
            handler.post(() -> {
                if (!open()) {
                    Log.w(TAG, "audio feeder could not open " + uri + " — the far end gets picture only");
                    return;
                }
                handler.postDelayed(this, TICK_MS);
            });
        }

        void setRunning(boolean on) {
            running = on;
        }

        void seek(long targetUs) {
            seekTargetUs = targetUs;
        }

        void shutdown() {
            shutdown = true;
            if (handler != null) {
                handler.post(this::close);
            }
            thread.quitSafely();
        }

        private boolean open() {
            try {
                extractor = new MediaExtractor();
                extractor.setDataSource(context, uri, null);
                int audioTrack = -1;
                MediaFormat format = null;
                for (int i = 0; i < extractor.getTrackCount(); i++) {
                    MediaFormat f = extractor.getTrackFormat(i);
                    String mime = f.getString(MediaFormat.KEY_MIME);
                    if (mime != null && mime.startsWith("audio/")) {
                        audioTrack = i;
                        format = f;
                        break;
                    }
                }
                if (audioTrack < 0 || format == null) {
                    return false;
                }
                extractor.selectTrack(audioTrack);
                format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT);
                codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME));
                codec.configure(format, null, null, 0);
                codec.start();
                sampleRate = format.containsKey(MediaFormat.KEY_SAMPLE_RATE) ? format.getInteger(MediaFormat.KEY_SAMPLE_RATE) : 48000;
                channels = format.containsKey(MediaFormat.KEY_CHANNEL_COUNT) ? format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) : 1;
                return true;
            } catch (Exception e) {
                Log.w(TAG, "audio feeder open failed", e);
                close();
                return false;
            }
        }

        private void close() {
            try {
                if (codec != null) {
                    codec.stop();
                    codec.release();
                }
            } catch (Exception ignored) {
            }
            codec = null;
            if (extractor != null) {
                extractor.release();
                extractor = null;
            }
            fifo.clear();
        }

        @Override
        public void run() {
            if (shutdown || codec == null) {
                return;
            }
            try {
                applySeekIfAny();
                topUp();
                pushDue();
            } catch (Exception e) {
                Log.w(TAG, "audio feeder tick", e);
            }
            if (!shutdown) {
                handler.postDelayed(this, TICK_MS);
            }
        }

        private long playerPositionUs() {
            MediaPlayer mp = player;
            if (mp == null) {
                return 0;
            }
            try {
                return mp.getCurrentPosition() * 1000L;
            } catch (IllegalStateException e) {
                return 0;
            }
        }

        private void applySeekIfAny() {
            long target = seekTargetUs;
            if (target < 0) {
                return;
            }
            seekTargetUs = -1;
            fifo.clear();
            codec.flush();
            extractor.seekTo(target, MediaExtractor.SEEK_TO_PREVIOUS_SYNC);
            inputDone = false;
            outputDone = false;
        }

        /** Decode until the FIFO reaches LEAD_US past the player's position (or EOF). */
        private void topUp() {
            final long horizon = playerPositionUs() + LEAD_US;
            int guard = 0;
            while (!outputDone && guard++ < 64) {
                Chunk last = fifo.peekLast();
                if (last != null && last.ptsUs >= horizon) {
                    return;
                }
                if (!inputDone) {
                    int in = codec.dequeueInputBuffer(TIMEOUT_US);
                    if (in >= 0) {
                        ByteBuffer buf = codec.getInputBuffer(in);
                        int n = buf == null ? -1 : extractor.readSampleData(buf, 0);
                        if (n < 0) {
                            codec.queueInputBuffer(in, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputDone = true;
                        } else {
                            codec.queueInputBuffer(in, 0, n, extractor.getSampleTime(), 0);
                            extractor.advance();
                        }
                    }
                }
                MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
                int out = codec.dequeueOutputBuffer(info, TIMEOUT_US);
                if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat f = codec.getOutputFormat();
                    sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE);
                    channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
                    continue;
                }
                if (out < 0) {
                    if (inputDone) {
                        // Nothing more will come this tick; the EOS output arrives on a later one.
                        return;
                    }
                    continue;
                }
                if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    outputDone = true;
                }
                if (info.size > 0) {
                    ByteBuffer buf = codec.getOutputBuffer(out);
                    if (buf != null) {
                        int samples = info.size / 2;
                        short[] pcm = new short[samples];
                        buf.position(info.offset);
                        buf.order(java.nio.ByteOrder.nativeOrder()).asShortBuffer().get(pcm, 0, samples);
                        fifo.addLast(new Chunk(info.presentationTimeUs, pcm));
                    }
                }
                codec.releaseOutputBuffer(out, false);
            }
        }

        /** Push every chunk that is due against the player's clock; drop what is hopelessly late. */
        private void pushDue() {
            if (!running) {
                return;
            }
            final long now = playerPositionUs();
            Chunk c;
            while ((c = fifo.peekFirst()) != null) {
                if (c.ptsUs > now + TICK_MS * 1000L) {
                    return;   // not due yet
                }
                fifo.pollFirst();
                if (c.ptsUs < now - LATE_US) {
                    continue; // behind after a seek/stall: drop rather than smear old audio
                }
                bus.pushAux(auxId, c.pcm, c.pcm.length, sampleRate, channels);
            }
        }
    }
}
