import Foundation
import ReachyKit

/// Signaling the test drives by hand: events go in through `deliver`, and whatever
/// the session sends comes out in `sent`, for the test to carry to the robot — or to
/// drop, which is the point of most of them.
///
/// Every `events()` call is a subscription, and a session that starts an attempt over
/// subscribes again; `deliver` always reaches the newest one, the way a carrier only
/// ever has one live session.
actor ScriptedSignaling: RobotSignaling {
    enum Sent: Equatable, Sendable {
        case answer(String)
        case candidate(String, sdpMLineIndex: Int32, sdpMid: String?)
        case disconnect
    }

    private var continuation: AsyncStream<SignalingEvent>.Continuation?
    private(set) var sent: [Sent] = []
    private(set) var subscriptions = 0

    func events() -> AsyncStream<SignalingEvent> {
        // `makeStream`, not the builder: a closure that stores its escaping continuation
        // is the shape that hangs the compiler (`RemoteControlChannelTests`).
        let (stream, continuation) = AsyncStream.makeStream(of: SignalingEvent.self)
        self.continuation?.finish()
        self.continuation = continuation
        subscriptions += 1
        return stream
    }

    func deliver(_ event: SignalingEvent) {
        continuation?.yield(event)
    }

    func send(answerSDP: String) {
        sent.append(.answer(answerSDP))
    }

    func send(candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        sent.append(.candidate(candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid))
    }

    func disconnect() {
        sent.append(.disconnect)
    }

    var answers: Int {
        sent.count {
            if case .answer = $0 {
                true
            } else {
                false
            }
        }
    }

    var disconnects: Int {
        sent.count { $0 == .disconnect }
    }
}
