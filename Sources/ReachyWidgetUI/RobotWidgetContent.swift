import Foundation
import ReachyDesign
import ReachyKit

/// What the widget puts on screen, worked out from a snapshot before any view is
/// involved — so the one rule that matters here is testable without rendering
/// anything.
///
/// That rule: a reading past its window is reported as *when it was taken*, never
/// as what the robot is doing. Nothing tells this app that a robot was switched
/// off, carried out of range or unplugged, and a widget still reading "Awake" an
/// hour later is worse than one admitting it does not know.
public struct RobotWidgetContent: Equatable, Sendable {
    /// The one command the widget offers, chosen from the reading.
    ///
    /// **One button rather than two, and the rule is asymmetric on purpose.**
    /// `RobotPowerControls` argues against a state-driven control because a
    /// `StaticControlConfiguration` cannot expire — but a widget can and does:
    /// `RobotStatusProvider.getTimeline` already files an entry at the freshness
    /// boundary that flips this content to `.stale`. What settles it is the
    /// asymmetry `ReachyWidgetUI/AGENTS.md` records — a snapshot may be believed
    /// when it says awake and not when it says asleep. `.sleep`, the destructive
    /// direction, is therefore offered only off `isAwake == true`, the believable
    /// half; `.wake` is offered off everything else, including a stale reading,
    /// because `RobotPower.resume()` handles both meanings of a false `isAwake` by
    /// itself and because an imperative is not a claim about the present.
    public enum Action: Equatable, Sendable {
        case wake
        case sleep
    }

    public let title: String
    public let detail: String
    /// The line the wide layout has room for and the compact one does not.
    ///
    /// `detail` gives a running app the whole line, for the reason `activity(of:)`
    /// states. At medium there is room for both, so the motor state that was
    /// displaced is handed over separately rather than the precedence being
    /// rewritten per family. Nil whenever nothing was displaced.
    public let secondaryDetail: String?
    public let symbolName: String
    /// Lets the view render a memory differently from a live reading, without
    /// having to work out which it is.
    public let isStale: Bool
    /// Nil where there is nothing to command: no robot at all, or a transition
    /// already in flight.
    public let action: Action?
    /// A transition is in flight, which is why `action` is nil — as distinct from
    /// `.unknown`, where it is nil because there is no robot to command. The two
    /// read the same on screen and mean opposite things to anything reasoning about
    /// the widget.
    public let isPending: Bool
    /// The running app as the apps cache knows it — artwork and title — for the
    /// wide layout to draw as a tile. Nil off a stale reading, during a transition,
    /// with no app running, or when the cache does not hold the one that is.
    public private(set) var runningApp: RobotAppSummary?

    public init(
        title: String,
        detail: String,
        secondaryDetail: String? = nil,
        symbolName: String,
        isStale: Bool,
        action: Action? = nil,
        isPending: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.secondaryDetail = secondaryDetail
        self.symbolName = symbolName
        self.isStale = isStale
        self.action = action
        self.isPending = isPending
    }

    public init(
        state: RobotSnapshotState,
        power: RobotPowerTransitionState? = nil,
        apps: RobotAppsCache? = nil,
        at date: Date = Date()
    ) {
        switch state {
        case .unknown:
            // No robot means nothing to command: `RobotIntentTarget` would throw
            // `noKnownRobot`, and the tap is better spent falling through to the
            // widget's own `widgetURL`.
            self.init(
                title: String(localized: .reachy("No robot")),
                detail: String(localized: .reachy("Open the app to connect")),
                symbolName: "questionmark.circle",
                isStale: false
            )
        case let .fresh(snapshot):
            self.init(
                snapshot: snapshot,
                power: power,
                isStale: false,
                resting: Self.activity(of: snapshot, at: date),
                displaced: Self.displacedActivity(of: snapshot, at: date),
                restingSymbol: Self.symbol(for: snapshot, at: date),
                action: snapshot.isAwake ? .sleep : .wake,
                at: date
            )
        case let .stale(snapshot):
            self.init(
                snapshot: snapshot,
                power: power,
                isStale: true,
                resting: String(localized: .reachy("Last seen \(Self.age(of: snapshot, at: date))")),
                displaced: nil,
                restingSymbol: "clock.arrow.circlepath",
                // Never `.sleep` on a memory: parking the motors of a robot that
                // may already be parked is the direction where being wrong costs
                // something.
                action: .wake,
                at: date
            )
        }
        runningApp = isPending ? nil : Self.runningApp(in: state, apps: apps, at: date)
    }

