import Foundation
import ReachyKit

/// The fifth navigation system: what the *other* device was doing.
///
/// A continued activity carries the selected tab and the robot's identity — never the live
/// media session, which is re-established, and never an address (rule 4). What the receiver
/// does with it, decided in `RootLifecycle`:
/// - the same robot is connected → the tab switches live;
/// - nothing is connected → the tab is set on the router (it outlives the gate) and the
///   gate's own discovery finds the robot, so the shell opens on the handed-off tab;
/// - a different or unknown robot → the tab only; an inbound activity never disconnects a
///   live session.
///
/// `activityType` is declared a second time in `Apps/Project.swift`'s `NSUserActivityTypes`
/// — a unit test cannot read the app's Info.plist, so the pair can drift; the symptom is a
/// Handoff badge that never appears. Copy the string, do not retype it.
enum ReachyHandoff {
    static let activityType = "com.alexey1312.ReachyMini.session"
    static let tabKey = "tab"
    static let robotKey = "robotKey"

    struct Payload: Equatable {
        let tab: ReachyRouter.Tab
        let robotKey: String
    }

    /// Fills a system-provided activity. The title is the robot's own name — data, so it
    /// takes no catalogue key — and the identity travels as `deduplicationKey`, the same
    /// join key `KnownRobots` stores.
    static func publish(tab: ReachyRouter.Tab, identity: RobotIdentity, into activity: NSUserActivity) {
        activity.title = identity.name
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.userInfo = [
            tabKey: tab.rawValue,
            robotKey: identity.deduplicationKey,
        ]
        activity.requiredUserInfoKeys = [tabKey, robotKey]
    }

    /// Refuses a foreign activity type and an unknown tab spelling, the way
    /// `ReachySpotlightIndex.destination(for:)` refuses what is not its own.
    static func payload(for activity: NSUserActivity) -> Payload? {
        guard activity.activityType == activityType,
              let rawTab = activity.userInfo?[tabKey] as? String,
              let tab = ReachyRouter.Tab(rawValue: rawTab),
              let robot = activity.userInfo?[robotKey] as? String
        else { return nil }
        return Payload(tab: tab, robotKey: robot)
    }
}
