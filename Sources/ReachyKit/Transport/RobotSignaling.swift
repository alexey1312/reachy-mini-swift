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
    /// Ends the session this carrier holds. `hangUp` says why, and only the relay
    /// passes it on — see ``SignalingHangUp``.
    func disconnect(_ hangUp: SignalingHangUp) async
}

public extension RobotSignaling {
    /// The client is done with the robot.
    func disconnect() async {
        await disconnect(.stop)
    }
}

/// Why this client ends a session, in the words the JS SDK sends to central.
///
/// From daemon 1.13.0 the robot reads an `endSession` **without** a reason as central's
/// own bookkeeping, not as the client hanging up: while the peer link still carries
/// the client's RTCP or data, it keeps the session (`central_signaling_relay.py`,
/// pollen-robotics/reachy_mini#1480). A restart that sent no reason therefore left the
/// old session alive, and the `startSession` after it was refused as
/// `robot_busy_local` for up to the 12 s the robot waits before it calls a session
/// idle. Any reason makes the hang-up deliberate.
public enum SignalingHangUp: String, Sendable, Equatable {
    /// The session is over: the screen closed, or the link was let go of.
    case stop = "client_stop"
    /// The session ends so that a new one can start at once — a stalled
    /// negotiation, or a retry after one.
    case redial = "client_redial"
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

/// The LAN carrier. It speaks `SignalingEvent` natively — the protocol was extracted
/// from this client's own shape. The robot's own socket has no reason to carry:
/// closing it ends the session there.
extension CameraSignalingClient: RobotSignaling {
    public func disconnect(_: SignalingHangUp) async {
        await disconnect()
    }
}
