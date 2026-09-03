import Foundation
import ReachyKit

/// Where the opt-in lives, readable from outside a `View`.
///
/// `@AppStorage` is a property wrapper and only a `View` may hold one, but the
/// decision to post is taken by `JobNotificationCenter`, which is not a view and must
/// not become one. So the key is declared once here and the two readers agree by
/// naming it rather than by convention.
///
/// The suite is the App Group rather than `.standard`, which is where every other
/// setting in this app already lives — `ThemeStore`, `KnownRobotStore`,
/// `RobotAppLaunchStateStore`, `RunningAppActivityDismissalStore`. `KnownRobots.defaults`
/// degrades to `.standard` on its own where no group is entitled, so a fork and every
/// unit test keep working.
enum JobNotificationSettings {
    static let key = "ReachyUI.jobNotifications"

    /// Off until the reader turns it on. An app that has never asked must not behave
    /// as though it had.
    static func isOn(_ defaults: UserDefaults = KnownRobots.defaults) -> Bool {
        defaults.bool(forKey: key)
    }
}
