import type RTCPeerConnection from './RTCPeerConnection';

/**
 * The live RTCPeerConnection objects by `_pcId`.
 *
 * An RTCRtpSender knows only its peer connection's id, and the conference binding needs the
 * object: which factory the connection was born on (`_conferenceLegId`) decides the leg id
 * the native bus must be told. Registered from the constructor, dropped when the connection
 * reports `closed`. Type-only import of the class, so this file sits below it with no cycle.
 */
const peerConnections = new Map<number, RTCPeerConnection>();

export function registerPeerConnection(peerConnection: RTCPeerConnection): void {
    peerConnections.set(peerConnection._pcId, peerConnection);
}

export function unregisterPeerConnection(pcId: number): void {
    peerConnections.delete(pcId);
}

export function getPeerConnection(pcId: number): RTCPeerConnection | undefined {
    return peerConnections.get(pcId);
}
