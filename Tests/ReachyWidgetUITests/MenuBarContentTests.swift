import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// The popover composes the two widget contents and decides nothing itself, so what
/// is worth pinning here is exactly that: the rules arrive intact, and the one piece
/// of new arithmetic — the merged refresh schedule — is right.
@Suite("Menu bar content")
struct MenuBarContentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        isAwake: Bool = true,
        runningApp: String? = nil,
        ageInMinutes: Double = 0
    ) -> RobotSnapshot {
        let takenAt = now.addingTimeInterval(-ageInMinutes * 60)
        return RobotSnapshot(
            robotName: "kitchen",
            isAwake: isAwake,
            runningApp: runningApp,
            runningAppName: runningApp,
            runningAppTakenAt: runningApp == nil ? nil : takenAt,
            takenAt: takenAt
        )
    }

    private func apps(_ names: [String]) -> [RobotAppSummary] {
        names.map { RobotAppSummary(id: $0, name: $0, title: $0.capitalized) }
    }

    private func cache(_ names: [String]) -> RobotAppsCache {
        RobotAppsCache(robotID: "test", installed: apps(names), takenAt: now)
    }

    @Test("a stale reading offers waking and never sleeping, and still lists the apps")
    func staleReadingKeepsTheList() {
        let content = MenuBarContent(
            snapshot: .stale(snapshot(isAwake: true, ageInMinutes: 120)),
            cache: cache(["dance"]),
            hasKnownRobot: true,
            at: now
        )

        #expect(content.status.action == .wake)
        #expect(content.status.isStale)
        #expect(content.apps.tiles.count == 1)
    }

    @Test("a transition in flight takes the button away and leaves the list alone")
    func pendingRemovesTheAction() {
        let content = MenuBarContent(
            snapshot: .fresh(snapshot(isAwake: false)),
            power: RobotPowerTransitionState(pending: .init(transition: .wakingUp, since: now)),
            cache: cache(["dance", "chess"]),
            hasKnownRobot: true,
            at: now
        )

        #expect(content.status.action == nil)
        #expect(content.status.isPending)
        #expect(content.apps.tiles.count == 2)
    }

    @Test("with no robot there is nothing to command and nothing to list")
    func noRobotOffersNothing() {
        let content = MenuBarContent(snapshot: .unknown, hasKnownRobot: false, at: now)

        #expect(content.status.action == nil)
        #expect(content.apps.tiles.isEmpty)
        #expect(content.apps.notice == .noRobot)
    }

    /// The popover has no configuration UI, so the robot's own installed list is
    /// what it must fall back to — the unconfigured behaviour, deliberately.
    @Test("it lists the robot's installed apps without any configuration")
    func listsTheInstalledApps() {
        let content = MenuBarContent(
            snapshot: .fresh(snapshot()),
            cache: cache(["dance", "chess", "wobbler"]),
            hasKnownRobot: true,
            at: now
        )

        #expect(content.apps.tiles.map(\.name) == ["dance", "chess", "wobbler"])
    }

    @Test("it takes more apps than a widget family does")
    func popoverHoldsMoreThanATile() {
        #expect(MenuBarContent.appLimit > 4)
    }

    @Test("the refresh schedule is the sorted union of both halves, in the future")
    func refreshDatesMergeBothHalves() {
        let state = RobotSnapshotState.fresh(snapshot(runningApp: "dance"))
        let power = RobotPowerTransitionState(pending: .init(transition: .wakingUp, since: now))
        let launch = RobotAppLaunchState(pending: .init(appID: "chess", isStop: false, since: now))

        let merged = MenuBarContent.refreshDates(snapshot: state, power: power, launch: launch, after: now)
        let status = RobotWidgetContent.refreshDates(snapshot: state, power: power, after: now)
        let apps = RobotAppsWidgetContent.refreshDates(snapshot: state, launch: launch, after: now)

        #expect(merged == Set(status + apps).sorted())
        #expect(merged.allSatisfy { $0 > now })
        #expect(merged == merged.sorted())
    }

    /// Both halves file the running app's expiry, so without deduplication the model
    /// would wake twice for one boundary.
    @Test("a boundary both halves file appears once")
    func refreshDatesDeduplicate() {
        let state = RobotSnapshotState.fresh(snapshot(runningApp: "dance"))

        let merged = MenuBarContent.refreshDates(snapshot: state, power: nil, launch: nil, after: now)

        #expect(merged.count == Set(merged).count)
    }
}
