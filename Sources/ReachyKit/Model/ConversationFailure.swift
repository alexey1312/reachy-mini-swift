import Foundation

/// Why a call to the conversation app did not do what was asked.
///
/// One vocabulary for both transports. The LAN arm reads it off the frame's `error`
/// object; the relay arm converts ``RemoteControlChannel/Failure`` into it. Both go
/// through ``init(code:message:reason:)``, so the mapping that matters most —
/// `-32601` means this build of the app has no such method — exists in exactly one
/// place and the two paths cannot drift.
public enum ConversationFailure: Error, Equatable, Sendable {
    /// The app answered `-32601`. A build without this method, which the caller
    /// hides the control for rather than reports: an app cannot grow a method
    /// mid-session, so there is nothing a reader could act on.
    case methodNotFound
    /// The app answered, and said no.
    ///
    /// `code` is optional because one path genuinely has none:
    /// ``RemoteControlChannel/Failure/robot(_:)`` carries a message and nothing else,
    /// and inventing a zero there would hand callers a number to branch on that no
    /// robot ever sent.
    case rejected(code: Int?, reason: ConversationReason?, message: String)
    case timedOut
    /// The socket failed, or the answer was not JSON-RPC.
    case unreachable
}

/// The app's and the daemon's own stable failure codes.
///
/// Both sides treat these as a contract — the app's web client calls it "the stable
/// reason" and maps about twenty of them to copy — so they are matched here rather
/// than reinvented. Open, because the set grows: an unrecognised one is carried as
/// itself so a screen can still show the robot's own word.
public enum ConversationReason: Equatable, Sendable {
    /// No conversation session is live. From the app when nothing is connected, and
    /// from the relay (with `-32000`) when no app is running at all.
    case notRunning
    /// The relay reached for the app's `/rpc` and could not get there, or the
    /// connection dropped with the call in flight. The app is there; it is not
    /// answering.
    case appUnavailable
    /// The app is still coming up. Its own web client retries this every two seconds
    /// against a ninety-second deadline, because that is how long the backend takes —
    /// so a first failure carrying this is not a failure yet.
    case loopUnavailable
    case invalidParameters
    case profileLocked
    case unknownProfile
    case missingVoice
    case voiceApplyFailed
    case unknown(String)

    init(_ wire: String) {
        switch wire {
        case "not_running": self = .notRunning
        case "app_unavailable": self = .appUnavailable
        case "loop_unavailable": self = .loopUnavailable
        case "invalid_params": self = .invalidParameters
        case "profile_locked": self = .profileLocked
        case "unknown_profile": self = .unknownProfile
        case "missing_voice": self = .missingVoice
        case "voice_apply_failed": self = .voiceApplyFailed
        case let other: self = .unknown(other)
        }
    }
}

public extension ConversationFailure {
    /// The one place `-32601` becomes ``methodNotFound``.
    init(code: Int?, message: String, reason: String?) {
        guard code != -32601 else {
            self = .methodNotFound
            return
        }
        self = .rejected(code: code, reason: reason.map(ConversationReason.init), message: message)
    }

    /// The relay's failures in the same words as the app's own.
    ///
    /// `.closed` becomes ``unreachable`` rather than a case of its own: to a caller
    /// they are the same fact — the app cannot be reached — and the data channel
    /// closing is the relay's version of the LAN socket failing.
    init(relay failure: RemoteControlChannel.Failure) {
        switch failure {
        case let .rpc(code, message, reason):
            self.init(code: code, message: message, reason: reason)
        case .timedOut:
            self = .timedOut
        case .closed:
            self = .unreachable
        case let .robot(message):
            self = .rejected(code: nil, reason: nil, message: message)
        }
    }

    /// The reason, where there is one. Nil for the three cases that are about the
    /// transport rather than about what the app said.
    var reason: ConversationReason? {
        guard case let .rejected(_, reason, _) = self else { return nil }
        return reason
    }
}

extension ConversationFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .methodNotFound:
            "This build of the app does not have that control"
        case let .rejected(_, _, message):
            message
        case .timedOut:
            "The app did not answer in time"
        case .unreachable:
            "The conversation app could not be reached"
        }
    }
}
