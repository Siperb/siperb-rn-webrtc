# Architecture

`siperb-rn-webrtc` is Siperb's maintained fork of
[react-native-webrtc](https://github.com/react-native-webrtc/react-native-webrtc).
It exposes the W3C WebRTC and `getUserMedia`/`getDisplayMedia` APIs to React
Native apps by bridging a JavaScript/TypeScript API layer to native WebRTC
implementations on Android, iOS, and macOS.

The underlying WebRTC binary is **Jitsi's prebuilt WebRTC 124** (`org.jitsi:webrtc`
on Android, the `JitsiWebRTC` CocoaPod on Apple platforms). This library does not
compile WebRTC itself — it wraps that binary and marshals calls across the React
Native bridge.

## Layers

```
┌─────────────────────────────────────────────────────────────┐
│  App code  — `import { RTCPeerConnection, … } from           │
│              'siperb-rn-webrtc'`                              │
├─────────────────────────────────────────────────────────────┤
│  JS / TS API layer  (src/)                                   │
│   • W3C-shaped classes: RTCPeerConnection, MediaStream, …     │
│   • EventEmitter.ts — native→JS event fan-out                 │
│   • Logger.ts — `debug`-based namespaced logging             │
│   • registerGlobals() — polyfills global.navigator.mediaDevices│
├─────────────────────────────────────────────────────────────┤
│  React Native bridge  (NativeModules.WebRTCModule)           │
│   • JS calls `WebRTCModule.<method>(...)`                     │
│   • Native emits events via NativeEventEmitter               │
├──────────────────────────┬──────────────────────────────────┤
│  Android native (Java)    │  Apple native (Objective-C)       │
│  android/src/main/java/   │  ios/RCTWebRTC/ (+ macos/)        │
│   com/oney/WebRTCModule/   │   WebRTCModule + categories       │
├──────────────────────────┴──────────────────────────────────┤
│  Jitsi prebuilt WebRTC 124  (org.jitsi:webrtc / JitsiWebRTC)  │
└─────────────────────────────────────────────────────────────┘
```

## JavaScript / TypeScript layer (`src/`)

The public API mirrors the browser WebRTC spec so web WebRTC code largely ports
unchanged. Entry point is [`src/index.ts`](src/index.ts), which:

- Throws early if the `WebRTCModule` native module is missing (wrong/no
  `pod install` / `npm install`).
- Calls `setupNativeEvents()` to wire native events into the JS emitter.
- Calls `Logger.enable('rn-webrtc:*')` — **all log namespaces are enabled by
  default**.
- Exports the W3C classes plus `mediaDevices`, `permissions`, `registerGlobals`,
  and the iOS Picture-in-Picture helpers `startIOSPIP`/`stopIOSPIP`.
- Defines `registerGlobals()`, which installs `RTCPeerConnection`,
  `MediaStream`, `navigator.mediaDevices.getUserMedia`, etc. onto `global` so
  spec-style code works without explicit imports.

Notable files:

| File | Responsibility |
|------|----------------|
| [`RTCPeerConnection.ts`](src/RTCPeerConnection.ts) | Core peer connection; owns a numeric `_pcId` used to address its native counterpart |
| [`MediaDevices.ts`](src/MediaDevices.ts) / [`getUserMedia.ts`](src/getUserMedia.ts) / [`getDisplayMedia.ts`](src/getDisplayMedia.ts) | Media capture entry points |
| [`MediaStream.ts`](src/MediaStream.ts) / [`MediaStreamTrack.ts`](src/MediaStreamTrack.ts) | Stream/track wrappers |
| [`RTCRtp*`](src/) | Sender/receiver/transceiver and parameter types |
| [`RTCDataChannel.ts`](src/RTCDataChannel.ts) | Data channels |
| [`RTCView.ts`](src/RTCView.ts) / [`RTCPIPView.tsx`](src/RTCPIPView.tsx) | Native video view + iOS PiP view |
| [`RTCAudioSession.ts`](src/RTCAudioSession.ts) | iOS audio-session control (manual audio mode) |
| [`ConferenceMixer.ts`](src/ConferenceMixer.ts) | Native conference audio bus — control only, audio never crosses the bridge (`WebRTCModule+Conference`, `SiperbConferenceMixManager`) |
| [`CallRecorder.ts`](src/CallRecorder.ts) | Native call recorder — taps mic + remote sinks below the encoder, writes channel-split PCM/AAC; with `video` composites the named tracks natively (`CallVideoRecorder`) |
| [`EventEmitter.ts`](src/EventEmitter.ts) | Subscribes once to each native event, re-emits on a JS-only emitter |
| [`Logger.ts`](src/Logger.ts) | Wraps the `debug` package; root prefix `rn-webrtc` |
| [`src/vendor/event-target-shim`](src/vendor) | Bundled `EventTarget` implementation |

