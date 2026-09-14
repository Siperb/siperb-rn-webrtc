# CLAUDE.md

Guidance for working in this repository. Read [Architecture.md](Architecture.md)
for the full system map; this file covers what you need to make changes safely.

## What this is

`siperb-rn-webrtc` is Siperb's maintained fork of `react-native-webrtc` — a
React Native library exposing the W3C WebRTC API by bridging a TypeScript layer
to native WebRTC (Jitsi prebuilt WebRTC 124) on Android, iOS, and macOS. It is a
**library**, not an app; the `examples/` apps are for manual testing.

## Layout

- `src/` — the TypeScript public API (W3C-shaped classes). **This is where most
  JS-side changes go.**
- `android/src/main/java/com/oney/WebRTCModule/` — Android native module (Java).
- `ios/RCTWebRTC/` — iOS native module (Objective-C); `macos/` reuses it.
- `apple/` — placeholder for the WebRTC xcframework artifact.
- `examples/GumTestApp`, `examples/GumTestApp_macOS` — sample apps.
- `Documentation/` — installation and usage guides.
- `tools/` — `format.sh`, `release.sh`.

## Commands

```bash
npm run lint       # eslint (max-warnings 0) + tsc --noEmit
npm run lintfix    # eslint --fix + tsc --noEmit
npm run format     # tools/format.sh (clang-format for native, prettier via lint-staged)
npm run prepare    # husky install && bob build && postbuild  -> produces lib/
npm test           # jest over tests/js against a mocked react-native bridge
./android/tests/run.sh   # pure-Java conference bus assertions (no Android toolchain needed)
```

Tests cover the JS layer (`tests/js/`, Jest + ts-jest; `react-native` and `react` are
stubbed in `tests/js/mocks/`, so nothing native runs) and the pure-Java conference bus.
Native capture and recording still have to be exercised on a device or through the
`examples/` apps / the Siperb consumers. Always run `npm run lint` and `npm test`
before considering a change done; `tsc --noEmit` is part of lint.

## Key conventions

- **Public API mirrors the W3C WebRTC spec.** Keep class/method/property names
  spec-accurate; consumers expect browser-compatible shapes.
- **The bridge module is named `WebRTCModule` on both platforms** — unrelated to
  the npm/pod name. JS always calls `NativeModules.WebRTCModule.<method>`.
- **Objects are addressed across the bridge by id** (`_pcId` for peer
  connections, track/stream ids for media). A JS-side change that adds native
  calls needs the matching `@ReactMethod` (Android) and category method (iOS).
- **Native events** must be registered in `NATIVE_EVENTS` in
  [`src/EventEmitter.ts`](src/EventEmitter.ts) to reach JS. Adding a native
  emit without registering it here does nothing on the JS side.
- **A change in `src/` is not live for consumers until rebuilt.** Run
  `bob build` (via `npm run prepare`) or, for the Git-URL consumer, re-install.
- **Cross-platform parity:** behavior changes usually need to be made in `src/`
  *and* both `android/` and `ios/`. Don't fix only one platform silently.
- Indentation is 4 spaces for TS; native code is clang-formatted
  (`.clang-format`).

## Logging

Logging uses the `debug` package via [`src/Logger.ts`](src/Logger.ts) under the
`rn-webrtc` root namespace (e.g. `rn-webrtc:pc:DEBUG`). `index.ts` enables
`rn-webrtc:*` by default, and output is routed through `console.log`, so
**high-frequency `log.debug` calls flood the consumer's console**. Be
conservative adding debug logs on hot paths (per-frame, per-poll, per-stats).
The per-poll `getStats` debug line was removed in this fork for this reason.

## Fork specifics

- **Forked from upstream `master` on 22 June 2026** (the `init` commit
  `0aa5e92`), as a snapshot with no shared git history. The base was upstream
  commit `e5d8781` (124.0.7 plus the unreleased `master` work that later shipped
  as 124.0.8); `package.json` kept the `124.0.7` version `master` carried.
- **Upstream is resynced by patch, not by merge.** There is no upstream remote
  and no shared history — a grafted merge would pull upstream's ~420 MB of
  history into a repo consumers install straight from Git. Current resync base:
  **upstream `master` @ `7266a9b` (9 Sep 2026)**, applied 14 Sep 2026. Next round:

  ```bash
  git fetch --no-tags https://github.com/react-native-webrtc/react-native-webrtc.git master
  git diff 7266a9b FETCH_HEAD -- . ':!examples' ':!package-lock.json' ':!package.json' | git apply --3way --index
  ```

  `--no-tags` matters (a plain fetch drags ~120 upstream tags into the repo).
  `package.json` is merged by hand because name/version differ. Then update the
  base SHA here and in [Architecture.md](Architecture.md).
- Package name: `siperb-rn-webrtc`; URLs point at
  `github.com/Siperb/siperb-rn-webrtc`. The podspec filename matches, and the
  iOS pod name derives from `package.json`'s `name`.
- Leave intentionally unchanged: the native module name (`WebRTCModule`), the
  Android Java package (`com.oney.WebRTCModule`), and links to external upstream
  resources (Jitsi, the react-native-webrtc web-shim, Discourse).
- The primary consumer is the **Siperb-Mobile** app, which depends on this fork
  via `github:Siperb/siperb-rn-webrtc`. After landing a change here, that app
  must re-install (and run `pod install` for iOS) to pick it up.

## Versioning

Tracks upstream WebRTC `124.x` (current `version` in `package.json` is
`124.0.7`). The native binaries are pinned to 124 (`org.jitsi:webrtc:124.+` /
`JitsiWebRTC ~> 124.0.0`); keep the JS `version`, the Android dep, and the pod
dep aligned to the same WebRTC major when bumping.
