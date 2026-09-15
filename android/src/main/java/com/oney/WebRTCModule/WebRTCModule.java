package com.oney.WebRTCModule;

import android.util.Log;
import android.util.Pair;
import android.util.SparseArray;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Callback;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.ReadableMapKeySetIterator;
import com.facebook.react.bridge.ReadableType;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.module.annotations.ReactModule;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import com.oney.WebRTCModule.audiorecorder.CallAudioRecordingManager;
import com.oney.WebRTCModule.webrtcutils.H264AndSoftwareVideoDecoderFactory;
import com.oney.WebRTCModule.webrtcutils.H264AndSoftwareVideoEncoderFactory;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import org.webrtc.*;
import com.oney.WebRTCModule.audio.ConferenceMixManager;

import org.webrtc.AudioSource;
import org.webrtc.AudioTrack;
import org.webrtc.ExternalAudioProcessingFactory;
import org.webrtc.MediaConstraints;
import org.webrtc.audio.AudioDeviceModule;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.util.Collections;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;

@ReactModule(name = "WebRTCModule")
public class WebRTCModule extends ReactContextBaseJavaModule {
    static final String TAG = WebRTCModule.class.getCanonicalName();

    PeerConnectionFactory mFactory;
    VideoEncoderFactory mVideoEncoderFactory;
    VideoDecoderFactory mVideoDecoderFactory;
    AudioDeviceModule mAudioDeviceModule;
    private final CallAudioRecordingManager mCallAudioRecordingManager;
    /** Wired into the default ADM only; with an injected ADM it never fires and reads false. */
    private final MicCaptureStateEmitter mMicCaptureState = new MicCaptureStateEmitter(this);

    // Need to expose the peer connection codec factories here to get capabilities
    private final SparseArray<PeerConnectionObserver> mPeerConnectionObservers;
    final Map<String, MediaStream> localStreams;

    // Store generated certificates by ID to avoid exposing private keys to JS
    private static final Map<String, RtcCertificatePem> mCertificates = new HashMap<>();

    private final GetUserMediaImpl getUserMediaImpl;

    /**
     * Conference audio. Inert until a leg is attached: the processing factory below ships
     * with both paths BYPASSED, so an ordinary 1:1 call never enters it.
     */
    private final ConferenceMixManager mConferenceMixManager;

    public WebRTCModule(ReactApplicationContext reactContext) {
        super(reactContext);

        mPeerConnectionObservers = new SparseArray<>();
        localStreams = new HashMap<>();

        WebRTCModuleOptions options = WebRTCModuleOptions.getInstance();

        AudioDeviceModule adm = options.audioDeviceModule;
        VideoEncoderFactory encoderFactory = options.videoEncoderFactory;
        VideoDecoderFactory decoderFactory = options.videoDecoderFactory;
        Loggable injectableLogger = options.injectableLogger;
        Logging.Severity loggingSeverity = options.loggingSeverity;
        String fieldTrials = options.fieldTrials;

        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(reactContext)
                        .setFieldTrials(fieldTrials)
                        .setNativeLibraryLoader(new LibraryLoader())
                        .setInjectableLogger(injectableLogger, loggingSeverity)
                        .createInitializationOptions());

        if (injectableLogger == null && loggingSeverity != null) {
            Logging.enableLogToDebugOutput(loggingSeverity);
        }

        if (encoderFactory == null || decoderFactory == null) {
            // Initialize EGL context required for HW acceleration.
            EglBase.Context eglContext = EglUtils.getRootEglBaseContext();

            if (eglContext != null) {
                encoderFactory = new H264AndSoftwareVideoEncoderFactory(eglContext);
                decoderFactory = new H264AndSoftwareVideoDecoderFactory(eglContext);
            } else {
                encoderFactory = new SoftwareVideoEncoderFactory();
                decoderFactory = new SoftwareVideoDecoderFactory();
            }
        }

        mCallAudioRecordingManager = new CallAudioRecordingManager(this);

        if (adm == null) {
            // Chain the call-recording mic tap only into the default ADM. An app-injected
            // ADM is left untouched, which means mic capture for recording is unavailable.
            adm = JavaAudioDeviceModule.builder(reactContext)
                          .setEnableVolumeLogger(false)
                          .setSamplesReadyCallback(mCallAudioRecordingManager.getMicDispatcher())
                          // Without these, an AudioRecord that fails to start or dies mid-call
                          // is a logcat line and a silent call; with them it is `mute` on the
                          // local audio tracks (see MicCaptureStateEmitter).
                          .setAudioRecordErrorCallback(mMicCaptureState)
                          .setAudioRecordStateCallback(mMicCaptureState)
                          .createAudioDeviceModule();
            mCallAudioRecordingManager.setMicCaptureAvailable(true);
        } else {
            Log.w(TAG, "Custom AudioDeviceModule injected; call recording mic capture is unavailable.");
        }

        Log.d(TAG, "Using video encoder factory: " + encoderFactory.getClass().getCanonicalName());
        Log.d(TAG, "Using video decoder factory: " + decoderFactory.getClass().getCanonicalName());

        mConferenceMixManager = new ConferenceMixManager(reactContext);

        mFactory = PeerConnectionFactory.builder()
                           .setAudioDeviceModule(adm)
                           // Installed at CONSTRUCTION because a factory's audio processing is
                           // fixed when it is built - the same per-factory constraint that makes
                           // a conference need a second factory at all. Bypassed until a leg
                           // attaches, so this line changes nothing for a plain call.
                           .setAudioProcessingFactory(mConferenceMixManager.buildMainAudioProcessing())
                           .setVideoEncoderFactory(encoderFactory)
                           .setVideoDecoderFactory(decoderFactory)
                           .createPeerConnectionFactory();

        // PeerConnectionFactory now owns the adm native pointer, and we don't need it anymore.
        adm.release();

        // Saving the encoder and decoder factories to get codec info later when needed.
        mVideoEncoderFactory = encoderFactory;
        mVideoDecoderFactory = decoderFactory;
        mAudioDeviceModule = adm;

