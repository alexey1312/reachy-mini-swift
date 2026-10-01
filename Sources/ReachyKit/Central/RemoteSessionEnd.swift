import Foundation

/// Why a remote session was refused or taken away, in words.
///
/// Central says it in one short code, and those codes are the only explanation a
/// remote user ever gets. They are not interchangeable: a robot that is busy may
/// be free in a minute, while a robot somebody just walked up to will not be —
/// and retrying the second case takes it out of their hands.
public struct RemoteSessionEnd: Equatable, Sendable {
    public let reason: String
    public let activeApp: String?

    public init(reason: String, activeApp: String? = nil) {
        self.reason = reason
        self.activeApp = activeApp
    }

    public var message: String {
        switch reason {
        case "robot_busy", "robot_busy_local", "robot_busy_local_app":
            activeApp.map { "The robot is running \($0)." } ?? "The robot is in use right now."
        case "local_app_started":
            activeApp.map { "\($0) was started on the robot, which takes priority." }
                ?? "An app was started on the robot, which takes priority."
        case "install_id_takeover":
            "This robot was opened from another device."
        default:
            // The raw code, so a bug report can name what a later central invented.
            "The session ended (\(reason))."
        }
    }

    /// The robot's own negotiation watchdog gave up on the session: ICE had not
    /// connected within its deadline, or the peer connection failed
    /// (`SESSION_FAILED_REASON_*` in the daemon's `media_server.py`). Not a refusal —
    /// nobody else holds the robot, and the next attempt often goes through, which is
    /// why the camera counts it as a stalled attempt instead of showing the code.
    public var isNegotiationStall: Bool {
        reason == "ice_negotiation_timeout" || reason == "peer_connection_failed"
    }

    /// Whether trying again in a moment could work. A robot busy with something
    /// that ends will free itself; one that was deliberately taken will not, and
    /// retrying is how two devices fight over it.
    public var isWorthRetrying: Bool {
        switch reason {
        case "local_app_started", "install_id_takeover": false
        default: true
        }
    }
}
