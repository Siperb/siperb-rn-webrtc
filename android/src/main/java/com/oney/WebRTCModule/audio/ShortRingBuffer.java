package com.oney.WebRTCModule.audio;

/**
 * Bounded mono sample ring; oldest samples are dropped on overflow. Producer is an
 * audio thread, consumer is the writer thread; all state guarded by this.
 */
public final class ShortRingBuffer {
    private final short[] buf;
    private int head; // next read index
    private int size;

    public ShortRingBuffer(int capacity) {
        buf = new short[capacity];
    }

    public synchronized void write(short[] src, int off, int len) {
        int cap = buf.length;
        if (len >= cap) {
            // Keep only the newest full window.
            off += len - cap;
            len = cap;
            head = 0;
            size = 0;
        }
        int overflow = size + len - cap;
        if (overflow > 0) {
            head = (head + overflow) % cap;
            size -= overflow;
        }
        int tail = (head + size) % cap;
        int first = Math.min(len, cap - tail);
        System.arraycopy(src, off, buf, tail, first);
        if (first < len) {
            System.arraycopy(src, off + first, buf, 0, len - first);
        }
        size += len;
    }

    public synchronized int read(short[] dst, int off, int len) {
        int n = Math.min(len, size);
        int first = Math.min(n, buf.length - head);
        System.arraycopy(buf, head, dst, off, first);
        if (first < n) {
            System.arraycopy(buf, 0, dst, off + first, n - first);
        }
        head = (head + n) % buf.length;
        size -= n;
        return n;
    }

    /**
     * Drop everything buffered.
     *
     * Exists because a ring OUTLIVES the conference that filled it: the microphone source
     * is process-wide, so without this the first frames of a new conference would carry up
     * to half a second of audio captured during the previous one — sent to a party who was
     * never on that call.
     */
    public synchronized void clear() {
        head = 0;
        size = 0;
    }

    public synchronized int available() {
        return size;
    }
}
