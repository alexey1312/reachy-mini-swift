import Foundation
import ReachyKit
import ReachyWidgetUI

/// Every decision the Live Activity makes, as a pure reducer.
///
/// The same shape as `CallLifecycle`, and for the same reason: ActivityKit is iOS
/// only, `mise run test` is SwiftPM on macOS, and a rule that lives inside an
/// `#if os(iOS)` fence is a rule no test can hold. So everything decidable lives
/// here — the controller is a thin adapter that performs the effects and owns the
/// one thing this cannot know, which is what `Activity.activities` currently holds.
///
/// **The rule the whole thing hangs off.** A snapshot may say "awake" and be
/// believed but may not say "asleep"; an activity's *existence* is a stronger claim
/// still, so it is sharpened:
///
/// > The activity's existence may assert that an app took the robot. Only a fresh
/// > reading may assert that it still holds it. And "Stop" is an imperative, so it
/// > survives both.
///
/// Three consequences run through every case below. The activity is created only on
/// an edge this app *observed*, never on one it inferred. Once frozen it degrades to
/// the past tense plus the age of the reading — never to silence, and never to a
/// verdict. And the Stop button is unaffected by staleness, exactly as
/// `RobotWidgetContent` offers `.wake` off a stale reading.
struct RunningAppActivityPlan: Equatable, Sendable {
    /// What this process believes is on the Lock Screen.
    ///
    /// A belief rather than a handle: the process that renders is not the process
    /// that started the activity, so `Activity.activities` is the truth and this is
    /// only what the last effect asked for.
    struct Live: Equatable, Sendable {
        var app: RunningAppActivityApp
        var content: RunningAppActivityContent
        var state: RobotAppStatus.State
        /// When this state was first seen. A transition joined late has no start
        /// time we observed, which is the rule `TransitionWatch` already follows.
        var stateSince: Date
        /// When content was last handed over, so an unchanged reading can still
        /// move the stale date without pushing on every poll tick.
        var pushedAt: Date
    }

    /// One status read that *answered*, joined with what the policy layer knows.
    /// A read that threw is not a reading and never reaches this type.
    struct Reading: Equatable, Sendable {
        var status: RobotAppStatus?
        var robotID: String?
        var robotName: String?
        var isReachable = true
        var wedged = false
        var actionFailure: String?
        /// Whether a Stop could be honoured — false for a robot known only over
        /// the relay, where an intent has no address to dial.
        var canStop = false
        /// A `restart-current-app` is stop-then-start behind one request. Ending
        /// in that gap would be a false "stopped" and a visible flicker 1.5 s
        /// later.
        var isRestarting = false
        var at: Date
    }

    /// Ours rather than `ActivityUIDismissalPolicy`, which is iOS only.
    enum Dismissal: Equatable, Sendable {
        case immediate
        case after(Date)
    }

    /// Resolved strings rather than resources: the title interpolates an app name
    /// and a robot name, which is the same trade `RunningAppCaption` makes.
    struct Alert: Equatable, Sendable {
        var title: String
        var body: String
    }

    enum Event: Equatable, Sendable {
        /// The only event that may create an activity.
        case read(Reading)
        /// What `Activity.activities` holds, on a foreground pass. Adoption rather
        /// than re-creation: a re-created card is a new Lock Screen item appearing
        /// for something the reader has been watching for ten minutes.
        case observed([RunningAppActivityApp], at: Date)
        /// The system ended it — the eight-hour cap.
        case systemEnded
        /// The reader swiped it away.
        case dismissed
    }

    enum Effect: Equatable, Sendable {
        case start(RunningAppActivityApp, RunningAppActivityContent, staleDate: Date)
        /// Every effect past the first names its own run, because the plan drops its
        /// belief before handing an ending over — an ended card is not live — and the
        /// adapter would otherwise have nothing left to address.
        case update(runKey: String, RunningAppActivityContent, staleDate: Date, alert: Alert?)
        case end(runKey: String, RunningAppActivityContent?, dismissal: Dismissal)
        /// This run must not be resurrected by the next foreground pass.
        case remember(runKey: String)
        /// The run is over, so a later one is news again.
        case forget(runKey: String)
    }

