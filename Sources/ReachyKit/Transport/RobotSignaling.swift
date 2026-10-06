import Foundation

/// What a WebRTC session needs from whoever is carrying its signaling.
///
/// Two carriers exist and the RTC half does not care which: on the LAN it is the
/// robot's own WebSocket on port 8443, and from outside it is the Hugging Face
/// relay's event stream. Both speak the same `webrtcsink` protocol, both make the
/// robot the offerer, and both end up handing this app an SDP offer to answer.
public protocol RobotSignaling: Sendable {
    func events() async -> AsyncStream<SignalingEvent>
    func send(answerSDP: String) async
    func send(candidate: String, sdpMLineIndex: Int32, sdpMid: String?) async
    func disconnect() async
}

/// The signaling half of a session, in the terms the media layer acts on.
public enum SignalingEvent: Sendable, Equatable {
    /// Signaling is up but nothing is producing yet — the simulator before media
    /// is acquired, or a robot whose relay has not registered.
    case waitingForProducer
    /// A producer is there and the carrier asked it for a session, so an offer is
    /// owed. After `waitingForProducer` this is the only sign that the wait is over —
    /// the robot registered late, just woken or with its media server restarted.
    case sessionRequested
    case offer(sessionID: String, sdp: String)
    case remoteCandidate(sessionID: String, candidate: String, sdpMLineIndex: Int32, sdpMid: String?)
    /// The session ended. `reason` exists only over the relay, where central says
    /// why — a local app took the robot, or another device did.
    case sessionEnded(reason: String?)
    /// Terminal: nothing will be retried. The LAN client reconnects on its own and
    /// never reports this; the relay does, for a token that was refused.
    case failed(String)
}

/// The LAN carrier. It speaks `SignalingEvent` natively, so the conformance is
/// empty — the protocol was extracted from this client's own shape.
extension CameraSignalingClient: RobotSignaling {}
