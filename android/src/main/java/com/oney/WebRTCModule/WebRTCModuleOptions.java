package com.oney.WebRTCModule;

import org.webrtc.Loggable;
import org.webrtc.Logging;
import org.webrtc.VideoDecoderFactory;
import org.webrtc.VideoEncoderFactory;
import org.webrtc.audio.AudioDeviceModule;

public class WebRTCModuleOptions {
    private static WebRTCModuleOptions instance;

    public VideoEncoderFactory videoEncoderFactory;
    public VideoDecoderFactory videoDecoderFactory;
    public AudioDeviceModule audioDeviceModule;
    public Loggable injectableLogger;
    public Logging.Severity loggingSeverity;
    public String fieldTrials;
    /**
     * Whether getDisplayMedia() starts the bundled MediaProjectionService.
     *
     * ON BY DEFAULT in this fork (upstream: off). The manifest declares the service and its
     * permissions either way, so the flag never changed what the app declares - only whether
     * screen capture could work at all on Android 10+, which needs that foreground service
     * running before MediaProjection hands over the screen. Off, the service silently declined
     * to start and the capture failed with a SecurityException three frames later. An app that
     * must not screen-share sets this false in Application.onCreate, before the bridge starts.
     */
    public boolean enableMediaProjectionService = true;

    public static WebRTCModuleOptions getInstance() {
        if (instance == null) {
            instance = new WebRTCModuleOptions();
        }

        return instance;
    }
}