    /// Only off a fresh reading, which is the one kind the wide layout says
    /// "Running" for; a memory of an app is not one. Matched by entry point first
    /// and by title second, because a legacy snapshot carries only the title.
    private static func runningApp(
        in state: RobotSnapshotState,
        apps: RobotAppsCache?,
        at date: Date
    ) -> RobotAppSummary? {
        guard case let .fresh(snapshot) = state, let apps else { return nil }
        guard let name = snapshot.runningAppName(at: date) ?? snapshot.runningAppTitle(at: date) else { return nil }
        return apps.installed.first { $0.name == name || $0.title == name }
    }

    /// The fork every reading with a robot behind it takes: a transition in flight
    /// outranks the reading, a failure outranks a plain state, and the resting
    /// description is what is left.
    private init(
        snapshot: RobotSnapshot,
        power: RobotPowerTransitionState?,
        isStale: Bool,
        resting: String,
        displaced: String?,
        restingSymbol: String,
        action: Action,
        at date: Date
    ) {
        let name = Self.name(of: snapshot)
        if let pending = Self.pending(power, snapshot: snapshot, at: date) {
            self.init(
                title: name,
                detail: Self.caption(for: pending.transition),
                symbolName: Self.symbol(for: pending.transition),
                // A transition already renders as stale-free news about right now.
                isStale: false,
                action: nil,
                isPending: true
            )
        } else if let failure = power?.failure(at: date) {
            self.init(
                title: name,
                detail: failure.message,
                secondaryDetail: resting,
                symbolName: "exclamationmark.triangle.fill",
                isStale: isStale,
                action: action
            )
        } else {
            self.init(
                title: name,
                detail: resting,
                secondaryDetail: displaced,
                symbolName: restingSymbol,
                isStale: isStale,
                action: action
            )
        }
    }

    /// The moments something on screen stops being true, in order.
    ///
    /// Lives here rather than in the provider — where the app-expiry half used to —
    /// because `Apps/ReachyWidget/Sources` has no test target at all, and this is
    /// arithmetic worth pinning. Mirrors `RobotAppsWidgetContent.refreshDates`,
    /// including the millisecond past each inclusive boundary, so an entry rendered
    /// at exactly that date is unambiguously expired.
    public static func refreshDates(
        snapshot: RobotSnapshotState,
        power: RobotPowerTransitionState?,
        after now: Date
    ) -> [Date] {
        var moments: [Date] = []
        if case let .fresh(reading) = snapshot {
            if reading.runningAppName(at: now) != nil, let expiry = reading.runningAppExpiresAt {
                moments.append(expiry.addingTimeInterval(0.001))
            }
            if reading.failedApp(at: now) != nil, let expiry = reading.failedAppExpiresAt {
                moments.append(expiry.addingTimeInterval(0.001))
            }
            // The reading itself going stale, so the widget stops repeating "Awake"
            // for a robot switched off hours ago with the app not running to correct
            // it. The millisecond is what makes it happen: `state(at:)` calls the
            // boundary itself fresh, and an idle reading — no app, so no expiry a
            // millisecond behind this one — has no later entry to correct it.
            moments.append(reading.takenAt.addingTimeInterval(RobotSnapshotStore.freshness + 0.001))
        }
        if let pending = power?.pending {
            let window = RobotPowerTransitionState.window(for: pending.transition)
            moments.append(pending.since.addingTimeInterval(window + 0.001))
        }
        if let failure = power?.failure {
            moments.append(failure.at.addingTimeInterval(RobotPowerTransitionState.failureWindow + 0.001))
        }
        return moments.filter { $0 > now }.sorted()
    }

