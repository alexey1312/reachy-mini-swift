import Foundation
import ReachyKit

/// What the macOS menu bar popover puts on screen: the status widget's reading
/// and the launcher's tiles, side by side.
///
/// **It decides nothing of its own, and that is the whole design.** Every rule
/// worth having is already decided and already tested next door — the awake/asleep
/// asymmetry, the staleness gloss, the tile states, the notice precedence — so
/// restating any of it here is how the popover and the widget start disagreeing on
/// the same Mac. The two content types are composed, never re-derived.
public struct MenuBarContent: Equatable, Sendable {
    /// More than a widget family gets, because a popover has vertical room a
    /// 158 pt tile does not. Named here rather than passed as a literal so the
    /// number has one place to be argued with.
    public static let appLimit = 6

    public let status: RobotWidgetContent
    public let apps: RobotAppsWidgetContent

    public init(status: RobotWidgetContent, apps: RobotAppsWidgetContent) {
        self.status = status
        self.apps = apps
    }

    /// `configured` is deliberately empty: the menu bar has no configuration UI, so
    /// it always shows the robot's own installed list — which is exactly the
    /// unconfigured behaviour `RobotAppsWidgetContent` already defines.
    public init(
        snapshot: RobotSnapshotState,
        power: RobotPowerTransitionState? = nil,
        launch: RobotAppLaunchState? = nil,
        cache: RobotAppsCache? = nil,
        hasKnownRobot: Bool,
        limit: Int = MenuBarContent.appLimit,
        at date: Date = Date()
    ) {
        self.init(
            status: RobotWidgetContent(state: snapshot, power: power, at: date),
            apps: RobotAppsWidgetContent(
                configured: [],
                cache: cache,
                snapshot: snapshot,
                launch: launch,
                hasKnownRobot: hasKnownRobot,
                limit: limit,
                at: date
            )
        )
    }

    /// The moments something on screen stops being true, in order.
    ///
    /// The union of the two halves rather than a third calculation: both already
    /// file each boundary a millisecond late, for the reason
    /// `RobotWidgetContent.refreshDates` records, and recomputing that here would be
    /// a second answer that can drift. Deduplicated because both file the running
    /// app's expiry — without it the model would wake twice for one boundary.
    public static func refreshDates(
        snapshot: RobotSnapshotState,
        power: RobotPowerTransitionState?,
        launch: RobotAppLaunchState?,
        after now: Date
    ) -> [Date] {
        let status = RobotWidgetContent.refreshDates(snapshot: snapshot, power: power, after: now)
        let apps = RobotAppsWidgetContent.refreshDates(snapshot: snapshot, launch: launch, after: now)
        return Set(status + apps).sorted()
    }
}
