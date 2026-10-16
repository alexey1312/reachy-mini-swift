import Foundation
import OSLog
import ReachyKit

/// What a failed robot sign-in says, in this app's words.
///
/// Daemon 1.12 answers a failed Hugging Face sign-in with one of a few fixed
/// English sentences and keeps the detail in its own log
/// (pollen-robotics/reachy_mini#1363). Before 1.12 the same slot could carry the
/// provider's own text — `str(e)` of whatever the Hub raised — which upstream
/// stopped sending because it could carry credentials. So a known sentence is
/// translated, and any other text is replaced by a general one rather than shown;
/// the raw text goes to the log as private.
enum RobotHFFailureCaption {
    static func text(for daemonMessage: String?) -> String {
        guard let daemonMessage else { return general }
        if let known = known(daemonMessage) {
            return known
        }
        log.notice("robot sign-in failed with text this app does not know: \(daemonMessage, privacy: .private)")
        return general
    }

    static var general: String {
        String(localized: .reachy("Hugging Face did not sign the robot in."))
    }

    /// The daemon's sentences, verbatim from `apps/sources/hf_auth.py` in 1.12.0:
    /// the five #1363 introduced and the three it left as they were.
    private static func known(_ message: String) -> String? {
        switch message.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Authentication failed. Please try again.":
            String(localized: .reachy("Hugging Face did not sign the robot in. Try again."))
        case "Authorization was denied.":
            String(localized: .reachy("The sign-in was denied on huggingface.co."))
        case "Login expired. Please try again.",
             "Invalid or expired session. Please try again.",
             "Session expired or not found":
            String(localized: .reachy("The sign-in expired. Link the robot again."))
        case "Sign-in was cancelled. Please try again.":
            String(localized: .reachy("The sign-in was cancelled. Link the robot again."))
        case "Could not save credentials. Please try again.":
            String(localized: .reachy("The robot could not save its sign-in. Try again."))
        case "Invalid token or network error":
            String(localized: .reachy("Hugging Face refused the token, or the robot could not reach Hugging Face."))
        default:
            nil
        }
    }

    private static let log = Logger(subsystem: "com.alexey1312.ReachyMini", category: "RobotHFLink")
}
