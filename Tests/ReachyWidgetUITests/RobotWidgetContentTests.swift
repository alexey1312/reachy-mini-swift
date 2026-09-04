import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// The widget's whole job is to say something true about a robot nobody is
/// currently talking to. What it must never do is state a reading it cannot
/// stand behind.
@Suite("Robot widget content")
struct RobotWidgetContentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        name: String? = "kitchen",
        isAwake: Bool = true,
        runningApp: String? = nil,
        failedApp: RobotSnapshot.FailedApp? = nil,
        ageInMinutes: Double = 0
    ) -> RobotSnapshot {
        let takenAt = now.addingTimeInterval(-ageInMinutes * 60)
        return RobotSnapshot(
            robotName: name,
            isAwake: isAwake,
            runningApp: runningApp,
            failedApp: failedApp,
            runningAppTakenAt: runningApp == nil && failedApp == nil ? nil : takenAt,
            takenAt: takenAt
        )
    }

    @Test("with no robot ever connected it offers the app rather than a state")
    func describesTheEmptyState() {
        let content = RobotWidgetContent(state: .unknown, at: now)

        #expect(content.isStale == false)
        #expect(content.detail.localizedCaseInsensitiveContains("awake") == false)
        #expect(content.detail.localizedCaseInsensitiveContains("asleep") == false)
    }

    @Test("a fresh reading is stated in the present tense")
    func describesAnAwakeRobot() {
        let content = RobotWidgetContent(state: .fresh(snapshot()), at: now)

        #expect(content.title == "kitchen")
        #expect(content.detail.localizedCaseInsensitiveContains("awake"))
        #expect(content.isStale == false)
    }

    @Test("an asleep robot says so")
    func describesASleepingRobot() {
        let content = RobotWidgetContent(state: .fresh(snapshot(isAwake: false)), at: now)

        #expect(content.detail.localizedCaseInsensitiveContains("asleep"))
    }

    /// The one rule worth a test of its own: past the window the widget reports
    /// when it last looked, never what the robot is doing. A robot switched off
    /// an hour ago would otherwise still read as awake.
    @Test("a stale reading reports when it was taken, not what the robot is doing")
    func refusesToStateAStaleReading() {
        let content = RobotWidgetContent(state: .stale(snapshot(ageInMinutes: 120)), at: now)

        #expect(content.isStale)
        #expect(content.title == "kitchen")
        #expect(content.detail.localizedCaseInsensitiveContains("awake") == false)
        #expect(content.detail.localizedCaseInsensitiveContains("asleep") == false)
    }

    /// Daemon 1.9.0 cannot be renamed and reports an empty name, so a robot
    /// without one is the common case rather than an edge.
    @Test("a robot with no name still has something to be called")
    func namesAnUnnamedRobot() {
        let content = RobotWidgetContent(state: .fresh(snapshot(name: nil)), at: now)

        #expect(content.title.isEmpty == false)
    }

    /// The running app is the most useful thing on the widget when there is one,
    /// and it belongs in front of the plain awake/asleep reading.
    @Test("a running app is named instead of the plain state")
    func namesTheRunningApp() {
        let content = RobotWidgetContent(state: .fresh(snapshot(runningApp: "Hand Tracker")), at: now)

        #expect(content.detail.contains("Hand Tracker"))
    }

    /// Falling silently back to "Awake" would be this widget's way of pretending
    /// nothing happened — the same gap the launcher's idle tile used to leave.
    @Test("an app that died displaces the plain state too")
    func namesACrashedApp() {
        let crashed = RobotSnapshot.FailedApp(name: "hand_tracker", title: "Hand Tracker", error: "boom")

        let content = RobotWidgetContent(state: .fresh(snapshot(failedApp: crashed)), at: now)

        #expect(content.detail.contains("Hand Tracker"))
        #expect(content.detail.localizedCaseInsensitiveContains("awake") == false)
    }

    /// On its own, shorter window: nothing will ever arrive to say a crash is over.
    @Test("an old crash gives the plain state back")
    func forgetsAnOldCrash() {
        let crashed = RobotSnapshot.FailedApp(name: "hand_tracker", title: "Hand Tracker")
        let age = (RobotSnapshotStore.failureFreshness + 60) / 60

        let content = RobotWidgetContent(state: .fresh(snapshot(failedApp: crashed, ageInMinutes: age)), at: now)

        #expect(content.detail.localizedCaseInsensitiveContains("awake"))
    }

    // MARK: - The tile

    @Test("a running app the cache knows is handed to the wide layout as a tile")
    func handsTheRunningAppToTheWideLayout() {
        let cache = RobotAppsCache(
            robotID: "abc",
            installed: [RobotAppSummary(
                id: "pollen-robotics/hand-tracker",
                name: "hand_tracker",
                title: "Hand Tracker"
            )],
            takenAt: now
        )

        let content = RobotWidgetContent(state: .fresh(snapshot(runningApp: "Hand Tracker")), apps: cache, at: now)

        #expect(content.runningApp?.title == "Hand Tracker")
    }

    @Test("without a cache, or off a stale reading, there is no tile")
    func noTileWithoutACache() {
        let cache = RobotAppsCache(
            robotID: "abc",
            installed: [RobotAppSummary(id: "x", name: "hand_tracker", title: "Hand Tracker")],
            takenAt: now
        )

        let fresh = RobotWidgetContent(state: .fresh(snapshot(runningApp: "Hand Tracker")), at: now)
        let stale = RobotWidgetContent(
            state: .stale(snapshot(runningApp: "Hand Tracker", ageInMinutes: 90)),
            apps: cache,
            at: now
        )

        #expect(fresh.runningApp == nil)
        #expect(stale.runningApp == nil)
    }

    // MARK: - The button

    /// The asymmetry the whole design turns on: `.sleep` only off the half of the
    /// reading a snapshot may be believed on.
    @Test("an awake robot is offered sleep and an asleep one is offered wake")
    func offersTheOppositeOfTheReading() {
        #expect(RobotWidgetContent(state: .fresh(snapshot()), at: now).action == .sleep)
        #expect(RobotWidgetContent(state: .fresh(snapshot(isAwake: false)), at: now).action == .wake)
    }

    /// A running app holds the robot, so the robot is awake and sleeping is still
    /// what the button is for.
    @Test("a running app does not take the sleep button away")
    func offersSleepOverARunningApp() {
        let content = RobotWidgetContent(state: .fresh(snapshot(runningApp: "Hand Tracker")), at: now)

        #expect(content.action == .sleep)
    }

    /// Never `.sleep` on a memory. `resume()` handles both meanings of a false
    /// `isAwake`; parking a robot that may already be parked is the direction where
    /// being wrong costs something.
    @Test("a stale reading offers only wake")
    func offersOnlyWakeOnAMemory() {
        #expect(RobotWidgetContent(state: .stale(snapshot(ageInMinutes: 120)), at: now).action == .wake)
        #expect(RobotWidgetContent(state: .stale(snapshot(isAwake: false, ageInMinutes: 120)), at: now).action == .wake)
    }

    /// `RobotIntentTarget` would throw `noKnownRobot`; the tap is better spent on
    /// the widget's own `widgetURL`.
    @Test("with no robot there is nothing to command")
    func offersNothingWithoutARobot() {
        #expect(RobotWidgetContent(state: .unknown, at: now).action == nil)
    }

    // MARK: - Transitions

    private func pending(
        _ transition: RobotSession.PowerTransition,
        secondsAgo: Double = 0,
        writer: RobotPowerTransitionState.Pending.Writer = .intent
    ) -> RobotPowerTransitionState {
        RobotPowerTransitionState(pending: .init(
            transition: transition,
            since: now.addingTimeInterval(-secondsAgo),
            writer: writer
        ))
    }

    @Test("a transition in flight replaces the state and takes the button away")
    func reportsATransition() {
        let content = RobotWidgetContent(
            state: .fresh(snapshot(isAwake: false)),
            power: pending(.startingBackend),
            at: now
        )

        #expect(content.isPending)
        #expect(content.action == nil)
        #expect(content.detail.localizedCaseInsensitiveContains("starting"))
    }

    /// The extension is not running to clear its own marker, so the window is the
    /// only thing that retires a transition nothing came back from.
    @Test("a transition past its own window is forgotten")
    func forgetsAStuckTransition() {
        let window = RobotPowerTransitionState.window(for: .wakingUp)

        let content = RobotWidgetContent(
            // Older than the transition, so the window is the only thing that can
            // retire it — otherwise supersession would and this would pass for the
            // wrong reason.
            state: .fresh(snapshot(isAwake: false, ageInMinutes: 5)),
            power: pending(.wakingUp, secondsAgo: window + 1),
            at: now
        )

        #expect(content.isPending == false)
        #expect(content.action == .wake)
    }

    /// Each transition carries its own budget: a cold start outlives a wake by
    /// minutes, and one window would be wrong for one of them.
    @Test("a cold start outlives a wake at the same age")
    func windowsDifferPerTransition() {
        let age = RobotPowerTransitionState.window(for: .wakingUp) + 1
        // Older than the transition, or supersession retires both markers before
        // either window is reached — which is what this test is not about.
        let snapshot = snapshot(isAwake: false, ageInMinutes: 5)

        #expect(RobotWidgetContent(state: .fresh(snapshot), power: pending(.wakingUp, secondsAgo: age), at: now)
            .isPending == false)
        #expect(RobotWidgetContent(state: .fresh(snapshot), power: pending(.startingBackend, secondsAgo: age), at: now)
            .isPending)
    }

    /// The rule `RobotAppLaunchState` has no equivalent of. Whoever wrote the
    /// snapshot spoke to the robot more recently than the marker did.
    @Test("a reading taken after the transition started supersedes it")
    func aNewerReadingSupersedesTheTransition() {
        // Snapshot taken now; the transition began a minute ago.
        let content = RobotWidgetContent(
            state: .fresh(snapshot()),
            power: pending(.wakingUp, secondsAgo: 60),
            at: now
        )

        #expect(content.isPending == false)
        #expect(content.detail.localizedCaseInsensitiveContains("awake"))
    }

    /// The app clears its own marker in a `defer` and writes a snapshot every poll
    /// interval while the transition runs, so supersession would hide a marker three
    /// seconds after it was written — and leave **Wake up** on screen through ninety
    /// seconds of a cold start the app itself started.
    @Test("the app's own transition is not superseded by the app's own reading")
    func aSessionTransitionSurvivesANewerReading() {
        let content = RobotWidgetContent(
            // Taken now; the transition began a minute ago — the exact pairing that
            // retires an intent's marker one test above.
            state: .fresh(snapshot()),
            power: pending(.startingBackend, secondsAgo: 60, writer: .session),
            at: now
        )

        #expect(content.isPending)
        #expect(content.action == nil)
    }

    /// The window is the only backstop a `.session` marker has left, and it covers
    /// the one case with no writer at all: the app killed mid-transition.
    @Test("even the app's own transition is forgotten past its window")
    func aSessionTransitionStillExpires() {
        let window = RobotPowerTransitionState.window(for: .goingToSleep)

        let content = RobotWidgetContent(
            state: .fresh(snapshot()),
            power: pending(.goingToSleep, secondsAgo: window + 1, writer: .session),
            at: now
        )

        #expect(content.isPending == false)
        #expect(content.action == .sleep)
    }

    @Test("a failure is reported in place of the state but keeps the button")
    func reportsAFailure() {
        let content = RobotWidgetContent(
            state: .fresh(snapshot()),
            power: RobotPowerTransitionState(failure: .init(message: "Took too long.", at: now)),
            at: now
        )

        #expect(content.detail == "Took too long.")
        #expect(content.action == .sleep)
    }

    @Test("an old failure is not still being apologised for")
    func forgetsAnOldFailure() {
        let at = now.addingTimeInterval(-RobotPowerTransitionState.failureWindow - 1)

        let content = RobotWidgetContent(
            state: .fresh(snapshot()),
            power: RobotPowerTransitionState(failure: .init(message: "Took too long.", at: at)),
            at: now
        )

        #expect(content.detail.localizedCaseInsensitiveContains("awake"))
    }

    // MARK: - The second line

    /// The wide layout's whole reason to exist: `detail` gives a running app the
    /// line, and what it displaced is handed over rather than lost.
    @Test("the displaced state is offered separately, and only when something displaced it")
    func handsBackTheDisplacedState() {
        let running = RobotWidgetContent(state: .fresh(snapshot(runningApp: "Hand Tracker")), at: now)
        let idle = RobotWidgetContent(state: .fresh(snapshot()), at: now)

        #expect(running.secondaryDetail?.localizedCaseInsensitiveContains("awake") == true)
        #expect(idle.secondaryDetail == nil)
    }

    // MARK: - Timeline

    /// Without this the widget would sit on "Waking up…" until something else
    /// happened to reload it.
    @Test("the timeline is told when a transition expires")
    func schedulesTheTransitionExpiry() {
        let dates = RobotWidgetContent.refreshDates(
            snapshot: .fresh(snapshot()),
            power: pending(.startingBackend),
            after: now
        )

        let expiry = now.addingTimeInterval(RobotPowerTransitionState.window(for: .startingBackend))
        #expect(dates.contains { abs($0.timeIntervalSince(expiry)) < 1 })
        #expect(dates.allSatisfy { $0 > now })
        #expect(dates == dates.sorted())
    }

    /// The entry that retires a reading is rebuilt from the store at its own date,
    /// so it has to land *past* the boundary rather than on it — `state(at:)` calls
    /// the boundary itself fresh, and an entry filed there would come back saying
    /// "Awake" again. An idle reading is where this shows: with an app there is a
    /// second moment a millisecond later that covers the mistake, and with none
    /// there is no later entry at all.
    @Test("the entry that retires a reading is rebuilt as stale, not fresh")
    func schedulesTheStalenessFlipPastTheBoundary() throws {
        let reading = snapshot()
        let defaults = try #require(UserDefaults(suiteName: "RobotWidgetContentTests.\(UUID().uuidString)"))
        let store = RobotSnapshotStore(defaults: defaults)
        store.write(reading)

        let moment = try #require(
            RobotWidgetContent.refreshDates(snapshot: .fresh(reading), power: nil, after: now).first
        )

        #expect(store.state(at: moment) == .stale(reading))
    }
}
