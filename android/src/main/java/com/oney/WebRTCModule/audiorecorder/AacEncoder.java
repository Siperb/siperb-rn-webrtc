package com.oney.WebRTCModule.audiorecorder;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;

/**
 * Offline WAV (mono 48 kHz 16-bit) to AAC-LC .m4a encoder. Blocking; run it on a
 * background executor, never on the WebRTC/module executor.
 */
final class AacEncoder {
    private static final String TAG = CallAudioRecordingManager.TAG;

    private static final int CHANNELS = 1;
    private static final int BIT_RATE = 64000;
    private static final long CODEC_TIMEOUT_US = 10000;
    private static final int PCM_CHUNK_BYTES = 8192;

    static final class Result {
        final long durationMs;
        final long sizeBytes;

        Result(long durationMs, long sizeBytes) {
            this.durationMs = durationMs;
            this.sizeBytes = sizeBytes;
        }
    }

    private AacEncoder() {}

    /**
     * Encodes the WAV's PCM payload into {@code m4aFile}. The PCM size is derived from the
     * file length, not the header, so an unpatched (crashed) header still encodes correctly.
     * On failure any partial .m4a is deleted and the WAV is left untouched for salvage.
     */
    static Result encode(File wavFile, File m4aFile) throws IOException {
        long pcmBytes = wavFile.length() - WavFileWriter.HEADER_SIZE;
        if (pcmBytes <= 0) {
            throw new IOException("WAV contains no audio data: " + wavFile);
        }
        if (m4aFile.exists() && !m4aFile.delete()) {
            throw new IOException("Cannot replace existing output file: " + m4aFile);
        }

        MediaCodec codec = null;
        MediaMuxer muxer = null;
        boolean muxerStarted = false;
        boolean success = false;
        try (FileInputStream in = new FileInputStream(wavFile)) {
            skipFully(in, WavFileWriter.HEADER_SIZE);

            MediaFormat format =
                    MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, WavFileWriter.SAMPLE_RATE, CHANNELS);
            format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
            format.setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE);
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, PCM_CHUNK_BYTES);

            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            codec.start();
            muxer = new MediaMuxer(m4aFile.getAbsolutePath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);

            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            byte[] readBuf = new byte[PCM_CHUNK_BYTES];
            long bytesQueued = 0;
            int trackIndex = -1;
            boolean inputDone = false;
            boolean outputDone = false;

            while (!outputDone) {
                if (!inputDone) {
                    int inIndex = codec.dequeueInputBuffer(CODEC_TIMEOUT_US);
                    if (inIndex >= 0) {
                        ByteBuffer inBuf = codec.getInputBuffer(inIndex);
                        int max = Math.min(inBuf.capacity(), readBuf.length);
                        int read = in.read(readBuf, 0, max);
                        // Presentation time derived from PCM position keeps timestamps
                        // monotonic and exact regardless of chunking.
                        long ptsUs = bytesQueued * 1_000_000L / (2L * WavFileWriter.SAMPLE_RATE);
                        if (read <= 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputDone = true;
                        } else {
                            inBuf.clear();
                            inBuf.put(readBuf, 0, read);
                            codec.queueInputBuffer(inIndex, 0, read, ptsUs, 0);
                            bytesQueued += read;
                        }
                    }
                }

                int outIndex = codec.dequeueOutputBuffer(info, CODEC_TIMEOUT_US);
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    if (muxerStarted) {
                        throw new IOException("AAC output format changed twice");
                    }
                    trackIndex = muxer.addTrack(codec.getOutputFormat());
                    muxer.start();
                    muxerStarted = true;
                } else if (outIndex >= 0) {
                    if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && info.size > 0) {
                        if (!muxerStarted) {
                            throw new IOException("AAC sample produced before output format");
                        }
                        ByteBuffer outBuf = codec.getOutputBuffer(outIndex);
                        outBuf.position(info.offset);
                        outBuf.limit(info.offset + info.size);
                        muxer.writeSampleData(trackIndex, outBuf, info);
                    }
                    codec.releaseOutputBuffer(outIndex, false);
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        outputDone = true;
                    }
                }
            }

            if (!muxerStarted) {
                throw new IOException("Encoder produced no AAC output");
            }
            // Stop in-band (not in finally) so a broken moov write surfaces as a failure.
            muxer.stop();
            muxerStarted = false;
            success = true;
        } catch (Exception e) {
            throw (e instanceof IOException) ? (IOException) e : new IOException("AAC encode failed", e);
        } finally {
            if (codec != null) {
                try {
                    codec.stop();
                } catch (Exception e) {
                    Log.w(TAG, "codec.stop() failed", e);
                }
                try {
                    codec.release();
                } catch (Exception e) {
                    Log.w(TAG, "codec.release() failed", e);
                }
            }
            if (muxer != null) {
                try {
                    if (muxerStarted) {
                        muxer.stop();
                    }
                } catch (Exception e) {
                    Log.w(TAG, "muxer.stop() failed", e);
                }
                try {
                    muxer.release();
                } catch (Exception e) {
                    Log.w(TAG, "muxer.release() failed", e);
                }
            }
            if (!success && m4aFile.exists() && !m4aFile.delete()) {
                Log.w(TAG, "Could not delete partial output " + m4aFile);
            }
        }

        long durationMs = (pcmBytes / 2) * 1000L / WavFileWriter.SAMPLE_RATE;
        return new Result(durationMs, m4aFile.length());
    }

    private static void skipFully(InputStream in, long bytes) throws IOException {
        long remaining = bytes;
        while (remaining > 0) {
            long skipped = in.skip(remaining);
            if (skipped <= 0) {
                throw new IOException("Unexpected EOF while skipping WAV header");
            }
            remaining -= skipped;
        }
    }
}
