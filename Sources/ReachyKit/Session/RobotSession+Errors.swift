import Foundation
import OpenAPIRuntime
import OSLog

/// Everything that turns a thrown error into something a person reads, in one
/// place: the sentence itself, whether there is anything to say at all, and the
/// log line that survives either way.
public extension RobotSession {
    /// `ReachyKitError` carries actionable text; raw interpolation would print
    /// the bare case name instead.
    ///
    /// The generated client wraps transport failures in a `ClientError` whose
    /// description carries the whole operation context — around twenty lines of
    /// `NSError` internals that bury the one sentence worth reading. Unwrap to the
    /// root cause first, so a refused connection reads as "Could not connect to
    /// the server."
    /// Public because a session is not the only thing that has to put a daemon
    /// failure in front of someone: an App Intent gets one line in Shortcuts and
    /// no screen to elaborate on.
    /// `nonisolated` because it reads only its argument: an intent runs off the
    /// main actor and still has to render the same sentence.
    nonisolated static func describe(_ error: Error) -> String {
        let root = rootCause(of: error)
        return (root as? LocalizedError)?.errorDescription ?? root.localizedDescription
    }

    /// The sentence to show for a failed daemon call, or `nil` when there is
    /// nothing worth showing. Logs either way, and is the **only** place that
    /// does — a second logging point in the funnels would double every line.
    ///
    /// Every screen that displays a daemon failure goes through this rather than
    /// through `describe` directly. That is not a style preference: a cancelled
    /// request reads as the word "cancelled" (see `isCancellation`), so a model
    /// left to describe its own errors puts it on its own tab instead. Moving the
    /// filter into the session alone would have moved the bug, not fixed it.
    ///
    /// `nil` means *leave what is on screen alone*. An abandoned call learned
    /// nothing, so it may neither report a failure nor clear one still being read.
    nonisolated static func message(for error: Error) -> String? {
        guard !isCancellation(error) else {
            // `.public`: an error description carries no user data, and a line
            // reading `<private>` would defeat the point of keeping it.
            log.debug("dropped cancelled call: \(String(describing: error), privacy: .public)")
            return nil
        }
        let message = describe(error)
        log.error("daemon call failed: \(message, privacy: .public)")
        return message
    }

    /// A cancelled call is not a robot failure — it is this app letting go. The
    /// screen that asked went away, or the session was torn down under an
    /// in-flight request; either way nobody is waiting for the answer and the
    /// robot did nothing wrong.
    ///
    /// It has to be recognised by code, never by text: `URLSession` reports an
    /// abandoned task as `NSURLErrorCancelled` whose entire localized description
    /// is the single word **"cancelled"**, and `describe` faithfully passed that
    /// word on. Opening the Apps tab and leaving again before the catalogue
    /// arrived was all it took to print it in red monospace on the robot screen.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        switch rootCause(of: error) {
        case is CancellationError: true
        case let urlError as URLError: urlError.code == .cancelled
        default: false
        }
    }

    /// Whether the link went away before the robot answered.
    ///
    /// Not the same as a refusal the daemon made, and the difference is the whole
    /// story on the Wi-Fi join screen: there, success *is* the link going away, so
    /// a dropped call may well have been obeyed. Reporting it as a refusal sent
    /// people back to retype a password that had worked.
    nonisolated static func isLinkLoss(_ error: Error) -> Bool {
        guard let urlError = rootCause(of: error) as? URLError else { return false }
        return switch urlError.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            true
        default:
            false
        }
    }
}

extension RobotSession {
    private nonisolated static let log = Logger(
        subsystem: "com.alexey1312.ReachyMini",
        category: "RobotSession"
    )

    private nonisolated static func rootCause(of error: Error) -> Error {
        if let clientError = error as? ClientError {
            return rootCause(of: clientError.underlyingError)
        }
        return error
    }

    /// Records a connection or power failure in `robotError` — the session's own
    /// slot, and the only kind of failure entitled to it. A feature's funnel
    /// throws and says nothing here; its screen owns the message.
    func report(_ error: Error) {
        guard let message = Self.message(for: error) else { return }
        robotError = message
    }
}
