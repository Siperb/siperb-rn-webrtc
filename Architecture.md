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

- npm package renamed to `siperb-rn-webrtc`; repository/homepage/issue URLs point
  at `github.com/Siperb/siperb-rn-webrtc`. The podspec was renamed to match.
- No upstream sync is planned — changes are maintained directly here.
- The native module name (`WebRTCModule`), the Android Java package
  (`com.oney.WebRTCModule`), and links to genuinely-external upstream resources
  (Jitsi, the web-shim, Discourse) are intentionally left unchanged.
