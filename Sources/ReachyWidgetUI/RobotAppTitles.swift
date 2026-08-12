import Foundation
import ReachyKit

/// The human title for an app the daemon named, out of the installed list this
/// process last cached.
///
/// **A running app arrives with no title at all.** `AppManager.start_app` files
/// the status as `AppInfo(name=…, source_kind=INSTALLED)` with an empty `extra`,
/// so `RobotApp.title` on a `current-app-status` or a `start-app` reply falls back
/// to the Python entry point — and Siri then says `dance_party` where the robot's
/// own store says "Dance Party". `RobotSession.describedFromInstalled` is the
/// app's join for that gap; this is the intents', off the cache `RobotAppQuery`
/// already fills, because an intent has neither a list loaded nor the seconds to
/// fetch one.
///
/// An unmatched name comes back untouched. A local app with no Hub card is still
/// an app, and speaking somebody else's title would be worse than speaking a slug.
struct RobotAppTitles: Sendable {
    private let cache: RobotAppsCacheStore
    private let robotID: @Sendable () -> String?

    /// `robot` is a `RobotEntity.id`, so the title comes out of the cache belonging
    /// to the robot the intent addressed rather than to whichever one was connected
    /// to last.
    init(robot: String? = nil) {
        self.init(cache: RobotAppsCacheStore(), robotID: { RobotIntentTarget.knownRobot(id: robot)?.key })
    }

    init(cache: RobotAppsCacheStore, robotID: @escaping @Sendable () -> String?) {
        self.cache = cache
        self.robotID = robotID
    }

    /// Keyed by the entry point name rather than by `RobotApp.id`, because the
    /// entry point is the only name the daemon gives a running app — and the two
    /// differ whenever a Space slug does (`RobotApp.matches(installed:)`).
    func title(for entryPoint: String) -> String {
        guard let robotID = robotID(),
              let match = cache.current(for: robotID)?.installed.first(where: { $0.name == entryPoint })
        else { return entryPoint }
        return match.title
    }
}
