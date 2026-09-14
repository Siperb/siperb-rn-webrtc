[<img src="https://avatars.githubusercontent.com/u/42463376" alt="Siperb RN WebRTC" style="height: 6em;" />](https://github.com/Siperb/siperb-rn-webrtc)

# Siperb-RN-WebRTC

> Siperb's maintained fork of [react-native-webrtc](https://github.com/react-native-webrtc/react-native-webrtc),
> forked from upstream `master` in June 2026 (between the 124.0.7 and 124.0.8 releases).

[![Discourse topics](https://img.shields.io/discourse/topics?server=https%3A%2F%2Freact-native-webrtc.discourse.group%2F)](https://react-native-webrtc.discourse.group/)

A WebRTC module for React Native.

## Feature Overview

|  | Android | iOS | tvOS | macOS* | Windows* | Web* | Expo* |
| :- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| Audio/Video | :heavy_check_mark: | :heavy_check_mark: | :heavy_check_mark: | - | - | :heavy_check_mark: | :heavy_check_mark: |
| Data Channels | :heavy_check_mark: | :heavy_check_mark: | - | - | - | :heavy_check_mark: | :heavy_check_mark: |
| Screen Capture | :heavy_check_mark: | :heavy_check_mark: | - | - | - | :heavy_check_mark: | :heavy_check_mark: |
| Plan B | - | - | - | - | - | - | - |
| Unified Plan* | :heavy_check_mark: | :heavy_check_mark: | - | - | - | :heavy_check_mark: | :heavy_check_mark: |
| Simulcast* | :heavy_check_mark: | :heavy_check_mark: | - | - | - | :heavy_check_mark: | :heavy_check_mark: |

> **macOS** - We don't currently actively support macOS at this time.  
Support might return in the future.

> **Windows** - We don't currently support the [react-native-windows](https://github.com/microsoft/react-native-windows) platform at this time.  
Anyone interested in getting the ball rolling? We're open to contributions.

> **Web** - The [react-native-webrtc-web-shim](https://github.com/react-native-webrtc/react-native-webrtc-web-shim) project provides a shim for [react-native-web](https://github.com/necolas/react-native-web) support.  
Which will allow you to use [(almost)](https://github.com/react-native-webrtc/react-native-webrtc-web-shim/tree/main#setup) the exact same code in your [react-native-web](https://github.com/necolas/react-native-web) project as you would with [react-native](https://reactnative.dev/) directly.  

> **Expo** - As this module includes native code it is not available in the [Expo Go](https://expo.dev/client) app by default.  
However you can get things working via the [expo-dev-client](https://docs.expo.dev/development/getting-started/) library and out-of-tree [config-plugins/react-native-webrtc](https://github.com/expo/config-plugins/tree/master/packages/react-native-webrtc) package.  

> **Unified Plan** - As of version 106.0.0 Unified Plan is the only supported mode.  
Those still in need of Plan B will need to use an older release.

> **Simulcast** - As of version 111.0.0 Simulcast is now possible with ease.  
Software encode/decode factories have been enabled by default.

## WebRTC Revision

* Currently used revision: [M124](https://github.com/jitsi/webrtc/tree/M124)
* Supported architectures
  * Android: armeabi-v7a, arm64-v8a, x86, x86_64
  * iOS: arm64, x86_64
  * tvOS: arm64
  * macOS: arm64, x86_64

## Getting Started

This fork is **not published to npm** — apps install it straight from GitHub. Pin a commit
rather than a branch, so a rebuild always produces the same binary:

```bash
npm install "siperb-rn-webrtc@github:Siperb/siperb-rn-webrtc#<commit-sha>"
```

(`yarn add siperb-rn-webrtc@github:Siperb/siperb-rn-webrtc#<commit-sha>` works the same way.)
Installing from Git runs this package's `prepare` script, which builds `lib/`; that needs the
Node version in [`.nvmrc`](.nvmrc). Then follow the platform guides below for the native setup.

## Updating the package in a React Native app

The JS layer is consumed from source and the native code is compiled from `node_modules`, so
an update touches three places: the dependency pin, the iOS Pods, and the Metro cache.

1. **Pick the commit** you want (the latest on `main`):
   ```bash
   git ls-remote https://github.com/Siperb/siperb-rn-webrtc.git main
   ```
2. **Move the pin** — updates `package.json` and the lock file, and rebuilds `lib/`:
   ```bash
   npm install "siperb-rn-webrtc@github:Siperb/siperb-rn-webrtc#<new-sha>"
   ```
   If the app tracks `main` without a SHA (`"siperb-rn-webrtc": "github:Siperb/siperb-rn-webrtc"`),
   re-resolve with `npm update siperb-rn-webrtc` instead.
3. **iOS — reinstall pods.** The pod is a `:path` pod pointing at `node_modules`, so Xcode
   compiles the new native sources, but CocoaPods must regenerate the project first:
   ```bash
   cd ios && LANG=en_US.UTF-8 pod install && cd ..
   ```
   (`LANG` matters only if your shell is not already UTF-8; CocoaPods refuses otherwise.)
4. **Android — nothing to install.** Gradle compiles the library from `node_modules` on the
   next build. After a change to `android/build.gradle` or the manifest, do a clean build:
   `cd android && ./gradlew clean && cd ..`.
5. **Restart Metro with a cold cache** — the app bundles this package's TypeScript directly:
   ```bash
   npx react-native start --reset-cache
   ```
6. **Rebuild the app**: `npx react-native run-ios` / `npx react-native run-android`.
   A JS-only reload is not enough when native code changed.
7. **Confirm what you got**:
   ```bash
   grep -A2 '"node_modules/siperb-rn-webrtc"' package-lock.json
   ```
   The `resolved` line must end in the SHA you asked for.

Packages that sit between the app and this library (for example `react-native-siperb-phone`)
declare `siperb-rn-webrtc` as a peer dependency — the **app** owns the pin, so an update is
always made in the app's `package.json`, never in the intermediate package.

**If something looks wrong after an update**

| Symptom | Cause |
|---|---|
| `WebRTC native module not found` at startup | Pods not reinstalled (iOS) or the app not rebuilt after a native change |
| `Class extends value undefined is not a constructor` from a shim | The app is pinned to an older commit than the code importing this package expects — move the pin forward |
| New JS behaviour missing, no error | Stale Metro cache — step 5 |
| `pod install` dies in `unicode_normalize` | Shell locale is not UTF-8 — step 3 |

## Guides

- [Android Install](./Documentation/AndroidInstallation.md)
- [iOS Install](./Documentation/iOSInstallation.md)
- [tvOS Install](./Documentation/tvOSInstallation.md)
- [Basic Usage](./Documentation/BasicUsage.md)
- [Step by Step Call Guide](./Documentation/CallGuide.md)
- [Improving Call Reliability](./Documentation/ImprovingCallReliability.md)
- [Migrating to Unified Plan](https://docs.google.com/document/d/1-ZfikoUtoJa9k-GZG1daN0BU3IjIanQ_JSscHxQesvU/edit#heading=h.wuu7dx8tnifl)

## Example Projects

We have some very basic example projects included in the [examples](./examples) directory.  
Don't worry, there are plans to include a much more broader example with backend included.  

## Community

Come join our [Discourse Community](https://react-native-webrtc.discourse.group/) if you want to discuss any React Native and WebRTC related topics.  
Everyone is welcome and every little helps.  

## Related Projects

Looking for extra functionality coverage?  
The [react-native-webrtc](https://github.com/react-native-webrtc) organization provides a number of packages which are more than useful when developing Real Time Communication applications.  
