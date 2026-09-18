package com.oney.WebRTCModule;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.projection.MediaProjectionManager;
import android.media.projection.MediaProjectionConfig;
import android.net.Uri;
import android.util.Base64;
import android.util.DisplayMetrics;
import android.util.Log;
import android.os.Build;
import android.view.View;

import androidx.core.util.Consumer;

import com.facebook.react.bridge.UIManager;
import com.facebook.react.bridge.UiThreadUtil;
import com.facebook.react.uimanager.UIManagerHelper;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.BaseActivityEventListener;
import com.facebook.react.bridge.Callback;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.ReadableType;
import com.facebook.react.bridge.UiThreadUtil;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;
import com.oney.WebRTCModule.videoEffects.ProcessorProvider;
import com.oney.WebRTCModule.videoEffects.VideoEffectProcessor;
import com.oney.WebRTCModule.videoEffects.VideoFrameProcessor;

import com.oney.WebRTCModule.filesource.FileSource;

import org.webrtc.*;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

/**
 * The implementation of {@code getUserMedia} extracted into a separate file in
 * order to reduce complexity and to (somewhat) separate concerns.
 */
class GetUserMediaImpl {
    /**
     * The {@link Log} tag with which {@code GetUserMediaImpl} is to log.
     */
    private static final String TAG = WebRTCModule.TAG;

    private static final int PERMISSION_REQUEST_CODE = (int) (Math.random() * Short.MAX_VALUE);

    private CameraEnumerator cameraEnumerator;
    private final ReactApplicationContext reactContext;

    /**
     * The application/library-specific private members of local
     * {@link MediaStreamTrack}s created by {@code GetUserMediaImpl} mapped by
     * track ID.
     */
    private final Map<String, TrackPrivate> tracks = new HashMap<>();

    private final WebRTCModule webRTCModule;

    private Promise displayMediaPromise;
    private Intent mediaProjectionPermissionResultData;
    private boolean createConfigForDefaultDisplay = false;
    private float resolutionScale = 1.0f;

