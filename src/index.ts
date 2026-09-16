import { NativeModules, Platform } from 'react-native';
const { WebRTCModule } = NativeModules;

if (WebRTCModule === null) {
    throw new Error(`WebRTC native module not found.\n${Platform.OS === 'ios' ?
        'Try executing the "pod install" command inside your projects ios folder.' :
        'Try executing the "npm install" command inside your projects folder.'
    }`);
}

import AudioContext from './AudioContext';
import AudioDestinationNode from './AudioDestinationNode';
import AudioNode from './AudioNode';
import AudioParam from './AudioParam';
import BlobEvent from './BlobEvent';
import CallRecorder, {
    type CallRecordingLayout,
    type CallRecordingOptions,
    type CallRecordingResult,
    type CallVideoRecordingOptions,
    type CallVideoSources,
} from './CallRecorder';
import ChannelMergerNode from './ChannelMergerNode';
import ConferenceMixer from './ConferenceMixer';
import { setupNativeEvents } from './EventEmitter';
import FileAudioTrack from './FileAudioTrack';
import FilePlayback, { type FilePlaybackState } from './FilePlayback';
import FileVideoTrack from './FileVideoTrack';
import GainNode from './GainNode';
import Logger from './Logger';
import mediaDevices from './MediaDevices';
import MediaRecorder from './MediaRecorder';
import MediaRecorderErrorEvent from './MediaRecorderErrorEvent';
import MediaStream from './MediaStream';
import MediaStreamAudioDestinationNode from './MediaStreamAudioDestinationNode';
import MediaStreamAudioSourceNode from './MediaStreamAudioSourceNode';
import MediaStreamTrack, { type MediaTrackSettings } from './MediaStreamTrack';
import MediaStreamTrackEvent from './MediaStreamTrackEvent';
import MixedAudioTrack from './MixedAudioTrack';
import permissions from './Permissions';
import RTCAudioSession from './RTCAudioSession';
import RTCCertificate from './RTCCertificate';
import RTCDTMFSender from './RTCDTMFSender';
import RTCErrorEvent from './RTCErrorEvent';
import RTCIceCandidate from './RTCIceCandidate';
import RTCPIPView, { startIOSPIP, stopIOSPIP } from './RTCPIPView';
import RTCPeerConnection from './RTCPeerConnection';
import RTCRtpEncodingParameters, { type RTCRtpEncodingParametersInit } from './RTCRtpEncodingParameters';
import RTCRtpReceiver from './RTCRtpReceiver';
import RTCRtpSendParameters, { type RTCRtpSendParametersInit } from './RTCRtpSendParameters';
import RTCRtpSender from './RTCRtpSender';
import RTCRtpTransceiver from './RTCRtpTransceiver';
import RTCSessionDescription from './RTCSessionDescription';
import RTCView, { type RTCVideoViewProps, type RTCIOSPIPOptions } from './RTCView';
import RecordingBlob from './RecordingBlob';
import {
    type MediaRecorderOptions,
    type MediaRecorderVideoOptions,
    type NativeRecordingHandle,
    type RecordingRequest,
} from './RecordingRequest';
import ScreenCapturePickerView from './ScreenCapturePickerView';
import { FileMediaStream, type FileMediaConstraints } from './getFileMedia';

Logger.enable(`${Logger.ROOT_PREFIX}:*`);

// Add listeners for the native events early, since they are added asynchronously.
setupNativeEvents();

export {
    RTCIceCandidate,
    RTCPeerConnection,
    RTCSessionDescription,
    RTCCertificate,
    RTCDTMFSender,
    RTCView,
    RTCPIPView,
    ScreenCapturePickerView,
    RTCRtpEncodingParameters,
    RTCRtpTransceiver,
    RTCRtpReceiver,
    RTCRtpSender,
    RTCRtpSendParameters,
    RTCErrorEvent,
    RTCAudioSession,
    CallRecorder,
    ConferenceMixer,
    type CallRecordingLayout,
    type CallRecordingOptions,
    type CallRecordingResult,
    type CallVideoRecordingOptions,
    type CallVideoSources,
    AudioContext,
    AudioNode,
    AudioParam,
    AudioDestinationNode,
    GainNode,
    ChannelMergerNode,
    MediaStreamAudioSourceNode,
    MediaStreamAudioDestinationNode,
    MixedAudioTrack,
    FileAudioTrack,
    FileVideoTrack,
    FilePlayback,
    FileMediaStream,
    type FileMediaConstraints,
    type FilePlaybackState,
    MediaRecorder,
    RecordingBlob,
    BlobEvent,
    MediaRecorderErrorEvent,
    type MediaRecorderOptions,
    type MediaRecorderVideoOptions,
    type NativeRecordingHandle,
    type RecordingRequest,
    MediaStream,
    MediaStreamTrack,
    type MediaTrackSettings,
    type RTCRtpEncodingParametersInit,
    type RTCRtpSendParametersInit,
    type RTCVideoViewProps,
    type RTCIOSPIPOptions,
    mediaDevices,
    permissions,
    registerGlobals,
    startIOSPIP,
    stopIOSPIP,
};

declare const global: any;

function registerGlobals(): void {
    // Should not happen. React Native has a global navigator object.
    if (typeof global.navigator !== 'object') {
        throw new Error('navigator is not an object');
    }

    if (!global.navigator.mediaDevices) {
        global.navigator.mediaDevices = {};
    }

    global.navigator.mediaDevices.getUserMedia = mediaDevices.getUserMedia.bind(mediaDevices);
    global.navigator.mediaDevices.getDisplayMedia = mediaDevices.getDisplayMedia.bind(mediaDevices);
    global.navigator.mediaDevices.enumerateDevices = mediaDevices.enumerateDevices.bind(mediaDevices);

    global.RTCIceCandidate = RTCIceCandidate;
    global.RTCCertificate = RTCCertificate;
    global.RTCPeerConnection = RTCPeerConnection;
    global.RTCSessionDescription = RTCSessionDescription;
    global.MediaStream = MediaStream;
    global.MediaStreamTrack = MediaStreamTrack;
    global.MediaStreamTrackEvent = MediaStreamTrackEvent;
    global.RTCRtpTransceiver = RTCRtpTransceiver;
    global.RTCRtpReceiver = RTCRtpReceiver;
    global.RTCRtpSender = RTCRtpSender;
    global.RTCErrorEvent = RTCErrorEvent;

    // PUBLISH-OR-DON'T. Web code feature-detects these two by their mere presence, and a
    // present-but-powerless constructor makes it build a mix or a recording that reports
    // success carrying nothing. So each is installed only when the native half it drives is in
    // THIS binary — an OTA JS bundle can be newer than the app around it. A host that installs
    // its own (a subclass with its conventions) is left alone.
    if (typeof WebRTCModule.conferenceAttachLeg === 'function' && typeof global.AudioContext !== 'function') {
        global.AudioContext = AudioContext;
    }

    // The generic recorder writes to native default paths, which only a binary exporting
    // `recordingsDirectory` provides; a host subclass supplies its own paths and its own gate.
    if (typeof WebRTCModule.startCallRecording === 'function'
        && typeof WebRTCModule.recordingsDirectory === 'string'
        && typeof global.MediaRecorder !== 'function') {
        global.MediaRecorder = MediaRecorder;
    }
}
