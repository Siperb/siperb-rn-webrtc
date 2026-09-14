/**
 * The bridge as the JS layer sees it, with every method a jest.fn so a test can assert what
 * crossed to native and script what comes back. `emitNative` plays a native event into the
 * NativeEventEmitter the library subscribed through.
 */
type Listener = (payload: any) => void;

const nativeListeners = new Map<string, Set<Listener>>();

export function emitNative(eventName: string, payload: any): void {
    for (const listener of Array.from(nativeListeners.get(eventName) ?? [])) {
        listener(payload);
    }
}

export function makeWebRTCModule() {
    return {
        // constants
        callRecordingSupportsVideo: true,
        displayMediaSupported: false,
        recordingsDirectory: '/data/app/files/siperb-rn-webrtc/recordings',
        // peer connection
        peerConnectionInit: jest.fn(() => true),
        peerConnectionSetConfiguration: jest.fn(),
        peerConnectionClose: jest.fn(),
        peerConnectionDispose: jest.fn(),
        peerConnectionAddTrack: jest.fn(),
        peerConnectionRemoveTrack: jest.fn(),
        senderReplaceTrack: jest.fn(() => Promise.resolve()),
        // streams / tracks
        mediaStreamCreate: jest.fn(),
        mediaStreamAddTrack: jest.fn(),
        mediaStreamRemoveTrack: jest.fn(),
        mediaStreamRelease: jest.fn(),
        mediaStreamTrackRelease: jest.fn(),
        mediaStreamTrackSetEnabled: jest.fn(),
        mediaStreamTrackSetVolume: jest.fn(),
        // recorder
        startCallRecording: jest.fn(() => Promise.resolve()),
        stopCallRecording: jest.fn(() => Promise.resolve({
            recordingId: 'rec-1', filePath: '/tmp/rec-1.m4a', durationMs: 1200, size: 4096,
            withVideo: false, mimeType: 'audio/mp4'
        })),
        getActiveCallRecordings: jest.fn(() => Promise.resolve([])),
        finalizeOrphanRecording: jest.fn(),
        updateCallRecordingVideoSources: jest.fn(() => Promise.resolve()),
        // conference
        conferenceAttachLeg: jest.fn(() => Promise.resolve(true)),
        conferenceAttachLegAudio: jest.fn(() => Promise.resolve(true)),
        conferenceDetachLeg: jest.fn(() => Promise.resolve(true)),
        conferenceTeardown: jest.fn(() => Promise.resolve(true)),
        conferenceSetMicMuted: jest.fn(() => Promise.resolve(true)),
        conferenceGetLegs: jest.fn(() => Promise.resolve([])),
        // misc
        checkPermission: jest.fn(() => Promise.resolve('granted')),
        requestPermission: jest.fn(() => Promise.resolve(true)),
        audioSessionDidActivate: jest.fn(),
        audioSessionDidDeactivate: jest.fn(),
        addListener: jest.fn(),
        removeListeners: jest.fn()
    };
}

export const NativeModules: { WebRTCModule: any } = { WebRTCModule: makeWebRTCModule() };

export class NativeEventEmitter {
    addListener(eventName: string, listener: Listener) {
        if (!nativeListeners.has(eventName)) {
            nativeListeners.set(eventName, new Set());
        }

        nativeListeners.get(eventName)?.add(listener);

        return { remove: () => nativeListeners.get(eventName)?.delete(listener) };
    }
}

export const Platform = { OS: 'ios' };

export const PermissionsAndroid = {
    PERMISSIONS: { CAMERA: 'android.permission.CAMERA', RECORD_AUDIO: 'android.permission.RECORD_AUDIO' },
    RESULTS: { GRANTED: 'granted' },
    request: jest.fn(() => Promise.resolve('granted')),
    check: jest.fn(() => Promise.resolve(true))
};

export function requireNativeComponent(name: string) {
    return name;
}

export const UIManager = {
    dispatchViewManagerCommand: jest.fn(),
    getViewManagerConfig: () => {
        return { Commands: { startIOSPIP: 1, stopIOSPIP: 2 } };
    }
};

export function findNodeHandle() {
    return 1;
}

export type ViewProps = Record<string, unknown>;
export type Permission = string;
export type EmitterSubscription = { remove: () => void };

export default {
    NativeModules, NativeEventEmitter, Platform, PermissionsAndroid, requireNativeComponent, UIManager, findNodeHandle
};
