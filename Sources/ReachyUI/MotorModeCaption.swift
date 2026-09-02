import Foundation
import ReachyDesign
import ReachyKit

/// The motor mode as a caption, mapped from the generated enum here rather than in
/// `ReachyKit`, which does not link `ReachyDesign` and so cannot spell `.reachy`.
///
/// The Robot tab used to print `mode.rawValue` — "enabled" in lowercase beside a
/// "Running" that was not, and `gravity_compensation` with its underscore on show.
/// Project rule 9 says never to show a domain enum's own spelling; this is the
/// caption type it asks for, in the shape `DaemonStateCaption` already has. The
/// enum is closed, so an exhaustive switch is what keeps a new mode from shipping
/// as its wire value.
enum MotorModeCaption {
    static func text(for mode: Components.Schemas.MotorControlMode) -> LocalizedStringResource {
        switch mode {
        case .enabled: .reachy("On")
        case .disabled: .reachy("Off")
        case .gravityCompensation: .reachy("Gravity compensation")
        }
    }
}
