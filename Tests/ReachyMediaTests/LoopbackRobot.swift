import Foundation
@preconcurrency import WebRTC

/// The robot's half of a session, as a second peer connection in the test process.
///
/// It plays `webrtcsink`: it is the offerer, it sends a video track and opens the
/// `data` channel, and it answers to nobody but the signaling the test routes to it.
/// What it deliberately leaves out is audio. An audio m-line makes the session under
/// test attach its microphone track, and on macOS — where nothing holds libwebrtc in
/// manual audio mode — a sending audio stream starts the capture device, which a test
/// process with no usage description is killed for.
@MainActor
final class LoopbackRobot {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private let peer: RTCPeerConnection
    private let observer: Observer
    /// Held so the channel is in the offer and stays open; nothing reads it.
    private let channel: RTCDataChannel?

    /// Every local candidate, in the order the robot gathered them.
    private(set) var candidates: [RTCIceCandidate] = []
    private(set) var connectionState: RTCPeerConnectionState = .new

    init() {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let observer = Observer()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: observer)
        else {
            preconditionFailure("libwebrtc refused to build a peer connection")
        }
        let source = Self.factory.videoSource()
        let track = Self.factory.videoTrack(with: source, trackId: "camera")
        peer.add(track, streamIds: ["reachymini"])
        channel = peer.dataChannel(forLabel: "data", configuration: RTCDataChannelConfiguration())
        self.peer = peer
        self.observer = observer
        observer.robot = self
    }

    /// An offer, already applied locally — what the robot sends the moment a session starts.
    func offer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await peer.offer(for: constraints)
        try await peer.setLocalDescription(offer)
        return offer.sdp
    }

    func accept(answer sdp: String) async throws {
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
    }

    func add(candidate sdp: String, sdpMLineIndex: Int32, sdpMid: String?) async {
        guard !sdp.isEmpty else { return }
        try? await peer.add(RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid))
    }

    func close() {
        peer.close()
    }

    private func gathered(_ candidate: RTCIceCandidate) {
        candidates.append(candidate)
    }

    private func changed(to state: RTCPeerConnectionState) {
        connectionState = state
    }

    private final class Observer: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
        @MainActor weak var robot: LoopbackRobot?

        func peerConnection(_: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            Task { @MainActor [weak self] in self?.robot?.gathered(candidate) }
        }

        func peerConnection(_: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
            Task { @MainActor [weak self] in self?.robot?.changed(to: newState) }
        }

        func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
        func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
        func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
        func peerConnection(_: RTCPeerConnection, didChange _: RTCIceConnectionState) {}
        func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
        func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
        func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
    }
}
