package com.oney.WebRTCModule.audiorecorder;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;

/**
 * Streaming 48 kHz 16-bit PCM WAV writer, mono or stereo.
 *
 * The canonical 44-byte header is written up front with zero-size placeholders so that a
 * recording interrupted by a crash leaves a file whose true data size can be recovered from
 * the file length alone (see {@link #salvage(File)}).
 *
 * Only the header knows the channel count: {@link #append} takes already-interleaved
 * samples, so the mixer decides the layout and the encoder reads it back with
 * {@link #readChannels(File)}.
 */
final class WavFileWriter {
    static final int HEADER_SIZE = 44;
    static final int SAMPLE_RATE = 48000;
    static final int BYTES_PER_SAMPLE = 2;
    /** fmt-chunk channel-count field, little-endian u16. */
    private static final int CHANNELS_OFFSET = 22;

    private final RandomAccessFile raf;
    private final int channels;
    private long dataBytes;
    private byte[] byteScratch = new byte[0];

    WavFileWriter(File file, int channels) throws IOException {
        this.channels = channels;
        raf = new RandomAccessFile(file, "rw");
        raf.setLength(0);
        raf.write(buildHeader(channels, 0));
    }

    /** Appends {@code count} 16-bit samples, already interleaved. Writer-thread only. */
    void append(short[] samples, int count) throws IOException {
        int bytes = count * 2;
        if (byteScratch.length < bytes) {
            byteScratch = new byte[bytes];
        }
        for (int i = 0; i < count; i++) {
            byteScratch[i * 2] = (byte) (samples[i] & 0xff);
            byteScratch[i * 2 + 1] = (byte) ((samples[i] >> 8) & 0xff);
        }
        raf.write(byteScratch, 0, bytes);
        dataBytes += bytes;
    }

    /** Patches the RIFF/data chunk sizes and closes the file. */
    void finalizeHeader() throws IOException {
        try {
            raf.seek(4);
            writeIntLe(raf, (int) (36 + dataBytes));
            raf.seek(40);
            writeIntLe(raf, (int) dataBytes);
        } finally {
            raf.close();
        }
    }

    /**
     * Repairs a WAV whose header sizes were never patched (app killed mid-recording) by
     * deriving the data size from the file length. Safe to run on an already-finalized file.
     * Rejects files that don't have this writer's canonical header layout.
     */
    static void salvage(File file) throws IOException {
        try (RandomAccessFile raf = new RandomAccessFile(file, "rw")) {
            long length = raf.length();
            if (length < HEADER_SIZE) {
                throw new IOException("Not a salvageable WAV (shorter than header): " + file);
            }
            byte[] header = new byte[HEADER_SIZE];
            raf.readFully(header);
            if (!matches(header, 0, "RIFF") || !matches(header, 8, "WAVE") || !matches(header, 36, "data")) {
                throw new IOException("Not a canonical recorder WAV: " + file);
            }
            // Whole frames only. A stereo file cut on a sample boundary keeps a trailing lone
            // sample, so the data chunk would claim a size that is not a whole number of
            // frames; the count comes from the header, so a mono WAV still salvages as before.
            int channels = (header[CHANNELS_OFFSET] & 0xff) | ((header[CHANNELS_OFFSET + 1] & 0xff) << 8);
            if (channels != 1 && channels != 2) {
                throw new IOException("Unsupported WAV channel count " + channels + ": " + file);
            }
            long dataBytes = length - HEADER_SIZE;
            dataBytes -= dataBytes % ((long) channels * BYTES_PER_SAMPLE);
            raf.seek(4);
            writeIntLe(raf, (int) (36 + dataBytes));
            raf.seek(40);
            writeIntLe(raf, (int) dataBytes);
        }
    }

    /**
     * Channel count from an existing recorder WAV. The encoder needs it to size frames, and
     * reading it back (rather than assuming) is what lets a mono WAV written by an older
     * build still salvage correctly after the recorder switched to stereo.
     */
    static int readChannels(File file) throws IOException {
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            if (raf.length() < HEADER_SIZE) {
                throw new IOException("Not a recorder WAV (shorter than header): " + file);
            }
            raf.seek(CHANNELS_OFFSET);
            int lo = raf.read();
            int hi = raf.read();
            int channels = (hi << 8) | lo;
            if (channels != 1 && channels != 2) {
                throw new IOException("Unsupported WAV channel count " + channels + ": " + file);
            }
            return channels;
        }
    }

    private static byte[] buildHeader(int channels, int dataBytes) {
        int blockAlign = channels * BYTES_PER_SAMPLE;
        byte[] h = new byte[HEADER_SIZE];
        putAscii(h, 0, "RIFF");
        putIntLe(h, 4, 36 + dataBytes);
        putAscii(h, 8, "WAVE");
        putAscii(h, 12, "fmt ");
        putIntLe(h, 16, 16); // fmt chunk size (PCM)
        putShortLe(h, 20, (short) 1); // audio format: PCM
        putShortLe(h, CHANNELS_OFFSET, (short) channels);
        putIntLe(h, 24, SAMPLE_RATE);
        putIntLe(h, 28, SAMPLE_RATE * blockAlign); // byte rate
        putShortLe(h, 32, (short) blockAlign);
        putShortLe(h, 34, (short) 16); // bits per sample
        putAscii(h, 36, "data");
        putIntLe(h, 40, dataBytes);
        return h;
    }

    private static boolean matches(byte[] buf, int offset, String ascii) {
        for (int i = 0; i < ascii.length(); i++) {
            if (buf[offset + i] != (byte) ascii.charAt(i)) {
                return false;
            }
        }
        return true;
    }

    private static void putAscii(byte[] buf, int offset, String ascii) {
        for (int i = 0; i < ascii.length(); i++) {
            buf[offset + i] = (byte) ascii.charAt(i);
        }
    }

    private static void putIntLe(byte[] buf, int offset, int v) {
        buf[offset] = (byte) (v & 0xff);
        buf[offset + 1] = (byte) ((v >> 8) & 0xff);
        buf[offset + 2] = (byte) ((v >> 16) & 0xff);
        buf[offset + 3] = (byte) ((v >> 24) & 0xff);
    }

    private static void putShortLe(byte[] buf, int offset, short v) {
        buf[offset] = (byte) (v & 0xff);
        buf[offset + 1] = (byte) ((v >> 8) & 0xff);
    }

    private static void writeIntLe(RandomAccessFile raf, int v) throws IOException {
        raf.write(v & 0xff);
        raf.write((v >> 8) & 0xff);
        raf.write((v >> 16) & 0xff);
        raf.write((v >> 24) & 0xff);
    }
}
