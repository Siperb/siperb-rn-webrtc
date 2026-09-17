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
| `MediaRecorder` + `AudioContext` (W3C subset over the native recorder/mixer, incl. `replaceTrack(mix)` → conference leg) | ✅ | ✅ | ❌ | ❌ |
| Native conference mixing | ✅ | ✅ | ❌ | ❌ |
| File source that streams a video file, soundtrack included (`getFileMedia`) | ✅ MediaPlayer + MediaCodec | ✅ AVPlayer + MTAudioProcessingTap | ❌ | ❌ |
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

### `MediaRecorder` and `AudioContext` — W3C-shaped, natively backed
For web code that feature-detects them (the shared phone SDK does), the library provides the
subset such code uses — no DSP in JS, the native recorder and mixer do the work:
- **`AudioContext`**: `createMediaStreamSource/Destination`, `createGain`, `createChannelMerger`,
  `connect(dest, output, input)` / `disconnect()`, `gain.value`, `state`, `resume`/`suspend`/`close`,
  `statechange`. The graph is *declarative*: a destination's stream carries one virtual audio
  track that stands for whatever is wired to it. Absent on purpose (feature probes must fail):
  `createMediaElementSource`, oscillators, analysers, `decodeAudioData`, worklets.
- **`MediaRecorder(stream, options?)`**: `start()`, `stop()`, `state`, `mimeType`, `stream`,
  `isTypeSupported()` (`audio/mp4`, `video/mp4`), events `start`/`stop`/`dataavailable`/`error`
  with `BlobEvent` and DOMException-named errors. A virtual mix track compiles to the recorder's
  options (local sources → mic, remote → tapped tracks, two merger inputs → channel-split stereo);
  real tracks record directly; video tracks engage the compositor (non-standard `options.video`
  for geometry). `dataavailable.data` is a `RecordingBlob`: `size`, `type`, plus `path`/`uri` — a
  file reference, not bytes. One chunk at stop: `pause`/`resume`/`requestData`/`timeslice` throw
  `NotSupportedError`.
- **Host seam**: subclass and override `startNative`/`stopNative` to own ids, paths and rows
  (react-native-siperb-phone does). Defaults write under `CallRecorder.recordingsDirectory`.
- **Conference via `replaceTrack`**: `sender.replaceTrack(destination.stream.getAudioTracks()[0])`
  attaches the sender's peer connection to the native conference bus (`ConferenceMixer.attachLeg`)
  — child legs under their `siperbConferenceLegId`, the host under `pc-<id>` — and
  `replaceTrack(realTrack)` / `context.close()` / `track.stop()` / the connection closing detach it
  and restore the sender's real track. Nothing is swapped natively; the bus overwrites the capture
  below the encoder. Idempotent across the SDK's per-join republish.
- `registerGlobals()` installs both only when the native recorder / conference bus exist in the
  binary, and never over a host-installed class.

### Native conference mixing — `ConferenceMixer`
Three-way (and N-way) calls mixed natively: each remote party is sent the microphone plus every
*other* party, never itself. Because one peer-connection factory has one outbound audio path,
the host leg keeps the app's factory and each further leg is born on its own — declared at
construction with `new RTCPeerConnection({ ..., siperbConferenceLegId })`. **Until a host leg
is attached (the Join), a leg born that way is an ordinary call**: its capture passes the real
microphone through, so the third party hears you during the consultation; the overwrite-with-mix
only starts once `attachLeg(host: true)` has run.
`attachLeg(pcId, legId, host)`, `attachLegAudio`, `detachLeg`, `teardown`, `getLegs`, and
`setMicMuted` — mute happens *in the mix*, so it silences only you, not the whole leg.
Idle-cost is zero for ordinary 1:1 calls; a pure-Java test suite covers the bus
(`android/tests/run.sh`).

### Screen share that tells the truth
- `mediaDevices.supportsDisplayMedia` — a native constant saying whether `getDisplayMedia()` on
  *this build* can deliver a frame (iOS: extension bundled, App Group entitled, Info.plist keys
  present; Android: foreground service enabled and permitted). Gate the feature on it.
  On iOS it is `YES` only when **all four** of these hold — `isDisplayMediaSupported`
  (`ios/RCTWebRTC/WebRTCModule.m`) checks them in order and returns `NO` on the first miss, with
  no log: (1) a real device — Simulator/macOS/tvOS is always `NO`; (2) `RTCAppGroupIdentifier` and
  `RTCScreenSharingExtension` in the app's `Info.plist`; (3) the App Group *entitlement* on the
  running build (`containerURLForSecurityApplicationGroupIdentifier:` is nil when the profile is
  not entitled — the key in the plist is not enough); (4) the extension bundled under `PlugIns/`
  as a `com.apple.broadcast-services-upload` appex. Consumers get all four from
  `react-native-siperb-phone`'s `siperb_broadcast_extension!` Podfile helper.
