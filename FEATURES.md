# Features

What `siperb-rn-webrtc` supports today, on which platform, and what it deliberately does
not. It is Siperb's fork of `react-native-webrtc` (upstream `master`, June 2026, resynced by
patch — see [CLAUDE.md](CLAUDE.md)) on top of **LiveKit webrtc-sdk 125.6422.07** (WebRTC
M125), extended with call recording, conference mixing, in-band DTMF and screen-share
plumbing for the Siperb phone.

## At a glance

| | Android | iOS | macOS | tvOS |
|---|:-:|:-:|:-:|:-:|
| Audio / video calls (`getUserMedia`, `RTCPeerConnection`) | ✅ | ✅ | ⚠️ | ❌ |
| Data channels | ✅ | ✅ | ⚠️ | ❌ |
| Screen capture (`getDisplayMedia`) | ✅ MediaProjection | ✅ ReplayKit broadcast extension | ❌ | ❌ |
| Video rendering (`RTCView`) | ✅ | ✅ + Picture-in-Picture | ⚠️ | – |
| In-band DTMF (RFC 4733) | ✅ | ✅ | ⚠️ | ❌ |
| Native call recording (audio, video) | ✅ | ✅ | ❌ | ❌ |
| Native conference mixing | ✅ | ✅ | ❌ | ❌ |
| CallKit manual audio (`RTCAudioSession`) | – | ✅ | – | – |

Android: `minSdkVersion 24`. iOS: 12.0+. **macOS** ⚠️: the Xcode project under `macos/` has
not been kept up with the fork's new sources and is not built or tested. **tvOS** ❌: the
podspec lists it, but `getUserMedia` returns `PlatformNotSupported` and no capture path exists.

## Standard WebRTC API (W3C-shaped)

The JS layer mirrors the browser API so web WebRTC code ports largely unchanged;
`registerGlobals()` installs the classes and `navigator.mediaDevices` onto `global`.

### Media capture

| API | Notes |
|---|---|
| `mediaDevices.getUserMedia({ audio, video })` | Requests OS permission itself. Video constraints: `deviceId`, `facingMode` (`user`/`environment`), `width`, `height`, `frameRate` (defaults 1280×720 @ 30, front camera). Audio constraints are passed to the engine on Android (`goog*` names); iOS ignores them. Denied media is dropped rather than failing the call when the other kind was granted. |
| `mediaDevices.getDisplayMedia()` | Android: MediaProjection behind a foreground service (started automatically on 10+; permissions declared in the library manifest). iOS: ReplayKit via a Broadcast Upload Extension — see *Screen share* below. |
| `mediaDevices.enumerateDevices()` | Cameras with `facing`; a single placeholder `audioinput` (the OS owns audio routing). |
| `permissions.request/query({ name })` | `camera`, `microphone`. |
| `MediaStream` | `addTrack`/`removeTrack`/`getTracks`/`getAudioTracks`/`getVideoTracks`/`getTrackById`, `toURL()` for `RTCView`, and the non-standard `release()` that frees native resources (`track.stop()` alone does not). |
| `MediaStreamTrack` | `enabled`, `muted`, `readyState`, `stop()`, `getSettings()`, `getConstraints()`, `applyConstraints()` (video only — camera switch/resolution/fps without renegotiation), `mute`/`unmute`/`ended` events. **`muted` on a local audio track reflects the real microphone**: it flips to `true` (with a `mute` event) when capture fails — Android `AudioRecord` init/start/runtime errors; iOS audio-unit start failure, an audio-session interruption, or media-server loss — and back on recovery. A track created while the microphone is failing is born `muted`. Non-standard: `_switchCamera()`, `_setVolume()` (audio gain 0–10), `_setVideoEffects(names)` (native frame processors registered through `ProcessorProvider`). |

### Peer connection

| API | Notes |
|---|---|
| `RTCPeerConnection` | Unified Plan only. `createOffer`/`createAnswer`, `setLocalDescription`/`setRemoteDescription` (incl. rollback), `addIceCandidate`, `addTrack`/`removeTrack`/`addTransceiver`, `getSenders`/`getReceivers`/`getTransceivers`, `getStats(selector?)`, `restartIce()`, `setConfiguration`, `createDataChannel`, `close()`. Events: `track`, `icecandidate`, `icecandidateerror`, `negotiationneeded`, `connectionstatechange`, `iceconnectionstatechange`, `icegatheringstatechange`, `signalingstatechange`, `datachannel`. |
| `RTCPeerConnection.generateCertificate()` | `RTCCertificate` kept native-side; only an id crosses the bridge. |
| Configuration | ICE servers, `iceTransportPolicy`, bundle/rtcp-mux policies, ICE candidate pool, GCM crypto suites on, implicit rollback on. Fork extra: `siperbConferenceLegId` (see *Conference mixing*). |
| `RTCRtpSender` | `replaceTrack`, `getParameters`/`setParameters` (encodings, degradation preference), `getStats`, static `getCapabilities(kind)`, `dtmf` (fork). |
| `RTCRtpReceiver` | `track`, `getParameters`, `getStats`, static `getCapabilities(kind)`. |
| `RTCRtpTransceiver` | `direction`/`currentDirection`, `mid`, `stop()`, `setCodecPreferences()`. Simulcast via send encodings. |
| `RTCDataChannel` | Ordered/unordered, `maxRetransmits`/`maxPacketLifeTime`, negotiated ids, string and binary (`ArrayBuffer`) messages, `bufferedAmount` + `bufferedamountlow`. |

### Rendering

