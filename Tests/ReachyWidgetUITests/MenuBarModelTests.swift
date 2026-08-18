import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// The popover's timeline, which is the part of this feature with no widget
/// equivalent: a `MenuBarExtra` has no `TimelineProvider` behind it, so the
/// refresh-after-a-command dance is new code and exactly the sort that rots
/// silently. The commands themselves stay untested for the structural reason
/// `RobotPowerCommand` records; what is testable is that this model re-reads.
@MainActor
@Suite("Menu bar model", .timeLimit(.minutes(1)))
struct MenuBarModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let kitchen = KnownRobot(
        key: "aa11bb22cc33dd44",
        name: "kitchen",
        address: RobotAddress(host: "reachy-mini.local"),
        lastConnected: Date(timeIntervalSince1970: 1_800_000_000)
    )

    private func suiteName() -> String {
        "MenuBarModelTests.\(UUID().uuidString)"
    }

    private func store(_ suite: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: suite))
    }

    private func makeModel(
        suite: String,
        perform: @escaping @Sendable (MenuBarCommand) async throws -> Void = { _ in }
    ) throws -> MenuBarModel {
        let known = kitchen
        let fixed = now
        return try MenuBarModel(
            defaults: store(suite),
            robot: { known },
            now: { fixed },
            perform: perform
        )
    }

    private func awakeSnapshot() -> RobotSnapshot {
        RobotSnapshot(robotName: "kitchen", isAwake: true, runningApp: nil, takenAt: now)
    }

    /// Polls rather than sleeping a fixed span: these suites are `@MainActor` and a
    /// loaded runner starves them, so a duration before the assertion would be a
    /// flake waiting to happen (project rule 7).
    private func waitUntilIdle(_ model: MenuBarModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.isBusy == false)
    }

    @Test("it reads the defaults it was given rather than the shared suite")
    func readsTheInjectedDefaults() throws {
        let suite = suiteName()
        try RobotSnapshotStore(defaults: store(suite)).write(awakeSnapshot())

        let model = try makeModel(suite: suite)

        #expect(model.content.status.action == .sleep)
        #expect(model.content.status.isStale == false)
    }

    @Test("with nothing stored it reports no robot rather than guessing")
    func emptyStorageReportsNothing() throws {
        let model = try makeModel(suite: suiteName())

        #expect(model.content.status.action == nil)
        #expect(model.content.apps.tiles.isEmpty)
    }

    /// The whole reason `perform:` is a seam. A command writes its own failure to
    /// the store before it throws, so the refresh on the way out **is** how this
    /// popover reports it — in the same words the widget uses for the same failure.
    @Test("a command that throws still leaves its failure on screen")
    func aFailedCommandIsReported() async throws {
        let suite = suiteName()
        let message = "The robot took too long to answer."
        // Stamped with the model's clock, not the wall clock. `fail(message:)`
        // defaults `at:` to `Date()`, and this suite reads at a fixed instant in
        // 2027 — so a real-time stamp lands months outside `failureWindow`, the
        // failure correctly expires, and the popover shows "Awake" instead.
        let stamp = now
        try RobotSnapshotStore(defaults: store(suite)).write(awakeSnapshot())
        let model = try makeModel(suite: suite) { _ in
            if let defaults = UserDefaults(suiteName: suite) {
                RobotPowerTransitionStore(defaults: defaults).fail(message: message, at: stamp)
            }
            throw CancellationError()
        }

        model.send(.wake)
        try await waitUntilIdle(model)

        #expect(model.content.status.detail == message)
    }

    @Test("a command marks the model busy and clears it when it returns")
    func busyIsClearedOnTheWayOut() async throws {
        let model = try makeModel(suite: suiteName())

        model.send(.wake)
        #expect(model.isBusy)

        try await waitUntilIdle(model)
    }

    /// A popover row is a far larger target than a Control Centre button, and these
    /// commands are not idempotent — a second toggle would undo the first.
    @Test("a second command while one is out is ignored")
    func oneCommandAtATime() async throws {
        let counter = CommandCounter()
        let model = try makeModel(suite: suiteName()) { _ in
            await counter.record()
            try await Task.sleep(for: .milliseconds(50))
        }

        model.send(.wake)
        model.send(.sleep)
        try await waitUntilIdle(model)

        let count = await counter.count
        #expect(count == 1)
    }
}

/// Counts calls from a `@Sendable` closure without the test having to reason about
/// which isolation the command ran on.
private actor CommandCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