- The iOS screen track is created **`muted`** and fires `unmute` when the Broadcast Upload
  Extension connects — the only signal that the user tapped *Start Broadcast* rather than
  dismissing the picker. `ended` fires when the broadcast stops.
- `BroadcastExtension/` — the extension half as its own pod (`SiperbBroadcastExtension`): an
  `RPBroadcastSampleHandler` that streams ReplayKit frames to the host app over the App Group
  socket. Add it to the extension target, not the app.

### View source that streams a canvas — `getWhiteboardMedia` / `getPictureMedia`
The React Native analogue of the web's `canvas.captureStream(fps)`: a native **view** (or a decoded
still image) is rasterised into an `RTCVideoSource` and sampled on a timer, so the pixels never
cross the bridge. It is the in-process sibling of screen capture — `ViewFrameCapturer` plays the
role of the screen capturer on both platforms: on iOS it feeds the same `didCaptureVideoFrame:` →
`RTCVideoFrame` path as `ScreenCapturer`; on Android it is a `VideoCapturer` drawing the view to the
`SurfaceTextureHelper`'s Surface with a software `Canvas`, the same helper → `CapturerObserver`
machinery `ScreenCapturerAndroid` uses, minus the `VirtualDisplay`. Because the source is in-process
there is **no extension, App Group, entitlement, plist key or Simulator gate on iOS, and no
MediaProjection, foreground service or runtime permission on Android**. Use it for a whiteboard (draw
with any renderer; the layer is what streams) or to present a picture.
- `mediaDevices.supportsFrameSource` — a native constant, `true` on both platforms wherever the code
  is present. Unlike `supportsDisplayMedia` it depends on no app packaging; its only job is version
  skew (an OTA JS bundle reaching an older binary reads it `undefined` and withholds the builders).
- `mediaDevices.getWhiteboardMedia({ sourceTag, fps? })` — sample the mounted view whose React tag is
  `sourceTag` (its `findNodeHandle`) at `fps` (default 10; a drawing is near-static, so keep it low).
  Resolves a `MediaStream` with one video track that delivers from the first tick (never born muted).
  `videoSourceForScreenCast:YES` under the hood — a whiteboard is screen-like content, so the
  encoder favours sharp strokes over frame rate.
- `mediaDevices.getPictureMedia({ uri, fps? })` — present a still (local file / `file://` / `data:`
  URI) as a video track, re-emitted at a low `fps` (default 2) to keep the track flowing.
- The tick runs on the main/UI thread on both platforms. iOS: `drawViewHierarchyInRect:afterScreenUpdates:NO`,
  which captures GPU-composited content — Skia/Metal — that `-[CALayer renderInContext:]` cannot; a
  target view that deallocates ends the track cleanly (`capturerDidEnd:`). Android: `View.draw()` into
  `Surface.lockCanvas()` — a **software** canvas, so a hardware-only layer (a GL/Vulkan surface) draws
  blank, but `react-native-svg` (the whiteboard renderer) draws through the ordinary Canvas and captures
  exactly; a target view that is garbage-collected stops the tick. Android resolves the view through
  the Paper `UIManagerModule` (`resolveView(tag)`), so it needs the classic renderer.

### File source that streams a video file, soundtrack included — `getFileMedia`
The React Native analogue of the web's "load a file into `<video>`, then `captureStream()`". A
native player decodes the file: its frames go into a real video track through the same capturer
pipeline the camera and the screen use (`FileFrameSource` on iOS, `FileVideoCapturer` + `FileSource`
on Android), and its **soundtrack goes onto the native conference bus as an AUX source** — summed
into every leg's outbound mix beside the microphone, so the far end hears mic + file on a 1:1 call
and on a conference alike. One `MediaStream` comes back carrying both halves, the exact shape a
`<video>` element's `captureStream()` has, so a host assigns it to both `PresentVideoMediaStream`
and `PresentAudioMediaStream` and the SDK's present path needs no glue.
- `mediaDevices.supportsFileSource` — the native constant AND the three methods present; a host
  withholds "present a video file" where this is false (OTA-vs-binary skew, a partial binary).
