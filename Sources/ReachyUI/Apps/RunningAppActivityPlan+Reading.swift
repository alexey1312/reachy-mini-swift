import Foundation
import ReachyDesign
import ReachyKit
import ReachyWidgetUI

/// Turning one status read into the two values ActivityKit carries.
///
/// Separated from the reducer because that file holds the decisions and this one
/// holds the wording and the arithmetic — the same split `RunningAppModel` and its
/// `Configuration` already make.
extension RunningAppActivityPlan.Reading {
    /// The status only while an app still holds the robot.
    ///
    /// `isBusy` counts `.unknown` as held, and that is inherited rather than
    /// decided here: the daemon reports a status at all only while an app is
    /// loaded, so a word this build has never heard of is far more likely a later
    /// daemon's name for running than an app that quietly finished.
    var busyStatus: RobotAppStatus? {
        status.flatMap { $0.isBusy ? $0 : nil }
    }

    /// The same sentence the dock shows, from the same call.
    ///
    /// Not re-derived from the state here, and that is the whole point: a reader who
    /// sees "Stopping…" on the Lock Screen and "Running" in the dock has been told
    /// the robot is in two states at once, which is the disagreement
    /// `RunningAppCaption` exists to prevent. Its precedence — a crash, a wedge, the
    /// refusal, then the state — is already the order this surface wants.
    ///
    /// **The conversation turn is deliberately left out.** It is what the app on the
    /// robot was last heard doing, it moves several times a second, and this card
    /// freezes the moment the phone is put down. "Listening" frozen for half an hour
    /// is exactly the stale verdict the whole design refuses to render.
    func content(canStop: Bool) -> RunningAppActivityContent {
        guard let status = status ?? busyStatus else {
            return RunningAppActivityContent(
                caption: String(localized: .reachy("Robot unreachable")),
                symbolName: RunningAppActivityPlan.failedSymbol,
                isFailed: true,
                canStop: false,
                readAt: at
            )
        }
        let failed = RunningAppCaption.tone(of: status, wedged: wedged, actionFailure: actionFailure) == .failed
        return RunningAppActivityContent(
            caption: RunningAppCaption.description(
                of: status,
                isReachable: isReachable,
                wedged: wedged,
                actionFailure: actionFailure
            ),
            symbolName: Self.symbol(for: status.state, isFailed: failed),
            isFailed: failed,
            canStop: canStop,
            readAt: at
        )
    }

    /// When this content stops being something the card may state in the present
    /// tense.
    ///
    /// **The only scheduled change an activity gets without a process**, so it is
    /// spent on the one moment that matters for the state being written — and every
    /// answer already exists in this repository as a justified constant, named here
    /// rather than restated as a number.
    ///
    /// `running` matches `RobotSnapshotStore.freshness` because it has to: the
    /// widget's reading and this one come from the same `runningAppTakenAt`, so a
    /// card that went quiet at thirty seconds while the widget still named the app
    /// would put two different claims about one robot on one Lock Screen.
    ///
    /// A transition is measured from **first sight** rather than from the reading,
    /// because a transition joined late has no start this device observed — the rule
    /// `TransitionWatch` already follows.
    func staleDate(
        for state: RobotAppStatus.State,
        since: Date,
        _ configuration: RunningAppModel.Configuration
    ) -> Date {
        switch state {
        case .starting: since + configuration.startingDeadline.inSeconds
        case .stopping: since + configuration.stoppingDeadline.inSeconds
        case .running, .done, .error, .unknown: at + RobotSnapshotStore.freshness
        }
    }

    /// The same glyphs the status widget already uses for the same two facts, so a
    /// reader meeting both surfaces meets one vocabulary.
    private static func symbol(for state: RobotAppStatus.State, isFailed: Bool) -> String {
        if isFailed {
            return RunningAppActivityPlan.failedSymbol
        }
        return switch state {
        case .starting: RunningAppActivityPlan.startingSymbol
        case .stopping: RunningAppActivityPlan.stoppingSymbol
        case .running, .done, .error, .unknown: RunningAppActivityPlan.runningSymbol
        }
    }
}

extension RunningAppActivityApp {
    /// Everything the card needs about *which* app, taken once when the activity
    /// starts.
    ///
    /// The identity is already joined by the time it gets here: `recordRunning` is
    /// fed by `describedFromInstalled`, which swaps in the installed twin — title,
    /// emoji and palette included — before the funnel ever sees the status. So this
    /// reads `status.app` directly, and the one case it cannot fix is the one
    /// nothing can: a local app with no Hub card, which keeps its entry point as its
    /// name because inventing somebody else's title would be worse.
    init(_ status: RobotAppStatus, _ reading: RunningAppActivityPlan.Reading) {
        self.init(
            robotID: reading.robotID,
            robotName: reading.robotName,
            appName: status.app.name,
            appTitle: status.app.title,
            emoji: status.app.emoji,
            gradientFrom: status.app.gradient?.from,
            gradientTo: status.app.gradient?.to,
            artworkKey: status.app.id
        )
    }
}

private extension Duration {
    var inSeconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}