    /// Whether the app may request one at all: foreground, and not switched off in
    /// Settings. Read at every attempt rather than once — it flips without this
    /// process being told.
    var isPermitted = false
    /// Run keys the reader (or the system) has already dismissed.
    var dismissed: Set<String> = []
    private(set) var live: Live?

    let configuration: RunningAppModel.Configuration

    init(configuration: RunningAppModel.Configuration = .init()) {
        self.configuration = configuration
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .read(reading): read(reading)
        case let .observed(apps, at: date): observed(apps, at: date)
        case .systemEnded, .dismissed: taken()
        }
    }

    // MARK: - Readings

    private mutating func read(_ reading: Reading) -> [Effect] {
        guard let busy = reading.busyStatus else { return released(reading) }
        guard let live else { return begin(busy, reading) }
        // A reading about a different robot is not news about this card, it is the
        // end of it: nothing true can be said about the old one again, and the
        // session that could have corrected it is gone.
        guard live.app.robotID == reading.robotID else {
            self.live = nil
            return [.end(runKey: live.app.runKey, nil, dismissal: .immediate), .forget(runKey: live.app.runKey)]
        }
        guard live.app.runKey == RunningAppActivityApp(busy, reading).runKey else {
            return switched(to: busy, reading)
        }
        return carry(busy, reading, from: live)
    }

    /// The app let go. Which ending it gets is the whole difference between a job
    /// finished and a job that failed.
    private mutating func released(_ reading: Reading) -> [Effect] {
        // A restart is not a release: the daemon stops the app and starts it again
        // behind one request, and the gap reads exactly like an app that ended.
        guard !reading.isRestarting else { return [] }
        guard let live else { return [] }
        self.live = nil
        let key = live.app.runKey
        guard case .error = reading.status?.state else {
            return [.end(runKey: key, nil, dismissal: .immediate), .forget(runKey: key)]
        }
        return crashed(reading, live: live, key: key)
    }

    /// The one transition the phone is obliged to announce: unexpected, actionable,
    /// and about a robot that may be mid-motion in another room. Every other
    /// transition is either something the reader just did or the absence of an
    /// event, and alerting on silence is how a Wi-Fi blip becomes a notification.
    ///
    /// **Update then end, in that order, and it is ActivityKit's shape rather than
    /// a choice.** Only `update(_:alertConfiguration:)` raises an alert; `end` takes
    /// a dismissal policy and no alert at all. So the failure is pushed with the
    /// alert on it and the card is then given fifteen minutes to be read — the same
    /// window the widget already gives a crash, named rather than restated.
    ///
    /// It can only fire once: `released` runs on the busy edge, which
    /// `recordRunning` notices exactly once per run.
    private mutating func crashed(_ reading: Reading, live: Live, key: String) -> [Effect] {
        let content = reading.content(canStop: false)
        return [
            .update(
                runKey: key,
                content,
                staleDate: reading.at + RobotAppLaunchState.failureWindow,
                alert: Alert(
                    title: String(
                        localized: .reachy("\(live.app.appTitle) stopped on \(live.app.displayName)")
                    ),
                    // The summary line only. On a paired Apple Watch this is a real
                    // alert, and a stack frame is not a sentence — `content.caption`
                    // is already clamped to one line for exactly that reason.
                    body: content.caption
                )
            ),
            .end(runKey: key, content, dismissal: .after(reading.at + RobotAppLaunchState.failureWindow)),
            .forget(runKey: key),
        ]
    }

    /// Nothing on screen, something running.
    private mutating func begin(_ status: RobotAppStatus, _ reading: Reading) -> [Effect] {
        let app = RunningAppActivityApp(status, reading)
        guard isPermitted, reading.robotID != nil, !dismissed.contains(app.runKey) else { return [] }
        let content = reading.content(canStop: reading.canStop)
        live = Live(
            app: app,
            content: content,
            state: status.state,
            stateSince: reading.at,
            pushedAt: reading.at
        )
        return [.start(app, content, staleDate: reading.staleDate(for: status.state, since: reading.at, configuration))]
    }

    /// Something else holds the robot now.
    ///
    /// **This ends the card and starts another, and ActivityKit leaves no choice.**
    /// `ActivityAttributes` are fixed when the activity is requested and never
    /// change again, and the app's identity — its title, its artwork — lives there,
    /// because it is what does not move for the life of one run. Renaming a card in
    /// place would mean putting that identity in the content state instead, and then
    /// every update would carry it.
    ///
    /// The cost is small because the case is rare rather than ordinary: the daemon
    /// runs one app at a time, so A→B without an idle reading in between means the
    /// poll missed the gap entirely — 1.5 s while a transition is in flight. And two
    /// apps really are two runs, so a card replacing another is not a lie about
    /// either.
    private mutating func switched(to status: RobotAppStatus, _ reading: Reading) -> [Effect] {
        guard let previous = live else { return begin(status, reading) }
        live = nil
        return [
            .end(runKey: previous.app.runKey, nil, dismissal: .immediate),
            .forget(runKey: previous.app.runKey),
        ] + begin(status, reading)
    }

    /// The same run, still going.
    private mutating func carry(_ status: RobotAppStatus, _ reading: Reading, from live: Live) -> [Effect] {
        let content = reading.content(canStop: reading.canStop)
        let since = live.state == status.state ? live.stateSince : reading.at
        let stale = reading.staleDate(for: status.state, since: since, configuration)
        // An unchanged reading still moves the stale date, or a healthy app polled
        // every ten seconds goes grey on screen. Pushing every tick would spend the
        // update budget on nothing, so an unchanged one is rewritten at a floor.
        let changed = !content.rendersSameAs(live.content)
        guard changed || reading.at >= live.pushedAt + Self.refreshFloor else {
            self.live?.state = status.state
            self.live?.stateSince = since
            return []
        }
        self.live = Live(
            app: live.app,
            content: content,
            state: status.state,
            stateSince: since,
            pushedAt: reading.at
        )
        return [.update(runKey: live.app.runKey, content, staleDate: stale, alert: nil)]
    }

    /// How long an unchanged reading may leave the stale date where it is.
    static let refreshFloor: TimeInterval = 60

    // MARK: - Reconciliation and the reader's own actions

    private mutating func observed(_ apps: [RunningAppActivityApp], at _: Date) -> [Effect] {
        guard let live else { return [] }
        guard !apps.contains(where: { $0.runKey == live.app.runKey }) else { return [] }
        // Gone without this process ending it: the reader swiped it, or the system
        // hit the eight-hour cap. Both mean the same thing here — do not bring it
        // back on the next foreground pass.
        self.live = nil
        dismissed.insert(live.app.runKey)
        return [.remember(runKey: live.app.runKey)]
    }

    /// The system or the reader took it away. Nothing is stopped and nothing is
    /// concluded about the robot — removing a card does not cancel what it was
    /// about.
    private mutating func taken() -> [Effect] {
        guard let live else { return [] }
        self.live = nil
        dismissed.insert(live.app.runKey)
        return [.remember(runKey: live.app.runKey)]
    }

    static let runningSymbol = "square.grid.2x2.fill"
    static let failedSymbol = "exclamationmark.triangle.fill"
    static let startingSymbol = "arrow.trianglehead.clockwise"
    static let stoppingSymbol = "stop.circle"
}

/// The reducer works in `Date` arithmetic because a stale date is a `Date`, while
/// the budgets it reads are `Duration`s on `RunningAppModel.Configuration`.
///
/// File-private and spelled the way `TeleopDriver` already spells it, rather than
/// one shared helper: `ReachyKit` has its own copy and it is internal to that
/// module, so promoting this would mean widening a public surface for three lines
/// of arithmetic.
private extension Duration {
    var inSeconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}