    GetUserMediaImpl(WebRTCModule webRTCModule, ReactApplicationContext reactContext) {
        this.webRTCModule = webRTCModule;
        this.reactContext = reactContext;

        reactContext.addActivityEventListener(new BaseActivityEventListener() {
            @Override
            public void onActivityResult(Activity activity, int requestCode, int resultCode, Intent data) {
                super.onActivityResult(activity, requestCode, resultCode, data);
                if (requestCode == PERMISSION_REQUEST_CODE) {
                    // Guard against a duplicate onActivityResult dispatch. Some hosts (e.g.
                    // react-native-navigation) forward the activity result to every registered
                    // ActivityEventListener more than once, so this callback can fire twice for a
                    // single getDisplayMedia() request. The first pass consumes displayMediaPromise;
                    // a second pass would call reject()/resolve() on a null promise and crash.
                    if (displayMediaPromise == null) {
                        return;
                    }

                    if (resultCode != Activity.RESULT_OK) {
                        displayMediaPromise.reject("DOMException", "NotAllowedError");
                        displayMediaPromise = null;
                        return;
                    }

                    mediaProjectionPermissionResultData = data;

                    CompletableFuture<Void> launchFuture = MediaProjectionService.launch(activity);
                    // orTimeout is API 33+ (Android 13 added it to java.util.concurrent.CompletableFuture) and is NOT
                    // covered by core-library desugaring, so calling it unconditionally NoSuchMethodError-crashes on
                    // Android < 33. Keep the 10s safety timeout where it exists; on older Android skip it (the service
                    // launch completes on its own — the timeout is only a guard against a hung start).
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        launchFuture = launchFuture.orTimeout(10, TimeUnit.SECONDS);
                    }
                    launchFuture
                        .whenCompleteAsync((value, error) -> {
                            if (error != null) {
                                Log.e(TAG, "Failed to start MediaProjection service", error);
                                displayMediaPromise.reject("DOMException", "AbortError");
                                displayMediaPromise = null;
                                mediaProjectionPermissionResultData = null;
                                return;
                            }

                            createScreenStream();
                        }, ThreadUtils.getExecutor());
                }
            }
        });
    }

    private AudioTrack createAudioTrack(ReadableMap constraints) {
        ReadableMap audioConstraintsMap = constraints.getMap("audio");

        Log.d(TAG, "getUserMedia(audio): " + audioConstraintsMap);

        String id = UUID.randomUUID().toString();
        PeerConnectionFactory pcFactory = webRTCModule.mFactory;
        MediaConstraints peerConstraints = webRTCModule.constraintsForOptions(audioConstraintsMap);

        // PeerConnectionFactory.createAudioSource will throw an error when mandatory constraints contain nulls.
        // so, let's check for nulls
        checkMandatoryConstraints(peerConstraints);

        AudioSource audioSource = pcFactory.createAudioSource(peerConstraints);
        AudioTrack track = pcFactory.createAudioTrack(id, audioSource);

        // surfaceTextureHelper is initialized for videoTrack only, so its null here.
        tracks.put(id, new TrackPrivate(track, audioSource, /* videoCapturer */ null, /* surfaceTextureHelper */ null));

        return track;
    }

    private void checkMandatoryConstraints(MediaConstraints peerConstraints) {
        ArrayList<MediaConstraints.KeyValuePair> valid = new ArrayList<>(peerConstraints.mandatory.size());

        for (MediaConstraints.KeyValuePair constraint : peerConstraints.mandatory) {
            if (constraint.getValue() != null) {
                valid.add(constraint);
            } else {
                Log.d(TAG, String.format("constraint %s is null, ignoring it", constraint.getKey()));
            }
        }

        peerConstraints.mandatory.clear();
        peerConstraints.mandatory.addAll(valid);
    }

    private CameraEnumerator getCameraEnumerator() {
        if (cameraEnumerator == null) {
            if (Camera2Enumerator.isSupported(reactContext)) {
                Log.d(TAG, "Creating camera enumerator using the Camera2 API");
                cameraEnumerator = new Camera2Enumerator(reactContext);
            } else {
                Log.d(TAG, "Creating camera enumerator using the Camera1 API");
                cameraEnumerator = new Camera1Enumerator(false);
            }
        }

        return cameraEnumerator;
    }

    ReadableArray enumerateDevices() {
        WritableArray array = Arguments.createArray();
        String[] devices = getCameraEnumerator().getDeviceNames();

        for (int i = 0; i < devices.length; ++i) {
            String deviceName = devices[i];
            boolean isFrontFacing;
            try {
                // This can throw an exception when using the Camera 1 API.
                isFrontFacing = getCameraEnumerator().isFrontFacing(deviceName);
            } catch (Exception e) {
                Log.e(TAG, "Failed to check the facing mode of camera");
                continue;
            }
            WritableMap params = Arguments.createMap();
            params.putString("facing", isFrontFacing ? "front" : "environment");
            params.putString("deviceId", "" + i);
            params.putString("groupId", "");
            params.putString("label", deviceName);
            params.putString("kind", "videoinput");
            array.pushMap(params);
        }

        WritableMap audio = Arguments.createMap();
        audio.putString("deviceId", "audio-1");
        audio.putString("groupId", "");
        audio.putString("label", "Audio");
        audio.putString("kind", "audioinput");
        array.pushMap(audio);

        return array;
    }

    MediaStreamTrack getTrack(String id) {
        TrackPrivate private_ = tracks.get(id);

        return private_ == null ? null : private_.track;
    }

    /** Ids of the live local audio tracks, for microphone-state fan-out. Executor only. */
    List<String> getLocalAudioTrackIds() {
        List<String> ids = new ArrayList<>();
        for (Map.Entry<String, TrackPrivate> entry : tracks.entrySet()) {
            if (entry.getValue().track instanceof AudioTrack) {
                ids.add(entry.getKey());
            }
        }
        return ids;
    }

    /**
     * Implements {@code getUserMedia}. Note that at this point constraints have
     * been normalized and permissions have been granted. The constraints only
     * contain keys for which permissions have already been granted, that is,
     * if audio permission was not granted, there will be no "audio" key in
     * the constraints map.
     */
    void getUserMedia(final ReadableMap constraints, final Callback successCallback, final Callback errorCallback) {
        AudioTrack audioTrack = null;
        VideoTrack videoTrack = null;

        // Resolved BEFORE the audio track exists: with the check below the audio path, a
        // video call answered while no Activity is resumed (CallKit/ConnectionService in the
        // background) created and registered an audio track, then failed the whole request -
        // leaving a native track and source with no JS handle to ever release them.
        Activity currentActivity = null;
        if (constraints.hasKey("video")) {
            currentActivity = this.reactContext.getCurrentActivity();
            if (currentActivity == null) {
                errorCallback.invoke("Error", "No current Activity.");
                return;
            }
        }

        if (constraints.hasKey("audio")) {
            audioTrack = createAudioTrack(constraints);
        }

        if (constraints.hasKey("video")) {
            ReadableMap videoConstraintsMap = constraints.getMap("video");

            Log.d(TAG, "getUserMedia(video): " + videoConstraintsMap);

            CameraCaptureController cameraCaptureController = new CameraCaptureController(
                    currentActivity, getCameraEnumerator(), videoConstraintsMap);

            videoTrack = createVideoTrack(cameraCaptureController);
        }

        if (audioTrack == null && videoTrack == null) {
            // Fail with DOMException with name AbortError as per:
            // https://www.w3.org/TR/mediacapture-streams/#dom-mediadevices-getusermedia
            errorCallback.invoke("DOMException", "AbortError");
            return;
        }

        createStream(new MediaStreamTrack[] {audioTrack, videoTrack}, (streamId, tracksInfo) -> {
            WritableArray tracksInfoWritableArray = Arguments.createArray();

            for (WritableMap trackInfo : tracksInfo) {
                tracksInfoWritableArray.pushMap(trackInfo);
            }

            successCallback.invoke(streamId, tracksInfoWritableArray);
        });
    }

    void mediaStreamTrackSetEnabled(String trackId, final boolean enabled) {
        TrackPrivate track = tracks.get(trackId);
        if (track != null && track.videoCaptureController != null) {
            if (enabled) {
                track.videoCaptureController.startCapture();
            } else {
                track.videoCaptureController.stopCapture();
            }
        }
    }

    void disposeTrack(String id) {
        TrackPrivate track = tracks.remove(id);
        if (track != null) {
            track.dispose();
        }
    }

    void applyConstraints(String trackId, ReadableMap constraints, Promise promise) {
        TrackPrivate track = tracks.get(trackId);
        if (track != null && track.videoCaptureController instanceof AbstractVideoCaptureController) {
            AbstractVideoCaptureController captureController =
                    (AbstractVideoCaptureController) track.videoCaptureController;
            captureController.applyConstraints(constraints, new Consumer<Exception>() {
                public void accept(Exception e) {
                    if (e != null) {
                        promise.reject(e);
                        return;
                    }

                    promise.resolve(captureController.getSettings());
                }
            });
        } else {
            promise.reject(new Exception("Camera track not found!"));
        }
    }

    void initializeConstraints(ReadableMap constraints) {

        // Handle the incoming params

        ReadableMap androidConstraints = null;
        if (constraints.hasKey("android") && constraints.getType("android") == ReadableType.Map) {
            androidConstraints = constraints.getMap("android");
        }

        // Default values
        boolean createConfigForDefaultDisplay = false;
        float scale = 1.0f;

        if (androidConstraints != null) {
            // MediaProjectionConfig need API level 34
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
                && androidConstraints.hasKey("createConfigForDefaultDisplay")
                && androidConstraints.getType("createConfigForDefaultDisplay") == ReadableType.Boolean) {
                createConfigForDefaultDisplay = androidConstraints.getBoolean("createConfigForDefaultDisplay");
            }
            if (androidConstraints.hasKey("resolutionScale")
                && androidConstraints.getType("resolutionScale") == ReadableType.Number) {
                scale = (float) androidConstraints.getDouble("resolutionScale");
            }
        }

        this.createConfigForDefaultDisplay = createConfigForDefaultDisplay;
        // Force the value in [0, 1]
        this.resolutionScale = Math.max(0.0f, Math.min(1.0f, scale));

        Log.d(TAG, "initializeConstraints: createConfigForDefaultDisplay=" + this.createConfigForDefaultDisplay
            + " resolutionScale=" + this.resolutionScale);
    }

    void getDisplayMedia(final ReadableMap constraints, Promise promise) {
        if (this.displayMediaPromise != null) {
            promise.reject(new RuntimeException("Another operation is pending."));
            return;
        }

        Activity currentActivity = this.reactContext.getCurrentActivity();
        if (currentActivity == null) {
            promise.reject(new RuntimeException("No current Activity."));
            return;
        }

        this.initializeConstraints(constraints);

        this.displayMediaPromise = promise;

        MediaProjectionManager mediaProjectionManager =
                (MediaProjectionManager) currentActivity.getApplication().getSystemService(
                        Context.MEDIA_PROJECTION_SERVICE);

        if (mediaProjectionManager != null) {
            UiThreadUtil.runOnUiThread(new Runnable() {
                @Override
                public void run() {

                  if (createConfigForDefaultDisplay == true) {
                        //MediaProjectionConfig need API level 34
                        //Return mediaProjection which restricts the user to capturing the default display
                        currentActivity.startActivityForResult(
                            mediaProjectionManager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay()), PERMISSION_REQUEST_CODE);
                    } else {
                        //Return mediaProjection which allows the user to decide which region is captured
                        currentActivity.startActivityForResult(
                            mediaProjectionManager.createScreenCaptureIntent(), PERMISSION_REQUEST_CODE);
                    }
                }
            });

        } else {
            promise.reject(new RuntimeException("MediaProjectionManager is null."));
        }
    }

    private void createScreenStream() {
        // A duplicate onActivityResult dispatch (see onActivityResult above) can schedule this more
        // than once. The single-threaded executor runs them in order, so by the time a duplicate
        // runs the first has already consumed displayMediaPromise. Bail out instead of dereferencing
        // a null promise or creating a second screen stream.
        if (displayMediaPromise == null) {
            return;
        }

        VideoTrack track = createScreenTrack();

        if (track == null) {
            displayMediaPromise.reject(new RuntimeException("ScreenTrack is null."));
        } else {
            createStream(new MediaStreamTrack[] {track}, (streamId, tracksInfo) -> {
                WritableMap data = Arguments.createMap();

                data.putString("streamId", streamId);

                if (tracksInfo.size() == 0) {
                    displayMediaPromise.reject(new RuntimeException("No ScreenTrackInfo found."));
                } else {
                    data.putMap("track", tracksInfo.get(0));
                    displayMediaPromise.resolve(data);
                }
            });
        }

        // Cleanup
        mediaProjectionPermissionResultData = null;
        displayMediaPromise = null;
    }

    void createStream(MediaStreamTrack[] tracks, BiConsumer<String, ArrayList<WritableMap>> successCallback) {
        String streamId = UUID.randomUUID().toString();
        MediaStream mediaStream = webRTCModule.mFactory.createLocalMediaStream(streamId);

        ArrayList<WritableMap> tracksInfo = new ArrayList<>();

        for (MediaStreamTrack track : tracks) {
            if (track == null) {
                continue;
            }

            if (track instanceof AudioTrack) {
                mediaStream.addTrack((AudioTrack) track);
            } else {
                mediaStream.addTrack((VideoTrack) track);
            }

            WritableMap trackInfo = Arguments.createMap();
            String trackId = track.id();

            trackInfo.putBoolean("enabled", track.enabled());
            trackInfo.putString("id", trackId);
            trackInfo.putString("kind", track.kind());
            trackInfo.putString("readyState", "live");
            trackInfo.putBoolean("remote", false);

            if (track instanceof VideoTrack) {
                TrackPrivate tp = this.tracks.get(trackId);
                AbstractVideoCaptureController vcc = tp.videoCaptureController;
                trackInfo.putMap("settings", vcc.getSettings());
            }

            if (track instanceof AudioTrack) {
                WritableMap settings = Arguments.createMap();
                settings.putString("deviceId", "audio-1");
                settings.putString("groupId", "");
                trackInfo.putMap("settings", settings);
                // A track created while the microphone is failing is born muted; the ADM's
                // next successful start un-mutes it (MicCaptureStateEmitter).
                trackInfo.putBoolean("muted", webRTCModule.isMicCaptureMuted());
            }

            tracksInfo.add(trackInfo);
        }

        Log.d(TAG, "MediaStream id: " + streamId);
        webRTCModule.localStreams.put(streamId, mediaStream);

        successCallback.accept(streamId, tracksInfo);
    }

    private VideoTrack createScreenTrack() {
        DisplayMetrics displayMetrics = DisplayUtils.getDisplayMetrics(reactContext.getCurrentActivity());
        int width = displayMetrics.widthPixels;
        int height = displayMetrics.heightPixels;
        ScreenCaptureController screenCaptureController = new ScreenCaptureController(
                reactContext.getCurrentActivity(), width, height, mediaProjectionPermissionResultData, resolutionScale);
        return createVideoTrack(screenCaptureController);
    }

    // MARK: View / image frame source (whiteboard, picture)

    /** Longest side of a view/image source; a whiteboard needs sharpness, not 4K. */
    private static final int FRAME_SOURCE_MAX_SIDE = 720;

    /**
     * Fit {@code w}x{@code h} inside FRAME_SOURCE_MAX_SIDE, keeping aspect, both sides even (the
     * encoder wants even dimensions) and at least 2.
     */
    private static int[] fitFrameSource(int w, int h) {
        float scale = Math.min(1f, (float) FRAME_SOURCE_MAX_SIDE / Math.max(w, h));
        int fw = Math.max(2, ((int) (w * scale)) & ~1);
        int fh = Math.max(2, ((int) (h * scale)) & ~1);
        return new int[] {fw, fh};
    }

    /**
     * Resolve a stream whose one video track is a {@link ViewCaptureController} source; the shape
     * getDisplayMedia's caller already reads ({@code {streamId, track}}). A view track is NOT
     * born muted — frames flow from the first tick.
     */
    private void resolveFrameSourceTrack(VideoTrack track, Promise promise) {
        if (track == null) {
            promise.reject(new RuntimeException("Frame source track is null."));
            return;
        }
        createStream(new MediaStreamTrack[] {track}, (streamId, tracksInfo) -> {
            if (tracksInfo.size() == 0) {
                promise.reject(new RuntimeException("No frame source track info found."));
                return;
            }
            WritableMap data = Arguments.createMap();
            data.putString("streamId", streamId);
            data.putMap("track", tracksInfo.get(0));
            promise.resolve(data);
        });
    }

    /**
     * A video track whose frames are the native view with React tag {@code sourceTag} — the
     * whiteboard's canvas-that-streams. The view is resolved on the UI thread (the only thread
     * that may read it), then the track is built on the executor like every other local track,
     * so localTracks/localStreams are only ever written there.
     */
    void getWhiteboardMedia(int sourceTag, int fps, Promise promise) {
        // Architecture-neutral view lookup: `UIManagerHelper` hands back the Paper or the Fabric
        // UIManager for this tag, and both implement `resolveView`. The Paper-only
        // `UIManagerModule.addUIBlock` route rejected on every New Architecture app
        // ("UIManager unavailable"), which is what Siperb-Mobile runs.
        UiThreadUtil.runOnUiThread(() -> {
            View view = null;
            try {
                UIManager uiManager = UIManagerHelper.getUIManagerForReactTag(reactContext, sourceTag);
                view = uiManager == null ? null : uiManager.resolveView(sourceTag);
            } catch (Exception e) {
                Log.w(TAG, "getWhiteboardMedia: resolveView(" + sourceTag + ") failed", e);
            }
            // Native-host fallback: a Compose / Android-View drawing surface has no React tag, so it
            // registers its view in SiperbCaptureViewRegistry under the key it passes as sourceTag.
            // Only consulted when the React lookup misses, so an ordinary RN board is unaffected.
            if (view == null) {
                view = SiperbCaptureViewRegistry.viewForKey(sourceTag);
            }
            if (view == null) {
                promise.reject("NotFoundError", "No view for sourceTag " + sourceTag);
                return;
            }
            // Read the size on the UI thread too; an unlaid-out view (0x0) gets a portrait default
            // rather than a 2x2 stream nobody can see.
            int vw = view.getWidth();
            int vh = view.getHeight();
            int[] size = (vw > 0 && vh > 0) ? fitFrameSource(vw, vh) : new int[] {720, 1280};
            final View target = view;
            ThreadUtils.runOnExecutor(() -> {
                ViewCaptureController controller =
                        new ViewCaptureController(size[0], size[1], fps > 0 ? fps : 10, target);
                resolveFrameSourceTrack(createVideoTrack(controller), promise);
            });
        });
    }

    /**
     * A video track that re-emits one still image decoded from {@code uri} — data: URI, file
     * path / file:// URI, or content:// URI. Runs entirely on the executor.
     */
    void getPictureMedia(String uri, int fps, Promise promise) {
        Bitmap bitmap = decodeImage(uri);
        if (bitmap == null) {
            promise.reject("NotSupportedError", "Could not decode image: " + uri);
            return;
        }
        int[] size = fitFrameSource(bitmap.getWidth(), bitmap.getHeight());
        ViewCaptureController controller =
                new ViewCaptureController(size[0], size[1], fps > 0 ? fps : 2, bitmap);
        resolveFrameSourceTrack(createVideoTrack(controller), promise);
    }

    private Bitmap decodeImage(String uri) {
        if (uri == null || uri.isEmpty()) {
            return null;
        }
        try {
            if (uri.startsWith("data:")) {
                int comma = uri.indexOf(',');
                if (comma < 0) {
                    return null;
                }
                byte[] bytes = Base64.decode(uri.substring(comma + 1), Base64.DEFAULT);
                return BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            }
            if (uri.startsWith("content:")) {
                try (java.io.InputStream in = reactContext.getContentResolver().openInputStream(Uri.parse(uri))) {
                    return in == null ? null : BitmapFactory.decodeStream(in);
                }
            }
            String path = uri.startsWith("file://") ? Uri.parse(uri).getPath() : uri;
            return path == null ? null : BitmapFactory.decodeFile(path);
        } catch (Exception e) {
            Log.w(TAG, "decodeImage failed for " + uri, e);
            return null;
        }
    }

    // MARK: File source (a presented video file)

    /**
     * A video track whose frames are a video FILE decoded by a {@link FileCaptureController},
     * with the soundtrack pushed onto the conference bus as an AUX keyed by the track's id. The
     * resolved shape adds {@code audio} (null when the file has none), {@code duration},
     * {@code width}/{@code height} to the frame-source one. Runs on the executor.
     */
    void getFileMedia(String uri, int fps, int maxSide, boolean autoplay, Promise promise) {
        if (uri == null || uri.isEmpty()) {
            promise.reject("NotFoundError", "getFileMedia: uri is required");
            return;
        }
        Uri parsed = uri.startsWith("/") ? Uri.fromFile(new java.io.File(uri)) : Uri.parse(uri);
        // The aux key IS the track id, so it has to be known before the track exists: the id is
        // minted here and createVideoTrack is told to use it.
        String trackId = UUID.randomUUID().toString();
        FileSource source = new FileSource(reactContext, parsed, trackId);
        try {
            source.probe();
        } catch (java.io.IOException e) {
            promise.reject("NotSupportedError", "Could not open video: " + uri + " (" + e.getMessage() + ")", e);
            return;
        }
        // The web caps the SHORTER side at VideoResampleSize. The capturer scales to this size
        // itself (see FileVideoCapturer's header for why it does not leave that to WebRTC).
        // Rotation does not change which side is shorter.
        int outW = source.getWidth();
        int outH = source.getHeight();
        int shorter = Math.min(outW, outH);
        if (maxSide > 0 && shorter > maxSide) {
            float scale = (float) maxSide / shorter;
            outW = Math.max(2, Math.round(outW * scale) & ~1);
            outH = Math.max(2, Math.round(outH * scale) & ~1);
        }
        FileCaptureController controller = new FileCaptureController(
                source.getWidth(), source.getHeight(), fps > 0 ? fps : 25, source, autoplay, outW, outH);
        controller.setEventSink(body -> {
            body.putString("trackId", trackId);
            webRTCModule.sendEvent("fileMediaEvent", body);
        });
        VideoTrack track = createVideoTrack(controller, trackId);
        if (track == null) {
            source.release();
            promise.reject("NotSupportedError", "Could not create the file video track");
            return;
        }
        // Frames already arrive at outW x outH; this is the fps cap (a 60 fps file at 25).
        TrackPrivate tp = tracks.get(trackId);
        if (tp != null && tp.mediaSource instanceof VideoSource) {
            ((VideoSource) tp.mediaSource).adaptOutputFormat(outW, outH, fps > 0 ? fps : 25);
        }
        final int width = source.getWidth();
        final int height = source.getHeight();
        final boolean hasAudio = source.hasAudio();
        final double duration = source.getDurationSeconds();
        createStream(new MediaStreamTrack[] {track}, (streamId, tracksInfo) -> {
            if (tracksInfo.size() == 0) {
                promise.reject(new RuntimeException("No file source track info found."));
                return;
            }
            WritableMap data = Arguments.createMap();
            data.putString("streamId", streamId);
            data.putMap("track", tracksInfo.get(0));
            if (hasAudio) {
                WritableMap audio = Arguments.createMap();
                audio.putString("auxId", trackId);
                data.putMap("audio", audio);
            } else {
                data.putNull("audio");
            }
            data.putDouble("duration", duration);
            data.putInt("width", width);
            data.putInt("height", height);
            data.putBoolean("playing", autoplay);
            promise.resolve(data);
        });
    }

    /** {@code fileMediaControl(trackId, { action, position, value })} → the playback state. */
    void fileMediaControl(String trackId, ReadableMap command, Promise promise) {
        TrackPrivate tp = tracks.get(trackId);
        if (tp == null || !(tp.videoCaptureController instanceof FileCaptureController)) {
            promise.reject("NotFoundError", "No file source for track " + trackId);
            return;
        }
        FileCaptureController controller = (FileCaptureController) tp.videoCaptureController;
        FileSource source = controller.getSource();
        String action = command.hasKey("action") ? command.getString("action") : "";
        switch (action == null ? "" : action) {
            case "play":
                source.play();
                break;
            case "pause":
                source.pause();
                break;
            case "seek":
                source.seekTo(command.hasKey("position") ? command.getDouble("position") : 0);
                break;
            case "volume":
                source.setLocalVolume(command.hasKey("value") ? (float) command.getDouble("value") : 1f);
                break;
            default:
                promise.reject("NotSupportedError", "Unknown file media action: " + action);
                return;
        }
        promise.resolve(controller.state());
    }

    VideoTrack createVideoTrack(AbstractVideoCaptureController videoCaptureController) {
        return createVideoTrack(videoCaptureController, UUID.randomUUID().toString());
    }

    /** As above, with the caller choosing the track id (the file source keys its aux on it). */
    VideoTrack createVideoTrack(AbstractVideoCaptureController videoCaptureController, String id) {
        videoCaptureController.initializeVideoCapturer();

        VideoCapturer videoCapturer = videoCaptureController.videoCapturer;
        if (videoCapturer == null) {
            return null;
        }

        PeerConnectionFactory pcFactory = webRTCModule.mFactory;
        EglBase.Context eglContext = EglUtils.getRootEglBaseContext();
        SurfaceTextureHelper surfaceTextureHelper = SurfaceTextureHelper.create("CaptureThread", eglContext);

        if (surfaceTextureHelper == null) {
            Log.d(TAG, "Error creating SurfaceTextureHelper");
            return null;
        }

        TrackCapturerEventsEmitter eventsEmitter = new TrackCapturerEventsEmitter(webRTCModule, id);
        videoCaptureController.setCapturerEventsListener(eventsEmitter);

        VideoSource videoSource = pcFactory.createVideoSource(videoCapturer.isScreencast());
        videoCapturer.initialize(surfaceTextureHelper, reactContext, videoSource.getCapturerObserver());

        VideoTrack track = pcFactory.createVideoTrack(id, videoSource);

        track.setEnabled(true);
        tracks.put(id, new TrackPrivate(track, videoSource, videoCaptureController, surfaceTextureHelper));

        videoCaptureController.startCapture();

        return track;
    }

    /**
     * Set video effects to the TrackPrivate corresponding to the trackId with the help of VideoEffectProcessor
     * corresponding to the names.
     * @param trackId TrackPrivate id
     * @param names VideoEffectProcessor names
     */
    void setVideoEffects(String trackId, ReadableArray names) {
        TrackPrivate track = tracks.get(trackId);

        if (track != null && track.videoCaptureController instanceof CameraCaptureController) {
            VideoSource videoSource = (VideoSource) track.mediaSource;
            SurfaceTextureHelper surfaceTextureHelper = track.surfaceTextureHelper;

            if (names != null) {
                List<VideoFrameProcessor> processors =
                        names.toArrayList()
                                .stream()
                                .filter(name -> name instanceof String)
                                .map(name -> {
                                    VideoFrameProcessor videoFrameProcessor =
                                            ProcessorProvider.getProcessor((String) name);
                                    if (videoFrameProcessor == null) {
                                        Log.e(TAG, "no videoFrameProcessor associated with this name: " + name);
                                    }
                                    return videoFrameProcessor;
                                })
                                .filter(Objects::nonNull)
                                .collect(Collectors.toList());

                VideoEffectProcessor videoEffectProcessor = new VideoEffectProcessor(processors, surfaceTextureHelper);
                videoSource.setVideoProcessor(videoEffectProcessor);

            } else {
                videoSource.setVideoProcessor(null);
            }
        }
    }

    /**
     * Application/library-specific private members of local
     * {@code MediaStreamTrack}s created by {@code GetUserMediaImpl}.
     */
    private static class TrackPrivate {
        /**
         * The {@code MediaSource} from which {@link #track} was created.
         */
        public final MediaSource mediaSource;

        public final MediaStreamTrack track;

        /**
         * The {@code VideoCapturer} from which {@link #mediaSource} was created
         * if {@link #track} is a {@link VideoTrack}.
         */
        public final AbstractVideoCaptureController videoCaptureController;

        private final SurfaceTextureHelper surfaceTextureHelper;

        /**
         * Whether this object has been disposed or not.
         */
        private boolean disposed;

        /**
         * Initializes a new {@code TrackPrivate} instance.
         *
         * @param track
         * @param mediaSource            the {@code MediaSource} from which the specified
         *                               {@code code} was created
         * @param videoCaptureController the {@code AbstractVideoCaptureController} from which the
         *                               specified {@code mediaSource} was created if the specified
         *                               {@code track} is a {@link VideoTrack}
         */
        public TrackPrivate(MediaStreamTrack track, MediaSource mediaSource,
                AbstractVideoCaptureController videoCaptureController, SurfaceTextureHelper surfaceTextureHelper) {
            this.track = track;
            this.mediaSource = mediaSource;
            this.videoCaptureController = videoCaptureController;
            this.surfaceTextureHelper = surfaceTextureHelper;
            this.disposed = false;
        }

        public void dispose() {
            if (!disposed) {
                if (videoCaptureController != null) {
                    if (videoCaptureController.stopCapture()) {
                        videoCaptureController.dispose();
                    }
                }

                /*
                 * As per webrtc library documentation - The caller still has ownership of {@code
                 * surfaceTextureHelper} and is responsible for making sure surfaceTextureHelper.dispose() is
                 * called. This also means that the caller can reuse the SurfaceTextureHelper to initialize a new
                 * VideoCapturer once the previous VideoCapturer has been disposed. */

                if (surfaceTextureHelper != null) {
                    surfaceTextureHelper.stopListening();
                    surfaceTextureHelper.dispose();
                }

                mediaSource.dispose();
                track.dispose();
                disposed = true;
            }
        }
    }

    public interface BiConsumer<T, U> {
        void accept(T t, U u);
    }
}