| API | Notes |
|---|---|
| `RTCView` | `streamURL` (from `stream.toURL()`), `objectFit` `contain`/`cover`, `mirror`, `zOrder`, `onDimensionsChange`. |
| `RTCPIPView` + `startIOSPIP(ref)` / `stopIOSPIP(ref)` | iOS Picture-in-Picture for a video view; options `enabled`, `preferredSize`, `startAutomatically` (on background), `stopAutomatically` (on foreground), and a `fallbackView` shown in place of the video while PiP is active. |
| `ScreenCapturePickerView` | iOS: wraps `RPSystemBroadcastPickerView`; present the system sheet with the `show` view-manager command. |

### Engine

- **Video codecs** — Android: hardware H.264 plus software VP8/VP9/AV1 (`H264AndSoftware*Factory`); iOS: WebRTC's default factories (H.264 hardware, VP8/VP9/AV1 software). Both replaceable via `WebRTCModuleOptions`.
- **Audio** — Opus and the built-in codecs; software AEC/NS/AGC (Android defers to hardware AEC/NS when the device offers them).
- **Logging** — `debug`-style namespaces `rn-webrtc:*` routed to `console.log`; native log level settable through the options.

## Siperb additions

### In-band DTMF (RFC 4733)
`sender.dtmf` on any audio `RTCRtpSender`: `insertDTMF(tones, duration?, interToneGap?)`,
`canInsertDTMF` (true once `telephone-event` is negotiated), `toneBuffer`, `tonechange`
events. The engine produces the RTP; the events are a JS approximation of playout timing.

### Native call recording — `CallRecorder`
Records a call **below the encoder**, so no audio ever crosses the JS bridge.
- **Sources**: the microphone (post-AEC tap in the engine's audio pipeline) and any set of remote
  audio tracks, mixed to 48 kHz. Mono, or channel-split stereo (mic left, remotes right).
- **Output**: a crash-safe WAV streamed during the call, finalized to AAC `.m4a` on stop;
  `finalizeOrphan(wav, m4a)` salvages a recording after a crash or kill.
- **Video** (`supportsVideo`): composites named local + remote video tracks at a fixed frame rate
  — layouts `them-pnp`, `side-by-side`, `us-only`, `them-only` — encodes H.264 and muxes with the
  same mixed audio into `.mp4`. Sources can be swapped mid-segment (`updateVideoSources`), e.g.
  when a presentation replaces the camera. A video leg that cannot start or dies mid-call
  degrades to the audio file and reports `withVideo: false`; it never fails the segment.
- **Lifecycle**: `start` / `stop` (resolves once the container is final) / `getActive`;
  events `audioRecordingStarted`, `audioRecordingStopped`, `audioRecordingError`.
- Recording sinks are detached automatically when a peer connection closes.

### Native conference mixing — `ConferenceMixer`
Three-way (and N-way) calls mixed natively: each remote party is sent the microphone plus every
*other* party, never itself. Because one peer-connection factory has one outbound audio path,
the host leg keeps the app's factory and each further leg is born on its own — declared at
construction with `new RTCPeerConnection({ ..., siperbConferenceLegId })`.
`attachLeg(pcId, legId, host)`, `attachLegAudio`, `detachLeg`, `teardown`, `getLegs`, and
`setMicMuted` — mute happens *in the mix*, so it silences only you, not the whole leg.
Idle-cost is zero for ordinary 1:1 calls; a pure-Java test suite covers the bus
(`android/tests/run.sh`).

### Screen share that tells the truth
- `mediaDevices.supportsDisplayMedia` — a native constant saying whether `getDisplayMedia()` on
  *this build* can deliver a frame (iOS: extension bundled, App Group entitled, Info.plist keys
  present; Android: foreground service enabled and permitted). Gate the feature on it.
- The iOS screen track is created **`muted`** and fires `unmute` when the Broadcast Upload
  Extension connects — the only signal that the user tapped *Start Broadcast* rather than
  dismissing the picker. `ended` fires when the broadcast stops.
- `BroadcastExtension/` — the extension half as its own pod (`SiperbBroadcastExtension`): an
  `RPBroadcastSampleHandler` that streams ReplayKit frames to the host app over the App Group
  socket. Add it to the extension target, not the app.

### iOS audio session control — `RTCAudioSession`
`audioSessionDidActivate()` / `audioSessionDidDeactivate()` for apps that run WebRTC in
manual-audio mode and drive it from CallKit's `didActivate` / `didDeactivate`.

## Native integration options

Set before the bridge starts (`WebRTCModuleOptions`, both platforms unless noted):
custom video encoder/decoder factories, a custom audio device module (Android) / `audioDevice`
(iOS) — note this disables the recorder's mic tap —, field trials, native log severity,
`enableMediaProjectionService` (Android, default on), `enableMultitaskingCameraAccess` (iOS).

## Not supported or partial

- `MediaStream.clone()`, `MediaStreamTrack.clone()`, `MediaStreamTrack.getCapabilities()` — throw `Not implemented`.
- `applyConstraints()` on audio tracks; audio constraints on iOS.
- End-of-candidates signalling (`addIceCandidate(null)` is accepted as a no-op).
- Insertable streams / encoded transforms, identity assertions, Plan B.
- A microphone failure is reported as `mute`, never `ended`: the engine retries capture on the next session, so the track stays usable and `unmute` follows when it recovers. "Not sending yet" (no peer connection sending) is deliberately not modelled as muted.
- macOS and tvOS targets are unmaintained; see the table above.

## More

- [README.md](README.md) — install and platform guides
- [Architecture.md](Architecture.md) — how the JS layer, the bridge and the native modules fit together
- [Documentation/](Documentation) — Android/iOS installation, basic usage, call reliability guide
- [CLAUDE.md](CLAUDE.md) — conventions and the upstream resync procedure
