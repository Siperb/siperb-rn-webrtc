/* eslint-disable @typescript-eslint/no-var-requires -- isolateModules needs a fresh require per test */
const g = globalThis as any;

/**
 * registerGlobals publishes AudioContext / MediaRecorder only when the native half exists in
 * this binary, and never over a global a host already installed.
 */
function loadWith(mutate: (module: any) => void, preinstall: () => void = () => undefined) {
    jest.isolateModules(() => {
        const rn = require('react-native');

        rn.NativeModules.WebRTCModule = rn.makeWebRTCModule();
        mutate(rn.NativeModules.WebRTCModule);
        delete g.AudioContext;
        delete g.MediaRecorder;
        // React Native always has one; Node 20 does not.
        g.navigator = g.navigator ?? {};
        preinstall();
        require('../../src/index').registerGlobals();
    });
}

afterEach(() => {
    delete g.AudioContext;
    delete g.MediaRecorder;
});

describe('registerGlobals', () => {
    test('installs both when the native recorder and bus exist', () => {
        loadWith(() => undefined);

        expect(typeof g.AudioContext).toBe('function');
        expect(typeof g.MediaRecorder).toBe('function');
        expect(typeof g.RTCPeerConnection).toBe('function');
    });

    test('withholds MediaRecorder on a binary without default recording paths', () => {
        loadWith(module => {
            delete module.recordingsDirectory;
        });

        expect(typeof g.AudioContext).toBe('function');
        expect(g.MediaRecorder).toBeUndefined();
    });

    test('withholds AudioContext without the native conference bus', () => {
        loadWith(module => {
            delete module.conferenceAttachLeg;
        });

        expect(g.AudioContext).toBeUndefined();
        expect(typeof g.MediaRecorder).toBe('function');
    });

    test('leaves a host-installed class alone', () => {
        class HostRecorder {}

        loadWith(() => undefined, () => {
            g.MediaRecorder = HostRecorder;
        });

        expect(g.MediaRecorder).toBe(HostRecorder);
    });
});
