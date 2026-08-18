import Foundation
import ReachyDesign
import ReachyKit

/// Which kind of robot answered, in words — and why half the settings are gone.
///
/// Here rather than in `ReachyKit` for the reason the whole package graph is
/// arranged around, and the reason `DaemonStateCaption` next door gives: a caller
/// maps its own domain type onto a presentation value, never the other way, so
/// `ReachyKit` never has to link `ReachyDesign`.
enum DaemonFlavourCaption {
    /// The name of the thing, short enough for a `LabeledContent` value.
    static func text(for flavour: DaemonFlavour) -> LocalizedStringResource {
        switch flavour {
        case .wireless: .reachy("Wireless")
        case .lite: .reachy("Lite")
        case .simulation: .reachy("Simulation")
        // Named for what it is missing, because that is the only thing separating
        // it from the row above and the only thing a reader can act on: a robot
        // that does not fall over is a robot whose behaviour proves less.
        case .mockup: .reachy("Simulation (no physics)")
        case .remote: .reachy("Hugging Face relay")
        }
    }

    /// Why the Wi-Fi, software update and maintenance cards are not on screen.
    ///
    /// `nil` where nothing is missing, or where something else already explains it:
    /// a Wireless robot mounts every route, and a relayed session's absences belong
    /// to ADR 0003 and are described where the relay is chosen.
    ///
    /// It is one sentence and it names the computer rather than the robot, because
    /// that is the actionable half — those routes are mounted only under
    /// `--wireless-version`, which nothing but a Wireless unit passes, so the
    /// settings genuinely belong to the machine running the daemon.
    static func absentSettings(for flavour: DaemonFlavour) -> LocalizedStringResource? {
        switch flavour {
        case .lite:
            .reachy(
                // swiftlint:disable:next line_length
                "The daemon for this robot runs on the computer it is plugged into, so its Wi-Fi, software updates and maintenance belong to that computer rather than here."
            )
        case .simulation, .mockup:
            .reachy(
                // swiftlint:disable:next line_length
                "A simulated robot has no Wi-Fi, no software of its own to update and nothing to maintain — those belong to the computer running the simulator."
            )
        case .wireless, .remote:
            nil
        }
    }
}