### Bridging model

- **JS → native:** classes call methods on `NativeModules.WebRTCModule`, e.g.
  `WebRTCModule.peerConnectionInit(configuration, this._pcId)`. Objects are
  identified across the bridge by id (`_pcId` for peer connections, track/stream
  ids for media).
- **native → JS:** native code emits named events
  (`peerConnectionStateChanged`, `dataChannelReceiveMessage`,
  `mediaStreamTrackEnded`, …). [`EventEmitter.ts`](src/EventEmitter.ts) holds the
  authoritative list in `NATIVE_EVENTS`, listens via `NativeEventEmitter`, and
  re-broadcasts on an internal `EventEmitter` that the JS objects subscribe to.
  Adding a new native event requires registering it in `NATIVE_EVENTS`.
- **Local track state:** `mediaStreamTrackMuteChanged` without a `pcId` is a
  *local* track's `muted` changing — the iOS screen track un-muting when the
  broadcast extension connects, and every local audio track muting/un-muting
  as the microphone fails or recovers (`MicCaptureStateEmitter` on Android,
  `WebRTCModule+RTCAudioSession` as `RTCAudioSessionDelegate` on iOS).
  `RTCPeerConnection` filters on `pcId` and ignores these; `MediaStreamTrack`
  matches on `trackId`.

## Web-API classes — `AudioContext` and `MediaRecorder`

`react-native-siperb-phone` runs the shared browser SDK (`browser-phone-sdk.min.js`)
directly in Hermes, and that SDK gates conference mixing on `window.AudioContext` and
recording on `typeof MediaRecorder === "function"`. **This library owns the generic,
W3C-shaped classes; the phone keeps a thin shim carrying only its own conventions.**

- [`AudioContext.ts`](src/AudioContext.ts) is a **declarative graph**: nodes
  ([`AudioNode`](src/AudioNode.ts), `GainNode`, `ChannelMergerNode`,
  `MediaStreamAudioSourceNode`, `MediaStreamAudioDestinationNode`) record how they are
  wired and process nothing. A destination's `stream` holds one virtual local track
  ([`MixedAudioTrack`](src/MixedAudioTrack.ts), `_isVirtual`) that never crosses the
  bridge; consumers read the graph through it ([`MixRecipe.ts`](src/MixRecipe.ts)).
  Unsupported members (`createMediaElementSource`, oscillators, analysers, …) are
  absent, not stubbed — the SDK feature-probes them with `typeof`.
- [`MediaRecorder.ts`](src/MediaRecorder.ts) compiles the stream it is given into a
  native `CallRecorder` request ([`RecordingRequest.ts`](src/RecordingRequest.ts)): local
  sources → microphone, remote sources → tapped tracks, a merger with sources on two
  inputs → channel-split stereo — the SDK's own recording graph compiles to exactly what
  the hosts used to send by hand. `dataavailable` carries a
  [`RecordingBlob`](src/RecordingBlob.ts), a Blob-shaped *reference* to the file (`size`,
  `type`, `path`, `uri`), never its bytes. One chunk at stop; `pause`/`resume`/
  `requestData`/`timeslice` throw `NotSupportedError`.
- **The host seam** is two protected methods, `startNative(request)` and
  `stopNative(handle, reason)`, defaulting to `CallRecorder` with a generated id and
  native default paths (`CallRecorder.recordingsDirectory`). The phone's shim is a
  subclass overriding both to route through its `RecordingManager` by `Data.SessionId`
  — ids, paths, rows, CDR and crash salvage stay in the host.
