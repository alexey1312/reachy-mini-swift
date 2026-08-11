import Foundation
@testable import ReachyKit
import Testing

/// The widget renders what the app last saw, because a widget extension lives for
/// seconds and cannot connect to anything itself. Everything here exists to keep
/// that honest: what was seen, and how long ago.
@Suite("Robot snapshot")
struct RobotSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> RobotSnapshotStore {
        try RobotSnapshotStore(
            defaults: #require(UserDefaults(suiteName: "RobotSnapshotTests.\(UUID().uuidString)"))
        )
    }

    private func snapshot(
        robotID: String? = "robot-a",
        name: String? = "kitchen",
        isAwake: Bool = true,
        runningApp: String? = nil,
        runningAppName: String? = nil,
        takenAt: Date? = nil
    ) -> RobotSnapshot {
        RobotSnapshot(
            robotID: robotID,
            robotName: name,
            isAwake: isAwake,
            runningApp: runningApp,
            runningAppName: runningAppName,
            takenAt: takenAt ?? now
        )
    }

    @Test("a written snapshot comes back")
    func roundTrips() throws {
        let store = try store()
        let written = snapshot(runningApp: "Hand Tracker")

        store.write(written)

        #expect(store.current == written)
    }

    /// The state before a robot has ever been connected. A widget cannot invent
    /// one, and pretending otherwise is the whole failure mode here.
    @Test("an empty store knows nothing")
    func startsUnknown() throws {
        let store = try store()

        #expect(store.current == nil)
        #expect(store.state(at: now) == .unknown)
    }

    @Test("a snapshot just taken is fresh")
    func reportsFresh() throws {
        let store = try store()
        let written = snapshot()
        store.write(written)

        #expect(store.state(at: now.addingTimeInterval(60)) == .fresh(written))
    }

    /// A robot switched off does not tell anyone. Past the window the app stops
    /// claiming to know what it is doing and says only when it last looked.
    @Test("a snapshot past the freshness window is stale, not wrong")
    func reportsStale() throws {
        let store = try store()
        let written = snapshot()
        store.write(written)

        #expect(store.state(at: now.addingTimeInterval(RobotSnapshotStore.freshness + 1)) == .stale(written))
    }

    /// Exactly at the boundary still counts as fresh — the window is how long the
    /// reading is trusted for, inclusive.
    @Test("the freshness window is inclusive at its edge")
    func treatsTheBoundaryAsFresh() throws {
        let store = try store()
        let written = snapshot()
        store.write(written)

        #expect(store.state(at: now.addingTimeInterval(RobotSnapshotStore.freshness)) == .fresh(written))
    }

    /// A clock that went backwards — a timezone change, a manual correction —
    /// must not read as a reading from the future being stale.
    @Test("a snapshot dated in the future is still fresh")
    func toleratesAClockGoingBackwards() throws {
        let store = try store()
        let written = snapshot()
        store.write(written)

        #expect(store.state(at: now.addingTimeInterval(-600)) == .fresh(written))
    }

    /// Disconnecting clears it. Leaving the last reading behind would have the
    /// widget describe a robot the user deliberately let go of.
    @Test("clearing the snapshot returns to knowing nothing")
    func clears() throws {
        let store = try store()
        store.write(snapshot())

        store.clear()

        #expect(store.current == nil)
        #expect(store.state(at: now) == .unknown)
    }

    /// A reading written by a build that predates `runningAppName` must survive an
    /// update, not throw. A literal blob rather than a re-encode: encoding with
    /// today's type would put the field back and prove nothing.
    @Test("a snapshot written before the running app had a name still decodes")
    func decodesABlobWithoutTheName() throws {
        let defaults = try #require(UserDefaults(suiteName: "RobotSnapshotTests.\(UUID().uuidString)"))
        let legacy = """
        {"robotName":"kitchen","isAwake":true,"takenAt":\(now.timeIntervalSinceReferenceDate)}
        """
        defaults.set(Data(legacy.utf8), forKey: RobotSnapshotStore.key)

        let current = try #require(RobotSnapshotStore(defaults: defaults).current)

        #expect(current.robotName == "kitchen")
        #expect(current.robotID == nil)
        #expect(current.isAwake)
        #expect(current.runningApp == nil)
        #expect(current.runningAppName == nil)
        #expect(current.failedApp == nil)
        #expect(current.takenAt == now)
    }

    /// Whoever learned this only re-checked one field, so the rest of the reading
    /// has to survive.
    @Test("recording a running app keeps the rest of the reading")
    func recordsARunningApp() throws {
        let store = try store()
        store.write(snapshot(takenAt: now.addingTimeInterval(-300)))

        store.recordRunningApp(title: "Dance Party", name: "reachy_mini_dance", at: now)

        let current = try #require(store.current)
        #expect(current.robotName == "kitchen")
        #expect(current.isAwake)
        #expect(current.runningApp == "Dance Party")
        #expect(current.runningAppName == "reachy_mini_dance")
        #expect(current.runningAppTakenAt == now)
        // The caller had just spoken to the robot, so the reading is that fresh.
        #expect(current.takenAt == now)
    }

    /// Nothing running is a fact, not an absence of one.
    @Test("recording no running app clears the last one")
    func clearsARunningApp() throws {
        let store = try store()
        store.write(snapshot(runningApp: "Dance Party", runningAppName: "reachy_mini_dance"))

        store.recordRunningApp(title: nil, name: nil, at: now)

        let current = try #require(store.current)
        #expect(current.runningApp == nil)
        #expect(current.runningAppName == nil)
        #expect(current.runningAppTakenAt == nil)
        #expect(current.robotName == "kitchen")
    }

    @Test("recording a running app with nothing to merge into still writes one")
    func recordsWithoutAPriorReading() throws {
        let store = try store()

        store.recordRunningApp(title: "Dance Party", name: "reachy_mini_dance", at: now)

        let current = try #require(store.current)
        #expect(current.robotName == nil)
        #expect(current.runningApp == "Dance Party")
        #expect(store.state(at: now) == .fresh(current))
    }

    @Test("a caller that learned the motor state passes it through")
    func recordsAwakeness() throws {
        let store = try store()
        store.write(snapshot(isAwake: true))

        store.recordRunningApp(title: nil, name: nil, isAwake: false, at: now)

        #expect(store.current?.isAwake == false)
    }

    // MARK: - A crash

    /// A tile that quietly returns to idle explains nothing, so the crash travels
    /// too — but never as the app that is running, which would dim every other tile
    /// on behalf of a process that no longer exists.
    @Test("a crash is recorded apart from the running app")
    func recordsAFailure() throws {
        let store = try store()

        store.recordRunningApp(
            title: nil,
            name: nil,
            failed: .init(name: "reachy_mini_dance", title: "Dance Party", error: "ImportError"),
            at: now
        )

        let current = try #require(store.current)
        #expect(current.runningAppName == nil)
        #expect(current.failedApp?.name == "reachy_mini_dance")
        #expect(current.failedApp?.title == "Dance Party")
        #expect(current.failedApp?.error == "ImportError")
        // Dated, or there would be nothing to expire it against.
        #expect(current.runningAppTakenAt == now)
        #expect(current.failedApp(at: now)?.name == "reachy_mini_dance")
    }

    /// The daemon keeps returning a terminal status, and the UI keeps polling it.
    /// Treating every answer as a new crash would postpone this window forever.
    @Test("polling the same crash does not renew its expiry")
    func doesNotRenewARepeatedFailure() throws {
        let store = try store()
        let failed = RobotSnapshot.FailedApp(name: "reachy_mini_dance", error: "ImportError")
        store.recordRunningApp(title: nil, name: nil, failed: failed, at: now)
        let repeatedAt = now.addingTimeInterval(5 * 60)

        store.recordRunningApp(title: nil, name: nil, failed: failed, at: repeatedAt)

        let repeated = try #require(store.current)
        #expect(repeated.runningAppTakenAt == now)
        #expect(repeated.takenAt == repeatedAt)
        #expect(repeated.failedApp(at: now.addingTimeInterval(RobotSnapshotStore.failureFreshness + 1)) == nil)

        let changedAt = repeatedAt.addingTimeInterval(1)
        store.recordRunningApp(
            title: nil,
            name: nil,
            failed: .init(name: "reachy_mini_dance", error: "OSError"),
            at: changedAt
        )
        #expect(store.current?.runningAppTakenAt == changedAt)
    }

    /// One reading of one question: a caller that saw a live app has thereby seen
    /// no crash.
    @Test("recording a running app clears the crash before it")
    func clearsAFailure() throws {
        let store = try store()
        store.recordRunningApp(title: nil, name: nil, failed: .init(name: "reachy_mini_dance"), at: now)

        store.recordRunningApp(title: "Dance Party", name: "reachy_mini_dance", at: now)

        #expect(store.current?.failedApp == nil)
    }

    /// Nothing will ever arrive to say a crash is over, so it has to expire on its
    /// own — and sooner than a reading of a live robot, which at least goes wrong
    /// for a reason outside the app's control.
    @Test("a crash expires on its own, shorter window")
    func expiresAFailure() {
        let snapshot = RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: nil,
            failedApp: .init(name: "reachy_mini_dance", error: "boom"),
            runningAppTakenAt: now,
            takenAt: now
        )
        let window = RobotSnapshotStore.failureFreshness

        #expect(RobotSnapshotStore.failureFreshness < RobotSnapshotStore.freshness)
        #expect(snapshot.failedApp(at: now.addingTimeInterval(window)) != nil)
        #expect(snapshot.failedApp(at: now.addingTimeInterval(window + 1)) == nil)
        // The reading as a whole is still fresh at that point — only the crash has
        // stopped being worth repeating.
        #expect(snapshot.takenAt.addingTimeInterval(RobotSnapshotStore.freshness) > now.addingTimeInterval(window))
    }

    @Test("a reading with no crash has nothing to expire")
    func hasNoFailureExpiryWithoutAFailure() {
        #expect(snapshot(runningApp: "Dance Party").failedAppExpiresAt == nil)
    }

    @Test("a running app expires independently of a newer daemon reading")
    func expiresTheRunningAppIndependently() {
        let appReading = now.addingTimeInterval(-RobotSnapshotStore.freshness - 1)
        let snapshot = RobotSnapshot(
            robotID: "robot-a",
            robotName: "kitchen",
            isAwake: true,
            runningApp: "Dance Party",
            runningAppName: "reachy_mini_dance",
            runningAppTakenAt: appReading,
            takenAt: now
        )

        #expect(snapshot.runningAppName(at: now) == nil)
        #expect(snapshot.runningAppTitle(at: now) == nil)
    }

    /// The whole reason `recordPower` exists rather than another `recordRunningApp`
    /// call: waking stops nothing, so a writer that clears the app fields would have
    /// the widget forget a running app every time the robot was woken.
    @Test("recording the motors leaves the app reading alone")
    func recordsPowerWithoutTouchingTheApp() throws {
        let store = try store()
        store.write(snapshot(isAwake: false, runningApp: "Dance Party", runningAppName: "reachy_mini_dance"))

        store.recordPower(isAwake: true, robotID: "robot-a", robotName: "kitchen", at: now)

        let current = try #require(store.current)
        #expect(current.isAwake)
        #expect(current.runningApp == "Dance Party")
        #expect(current.runningAppName == "reachy_mini_dance")
        #expect(current.takenAt == now)
    }

    /// A reading about a different robot carries nothing forward — the previous app
    /// belonged to the previous robot.
    @Test("recording the motors of another robot drops the previous app")
    func recordsPowerForADifferentRobot() throws {
        let store = try store()
        store.write(snapshot(robotID: "robot-a", runningApp: "Dance Party", runningAppName: "reachy_mini_dance"))

        store.recordPower(isAwake: true, robotID: "robot-b", robotName: "study", at: now)

        let current = try #require(store.current)
        #expect(current.robotID == "robot-b")
        #expect(current.runningApp == nil)
        #expect(current.runningAppName == nil)
    }
}