    /// A transition still worth reporting.
    ///
    /// **Superseded by a reading taken after it started**, which
    /// `RobotAppLaunchState` has no equivalent of. The extension is not running to
    /// clear its own marker, so a wake tapped on the widget and then completed with
    /// the app open would otherwise say "Waking up…" for the rest of the window.
    /// Whoever wrote that snapshot spoke to the robot more recently than this marker
    /// did. The window is only the floor, for a phone that never opens the app.
    private static func pending(
        _ power: RobotPowerTransitionState?,
        snapshot: RobotSnapshot,
        at date: Date
    ) -> RobotPowerTransitionState.Pending? {
        guard let pending = power?.pending(at: date), snapshot.takenAt <= pending.since else { return nil }
        return pending
    }

    /// The widget's own mapping, because `ReachyUI` — where the app's copy lives —
    /// is not linkable from an extension. Same catalogue keys, so this adds none.
    private static func caption(for transition: RobotSession.PowerTransition) -> String {
        switch transition {
        case .startingBackend: String(localized: .reachy("Starting the motors and camera… this can take a minute"))
        case .stoppingBackend: String(localized: .reachy("Powering off… going to sleep first"))
        case .wakingUp: String(localized: .reachy("Waking up…"))
        case .goingToSleep: String(localized: .reachy("Going to sleep…"))
        }
    }

    private static func symbol(for transition: RobotSession.PowerTransition) -> String {
        switch transition {
        case .startingBackend, .wakingUp: "sun.max"
        case .stoppingBackend, .goingToSleep: "moon.zzz"
        }
    }

    /// Daemon 1.9.0 mounts no rename route and reports an empty name, so a robot
    /// without one is ordinary rather than exceptional — it still needs calling
    /// something.
    private static func name(of snapshot: RobotSnapshot) -> String {
        snapshot.robotName ?? String(localized: .reachy("Reachy Mini"))
    }

    /// A running app is the most useful thing there is to say, so it displaces
    /// the plain awake reading rather than crowding in beside it — and an app that
    /// just died displaces it for the same reason. Falling silently back to "Awake"
    /// would be this widget's version of pretending nothing happened.
    private static func activity(of snapshot: RobotSnapshot, at date: Date) -> String {
        if let runningApp = snapshot.runningAppTitle(at: date) {
            return runningApp
        }
        if let failed = snapshot.failedApp(at: date) {
            return String(localized: .reachy("\(failed.title ?? failed.name) stopped"))
        }
        return power(of: snapshot)
    }

    /// What `activity(of:at:)` pushed off the line, for a layout with room to put it
    /// back. Nil when nothing was pushed off — the state is already on screen.
    private static func displacedActivity(of snapshot: RobotSnapshot, at date: Date) -> String? {
        guard snapshot.runningAppTitle(at: date) != nil || snapshot.failedApp(at: date) != nil else { return nil }
        return power(of: snapshot)
    }

    private static func power(of snapshot: RobotSnapshot) -> String {
        snapshot.isAwake
            ? String(localized: .reachy("Awake"))
            : String(localized: .reachy("Asleep"))
    }

    private static func symbol(for snapshot: RobotSnapshot, at date: Date) -> String {
        if snapshot.runningAppTitle(at: date) != nil {
            return "square.grid.2x2.fill"
        }
        if snapshot.failedApp(at: date) != nil {
            return "exclamationmark.triangle.fill"
        }
        return snapshot.isAwake ? "figure.wave" : "moon.zzz.fill"
    }

    private static func age(of snapshot: RobotSnapshot, at date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: snapshot.takenAt, relativeTo: date)
    }
}