        getUserMediaImpl = new GetUserMediaImpl(this, reactContext);
    }

    @NonNull
    @Override
    public String getName() {
        return "WebRTCModule";
    }

    /**
     * Synchronous capability facts JS can read without a round trip.
     *
     * `callRecordingSupportsVideo` is what CallRecorder.supportsVideo answers from. A CONSTANT
     * rather than a probe on some proxy method, because it states the fact directly: an OTA JS
     * bundle can reach an app binary older than this file, where the key is simply absent and
     * reads as false. Version skew is then handled by construction rather than by a check
     * someone has to remember to write.
     *
     * `displayMediaSupported` is what mediaDevices.supportsDisplayMedia answers from: whether
     * getDisplayMedia() on THIS build can deliver a frame. MediaProjection itself is always
     * present (minSdk 24); what varies is the foreground service Android 10+ demands before it
     * hands over the screen - the option that starts it, and on API 34+ the permission it needs.
     * Read here, at bridge start, which is after Application.onCreate where an app would turn
     * the option off. False is the host's cue to withhold getDisplayMedia, so shared code that
     * feature-detects it reads "not supported" rather than crashing on consent.
     */
    @Nullable
    @Override
    public Map<String, Object> getConstants() {
        Map<String, Object> constants = new HashMap<>();
        constants.put("callRecordingSupportsVideo", true);
        constants.put("displayMediaSupported", isDisplayMediaSupported());
        // The in-process view/image frame source (whiteboard, picture): no MediaProjection, no
        // service, no permission — always available on Android. The constant exists so JS built
        // against a newer lib can tell an older BINARY (which reads `undefined`) apart, the same
        // publish-or-don't idiom as displayMediaSupported.
        constants.put("supportsFrameSource", true);
        constants.put("recordingsDirectory", recordingsDirectory());
        return constants;
    }

    /**
     * Where a recording started without paths is written. The app-private FILES dir, not the
     * cache: the OS may evict cache under pressure, and a call recording cannot be regenerated.
     * Reported as a constant so JS can find the files (crash salvage scans it); created lazily
     * by the first recording that needs it.
     */
    private String recordingsDirectory() {
        return new File(getReactApplicationContext().getFilesDir(), "siperb-rn-webrtc/recordings").getPath();
    }

    private boolean isDisplayMediaSupported() {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) {
            return true;
        }
        if (!WebRTCModuleOptions.getInstance().enableMediaProjectionService) {
            return false;
        }
        return MediaProjectionService.hasRequiredPermissions(getReactApplicationContext());
    }

    private PeerConnection getPeerConnection(int id) {
        PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
        return (pco == null) ? null : pco.getPeerConnection();
    }

    // Public so the audiorecorder package can emit through the same mechanism.
    public void sendEvent(String eventName, @Nullable ReadableMap params) {
        getReactApplicationContext()
                .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                .emit(eventName, params);
    }

    CallAudioRecordingManager getCallAudioRecordingManager() {
        return mCallAudioRecordingManager;
    }

    /** True while the default ADM reports the microphone as failing. */
    boolean isMicCaptureMuted() {
        return mMicCaptureState.isMuted();
    }

    /** Must be called on the executor; the track registry is confined to it. */
    List<String> getLocalAudioTrackIds() {
        return getUserMediaImpl == null ? Collections.emptyList() : getUserMediaImpl.getLocalAudioTrackIds();
    }

    private PeerConnection.IceServer createIceServer(String url) {
        return PeerConnection.IceServer.builder(url).createIceServer();
    }

    private PeerConnection.IceServer createIceServer(String url, String username, String credential) {
        return PeerConnection.IceServer.builder(url).setUsername(username).setPassword(credential).createIceServer();
    }

    private List<PeerConnection.IceServer> createIceServers(ReadableArray iceServersArray) {
        final int size = (iceServersArray == null) ? 0 : iceServersArray.size();
        List<PeerConnection.IceServer> iceServers = new ArrayList<>(size);
        for (int i = 0; i < size; i++) {
            ReadableMap iceServerMap = iceServersArray.getMap(i);
            boolean hasUsernameAndCredential = iceServerMap.hasKey("username") && iceServerMap.hasKey("credential");
            if (iceServerMap.hasKey("urls")) {
                switch (iceServerMap.getType("urls")) {
                    case String:
                        if (hasUsernameAndCredential) {
                            iceServers.add(createIceServer(iceServerMap.getString("urls"),
                                    iceServerMap.getString("username"),
                                    iceServerMap.getString("credential")));
                        } else {
                            iceServers.add(createIceServer(iceServerMap.getString("urls")));
                        }
                        break;
                    case Array:
                        ReadableArray urls = iceServerMap.getArray("urls");
                        for (int j = 0; j < urls.size(); j++) {
                            String url = urls.getString(j);
                            if (hasUsernameAndCredential) {
                                iceServers.add(createIceServer(
                                        url, iceServerMap.getString("username"), iceServerMap.getString("credential")));
                            } else {
                                iceServers.add(createIceServer(url));
                            }
                        }
                        break;
                }
            }
        }
        return iceServers;
    }

    private PeerConnection.RTCConfiguration parseRTCConfiguration(ReadableMap map) {
        ReadableArray iceServersArray = null;
        if (map != null && map.hasKey("iceServers")) {
            iceServersArray = map.getArray("iceServers");
        }
        List<PeerConnection.IceServer> iceServers = createIceServers(iceServersArray);

        PeerConnection.RTCConfiguration conf = new PeerConnection.RTCConfiguration(iceServers);
        conf.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;

        // Required for perfect negotiation.
        conf.enableImplicitRollback = true;

        // Enable GCM ciphers.
        CryptoOptions cryptoOptions = CryptoOptions.builder()
                                              .setEnableGcmCryptoSuites(true)
                                              .setEnableAes128Sha1_32CryptoCipher(false)
                                              .setEnableEncryptedRtpHeaderExtensions(false)
                                              .setRequireFrameEncryption(false)
                                              .createCryptoOptions();
        conf.cryptoOptions = cryptoOptions;

        if (map == null) {
            return conf;
        }

        // iceTransportPolicy (public api)
        if (map.hasKey("iceTransportPolicy") && map.getType("iceTransportPolicy") == ReadableType.String) {
            final String v = map.getString("iceTransportPolicy");
            if (v != null) {
                switch (v) {
                    case "all": // public
                        conf.iceTransportsType = PeerConnection.IceTransportsType.ALL;
                        break;
                    case "relay": // public
                        conf.iceTransportsType = PeerConnection.IceTransportsType.RELAY;
                        break;
                    case "nohost":
                        conf.iceTransportsType = PeerConnection.IceTransportsType.NOHOST;
                        break;
                    case "none":
                        conf.iceTransportsType = PeerConnection.IceTransportsType.NONE;
                        break;
                }
            }
        }

        // bundlePolicy (public api)
        if (map.hasKey("bundlePolicy") && map.getType("bundlePolicy") == ReadableType.String) {
            final String v = map.getString("bundlePolicy");
            if (v != null) {
                switch (v) {
                    case "balanced": // public
                        conf.bundlePolicy = PeerConnection.BundlePolicy.BALANCED;
                        break;
                    case "max-compat": // public
                        conf.bundlePolicy = PeerConnection.BundlePolicy.MAXCOMPAT;
                        break;
                    case "max-bundle": // public
                        conf.bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE;
                        break;
                }
            }
        }

        // rtcpMuxPolicy (public api)
        if (map.hasKey("rtcpMuxPolicy") && map.getType("rtcpMuxPolicy") == ReadableType.String) {
            final String v = map.getString("rtcpMuxPolicy");
            if (v != null) {
                switch (v) {
                    case "negotiate": // public
                        conf.rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.NEGOTIATE;
                        break;
                    case "require": // public
                        conf.rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE;
                        break;
                }
            }
        }

        // FIXME: peerIdentity of type DOMString (public api)

        // certificates (public api)
        if (map.hasKey("certificates") && map.getType("certificates") == ReadableType.Array) {
            ReadableArray certificates = map.getArray("certificates");
            if (certificates.size() > 0) {
                ReadableMap certMap = certificates.getMap(0);
                if (certMap.hasKey("certificateId")) {
                    String certId = certMap.getString("certificateId");
                    RtcCertificatePem cert;
                    synchronized (mCertificates) {
                        cert = mCertificates.get(certId);
                    }
                    if (cert != null) {
                        conf.certificate = cert;
                    }
                }
            }
        }

        // iceCandidatePoolSize of type unsigned short, defaulting to 0
        if (map.hasKey("iceCandidatePoolSize") && map.getType("iceCandidatePoolSize") == ReadableType.Number) {
            final int v = map.getInt("iceCandidatePoolSize");
            if (v > 0) {
                conf.iceCandidatePoolSize = v;
            }
        }

        // === below is private api in webrtc ===

        // tcpCandidatePolicy (private api)
        if (map.hasKey("tcpCandidatePolicy") && map.getType("tcpCandidatePolicy") == ReadableType.String) {
            final String v = map.getString("tcpCandidatePolicy");
            if (v != null) {
                switch (v) {
                    case "enabled":
                        conf.tcpCandidatePolicy = PeerConnection.TcpCandidatePolicy.ENABLED;
                        break;
                    case "disabled":
                        conf.tcpCandidatePolicy = PeerConnection.TcpCandidatePolicy.DISABLED;
                        break;
                }
            }
        }

        // candidateNetworkPolicy (private api)
        if (map.hasKey("candidateNetworkPolicy") && map.getType("candidateNetworkPolicy") == ReadableType.String) {
            final String v = map.getString("candidateNetworkPolicy");
            if (v != null) {
                switch (v) {
                    case "all":
                        conf.candidateNetworkPolicy = PeerConnection.CandidateNetworkPolicy.ALL;
                        break;
                    case "low_cost":
                        conf.candidateNetworkPolicy = PeerConnection.CandidateNetworkPolicy.LOW_COST;
                        break;
                }
            }
        }

        // KeyType (private api)
        if (map.hasKey("keyType") && map.getType("keyType") == ReadableType.String) {
            final String v = map.getString("keyType");
            if (v != null) {
                switch (v) {
                    case "RSA":
                        conf.keyType = PeerConnection.KeyType.RSA;
                        break;
                    case "ECDSA":
                        conf.keyType = PeerConnection.KeyType.ECDSA;
                        break;
                }
            }
        }

        // continualGatheringPolicy (private api)
        if (map.hasKey("continualGatheringPolicy") && map.getType("continualGatheringPolicy") == ReadableType.String) {
            final String v = map.getString("continualGatheringPolicy");
            if (v != null) {
                switch (v) {
                    case "gather_once":
                        conf.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE;
                        break;
                    case "gather_continually":
                        conf.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY;
                        break;
                }
            }
        }

        // audioJitterBufferMaxPackets (private api)
        if (map.hasKey("audioJitterBufferMaxPackets")
                && map.getType("audioJitterBufferMaxPackets") == ReadableType.Number) {
            final int v = map.getInt("audioJitterBufferMaxPackets");
            if (v > 0) {
                conf.audioJitterBufferMaxPackets = v;
            }
        }

        // iceConnectionReceivingTimeout (private api)
        if (map.hasKey("iceConnectionReceivingTimeout")
                && map.getType("iceConnectionReceivingTimeout") == ReadableType.Number) {
            final int v = map.getInt("iceConnectionReceivingTimeout");
            conf.iceConnectionReceivingTimeout = v;
        }

        // iceBackupCandidatePairPingInterval (private api)
        if (map.hasKey("iceBackupCandidatePairPingInterval")
                && map.getType("iceBackupCandidatePairPingInterval") == ReadableType.Number) {
            final int v = map.getInt("iceBackupCandidatePairPingInterval");
            conf.iceBackupCandidatePairPingInterval = v;
        }

        // audioJitterBufferFastAccelerate (private api)
        if (map.hasKey("audioJitterBufferFastAccelerate")
                && map.getType("audioJitterBufferFastAccelerate") == ReadableType.Boolean) {
            final boolean v = map.getBoolean("audioJitterBufferFastAccelerate");
            conf.audioJitterBufferFastAccelerate = v;
        }

        // pruneTurnPorts (private api)
        if (map.hasKey("pruneTurnPorts") && map.getType("pruneTurnPorts") == ReadableType.Boolean) {
            final boolean v = map.getBoolean("pruneTurnPorts");
            conf.pruneTurnPorts = v;
        }

        // presumeWritableWhenFullyRelayed (private api)
        if (map.hasKey("presumeWritableWhenFullyRelayed")
                && map.getType("presumeWritableWhenFullyRelayed") == ReadableType.Boolean) {
            final boolean v = map.getBoolean("presumeWritableWhenFullyRelayed");
            conf.presumeWritableWhenFullyRelayed = v;
        }

        return conf;
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    public boolean peerConnectionInit(ReadableMap configuration, int id, @Nullable String conferenceLegId) {
        PeerConnection.RTCConfiguration rtcConfiguration = parseRTCConfiguration(configuration);

        try {
            return (boolean) ThreadUtils
                    .submitToExecutor(() -> {
                        PeerConnectionObserver observer = new PeerConnectionObserver(this, id);
                        // WHICH FACTORY - and therefore which outbound audio this leg sends -
                        // is decided HERE and can never be changed afterwards. A conference
                        // child names its leg id in the configuration and is born on a factory
                        // of its own; everything else uses the app's single factory.
                        //
                        // Read off the configuration map because Android passes unknown keys
                        // straight through. iOS would need an explicit argument, since
                        // RCTConvert drops keys it does not recognise.
                        PeerConnectionFactory factory = mFactory;
                        if (conferenceLegId != null && !conferenceLegId.isEmpty()) {
                            factory = mConferenceMixManager.factoryForLeg(
                                    conferenceLegId, mVideoEncoderFactory, mVideoDecoderFactory);
                        }
                        PeerConnection peerConnection = factory.createPeerConnection(rtcConfiguration, observer);
                        if (peerConnection == null) {
                            return false;
                        }
                        observer.setPeerConnection(peerConnection);
                        mPeerConnectionObservers.put(id, observer);
                        return true;
                    })
                    .get();
        } catch (ExecutionException | InterruptedException e) {
            e.printStackTrace();
            throw new RuntimeException(e);
        }
    }

    // Must be called in the executor.
    MediaStream getStreamForReactTag(String streamReactTag) {
        MediaStream stream = localStreams.get(streamReactTag);

        if (stream != null) {
            return stream;
        }

        for (int i = 0, size = mPeerConnectionObservers.size(); i < size; i++) {
            PeerConnectionObserver pco = mPeerConnectionObservers.valueAt(i);
            stream = pco.remoteStreams.get(streamReactTag);
            if (stream != null) {
                return stream;
            }
        }

        return null;
    }

    public MediaStreamTrack getTrack(int pcId, String trackId) {
        if (pcId == -1) {
            return getLocalTrack(trackId);
        }

        PeerConnectionObserver pco = mPeerConnectionObservers.get(pcId);
        if (pco == null) {
            Log.d(TAG, "getTrack(): could not find PeerConnection");
            return null;
        }

        return pco.remoteTracks.get(trackId);
    }

    MediaStreamTrack getLocalTrack(String trackId) {
        return getUserMediaImpl.getTrack(trackId);
    }

    public VideoTrack createVideoTrack(AbstractVideoCaptureController videoCaptureController) {
        return getUserMediaImpl.createVideoTrack(videoCaptureController);
    }

    public void createStream(
            MediaStreamTrack[] tracks, GetUserMediaImpl.BiConsumer<String, ArrayList<WritableMap>> successCallback) {
        getUserMediaImpl.createStream(tracks, successCallback);
    }

    /**
     * Turns an "options" <tt>ReadableMap</tt> into a <tt>MediaConstraints</tt> object.
     *
     * @param options A <tt>ReadableMap</tt> which represents a JavaScript
     * object specifying the options to be parsed into a
     * <tt>MediaConstraints</tt> instance.
     * @return A new <tt>MediaConstraints</tt> instance initialized with the
     * mandatory keys and values specified by <tt>options</tt>.
     */
    MediaConstraints constraintsForOptions(ReadableMap options) {
        MediaConstraints mediaConstraints = new MediaConstraints();
        ReadableMapKeySetIterator keyIterator = options.keySetIterator();

        while (keyIterator.hasNextKey()) {
            String key = keyIterator.nextKey();
            String value = ReactBridgeUtil.getMapStrValue(options, key);

            mediaConstraints.mandatory.add(new MediaConstraints.KeyValuePair(key, value));
        }

        return mediaConstraints;
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    public WritableMap peerConnectionAddTransceiver(int id, ReadableMap options) {
        try {
            return (WritableMap) ThreadUtils
                    .submitToExecutor((Callable<Object>) () -> {
                        PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                        if (pco == null) {
                            Log.d(TAG, "peerConnectionAddTransceiver() peerConnection is null");
                            return null;
                        }

                        RtpTransceiver transceiver = null;
                        if (options.hasKey("type")) {
                            String kind = options.getString("type");
                            transceiver = pco.addTransceiver(SerializeUtils.parseMediaType(kind),
                                    SerializeUtils.parseTransceiverOptions(options.getMap("init")));
                        } else if (options.hasKey("trackId")) {
                            String trackId = options.getString("trackId");
                            MediaStreamTrack track = getLocalTrack(trackId);
                            transceiver = pco.addTransceiver(
                                    track, SerializeUtils.parseTransceiverOptions(options.getMap("init")));

                        } else {
                            // This should technically never happen as the JS side checks for that.
                            Log.d(TAG, "peerConnectionAddTransceiver() no type nor trackId provided in options");
                            return null;
                        }

                        if (transceiver == null) {
                            Log.d(TAG, "peerConnectionAddTransceiver() Error adding transceiver");
                            return null;
                        }
                        WritableMap params = Arguments.createMap();
                        // We need to get a unique order at which the transceiver was created
                        // to reorder the cached array of transceivers on the JS layer.
                        params.putInt("transceiverOrder", pco.getNextTransceiverId());
                        params.putMap("transceiver", SerializeUtils.serializeTransceiver(id, transceiver));
                        return params;
                    })
                    .get();
        } catch (InterruptedException | ExecutionException e) {
            Log.d(TAG, "peerConnectionAddTransceiver() " + e.getMessage());
            return null;
        }
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    public WritableMap peerConnectionAddTrack(int id, String trackId, ReadableMap options) {
        try {
            return (WritableMap) ThreadUtils
                    .submitToExecutor((Callable<Object>) () -> {
                        PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                        if (pco == null) {
                            Log.d(TAG, "peerConnectionAddTrack() peerConnection is null");
                            return null;
                        }

                        MediaStreamTrack track = getLocalTrack(trackId);
                        if (track == null) {
                            Log.w(TAG, "peerConnectionAddTrack() couldn't find track " + trackId);
                            return null;
                        }

                        List<String> streamIds = new ArrayList<>();
                        if (options.hasKey("streamIds")) {
                            ReadableArray rawStreamIds = options.getArray("streamIds");
                            if (rawStreamIds != null) {
                                for (int i = 0; i < rawStreamIds.size(); i++) {
                                    streamIds.add(rawStreamIds.getString(i));
                                }
                            }
                        }
                        RtpSender sender = pco.getPeerConnection().addTrack(track, streamIds);

                        // Need to get the corresponding transceiver as well
                        RtpTransceiver transceiver = pco.getTransceiver(sender.id());

                        // We need the transceiver creation order to reorder the transceivers array
                        // in the JS layer.
                        WritableMap params = Arguments.createMap();
                        params.putInt("transceiverOrder", pco.getNextTransceiverId());
                        params.putMap("transceiver", SerializeUtils.serializeTransceiver(id, transceiver));
                        params.putMap("sender", SerializeUtils.serializeSender(id, sender));
                        return params;
                    })
                    .get();
        } catch (InterruptedException | ExecutionException e) {
            Log.d(TAG, "peerConnectionAddTrack() " + e.getMessage());
            return null;
        }
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    public boolean peerConnectionRemoveTrack(int id, String senderId) {
        try {
            return (boolean) ThreadUtils
                    .submitToExecutor((Callable<Object>) () -> {
                        PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                        if (pco == null) {
                            Log.d(TAG, "peerConnectionRemoveTrack() peerConnection is null");
                            return false;
                        }
                        RtpSender sender = pco.getSender(senderId);
                        if (sender == null) {
                            Log.w(TAG, "peerConnectionRemoveTrack() sender is null");
                            return false;
                        }

                        return pco.getPeerConnection().removeTrack(sender);
                    })
                    .get();
        } catch (InterruptedException | ExecutionException e) {
            Log.d(TAG, "peerConnectionRemoveTrack() " + e.getMessage());
            return false;
        }
    }

    @ReactMethod
    public void senderSetParameters(int id, String senderId, ReadableMap options, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            try {
                PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                if (pco == null) {
                    Log.d(TAG, "senderSetParameters() peerConnectionObserver is null");
                    promise.reject(new Exception("Peer Connection is not initialized"));
                    return;
                }

                RtpSender sender = pco.getSender(senderId);
                if (sender == null) {
                    Log.w(TAG, "senderSetParameters() sender is null");
                    promise.reject(new Exception("Could not get sender"));
                    return;
                }

                RtpParameters params = sender.getParameters();
                params = SerializeUtils.updateRtpParameters(options, params);
                sender.setParameters(params);
                promise.resolve(SerializeUtils.serializeRtpParameters(sender.getParameters()));
            } catch (Exception e) {
                Log.d(TAG, "senderSetParameters: " + e.getMessage());
                promise.reject(e);
            }
        });
    }

    @ReactMethod
    public void transceiverStop(int id, String senderId, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            try {
                PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                if (pco == null) {
                    Log.d(TAG, "transceiverStop() peerConnectionObserver is null");
                    promise.reject(new Exception("Peer Connection is not initialized"));
                    return;
                }
                RtpTransceiver transceiver = pco.getTransceiver(senderId);
                if (transceiver == null) {
                    Log.w(TAG, "transceiverStop() transceiver is null");
                    promise.reject(new Exception("Could not get transceiver"));
                    return;
                }

                transceiver.stopStandard();
                promise.resolve(true);
            } catch (Exception e) {
                Log.d(TAG, "transceiverStop(): " + e.getMessage());
                promise.reject(e);
            }
        });
    }

    @ReactMethod
    public void senderReplaceTrack(int id, String senderId, String trackId, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            try {
                PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                if (pco == null) {
                    Log.d(TAG, "senderReplaceTrack() peerConnectionObserver is null");
                    promise.reject(new Exception("Peer Connection is not initialized"));
                    return;
                }

                RtpSender sender = pco.getSender(senderId);
                if (sender == null) {
                    Log.w(TAG, "senderReplaceTrack() sender is null");
                    promise.reject(new Exception("Could not get sender"));
                    return;
                }

                MediaStreamTrack track = getLocalTrack(trackId);
                sender.setTrack(track, false);
                promise.resolve(true);
            } catch (Exception e) {
                Log.d(TAG, "senderReplaceTrack(): " + e.getMessage());
                promise.reject(e);
            }
        });
    }

    @ReactMethod
    public void senderInsertDtmf(int id, String senderId, String tones, int duration, int interToneGap, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            try {
                PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                if (pco == null) {
                    Log.d(TAG, "senderInsertDtmf() peerConnectionObserver is null");
                    promise.reject(new Exception("Peer Connection is not initialized"));
                    return;
                }

                RtpSender sender = pco.getSender(senderId);
                if (sender == null) {
                    Log.w(TAG, "senderInsertDtmf() sender is null");
                    promise.reject(new Exception("Could not get sender"));
                    return;
                }

                DtmfSender dtmfSender = sender.dtmf();
                if (dtmfSender == null) {
                    Log.w(TAG, "senderInsertDtmf() sender has no DtmfSender");
                    promise.reject(new Exception("Sender does not support DTMF"));
                    return;
                }

                // libwebrtc produces the RFC 4733 telephone-event RTP and owns the
                // real playout timing; we forward the whole tone string in one call.
                boolean inserted = dtmfSender.insertDtmf(tones, duration, interToneGap);
                promise.resolve(inserted);
            } catch (Exception e) {
                Log.d(TAG, "senderInsertDtmf(): " + e.getMessage());
                promise.reject(e);
            }
        });
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    public boolean senderCanInsertDtmf(int id, String senderId) {
        try {
            return ThreadUtils
                    .submitToExecutor((Callable<Object>) () -> {
                        PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                        if (pco == null) {
                            return false;
                        }

                        RtpSender sender = pco.getSender(senderId);
                        if (sender == null) {
                            return false;
                        }

                        DtmfSender dtmfSender = sender.dtmf();
                        return dtmfSender != null && dtmfSender.canInsertDtmf();
                    })
                    .get() == Boolean.TRUE;
        } catch (ExecutionException | InterruptedException e) {
            Log.d(TAG, "senderCanInsertDtmf() " + e.getMessage());
            return false;
        }
    }

    @ReactMethod
    public void transceiverSetDirection(int id, String senderId, String direction, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            WritableMap identifier = Arguments.createMap();
            WritableMap params = Arguments.createMap();
            identifier.putInt("peerConnectionId", id);
            identifier.putString("transceiverId", senderId);
            try {
                PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                if (pco == null) {
                    Log.d(TAG, "transceiverSetDirection() peerConnectionObserver is null");
                    promise.reject(new Exception("Peer Connection is not initialized"));
                    return;
                }
                RtpTransceiver transceiver = pco.getTransceiver(senderId);
                if (transceiver == null) {
                    Log.d(TAG, "transceiverSetDirection() transceiver is null");
                    promise.reject(new Exception("Could not get sender"));
                    return;
                }

                transceiver.setDirection(SerializeUtils.parseDirection(direction));

                promise.resolve(true);
            } catch (Exception e) {
                Log.d(TAG, "transceiverSetDirection(): " + e.getMessage());
                promise.reject(e);
            }
        });
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    public boolean transceiverSetCodecPreferences(int id, String senderId, ReadableArray codecPreferences) {
        ThreadUtils.runOnExecutor(() -> {
            WritableMap identifier = Arguments.createMap();
            WritableMap params = Arguments.createMap();
            identifier.putInt("peerConnectionId", id);
            identifier.putString("transceiverId", senderId);
            try {
                PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
                if (pco == null) {
                    Log.d(TAG, "transceiverSetDirection() peerConnectionObserver is null");
                    return;
                }
                RtpTransceiver transceiver = pco.getTransceiver(senderId);
                if (transceiver == null) {
                    Log.d(TAG, "transceiverSetDirection() transceiver is null");
                    return;
                }

                // Convert JSON codec capabilities to the actual objects.
                RtpTransceiver.RtpTransceiverDirection direction = transceiver.getDirection();
                List<Pair<Map<String, Object>, RtpCapabilities.CodecCapability>> availableCodecs = new ArrayList<>();

                if (direction.equals(RtpTransceiver.RtpTransceiverDirection.SEND_RECV)
                        || direction.equals(RtpTransceiver.RtpTransceiverDirection.SEND_ONLY)) {
                    RtpCapabilities capabilities = mFactory.getRtpSenderCapabilities(transceiver.getMediaType());
                    for (RtpCapabilities.CodecCapability codec : capabilities.codecs) {
                        Map<String, Object> codecDict = SerializeUtils.serializeRtpCapabilitiesCodec(codec).toHashMap();
                        availableCodecs.add(new Pair<>(codecDict, codec));
                    }
                }

                if (direction.equals(RtpTransceiver.RtpTransceiverDirection.SEND_RECV)
                        || direction.equals(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY)) {
                    RtpCapabilities capabilities = mFactory.getRtpReceiverCapabilities(transceiver.getMediaType());
                    for (RtpCapabilities.CodecCapability codec : capabilities.codecs) {
                        Map<String, Object> codecDict = SerializeUtils.serializeRtpCapabilitiesCodec(codec).toHashMap();
                        availableCodecs.add(new Pair<>(codecDict, codec));
                    }
                }

                // Codec preferences is order sensitive.
                List<RtpCapabilities.CodecCapability> codecsToSet = new ArrayList<>();

                for (int i = 0; i < codecPreferences.size(); i++) {
                    Map<String, Object> codecPref = codecPreferences.getMap(i).toHashMap();
                    for (Pair<Map<String, Object>, RtpCapabilities.CodecCapability> pair : availableCodecs) {
                        Map<String, Object> availableCodecDict = pair.first;
                        if (codecPref.equals(availableCodecDict)) {
                            codecsToSet.add(pair.second);
                            break;
                        }
                    }
                }

                transceiver.setCodecPreferences(codecsToSet);
            } catch (Exception e) {
                Log.d(TAG, "transceiverSetCodecPreferences(): " + e.getMessage());
            }
        });
        return true;
    }

    @ReactMethod
    public void getDisplayMedia(ReadableMap constraints, Promise promise) {
        ThreadUtils.runOnExecutor(() -> getUserMediaImpl.getDisplayMedia(constraints, promise));
    }

    /**
     * {@code {sourceTag, fps?}} → a stream whose video track is the native view with that React
     * tag, sampled on a timer (the whiteboard). Not wrapped in runOnExecutor here: the impl must
     * first resolve the view on the UI thread, and hops to the executor itself for the track.
     */
    @ReactMethod
    public void getWhiteboardMedia(ReadableMap constraints, Promise promise) {
        int sourceTag = constraints != null && constraints.hasKey("sourceTag") ? constraints.getInt("sourceTag") : -1;
        int fps = constraints != null && constraints.hasKey("fps") ? constraints.getInt("fps") : 10;
        getUserMediaImpl.getWhiteboardMedia(sourceTag, fps, promise);
    }

    /** {@code {uri, fps?}} → a stream whose video track re-emits one decoded still image. */
    @ReactMethod
    public void getPictureMedia(ReadableMap constraints, Promise promise) {
        String uri = constraints != null && constraints.hasKey("uri") ? constraints.getString("uri") : null;
        int fps = constraints != null && constraints.hasKey("fps") ? constraints.getInt("fps") : 2;
        ThreadUtils.runOnExecutor(() -> getUserMediaImpl.getPictureMedia(uri, fps, promise));
    }

    @ReactMethod
    public void getUserMedia(ReadableMap constraints, Callback successCallback, Callback errorCallback) {
        ThreadUtils.runOnExecutor(() -> getUserMediaImpl.getUserMedia(constraints, successCallback, errorCallback));
    }

    @ReactMethod
    public void enumerateDevices(Callback callback) {
        ThreadUtils.runOnExecutor(() -> callback.invoke(getUserMediaImpl.enumerateDevices()));
    }

    @ReactMethod
    public void mediaStreamCreate(String id) {
        ThreadUtils.runOnExecutor(() -> {
            MediaStream mediaStream = mFactory.createLocalMediaStream(id);
            localStreams.put(id, mediaStream);
        });
    }

    @ReactMethod
    public void mediaStreamAddTrack(String streamId, int pcId, String trackId) {
        ThreadUtils.runOnExecutor(() -> {
            MediaStream stream = localStreams.get(streamId);
            if (stream == null) {
                Log.d(TAG, "mediaStreamAddTrack() could not find stream " + streamId);
                return;
            }

            MediaStreamTrack track = getTrack(pcId, trackId);
            if (track == null) {
                Log.d(TAG, "mediaStreamAddTrack() could not find track " + trackId);
                return;
            }

            String kind = track.kind();
            if ("audio".equals(kind)) {
                stream.addTrack((AudioTrack) track);
            } else if ("video".equals(kind)) {
                stream.addTrack((VideoTrack) track);
            }
        });
    }

    @ReactMethod
    public void mediaStreamRemoveTrack(String streamId, int pcId, String trackId) {
        ThreadUtils.runOnExecutor(() -> {
            MediaStream stream = localStreams.get(streamId);
            if (stream == null) {
                Log.d(TAG, "mediaStreamRemoveTrack() could not find stream " + streamId);
                return;
            }

            MediaStreamTrack track = getTrack(pcId, trackId);
            if (track == null) {
                Log.d(TAG, "mediaStreamRemoveTrack() could not find track " + trackId);
                return;
            }

            String kind = track.kind();
            if ("audio".equals(kind)) {
                stream.removeTrack((AudioTrack) track);
            } else if ("video".equals(kind)) {
                stream.removeTrack((VideoTrack) track);
            }
        });
    }

    @ReactMethod
    public void mediaStreamRelease(String id) {
        ThreadUtils.runOnExecutor(() -> {
            MediaStream stream = localStreams.get(id);
            if (stream == null) {
                Log.d(TAG, "mediaStreamRelease() stream is null");
                return;
            }
            localStreams.remove(id);
            stream.dispose();
        });
    }

    @ReactMethod
    public void mediaStreamTrackRelease(String id) {
        ThreadUtils.runOnExecutor(() -> {
            MediaStreamTrack track = getLocalTrack(id);
            if (track == null) {
                Log.d(TAG, "mediaStreamTrackRelease() track is null");
                return;
            }
            track.setEnabled(false);
            getUserMediaImpl.disposeTrack(id);
        });
    }

    @ReactMethod
    public void mediaStreamTrackSetEnabled(int pcId, String id, boolean enabled) {
        ThreadUtils.runOnExecutor(() -> {
            MediaStreamTrack track = getTrack(pcId, id);
            if (track == null) {
                Log.d(TAG, "mediaStreamTrackSetEnabled() could not find track " + id);
                return;
            }

            if (track.enabled() == enabled) {
                return;
            }
            track.setEnabled(enabled);
            getUserMediaImpl.mediaStreamTrackSetEnabled(id, enabled);
        });
    }

    @ReactMethod
    public void mediaStreamTrackApplyConstraints(String id, ReadableMap constraints, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            MediaStreamTrack track = getLocalTrack(id);
            if (track != null) {
                getUserMediaImpl.applyConstraints(id, constraints, promise);
            } else {
                promise.reject(new Exception("mediaStreamTrackApplyConstraints() could not find track " + id));
            }
        });
    }

    @ReactMethod
    public void mediaStreamTrackSetVolume(int pcId, String id, double volume) {
        ThreadUtils.runOnExecutor(() -> {
            MediaStreamTrack track = getTrack(pcId, id);
            if (track == null) {
                Log.d(TAG, "mediaStreamTrackSetVolume() could not find track " + id);
                return;
            }

            if (!(track instanceof AudioTrack)) {
                Log.d(TAG, "mediaStreamTrackSetVolume() track is not an AudioTrack!");
                return;
            }

            ((AudioTrack) track).setVolume(volume);
        });
    }

    /**
     * This serializes the transceivers current direction and mid and returns them
     * for update when an sdp negotiation/renegotiation happens
     */
    private ReadableArray getTransceiversInfo(PeerConnection peerConnection) {
        WritableArray transceiverUpdates = Arguments.createArray();

        for (RtpTransceiver transceiver : peerConnection.getTransceivers()) {
            WritableMap transceiverUpdate = Arguments.createMap();

            RtpTransceiver.RtpTransceiverDirection direction = transceiver.getCurrentDirection();
            if (direction != null) {
                String directionSerialized = SerializeUtils.serializeDirection(direction);
                transceiverUpdate.putString("currentDirection", directionSerialized);
            }

            transceiverUpdate.putString("transceiverId", transceiver.getSender().id());
            transceiverUpdate.putString("mid", transceiver.getMid());
            transceiverUpdate.putBoolean("isStopped", transceiver.isStopped());
            transceiverUpdate.putMap("senderRtpParameters",
                    SerializeUtils.serializeRtpParameters(transceiver.getSender().getParameters()));
            transceiverUpdate.putMap("receiverRtpParameters",
                    SerializeUtils.serializeRtpParameters(transceiver.getReceiver().getParameters()));
            transceiverUpdates.pushMap(transceiverUpdate);
        }
        return transceiverUpdates;
    }

    @ReactMethod
    public void mediaStreamTrackSetVideoEffects(String id, ReadableArray names) {
        ThreadUtils.runOnExecutor(() -> { getUserMediaImpl.setVideoEffects(id, names); });
    }

    @ReactMethod
    public void peerConnectionSetConfiguration(ReadableMap configuration, int id) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnection peerConnection = getPeerConnection(id);
            if (peerConnection == null) {
                Log.d(TAG, "peerConnectionSetConfiguration() peerConnection is null");
                return;
            }
            peerConnection.setConfiguration(parseRTCConfiguration(configuration));
        });
    }

    @ReactMethod
    public void peerConnectionCreateOffer(int id, ReadableMap options, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
            PeerConnection peerConnection = pco.getPeerConnection();

            if (peerConnection == null) {
                Log.d(TAG, "peerConnectionCreateOffer() peerConnection is null");
                promise.reject(new Exception("PeerConnection not found"));
                return;
            }

            List<String> receiversIds = new ArrayList<>();
            for (RtpTransceiver transceiver : peerConnection.getTransceivers()) {
                receiversIds.add(transceiver.getReceiver().id());
            }

            final SdpObserver observer = new SdpObserver() {
                @Override
                public void onCreateFailure(String s) {
                    ThreadUtils.runOnExecutor(() -> { promise.reject("E_OPERATION_ERROR", s); });
                }

                @Override
                public void onCreateSuccess(SessionDescription sdp) {
                    ThreadUtils.runOnExecutor(() -> {
                        WritableMap params = Arguments.createMap();
                        WritableMap sdpInfo = Arguments.createMap();

                        sdpInfo.putString("sdp", sdp.description);
                        sdpInfo.putString("type", sdp.type.canonicalForm());

                        params.putArray("transceiversInfo", getTransceiversInfo(peerConnection));
                        params.putMap("sdpInfo", sdpInfo);

                        WritableArray newTransceivers = Arguments.createArray();
                        for (RtpTransceiver transceiver : peerConnection.getTransceivers()) {
                            if (!receiversIds.contains(transceiver.getReceiver().id())) {
                                WritableMap newTransceiver = Arguments.createMap();
                                newTransceiver.putInt("transceiverOrder", pco.getNextTransceiverId());
                                newTransceiver.putMap(
                                        "transceiver", SerializeUtils.serializeTransceiver(id, transceiver));
                                newTransceivers.pushMap(newTransceiver);
                            }
                        }

                        params.putArray("newTransceivers", newTransceivers);

                        promise.resolve(params);
                    });
                }

                @Override
                public void onSetFailure(String s) {}

                @Override
                public void onSetSuccess() {}
            };

            peerConnection.createOffer(observer, constraintsForOptions(options));
        });
    }

    @ReactMethod
    public void peerConnectionCreateAnswer(int id, ReadableMap options, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnection peerConnection = getPeerConnection(id);

            if (peerConnection == null) {
                Log.d(TAG, "peerConnectionCreateAnswer() peerConnection is null");
                promise.reject(new Exception("PeerConnection not found"));
                return;
            }

            final SdpObserver observer = new SdpObserver() {
                @Override
                public void onCreateFailure(String s) {
                    ThreadUtils.runOnExecutor(() -> { promise.reject("E_OPERATION_ERROR", s); });
                }

                @Override
                public void onCreateSuccess(SessionDescription sdp) {
                    ThreadUtils.runOnExecutor(() -> {
                        WritableMap params = Arguments.createMap();
                        WritableMap sdpInfo = Arguments.createMap();

                        sdpInfo.putString("sdp", sdp.description);
                        sdpInfo.putString("type", sdp.type.canonicalForm());

                        params.putArray("transceiversInfo", getTransceiversInfo(peerConnection));
                        params.putMap("sdpInfo", sdpInfo);

                        promise.resolve(params);
                    });
                }

                @Override
                public void onSetFailure(String s) {}

                @Override
                public void onSetSuccess() {}
            };

            peerConnection.createAnswer(observer, constraintsForOptions(options));
        });
    }

    @ReactMethod
    public void peerConnectionSetLocalDescription(int pcId, ReadableMap desc, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnection peerConnection = getPeerConnection(pcId);
            if (peerConnection == null) {
                Log.d(TAG, "peerConnectionSetLocalDescription() peerConnection is null");
                promise.reject(new Exception("PeerConnection not found"));
                return;
            }

            final SdpObserver observer = new SdpObserver() {
                @Override
                public void onCreateSuccess(SessionDescription sdp) {}

                @Override
                public void onSetSuccess() {
                    ThreadUtils.runOnExecutor(() -> {
                        WritableMap newSdpMap = Arguments.createMap();
                        WritableMap params = Arguments.createMap();

                        SessionDescription newSdp = peerConnection.getLocalDescription();
                        // Can happen when doing a rollback.
                        if (newSdp != null) {
                            newSdpMap.putString("type", newSdp.type.canonicalForm());
                            newSdpMap.putString("sdp", newSdp.description);
                        }

                        params.putMap("sdpInfo", newSdpMap);
                        params.putArray("transceiversInfo", getTransceiversInfo(peerConnection));

                        promise.resolve(params);
                    });
                }

                @Override
                public void onCreateFailure(String s) {}

                @Override
                public void onSetFailure(String s) {
                    ThreadUtils.runOnExecutor(() -> { promise.reject("E_OPERATION_ERROR", s); });
                }
            };

            if (desc != null) {
                SessionDescription sdp = new SessionDescription(
                        SessionDescription.Type.fromCanonicalForm(Objects.requireNonNull(desc.getString("type"))),
                        desc.getString("sdp"));

                peerConnection.setLocalDescription(observer, sdp);
            } else {
                peerConnection.setLocalDescription(observer);
            }
        });
    }

    @ReactMethod
    public void peerConnectionSetRemoteDescription(int id, ReadableMap desc, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
            PeerConnection peerConnection = pco.getPeerConnection();

            if (peerConnection == null) {
                Log.d(TAG, "peerConnectionSetRemoteDescription() peerConnection is null");
                promise.reject(new Exception("PeerConnection not found"));
                return;
            }

            SessionDescription sdp = new SessionDescription(
                    SessionDescription.Type.fromCanonicalForm(desc.getString("type")), desc.getString("sdp"));

            List<String> receiversIds = new ArrayList<>();
            for (RtpTransceiver transceiver : peerConnection.getTransceivers()) {
                receiversIds.add(transceiver.getReceiver().id());
            }

            final SdpObserver observer = new SdpObserver() {
                @Override
                public void onCreateSuccess(final SessionDescription sdp) {}

                @Override
                public void onSetSuccess() {
                    ThreadUtils.runOnExecutor(() -> {
                        WritableMap newSdpMap = Arguments.createMap();
                        WritableMap params = Arguments.createMap();

                        SessionDescription newSdp = peerConnection.getRemoteDescription();
                        // Be defensive for the rollback cases.
                        if (newSdp != null) {
                            newSdpMap.putString("type", newSdp.type.canonicalForm());
                            newSdpMap.putString("sdp", newSdp.description);
                        }

                        params.putArray("transceiversInfo", getTransceiversInfo(peerConnection));
                        params.putMap("sdpInfo", newSdpMap);

                        WritableArray newTransceivers = Arguments.createArray();
                        for (RtpTransceiver transceiver : peerConnection.getTransceivers()) {
                            if (!receiversIds.contains(transceiver.getReceiver().id())) {
                                WritableMap newTransceiver = Arguments.createMap();
                                newTransceiver.putInt("transceiverOrder", pco.getNextTransceiverId());
                                newTransceiver.putMap(
                                        "transceiver", SerializeUtils.serializeTransceiver(id, transceiver));
                                newTransceivers.pushMap(newTransceiver);
                            }
                        }

                        params.putArray("newTransceivers", newTransceivers);

                        promise.resolve(params);
                    });
                }

                @Override
                public void onCreateFailure(String s) {}

                @Override
                public void onSetFailure(String s) {
                    ThreadUtils.runOnExecutor(() -> { promise.reject("E_OPERATION_ERROR", s); });
                }
            };

            peerConnection.setRemoteDescription(observer, sdp);
        });
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    public WritableMap receiverGetCapabilities(String kind) {
        try {
            return (WritableMap) ThreadUtils
                    .submitToExecutor((Callable<Object>) () -> {
                        MediaStreamTrack.MediaType mediaType;
                        if (kind.equals("audio")) {
                            mediaType = MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO;
                        } else if (kind.equals("video")) {
                            mediaType = MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO;
                        } else {
                            return Arguments.createMap();
                        }

                        RtpCapabilities capabilities = mFactory.getRtpReceiverCapabilities(mediaType);
                        return SerializeUtils.serializeRtpCapabilities(capabilities);
                    })
                    .get();
        } catch (ExecutionException | InterruptedException e) {
            Log.d(TAG, "receiverGetCapabilities() " + e.getMessage());
            return null;
        }
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    public WritableMap senderGetCapabilities(String kind) {
        try {
            return (WritableMap) ThreadUtils
                    .submitToExecutor((Callable<Object>) () -> {
                        MediaStreamTrack.MediaType mediaType;
                        if (kind.equals("audio")) {
                            mediaType = MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO;
                        } else if (kind.equals("video")) {
                            mediaType = MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO;
                        } else {
                            return Arguments.createMap();
                        }

                        RtpCapabilities capabilities = mFactory.getRtpSenderCapabilities(mediaType);
                        return SerializeUtils.serializeRtpCapabilities(capabilities);
                    })
                    .get();
        } catch (ExecutionException | InterruptedException e) {
            Log.d(TAG, "senderGetCapabilities() " + e.getMessage());
            return null;
        }
    }

    @ReactMethod
    public void receiverGetStats(int pcId, String receiverId, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnectionObserver pco = mPeerConnectionObservers.get(pcId);
            if (pco == null || pco.getPeerConnection() == null) {
                Log.d(TAG, "receiverGetStats() peerConnection is null");
                promise.resolve(StringUtils.statsToJSON(new RTCStatsReport(0, new HashMap<>())));
            } else {
                pco.receiverGetStats(receiverId, promise);
            }
        });
    }

    @ReactMethod
    public void senderGetStats(int pcId, String senderId, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnectionObserver pco = mPeerConnectionObservers.get(pcId);
            if (pco == null || pco.getPeerConnection() == null) {
                Log.d(TAG, "senderGetStats() peerConnection is null");
                promise.resolve(StringUtils.statsToJSON(new RTCStatsReport(0, new HashMap<>())));
            } else {
                pco.senderGetStats(senderId, promise);
            }
        });
    }

    @ReactMethod
    public void peerConnectionAddICECandidate(int pcId, ReadableMap candidateMap, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnection peerConnection = getPeerConnection(pcId);
            if (peerConnection == null) {
                Log.d(TAG, "peerConnectionAddICECandidate() peerConnection is null");
                promise.reject(new Exception("PeerConnection not found"));
                return;
            }

            if (!candidateMap.hasKey("sdpMid") && !candidateMap.hasKey("sdpMLineIndex")) {
                promise.reject("E_TYPE_ERROR", "Invalid argument");
                return;
            }

            IceCandidate candidate = new IceCandidate(candidateMap.hasKey("sdpMid") && !candidateMap.isNull("sdpMid")
                            ? candidateMap.getString("sdpMid")
                            : "",
                    candidateMap.hasKey("sdpMLineIndex") && !candidateMap.isNull("sdpMLineIndex")
                            ? candidateMap.getInt("sdpMLineIndex")
                            : 0,
                    candidateMap.getString("candidate"));

            peerConnection.addIceCandidate(candidate, new AddIceObserver() {
                @Override
                public void onAddSuccess() {
                    ThreadUtils.runOnExecutor(() -> {
                        WritableMap newSdpMap = Arguments.createMap();
                        SessionDescription newSdp = peerConnection.getRemoteDescription();
                        newSdpMap.putString("type", newSdp.type.canonicalForm());
                        newSdpMap.putString("sdp", newSdp.description);
                        promise.resolve(newSdpMap);
                    });
                }

                @Override
                public void onAddFailure(String s) {
                    ThreadUtils.runOnExecutor(() -> { promise.reject("E_OPERATION_ERROR", s); });
                }
            });
        });
    }

    @ReactMethod
    public void peerConnectionGetStats(int peerConnectionId, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnectionObserver pco = mPeerConnectionObservers.get(peerConnectionId);
            if (pco == null || pco.getPeerConnection() == null) {
                Log.d(TAG, "peerConnectionGetStats() peerConnection is null");
                promise.resolve(StringUtils.statsToJSON(new RTCStatsReport(0, new HashMap<>())));
            } else {
                pco.getStats(promise);
            }
        });
    }

    @ReactMethod
    public void peerConnectionClose(int id) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
            if (pco == null || pco.getPeerConnection() == null) {
                Log.d(TAG, "peerConnectionClose() peerConnection is null");
                return;
            }
            pco.close();
        });
    }

    @ReactMethod
    public void peerConnectionDispose(int id) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnectionObserver pco = mPeerConnectionObservers.get(id);
            if (pco == null || pco.getPeerConnection() == null) {
                Log.d(TAG, "peerConnectionDispose() peerConnection is null");
            }
            pco.dispose();
            mPeerConnectionObservers.remove(id);
        });
    }

    @ReactMethod
    public void peerConnectionRestartIce(int pcId) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnection peerConnection = getPeerConnection(pcId);
            if (peerConnection == null) {
                Log.w(TAG, "peerConnectionRestartIce() peerConnection is null");
                return;
            }

            peerConnection.restartIce();
        });
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    public WritableMap createDataChannel(int peerConnectionId, String label, ReadableMap config) {
        try {
            return (WritableMap) ThreadUtils
                    .submitToExecutor((Callable<Object>) () -> {
                        PeerConnectionObserver pco = mPeerConnectionObservers.get(peerConnectionId);
                        if (pco == null || pco.getPeerConnection() == null) {
                            Log.d(TAG, "createDataChannel() peerConnection is null");
                            return null;
                        } else {
                            return pco.createDataChannel(label, config);
                        }
                    })
                    .get();
        } catch (ExecutionException | InterruptedException e) {
            return null;
        }
    }

    @ReactMethod
    public void dataChannelClose(int peerConnectionId, String reactTag) {
        ThreadUtils.runOnExecutor(() -> {
            // Forward to PeerConnectionObserver which deals with DataChannels
            // because DataChannel is owned by PeerConnection.
            PeerConnectionObserver pco = mPeerConnectionObservers.get(peerConnectionId);
            if (pco == null || pco.getPeerConnection() == null) {
                Log.d(TAG, "dataChannelClose() peerConnection is null");
                return;
            }

            pco.dataChannelClose(reactTag);
        });
    }

    @ReactMethod
    public void dataChannelDispose(int peerConnectionId, String reactTag) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnectionObserver pco = mPeerConnectionObservers.get(peerConnectionId);
            if (pco == null || pco.getPeerConnection() == null) {
                Log.d(TAG, "dataChannelDispose() peerConnection is null");
                return;
            }

            pco.dataChannelDispose(reactTag);
        });
    }

    @ReactMethod
    public void dataChannelSend(int peerConnectionId, String reactTag, String data, String type) {
        ThreadUtils.runOnExecutor(() -> {
            // Forward to PeerConnectionObserver which deals with DataChannels
            // because DataChannel is owned by PeerConnection.
            PeerConnectionObserver pco = mPeerConnectionObservers.get(peerConnectionId);
            if (pco == null || pco.getPeerConnection() == null) {
                Log.d(TAG, "dataChannelSend() peerConnection is null");
                return;
            }

            pco.dataChannelSend(reactTag, data, type);
        });
    }

    @ReactMethod
    public void generateCertificate(ReadableMap options, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            try {
                PeerConnection.KeyType keyType = PeerConnection.KeyType.ECDSA;
                long expires = 2592000L; // Default 30 days

                if (options.hasKey("keyType")) {
                    String keyTypeStr = options.getString("keyType");
                    if ("RSA".equals(keyTypeStr)) {
                        keyType = PeerConnection.KeyType.RSA;
                    } else if ("ECDSA".equals(keyTypeStr)) {
                        keyType = PeerConnection.KeyType.ECDSA;
                    }
                }

                if (options.hasKey("expires")) {
                    expires = (long) options.getDouble("expires");
                }

                RtcCertificatePem cert = RtcCertificatePem.generateCertificate(keyType, expires);
                String certId = java.util.UUID.randomUUID().toString();
                synchronized (mCertificates) {
                    mCertificates.put(certId, cert);
                }

                WritableMap params = Arguments.createMap();
                params.putString("certificateId", certId);
                // Return expires as millis since epoch
                params.putDouble("expires", System.currentTimeMillis() + expires * 1000);

                // Calculate fingerprints
                WritableArray fingerprints = Arguments.createArray();

                try {
                    CertificateFactory cf = CertificateFactory.getInstance("X.509");
                    ByteArrayInputStream is = new ByteArrayInputStream(cert.certificate.getBytes(StandardCharsets.UTF_8));
                    X509Certificate x509Cert = (X509Certificate) cf.generateCertificate(is);

                    MessageDigest digest = MessageDigest.getInstance("SHA-256");
                    byte[] hash = digest.digest(x509Cert.getEncoded());

                    WritableMap fingerprint = Arguments.createMap();
                    fingerprint.putString("algorithm", "sha-256");
                    fingerprint.putString("value", bytesToHex(hash));
                    fingerprints.pushMap(fingerprint);
                } catch (Exception e) {
                    Log.e(TAG, "Failed to calculate fingerprint: " + e.getMessage());
                }

                params.putArray("fingerprints", fingerprints);

                promise.resolve(params);
            } catch (Exception e) {
                promise.reject(e);
            }
        });
    }

    private String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
            sb.append(":");
        }
        if (sb.length() > 0) {
            sb.setLength(sb.length() - 1);
        }
        return sb.toString();
    }

    /**
     * Starts a call recording segment. Mirrors the iOS API: resolves null on success,
     * rejects with "duplicate_id" / "no_sources" / "io_error".
     */
    @ReactMethod
    public void startCallRecording(ReadableMap options, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            String recordingId = options.hasKey("recordingId") ? options.getString("recordingId") : null;
            String wavPath = options.hasKey("wavPath") ? options.getString("wavPath") : null;
            String outputPath = options.hasKey("outputPath") ? options.getString("outputPath") : null;
            boolean includeMic = options.hasKey("includeMic") && options.getBoolean("includeMic");
            // Absent means mono: the caller owns the product decision, and an older caller
            // that never sends the flag keeps the layout it was written against.
            boolean stereo = options.hasKey("stereo") && options.getBoolean("stereo");
            ReadableArray remoteTrackIds = options.hasKey("remoteTrackIds") ? options.getArray("remoteTrackIds") : null;
            ReadableArray peerConnectionIds =
                    options.hasKey("peerConnectionIds") ? options.getArray("peerConnectionIds") : null;

            // REFUSE THE OLD KEY LOUDLY. `m4aPath` was renamed to `outputPath` when the
            // container stopped being fixed. Accepting it would mean a stale JS bundle
            // silently writing mp4 bytes to a path called .m4a — playable by nothing, and
            // traceable to nothing.
            if (outputPath == null && options.hasKey("m4aPath")) {
                promise.reject("io_error",
                        "startCallRecording: `m4aPath` was renamed to `outputPath`; this JS bundle is too old");
                return;
            }
            if (recordingId == null || recordingId.isEmpty()) {
                promise.reject("io_error", "startCallRecording requires recordingId");
                return;
            }
            // BOTH OR NEITHER. A caller that owns its files gives both paths; the library's
            // MediaRecorder gives none and records into recordingsDirectory. One of the two on
            // its own is a caller that forgot something, and a recording written half where
            // it expects is worse than a refusal.
            if ((wavPath == null) != (outputPath == null)) {
                promise.reject("io_error", "startCallRecording: give both wavPath and outputPath, or neither");
                return;
            }
            if (wavPath == null) {
                // The id becomes a file name; a path in it would escape the directory.
                if (recordingId.contains("/") || recordingId.contains("..")) {
                    promise.reject("io_error", "startCallRecording: recordingId must not contain '/' or '..'");
                    return;
                }
                File dir = new File(recordingsDirectory());
                if (!dir.isDirectory() && !dir.mkdirs()) {
                    promise.reject("io_error", "startCallRecording: could not create " + dir.getPath());
                    return;
                }
                wavPath = new File(dir, recordingId + ".wav").getPath();
                boolean wantsVideo = options.hasKey("video") && !options.isNull("video");
                outputPath = new File(dir, recordingId + (wantsVideo ? ".mp4" : ".m4a")).getPath();
            }

            List<Pair<AudioTrack, Integer>> remoteAudioTracks =
                    resolveRemoteAudioTracks(remoteTrackIds, peerConnectionIds);
            CallAudioRecordingManager.VideoRecordingRequest video =
                    resolveVideoRequest(options.hasKey("video") ? options.getMap("video") : null);
            mCallAudioRecordingManager.startRecording(
                    recordingId, wavPath, outputPath, includeMic, stereo, remoteAudioTracks, video, promise);
        });
    }

    /**
     * Swap the composited video sources for a live segment. Resolves either way — a no-op on
     * an audio-only segment or an unknown id, because the caller is reporting a source change
     * and not asserting that a compositor exists to hear it.
     */
    @ReactMethod
    public void updateCallRecordingVideoSources(String recordingId, ReadableMap sources, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            CallAudioRecordingManager.VideoRecordingRequest resolved = resolveVideoRequest(sources);
            if (resolved == null) {
                mCallAudioRecordingManager.updateVideoSources(recordingId, null, new ArrayList<>());
            } else {
                mCallAudioRecordingManager.updateVideoSources(
                        recordingId, resolved.localTrack, resolved.remoteTracks);
            }
            promise.resolve(null);
        });
    }

    /**
     * Builds the video request from the JS `video` block, or null for an audio-only segment.
     *
     * RESOLVING NOTHING IS NOT AN ERROR. A camera that is off and a remote that has not
     * started sending both land here with no tracks, and the honest outcome is an audio
     * recording that SAYS it has no video — not a refused segment. Must run on the executor.
     */
    @Nullable
    private CallAudioRecordingManager.VideoRecordingRequest resolveVideoRequest(@Nullable ReadableMap video) {
        if (video == null) {
            return null;
        }
        ReadableArray pcHints = video.hasKey("peerConnectionIds") ? video.getArray("peerConnectionIds") : null;

        CallAudioRecordingManager.VideoRecordingRequest request =
                new CallAudioRecordingManager.VideoRecordingRequest();
        request.width = video.hasKey("width") ? video.getInt("width") : 0;
        request.height = video.hasKey("height") ? video.getInt("height") : 0;
        request.fps = video.hasKey("fps") ? video.getInt("fps") : 0;
        request.pnpSize = video.hasKey("pnpSize") ? video.getInt("pnpSize") : 0;
        request.layout = video.hasKey("layout") ? video.getString("layout") : null;

        // The local camera / presentation track is a LOCAL track, so it is not in any peer
        // connection's remoteTracks — getLocalTrack is the only place it lives.
        String localId = video.hasKey("localTrackId") ? video.getString("localTrackId") : null;
        if (localId != null) {
            MediaStreamTrack local = getLocalTrack(localId);
            if (local instanceof VideoTrack) {
                request.localTrack = (VideoTrack) local;
            } else {
                Log.w(TAG, "startCallRecording: local video track not found: " + localId);
            }
        }

        ReadableArray remoteIds = video.hasKey("remoteTrackIds") ? video.getArray("remoteTrackIds") : null;
        if (remoteIds != null) {
            for (int i = 0; i < remoteIds.size(); i++) {
                String trackId = remoteIds.getString(i);
                if (trackId == null) {
                    continue;
                }
                MediaStreamTrack track = findRemoteTrack(trackId, pcHints);
                if (!(track instanceof VideoTrack)) {
                    Log.w(TAG, "startCallRecording: remote video track not found, skipping: " + trackId);
                    continue;
                }
                if (!request.remoteTracks.contains(track)) {
                    request.remoteTracks.add((VideoTrack) track);
                }
            }
        }

        if (request.localTrack == null && request.remoteTracks.isEmpty()) {
            Log.w(TAG, "startCallRecording: video requested but no video track resolved — recording audio only");
            return null;
        }
        if (request.width <= 0 || request.height <= 0 || request.fps <= 0) {
            Log.w(TAG, "startCallRecording: video block has no usable geometry — recording audio only");
            return null;
        }
        return request;
    }

    /** Hinted-then-exhaustive remote track lookup, shared by the audio and video resolvers. */
    @Nullable
    private MediaStreamTrack findRemoteTrack(String trackId, @Nullable ReadableArray pcIdHints) {
        if (pcIdHints != null) {
            for (int j = 0; j < pcIdHints.size(); j++) {
                PeerConnectionObserver pco = mPeerConnectionObservers.get(pcIdHints.getInt(j));
                if (pco != null) {
                    MediaStreamTrack candidate = pco.remoteTracks.get(trackId);
                    if (candidate != null) {
                        return candidate;
                    }
                }
            }
        }
        for (int j = 0; j < mPeerConnectionObservers.size(); j++) {
            MediaStreamTrack candidate = mPeerConnectionObservers.valueAt(j).remoteTracks.get(trackId);
            if (candidate != null) {
                return candidate;
            }
        }
        return null;
    }

    /**
     * Stops a recording segment. Resolves { recordingId, filePath, durationMs, size } only
     * after the .m4a finalize completes; rejects "not_found" / "encode_error".
     */
    @ReactMethod
    public void stopCallRecording(String recordingId, Promise promise) {
        ThreadUtils.runOnExecutor(() -> mCallAudioRecordingManager.stopRecording(recordingId, promise));
    }

    @ReactMethod
    public void getActiveCallRecordings(Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            WritableArray ids = Arguments.createArray();
            for (String recordingId : mCallAudioRecordingManager.getActiveRecordingIds()) {
                ids.pushString(recordingId);
            }
            promise.resolve(ids);
        });
    }

    @ReactMethod
    public void finalizeOrphanRecording(String wavPath, String m4aPath, Promise promise) {
        // Runs on the manager's encode executor; must not occupy the WebRTC executor.
        mCallAudioRecordingManager.finalizeOrphanRecording(wavPath, m4aPath, promise);
    }

    /**
     * Resolves remote audio tracks for call recording. The peer connection ids are hints:
     * tracks are looked up there first, then by scanning every observer, so a stale hint
     * cannot lose a track. Unresolvable ids are skipped (the recorder zero-pads); only a
     * fully empty result makes the manager reject with "no_sources". Must run on the
     * executor.
     */
    private List<Pair<AudioTrack, Integer>> resolveRemoteAudioTracks(
            @Nullable ReadableArray trackIds, @Nullable ReadableArray pcIdHints) {
        List<Pair<AudioTrack, Integer>> resolved = new ArrayList<>();
        if (trackIds == null) {
            return resolved;
        }
        for (int i = 0; i < trackIds.size(); i++) {
            String trackId = trackIds.getString(i);
            if (trackId == null) {
                continue;
            }
            MediaStreamTrack track = null;
            int ownerPcId = -1;
            if (pcIdHints != null) {
                for (int j = 0; j < pcIdHints.size() && track == null; j++) {
                    int pcId = pcIdHints.getInt(j);
                    PeerConnectionObserver pco = mPeerConnectionObservers.get(pcId);
                    if (pco != null) {
                        MediaStreamTrack candidate = pco.remoteTracks.get(trackId);
                        if (candidate != null) {
                            track = candidate;
                            ownerPcId = pcId;
                        }
                    }
                }
            }
            for (int j = 0; j < mPeerConnectionObservers.size() && track == null; j++) {
                MediaStreamTrack candidate = mPeerConnectionObservers.valueAt(j).remoteTracks.get(trackId);
                if (candidate != null) {
                    track = candidate;
                    ownerPcId = mPeerConnectionObservers.keyAt(j);
                }
            }
            if (track == null) {
                Log.w(TAG, "startCallRecording: remote track not found, skipping: " + trackId);
                continue;
            }
            if (!MediaStreamTrack.AUDIO_TRACK_KIND.equals(track.kind())) {
                Log.w(TAG, "startCallRecording: track is not audio, skipping: " + trackId);
                continue;
            }
            resolved.add(Pair.create((AudioTrack) track, ownerPcId));
        }
        return resolved;
    }

    @ReactMethod
    public void addListener(String eventName) {
        // Keep: Required for RN built in Event Emitter Calls.
    }

    @ReactMethod
    public void removeListeners(Integer count) {
        // Keep: Required for RN built in Event Emitter Calls.
    }

    // =====================================================================
    // Conference audio
    // =====================================================================

    /**
     * Put a leg on the conference bus and start tapping its remote audio.
     *
     * @param host true for the leg already carried by the app's main factory. Exactly one
     *             leg can be the host, because that factory has a single outbound to
     *             overwrite; every other leg needs a factory of its own, which is chosen
     *             when its PeerConnection is created and cannot be changed afterwards.
     */
    @ReactMethod
    public void conferenceAttachLeg(int pcId, String legId, boolean host, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            PeerConnectionObserver pco = mPeerConnectionObservers.get(pcId);
            if (pco == null) {
                promise.reject("no_peerconnection", "No peer connection " + pcId);
                return;
            }
            List<AudioTrack> remote = new ArrayList<>();
            for (MediaStreamTrack track : pco.remoteTracks.values()) {
                if (MediaStreamTrack.AUDIO_TRACK_KIND.equals(track.kind())) {
                    remote.add((AudioTrack) track);
                }
            }
            mConferenceMixManager.attachLeg(legId, remote, host);
            promise.resolve(true);
        });
    }

    /**
     * Give a synthesised leg's PeerConnection a local audio track FROM ITS OWN FACTORY.
     *
     * Not getUserMedia, which always builds on the app's single factory: a track from the
     * wrong factory does not crash, it silently sends the wrong audio, so the leg's own
     * factory has to mint it.
     */
    @ReactMethod
    public void conferenceAttachLegAudio(int pcId, String legId, Promise promise) {
        try {
            PeerConnectionFactory factory = mConferenceMixManager.factoryForLeg(
                    legId, mVideoEncoderFactory, mVideoDecoderFactory);
            if (factory == null) {
                promise.reject("no_leg_factory", "No factory for leg " + legId);
                return;
            }
            PeerConnectionObserver pco = mPeerConnectionObservers.get(pcId);
            if (pco == null || pco.getPeerConnection() == null) {
                promise.reject("no_peerconnection", "No peer connection " + pcId);
                return;
            }
            ThreadUtils.submitToExecutor(() -> {
                AudioSource source = factory.createAudioSource(new MediaConstraints());
                AudioTrack track = factory.createAudioTrack("conference-" + legId, source);
                pco.getPeerConnection().addTrack(track, Collections.singletonList("conference-" + legId));
            }).get();
            promise.resolve(true);
        } catch (Throwable e) {
            Log.e(TAG, "conferenceAttachLegAudio failed", e);
            promise.reject("conference_attach_audio_failed", e.getMessage(), e);
        }
    }

    /** Take one leg out of the mix. The rest of the conference carries on. */
    @ReactMethod
    public void conferenceDetachLeg(String legId, Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            mConferenceMixManager.detachLeg(legId);
            promise.resolve(true);
        });
    }

    /** The conference is over. Idempotent, and safe when none was ever up. */
    @ReactMethod
    public void conferenceTeardown(Promise promise) {
        ThreadUtils.runOnExecutor(() -> {
            mConferenceMixManager.teardown();
            promise.resolve(true);
        });
    }

    /**
     * Mute inside a conference.
     *
     * On the bus rather than on the sender track, because in a conference the sender track
     * is the MIX - muting it would mute everyone.
     */
    @ReactMethod
    public void conferenceSetMicMuted(boolean muted, Promise promise) {
        mConferenceMixManager.setMicMuted(muted);
        promise.resolve(true);
    }

    @ReactMethod
    public void conferenceGetLegs(Promise promise) {
        WritableArray ids = Arguments.createArray();
        for (String legId : mConferenceMixManager.legIds()) {
            ids.pushString(legId);
        }
        promise.resolve(ids);
    }
}
