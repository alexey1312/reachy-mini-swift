import Foundation
import ReachyDesign
import ReachyKit

/// Why the robot refused an app action over the relay, in this app's words.
///
/// Daemon 1.13.0's relay names each refusal with a `reason` (`jsonrpc_relay.py`),
/// and its message is an English sentence written for a developer:
/// "'reachy_mini_dance' is the startup app; unset it before removing it". Over the
/// relay the way out is often somewhere else — the startup app is HTTP alone — so
/// the reasons a reader can act on get a sentence that says where. An unknown
/// reason keeps the daemon's own words, which is what a bug report needs.
enum AppStoreRefusalCaption {
    static func sentence(for error: any Error) -> String? {
        guard case let .rpc(code, _, reason) = error as? RemoteControlChannel.Failure else { return nil }
        // An older robot answers every verb it lacks this way.
        if code == -32601 {
            return String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "This robot's software cannot do this over Hugging Face. Update the robot, or connect on its own network."
                )
            )
        }
        return switch reason {
        case "busy":
            String(
                localized: .reachy(
                    "Another app is being installed, updated or removed on the robot. Try again when it is done."
                )
            )
        case "app_running":
            String(localized: .reachy("This app is running. Stop it first, then try again."))
        case "startup_app":
            String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "The robot starts this app on wake-up. Turn that off on the robot's own network first, then remove it."
                )
            )
        case "not_found":
            String(localized: .reachy("Hugging Face has no Reachy Mini app at this address."))
        case "already_running":
            String(localized: .reachy("Another app is running on the robot. Stop it first."))
        default:
            nil
        }
    }
}

extension String? {
    /// ``recordDaemonFailure(_:)`` for an app action: the same filter and log, with
    /// a relay refusal said in this app's words (``AppStoreRefusalCaption``).
    mutating func recordAppStoreFailure(_ error: any Error) {
        guard let message = RobotSession.message(for: error) else { return }
        self = AppStoreRefusalCaption.sentence(for: error) ?? message
    }
}