- **Conference legs** (`replaceTrack(mixTrack)` → `ConferenceMixer.attachLeg`) are the
  next slice; until it lands, `replaceTrack` refuses a virtual track with
  `NotSupportedError` and the phone's `AudioContext` shim keeps doing that job.

| Web API the SDK expects | This library | Native work |
|---|---|---|
| `new AudioContext()` — `createMediaStreamSource`, `createMediaStreamDestination`, `createGain`, `createChannelMerger`, `connect`/`disconnect`, `gain.value`, `state`/`resume`/`close` | `AudioContext` + nodes, graph compiled on demand | `ConferenceMixer` → `WebRTCModule+Conference` / `SiperbConferenceMixManager` (iOS), the conference audio bus (Android). Mixes below the encoder; the mix is written into the leg's capture buffer, so no track is swapped and no SDP moves |
| `new MediaRecorder(stream)` — `start()`, `stop()`, `state`, `ondataavailable`, `onerror` | `MediaRecorder` (state machine, events, request compilation) | `CallRecorder` → `CallAudioRecorder` + `CallVideoRecorder`. Taps mic and remote sinks natively, writes the crash-safe WAV, encodes, and composites video from the named tracks with the SDK's own layout vocabulary (`them-pnp`, `side-by-side`, …) |
| `document` | — (phone: `documentShims/document.ts`, two no-op listener methods, **no `createElement`**) | none |

Two rules keep this honest; `registerGlobals()` now enforces the first here too (it
installs `AudioContext`/`MediaRecorder` only when the native half exists in this binary,
and never over a class a host already installed):

- **Publish-or-don't.** Each shim is installed only if the native method it reaches
  exists (`WebRTCModule.conferenceAttachLeg`, `WebRTCModule.startCallRecording`). A truthy
  name under `AudioContext` or `MediaRecorder` switches the SDK's whole feature on, so a
  shim that cannot do the work reports success and does nothing — worse than absence.
- **Probe the native module, not the JS wrapper.** `ConferenceMixer` and `CallRecorder`
  are static classes that exist on every host; only the bridged method's presence says
  whether the binary can do it. Adding a native capability means adding the bridged
  method — the shim gates on that and needs no change for a new platform.

### Not yet: `document.createElement("canvas")`

The SDK probes `typeof document.createElement === "function"` to mean "real DOM" and,
on a video call, uses it to run its own canvas compositor (`PhoneCore/RecordingManager.js`
`StartVideoComposite`: a `<canvas>` draw loop, `<video>` decode, `captureStream()`). On
this host that picture is already produced natively by `CallVideoRecorder`, so a canvas
shim today would run a second, fake compositor beside the real one. Before the phone can
install one, this library needs a **canvas-backed video source**: an `HTMLCanvasElement`-
shaped object whose `getContext("2d")` drawing lands in native and whose `captureStream()`
returns a real `MediaStreamTrack` — the same shape as a camera track, so it can be
`replaceTrack`ed onto a sender. That is what would also unlock the SDK's picture /
whiteboard presentation modes, which the web UI builds on a canvas. Until it exists, the
`document` shim deliberately has no `createElement`.

## Native module name

On **both** platforms the bridged module is registered as **`WebRTCModule`**
(`getName()` in `WebRTCModule.java`; `RCT_EXPORT_MODULE()` in `WebRTCModule.m`).
This is the React Native module name and is independent of the npm package name
(`siperb-rn-webrtc`) and the iOS pod name. The JS layer always references
`NativeModules.WebRTCModule`.

## Android (`android/`)

- Language: Java. Package/namespace: `com.oney.WebRTCModule`.
- WebRTC binary: `api 'org.jitsi:webrtc:124.+'` (see
  [`android/build.gradle`](android/build.gradle)).
- `minSdkVersion` 24, `compileSdkVersion` 24 (overridable via ext properties).
- [`WebRTCModule.java`](android/src/main/java/com/oney/WebRTCModule/WebRTCModule.java)
  is the bridge surface — its `@ReactMethod` (and synchronous
  `isBlockingSynchronousMethod`) methods are what the JS layer calls.
