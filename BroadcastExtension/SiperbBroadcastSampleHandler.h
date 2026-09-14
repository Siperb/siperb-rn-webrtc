#import <ReplayKit/ReplayKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * The Broadcast Upload Extension's principal class: the sending half of siperb-rn-webrtc's iOS
 * screen capture. The receiving half — the socket server, the JPEG decode, the WebRTC track —
 * lives in the app (ios/RCTWebRTC/ScreenCapturer.m). Everything the two share is in this
 * directory's headers.
 *
 * THE APP TARGET ADDS NO CODE. Point the extension's Info.plist at this class —
 *
 *     NSExtension / NSExtensionPrincipalClass = SiperbBroadcastSampleHandler
 *
 * — give the extension the same App Group as the app, and put the group's identifier under
 * `RTCAppGroupIdentifier` in BOTH Info.plists (the app's ScreenCaptureController reads it from
 * the app bundle; this class reads it from the extension bundle — they are different bundles).
 * Subclass only to change behaviour, e.g. override -broadcastStartedWithSetupInfo: to add
 * logging, and call super.
 *
 * HOW A SHARE STARTS. The app calls getDisplayMedia(), which binds the socket and waits, then
 * shows the system picker; the user taps "Start Broadcast"; iOS launches this process;
 * -broadcastStartedWithSetupInfo: connects to the socket (retrying, because the user may have
 * started the broadcast from Control Center before the app was listening); frames flow. The
 * app's track goes from `muted` to un-muted when the connection opens.
 *
 * HOW IT STOPS. Either end. The app stopping capture closes the socket, which arrives here as
 * end-of-stream and ends the broadcast; the user tapping the red status bar ends the broadcast,
 * which closes the socket and ends the app's track. There is no finishBroadcast without an
 * error in ReplayKit's API, so the app-initiated stop reports one with a plain message; iOS
 * shows it in an alert.
 *
 * BUDGET. A broadcast extension is killed past ~50 MB. Nothing here retains more than one
 * encoded frame, and there is no React, no WebRTC and no network stack in this target — keep
 * it that way when extending it.
 */
@interface SiperbBroadcastSampleHandler : RPBroadcastSampleHandler
@end

NS_ASSUME_NONNULL_END
