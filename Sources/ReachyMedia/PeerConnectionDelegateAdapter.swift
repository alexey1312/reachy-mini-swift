import Foundation
@preconcurrency import WebRTC

/// Bridges nonisolated WebRTC delegate callbacks onto the MainActor session.
///
/// Its own file to keep `CameraSession.swift` under SwiftLint's 400-line limit
/// (the `RobotFilesModel+Errors.swift` precedent). Everything it calls on the
/// owner is internal, so nothing had to widen for the move.
final class PeerConnectionDelegateAdapter: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private weak var owner: CameraSession?

    init(owner: CameraSession) {
        self.owner = owner
    }

    func peerConnection(_: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let sdp = candidate.sdp
        let index = candidate.sdpMLineIndex
        let mid = candidate.sdpMid
        Task { @MainActor [owner] in
            owner?.handleLocalCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
        }
    }

    func peerConnection(_: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams _: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [owner] in
            owner?.handleRemote(videoTrack: track)
        }
    }

    /// The connection state rather than ICE's: it is `connected` only once DTLS has
    /// finished on top of ICE, and `failed` when either one gives up — so one callback
    /// says both when the stream is real and when its attempt has stalled.
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let peer = ObjectIdentifier(peerConnection)
        Task { @MainActor [owner] in
            owner?.peer(peer, changedTo: newState)
        }
    }

    /// The robot is the one that opens the channel, and only once negotiation is
    /// far enough along — so this, not construction, is when the control surface
    /// becomes usable.
    func peerConnection(_: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [owner] in
            owner?.adopt(dataChannel)
        }
    }

    // Required by the protocol; nothing to do. ICE's own state included: its failure
    // reaches the connection state too, and reacting to both would count it twice.
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceConnectionState) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
}