- Registered with React Native by `WebRTCModulePackage`.
- Supporting areas: camera capture (`Camera1Helper`/`Camera2Helper`,
  `CameraCaptureController`), screen capture (`ScreenCaptureController`,
  `MediaProjectionService`), codec factories (`H264AndSoftware*`), video frame
  processing/effects, and `PeerConnectionObserver` for state callbacks.

## Apple — iOS & macOS (`ios/`, `macos/`, `apple/`)

- Language: Objective-C. iOS sources live in [`ios/RCTWebRTC/`](ios/RCTWebRTC);
  macOS reuses them via [`macos/RCTWebRTC.xcodeproj`](macos).
- WebRTC binary: the `JitsiWebRTC` pod (`~> 124.0.0`), declared in
  [`siperb-rn-webrtc.podspec`](siperb-rn-webrtc.podspec). `apple/` holds a
  placeholder for the WebRTC xcframework artifact.
- [`WebRTCModule.m`](ios/RCTWebRTC/WebRTCModule.m) is split into Objective-C
  categories by concern: `+RTCPeerConnection`, `+RTCMediaStream`,
  `+RTCDataChannel`, `+Transceivers`, `+Permissions`, `+RTCAudioSession`,
  `+VideoTrackAdapter`.
- Audio runs in **manual-audio mode** via `RTCAudioSession` — important for
  CallKit integrations where activation/deactivation is driven by the app.
- Picture-in-Picture is implemented in `PIPController` / `SampleBufferVideoCallView`
  and surfaced to JS as `RTCPIPView` + `startIOSPIP`/`stopIOSPIP`.
- The CocoaPods **pod name derives from `package.json`'s `name`** field
  (`s.name = package['name']`), so it is `siperb-rn-webrtc`. React Native
  autolinking discovers the single `*.podspec` at the package root.

## Build & packaging

- Built with [react-native-builder-bob](https://github.com/callstack/react-native-builder-bob):
  `source: src` → `output: lib`, targets `commonjs`, `module`, `typescript`.
- `package.json` entry points: `react-native` → `src/index.ts` (Metro consumes
  source directly), `main` → `lib/commonjs/index.js`, `module` →
  `lib/module/index.js`, `types` → `lib/typescript/index.d.ts`.
- The `prepare` script (`husky install && bob build`) runs on install — so a
  consumer installing this package straight from the Git URL
  (`github:Siperb/siperb-rn-webrtc`) gets `lib/` built automatically.
- Runtime dependencies: `base64-js`, `debug`. Peer dependency:
  `react-native >= 0.60.0`.

## Logging

[`Logger.ts`](src/Logger.ts) wraps the `debug` package under the root namespace
`rn-webrtc`, with per-area sub-loggers and `:DEBUG`/`:INFO`/`:WARN`/`:ERROR`
levels (e.g. `rn-webrtc:pc:DEBUG`). `index.ts` enables `rn-webrtc:*` on load, so
output appears unless the consuming app suppresses it. Because the `debug` output
is routed through `console.log`, high-frequency calls can flood the console — the
per-poll `getStats` debug line was removed in this fork for that reason.

## Fork notes (Siperb)

- Forked from upstream `master` on 22 June 2026 (the `init` commit `0aa5e92`),
  as a snapshot with no shared git history. The base is upstream 124.0.7 plus
  the unreleased `master` work that later shipped as 124.0.8 (July 2026).
- npm package renamed to `siperb-rn-webrtc`; repository/homepage/issue URLs point
  at `github.com/Siperb/siperb-rn-webrtc`. The podspec was renamed to match.
- Upstream is resynced by patch (no remote, no shared history). Current base:
  upstream `master` @ `7266a9b` (9 Sep 2026). The procedure is in
  [CLAUDE.md](CLAUDE.md) under "Fork specifics".
- The native module name (`WebRTCModule`), the Android Java package
  (`com.oney.WebRTCModule`), and links to genuinely-external upstream resources
  (Jitsi, the web-shim, Discourse) are intentionally left unchanged.
