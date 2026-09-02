import Foundation

/// One script in the robot's `commands/` directory, with what it actually costs to run.
///
/// The list comes from the robot, never from here: the characteristic is a listing of a
/// real directory that a later daemon release can add to. This type only supplies what a
/// directory listing cannot — how much each one costs. The words are `ReachyUI`'s.
public struct BLERecoveryScript: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        /// Interrupts the robot briefly and leaves everything where it was.
        case routine
        /// Takes the robot off the network, or forgets how to get back onto it. Nothing
        /// is destroyed, but the robot has to be set up again to be reachable.
        case disruptive
        /// Destroys something the robot cannot get back on its own.
        case destructive

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let name: String
    public let severity: Severity

    public var id: String {
        name
    }

    /// Reads the available-commands characteristic: `", "`-joined, `.sh` already stripped
    /// by the robot, and the literal `None` when the directory is empty.
    ///
    /// Sorted gently rather than left alone — the robot builds the string from
    /// `os.listdir`, whose order is arbitrary, and a list that reshuffles between reads is
    /// a list nobody can tap safely.
    public static func parse(_ raw: String) -> [BLERecoveryScript] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "None" else { return [] }
        return trimmed
            .split(separator: ",")
            .map { describing($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.name.isEmpty }
            .sorted { ($0.severity, $0.name) < ($1.severity, $1.name) }
    }

    /// What daemon 1.9.0 ships. Anything else is `.disruptive` deliberately: these are
    /// root shell scripts, and guessing "harmless" about one this build has never heard of
    /// is the wrong direction to be wrong in. What each one *does* is said by
    /// `BLERecoveryScriptCaption` in `ReachyUI`, where it can be translated.
    public static func describing(_ name: String) -> BLERecoveryScript {
        switch name {
        case "RESTART_DAEMON": BLERecoveryScript(name: name, severity: .routine)
        case "HOTSPOT", "WIFI_RESET": BLERecoveryScript(name: name, severity: .disruptive)
        case "SOFTWARE_RESET": BLERecoveryScript(name: name, severity: .destructive)
        default: BLERecoveryScript(name: name, severity: .disruptive)
        }
    }
}
