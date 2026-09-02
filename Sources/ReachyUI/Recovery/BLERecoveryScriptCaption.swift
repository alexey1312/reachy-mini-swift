import ReachyDesign
import ReachyKit

/// What each recovery script does, in the reader's language.
///
/// `BLERecoveryScript` names the script and grades it — that is what the robot's
/// directory listing supports — and this maps the name onto words, the way
/// `DaemonStateCaption` does for a daemon state: `ReachyKit` has no catalogue, and
/// a sentence a reader sees has to be translatable. The file name is the title of
/// a script this build has never met; inventing one would be the wrong kind of
/// helpful.
enum BLERecoveryScriptCaption {
    static func title(for script: BLERecoveryScript) -> String {
        switch script.name {
        case "RESTART_DAEMON": String(localized: .reachy("Restart the robot's software"))
        case "HOTSPOT": String(localized: .reachy("Switch to the robot's own hotspot"))
        case "WIFI_RESET": String(localized: .reachy("Forget every saved Wi-Fi network"))
        case "SOFTWARE_RESET": String(localized: .reachy("Software reset"))
        default: script.name
        }
    }

    static func summary(for script: BLERecoveryScript) -> String {
        switch script.name {
        case "RESTART_DAEMON":
            String(
                localized: .reachy(
                    "Restarts the robot's software. It drops off the network for a few seconds and comes back."
                )
            )
        case "HOTSPOT":
            String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "Disconnects Wi-Fi and puts the robot's own reachy-mini-ap network back up. It leaves your network until it is set up again."
                )
            )
        case "WIFI_RESET":
            String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "Deletes every Wi-Fi network the robot has saved, except its own hotspot. Every password has to be entered again."
                )
            )
        case "SOFTWARE_RESET":
            String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "Erases the robot's Python environments and restores the factory copy. Every installed app and everything it stored is gone."
                )
            )
        default:
            String(localized: .reachy("This app does not know what this script does. It runs as root on the robot."))
        }
    }
}
