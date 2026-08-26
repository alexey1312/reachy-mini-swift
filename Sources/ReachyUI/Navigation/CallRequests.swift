import Foundation
import Observation

/// A request to call a robot, arriving from outside the running interface: the
/// Siri phrase (`CallRobotIntent`, in the app target) or a Recents redial
/// (`CallActivity`). `RootCallLifecycle` routes it — Live tab, camera up,
/// microphone open — once the stream is there to unmute into.
///
/// The `shared`/token shape is `QuickActionInbox`'s, for the same two reasons:
/// the intent runs with no initialiser to inject through, and two identical
/// requests must arrive as two values or `onChange` never fires for the second.
@MainActor
@Observable
public final class CallRequestInbox {
    public struct Pending: Equatable, Sendable {
        public let request: CallRequest
        let token: Int
    }

    public static let shared = CallRequestInbox()

    public private(set) var pending: Pending?
    private var issued = 0

    public init() {}

    /// `robotID` is `RobotIdentity.deduplicationKey`, or `nil` for "whichever
    /// robot this app is connected to" — the same optional every intent takes.
    public func receive(robotID: String?, now: Date = Date()) {
        issued += 1
        pending = Pending(
            request: CallRequest(robotID: robotID, receivedAt: now),
            token: issued
        )
    }

    /// Routing decided the request cannot be honoured (expired, wrong robot, no
    /// camera) or has been honoured; either way it must not fire again.
    func drop() {
        pending = nil
    }
}

/// The request itself, with the one decision that is about *time*: a redial
/// that waits out a slow connection and then opens the microphone minutes after
/// the tap is a privacy bug, so a request expires rather than lurks.
public struct CallRequest: Equatable, Sendable {
    public let robotID: String?
    public let receivedAt: Date

    /// Long enough for the gate's own discovery to connect and the stream to
    /// negotiate; short enough that the unmute is still plainly the tap's.
    static let timeToLive: TimeInterval = 60

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(receivedAt) > Self.timeToLive
    }
}

/// Where an inbound call request may go, given who is connected. The receive
/// rules mirror `ReachyHandoff`'s: an inbound request never disconnects a live
/// session, and never opens the microphone at a robot the user did not name.
enum CallRequestRouting {
    enum Decision: Equatable {
        /// The named robot (or "whichever") is the connected one: go to the
        /// Live tab and unmute once streaming.
        case proceed
        /// A different robot was named: show the Live tab and stop there.
        case liveTabOnly
        /// Nothing connected yet: leave the request pending — the gate's own
        /// discovery connects, and expiry bounds the wait.
        case waitForConnection
    }

    static func decide(requestRobotID: String?, connectedRobotID: String?) -> Decision {
        guard let connectedRobotID else { return .waitForConnection }
        guard let requestRobotID, requestRobotID != connectedRobotID else { return .proceed }
        return .liveTabOnly
    }
}