- `mediaDevices.getFileMedia({ uri, fps?, maxSide?, autoplay? })` — `file://` or `content://` (a URI
  the player can read for the whole playback: copy a picker's result, or take a persistable grant);
  `fps` 25 and `maxSide` 360 by default (the web's canvas rate and `VideoResampleSize`: the SHORTER
  side is capped, WebRTC scales natively); `autoplay` false by default so a host can present first and
  `play()` once the mix is up, losing none of the opening second to the attach. Resolves a
  `FileMediaStream`: a `FileVideoTrack` (real, `screencast: NO` — a film is motion video) plus a
  virtual `FileAudioTrack` whose `_auxId` is the video track's id, and `stream.playback`.
- **`stream.playback`** — HTMLMediaElement vocabulary over the native player: `play()`, `pause()`,
  `seek(s)` / `currentTime`, `duration`, `paused`, `ended`, `volume`, and the `play` / `pause` /
  `ended` / `timeupdate` / `error` events. `play()` after `ended` restarts from the top. **EOF does
  not stop the track**: the last frame keeps going out (re-emitted at 2 fps) until the host stops
  presenting — the web's last frame stays on the wire too.
- **The presenter's copy is played by WebRTC, not by the player.** The player's own output is muted
  and the aux is ALSO summed into the playout by the APM render-pre hook (`HostRenderMixer` /
  `SiperbRenderAuxMixer`) — so what leaves the loudspeaker is in the echo canceller's reference by
  construction, on every route, and does not come back through the microphone. `playback.volume`
  is that local copy's gain and never what the far end receives.
- **Mute mutes the presenter, not the file.** The aux is summed outside the bus's `micMuted`. While
  the host conference leg is on the bus the microphone track's `enabled` is routed to that bus mute
  rather than to native (`ConferenceLegBinding`), because a native `setEnabled(false)` lands
  downstream of the capture hook and would silence the whole mixed outbound — the file and the other
  participants with it.
- **Hold pauses the file.** `track.enabled = false` on the video track (what the SDK does to every
  sender track on hold) suspends picture and sound together and `enabled = true` resumes; the user's
  own pause is a separate flag. `track.stop()` DISPOSES the player (the SDK stops a presented track
  and never releases it, and a paused-forever decoder would leak) and ends the soundtrack.
- **A recording gets the file on the near side** (left channel, beside the mic), as the web files
  presentation audio under the local channel; the far side stays legs-only.
- Android: `MediaPlayer` renders into the `SurfaceTextureHelper`'s Surface and is the clock; a
  second, audio-only `MediaExtractor` + `MediaCodec` decode feeds the bus, paced against the player's
  position (decoding the audio twice is the price of no player dependency). iOS: `AVPlayer` +
  `AVPlayerItemVideoOutput` (NV12, sampled on a GCD timer so backgrounding does not stall it) and an
  `MTAudioProcessingTap` on the item's audio mix. Both key the aux on the video track id and take
  it off the bus at teardown themselves, so a late JS detach is a no-op.
- Known limits: on an iOS Bluetooth HFP route the mixer refuses to mix at 16 kHz, so the far end
  gets mic only (the existing warning fires once); `?` device checks — a portrait file's rotation
  (Android carries it in the frame via `setFrameRotation`; if the SurfaceTexture transform already
  rotates, that line goes), and that a muted `AVPlayer` still drives its tap (it should).

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
- `AudioContext` is not Web Audio: no sample processing, no scheduling, no `context.destination`
  playback. Per-source `gain.value` is not applied natively (0 excludes a source, anything else
  passes through); conference mute goes through `ConferenceMixer.setMicMuted`.
- A microphone failure is reported as `mute`, never `ended`: the engine retries capture on the next session, so the track stays usable and `unmute` follows when it recovers. "Not sending yet" (no peer connection sending) is deliberately not modelled as muted.
- macOS and tvOS targets are unmaintained; see the table above.

## More

- [README.md](README.md) — install and platform guides
- [Architecture.md](Architecture.md) — how the JS layer, the bridge and the native modules fit together
- [Documentation/](Documentation) — Android/iOS installation, basic usage, call reliability guide
- [CLAUDE.md](CLAUDE.md) — conventions and the upstream resync procedure
