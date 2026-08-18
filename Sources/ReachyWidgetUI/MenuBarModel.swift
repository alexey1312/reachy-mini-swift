import Foundation
import Observation
import ReachyKit

/// The menu bar popover's timeline.
///
/// A `MenuBarExtra` has no `TimelineProvider` behind it, so something has to decide
/// when the reading on screen stops being true. This does — off
/// `MenuBarContent.refreshDates`, which is arithmetic that is already tested and
/// already right about the millisecond past each boundary. **Nothing polls:** once
/// no transition is pending and the reading has settled into stale, there is no
/// later moment to schedule and the model goes completely idle.
///
/// It reads the App Group stores rather than holding a `RobotSession`, and the
/// reason is lifetime rather than taste. A session is `@State` inside
/// `ReachyRootView`, i.e. inside the `WindowGroup`'s content, so it lives exactly as
/// long as a window — and a menu bar item whose whole point is "close the window,
/// keep the robot one click away" cannot depend on that. Hoisting the session to the
/// `App` would mean holding a 10 s sweep, a 3 s poll and a WebSocket open with
/// nothing on screen. Freshness is not lost by reading storage: `RobotSession`
/// writes those same stores whenever a window *is* open, and when none is,
/// `RobotWidgetContent` already says "Last seen …" rather than guessing.
///
/// It lives in this target and not in the app's, because the app target is invisible
/// to `swift test` and to both preview-hosting targets. Only the `Scene` is
/// macOS-specific.
@MainActor
@Observable
public final class MenuBarModel {
    public private(set) var content: MenuBarContent
    /// A command is out. The popover's own progress signal — a widget has
    /// `invalidatableContent()` and this has a live process.
    public private(set) var isBusy = false

    private let snapshots: RobotSnapshotStore
    private let transitions: RobotPowerTransitionStore
    private let launches: RobotAppLaunchStateStore
    private let caches: RobotAppsCacheStore
    private let robot: @Sendable () -> KnownRobot?
    private let now: @Sendable () -> Date
    private let perform: @Sendable (MenuBarCommand) async throws -> Void
    private var scheduled: Task<Void, Never>?

    /// Every seam here exists for a test, and two of them for the same reason the
    /// commands have none. `RobotIntentTarget.knownRobot` reads `KnownRobots.all`
    /// out of a static that takes no injected defaults, so a model given a throwaway
    /// suite would still be told there is no robot; `robot:` is what closes that.
    public init(
        defaults: UserDefaults = KnownRobots.defaults,
        robot: @escaping @Sendable () -> KnownRobot? = { RobotIntentTarget.knownRobot },
        now: @escaping @Sendable () -> Date = Date.init,
        // Wrapped in a literal rather than passed as `MenuBarModel.run`: a closure
        // literal is inferred `@Sendable` from the parameter, where a bare reference
        // to a static method has to be converted to one.
        perform: @escaping @Sendable (MenuBarCommand) async throws -> Void = { try await MenuBarModel.run($0) }
    ) {
        snapshots = RobotSnapshotStore(defaults: defaults)
        transitions = RobotPowerTransitionStore(defaults: defaults)
        launches = RobotAppLaunchStateStore(defaults: defaults)
        caches = RobotAppsCacheStore(defaults: defaults)
        self.robot = robot
        self.now = now
        self.perform = perform
        content = MenuBarContent(snapshot: .unknown, hasKnownRobot: false)
        refresh()
    }

    /// Re-read every store and re-arm the next wake-up. Called when the popover
    /// appears, when the app becomes active, when a command finishes, and at each
    /// moment `refreshDates` files.
    public func refresh() {
        let date = now()
        let known = robot()
        let snapshot = snapshots.state(at: date)
        let power = transitions.current
        let launch = launches.current
        content = MenuBarContent(
            snapshot: snapshot,
            power: power,
            launch: launch,
            cache: known.flatMap { caches.current(for: $0.key) },
            hasKnownRobot: known != nil,
            at: date
        )
        schedule(
            MenuBarContent.refreshDates(snapshot: snapshot, power: power, launch: launch, after: date).first
        )
    }

    /// Run one command, then re-read.
    ///
    /// **There is no error slot here, and none is missing.** Every command writes its
    /// own outcome before it returns — a new snapshot, or `transitions.fail(message:)`
    /// — and `RobotWidgetContent` renders that failure as the detail line with the
    /// action button still on it. So the refresh below *is* the report, in the same
    /// words the widget uses for the same failure. Swallowing the thrown error is
    /// what that buys, not what it costs.
    ///
    /// The pending caption ("Waking up…") is written inside the command's own
    /// prologue, so it lands whenever the next refresh runs rather than instantly;
    /// `isBusy` is what covers that window, and it is set before anything is awaited.
    public func send(_ command: MenuBarCommand) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer {
                self.isBusy = false
                self.refresh()
            }
            try? await self.perform(command)
        }
    }

    /// The real commands, verbatim — no wrapper, so the popover, Control Centre,
    /// Siri and the widget's own buttons share one implementation and one set of
    /// failure messages.
    ///
    /// `.open` is not carried out here: only the scene owns a way to bring the app
    /// forward, so it handles that case before it ever reaches the model.
    ///
    /// Two consequences worth knowing. `WidgetCenter.reloadTimelines` inside these
    /// commands does nothing on a Mac with no widget installed, and starts doing
    /// real work for free once one is. And a robot reached over the Hugging Face
    /// relay will fail with `unreachable`, because `RobotIntentTarget` is LAN-only
    /// by design — that failure arrives on screen through the store, correctly.
    public static func run(_ command: MenuBarCommand) async throws {
        switch command {
        case .wake:
            try await RobotPowerCommand(.wake).perform()
        case .sleep:
            try await RobotPowerCommand(.sleep).perform()
        case let .app(tile):
            try await RobotAppCommand(.toggle(name: tile.name), appID: tile.id).perform()
        case .open:
            break
        }
    }

    private func schedule(_ moment: Date?) {
        scheduled?.cancel()
        scheduled = nil
        guard let moment else { return }
        let interval = moment.timeIntervalSince(now())
        guard interval > 0 else { return }
        // Weak, because this task is stored on the model and may sleep for the
        // half hour a reading takes to go stale — a strong capture would be a
        // cycle that outlives whatever let go of the model.
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
