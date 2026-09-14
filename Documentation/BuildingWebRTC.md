# Building WebRTC

This package does not build WebRTC. Both platforms consume LiveKit's prebuilt
[`webrtc-sdk`](https://github.com/webrtc-sdk/webrtc) **125.6422.07** — `io.github.webrtc-sdk:android`
via Gradle and the `WebRTC-SDK` CocoaPod — chosen over Jitsi's build because it exposes the audio
hooks the call recorder and conference mixer depend on (`RTCDefaultAudioProcessingModule` on iOS,
`JavaAudioDeviceModule` sample/buffer callbacks on Android).

To move to a newer binary, change the version in [`android/build.gradle`](../android/build.gradle)
and [`siperb-rn-webrtc.podspec`](../siperb-rn-webrtc.podspec) together, keep the `package.json`
major on the same WebRTC major, and re-verify the audio paths on a device: those hooks are
LiveKit-specific and have changed between their releases.

The build scripts themselves live in [webrtc-sdk/webrtc-build](https://github.com/webrtc-sdk/webrtc-build).
