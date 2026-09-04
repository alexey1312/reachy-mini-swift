import ReachyKit
import ReachyWidgetUI
import SwiftUI
import WidgetKit

/// The subset of the session a widget actually renders, so `onChange` fires when
/// that changes and not on every unrelated field of the daemon's status.
struct RobotWidgetFacts: Equatable {
    let phase: RobotSession.ConnectionPhase
    let isAwake: Bool
    /// The whole status rather than its name: the widget dims every tile but one
    /// while an app holds the robot, marks the one that died, and prints the
    /// daemon's own sentence under the grid — so the state and the error are as
    /// much a reason to rebuild a timeline as the name is.
    ///
    /// Read from the session, not back out of the snapshot store. `UserDefaults` is
    /// not observable, so that reading only ever changed under a body being
    /// re-evaluated for some other reason; this one is what `RobotSession+Apps`
    /// assigns in the same funnel that writes the snapshot, and observing it is
    /// what makes the reload follow the fact rather than accompany it.
    let runningApp: RobotAppStatus?
}

/// The power ladder as the widget's store has to hear about it: which transition is
/// in flight, and the sentence the one that just ended left behind.
///
/// Separate from `RobotWidgetFacts` rather than folded into it, because the two
/// answer different questions. That one asks whether the widget's *reading* moved
/// and reloads a timeline; this one asks whether the app started, finished or
/// failed a transition, and writes a marker the widget renders instead of the
/// reading.
struct RobotPowerFacts: Equatable {
    let transition: RobotSession.PowerTransition?
    /// `RobotSession.robotError`, which every rung of the ladder clears on entry
    /// and `report(_:)` fills in before the `defer` that ends the transition — so
    /// by the moment this reads as ended, the failure is already here.
    let error: String?
}

/// What the app's own power ladder owes the widget's store, as a value.
///
/// A pure reducer rather than four writes spread through `RobotSession+Power`: the
/// interesting part is the *edges* — which change of a two-field fact means begin,
/// which means succeed, which means fail — and an edge is exactly what a test can
/// hold still. The writing is three lines that follow from the answer.
enum RobotPowerMirror {
    enum Write: Equatable {
        case begin(RobotSession.PowerTransition)
        case succeed
        case fail(String)
    }

    static func write(from old: RobotPowerFacts, to new: RobotPowerFacts) -> Write? {
        if let transition = new.transition {
            // Re-opened rather than left alone when the transition itself changes:
            // `wake()` claims `.wakingUp` and becomes `.startingBackend` the moment
            // it finds the backend down, and those two windows are ninety seconds
            // apart. Writing the second one again is what moves the deadline with
            // the job.
            return old.transition == transition ? nil : .begin(transition)
        }
        guard old.transition != nil else { return nil }
        // A *new* sentence, not merely a non-empty one. `claimRobotForApp` wakes the
        // robot without clearing `robotError` — it throws to the Apps model instead
        // of reporting onto the screen — so an error left over from this morning is
        // still there when its transition ends, and reporting it would apologise
        // twice for something the user has already seen.
        if let error = new.error, error != old.error {
            return .fail(error)
        }
        return .succeed
    }
}

/// The link owns signaling, the peer connection and potentially an open
/// microphone. Recoverable states keep it; leaving remote mode and terminal
/// connection failures end it.
enum RemoteLinkLifetime {
    static func shouldKeepAlive(
        isRemote: Bool,
        phase: RobotSession.ConnectionPhase
    ) -> Bool {
        guard isRemote else { return false }
        return switch phase {
        case .connected, .unreachable:
            true
        case let .connecting(step):
            switch step {
            case .handshaking, .checkingBackend, .backendUnavailable:
                true
            case .needsDaemonUpdate, .failed:
                false
            }
        case .idle:
            false
        }
    }
}

extension View {
    /// Tells the widget extension the reading it holds has moved on.
    ///
    /// Lives beside `RobotWidgetFacts` rather than in the root view: it is entirely
    /// about the widget, and the root view is at its length limit.
    func widgetReload(session: RobotSession, isPreview: Bool) -> some View {
        onChange(
            of: RobotWidgetFacts(
                phase: session.phase,
                isAwake: session.isAwake,
                runningApp: session.runningApp
            )
        ) { _, _ in
            guard !isPreview else { return }
            // The widget cannot ask the robot anything. `RobotSession` has already
            // written the snapshot by this point.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Mirrors the app's own power ladder into the store the widget reads.
    ///
    /// **The gap this closes is that the app had two power paths and only marked the
    /// lesser one.** `RobotPowerTransitionStore.begin` was called from
    /// `RobotPowerCommand` alone — Control Centre, Siri, Shortcuts, the widget's
    /// button and the macOS menu bar — while the Robot tab's ladder, Start on an
    /// app's page and the connection stepper wrote nothing at all. So a cold start
    /// begun in the app left the Lock Screen widget saying "Asleep" under an
    /// unchanged **Wake up** for up to the 90 s the daemon takes, and a tap on it
    /// reached a `RobotSleep` with no status guard, or a `daemon/stop` the daemon
    /// answers 409 to.
    ///
    /// An `onChange` over an `Equatable` fact, the same idiom `widgetReload` is, and
    /// for the same reason: the write follows the fact rather than being remembered
    /// at each of the six places that assign `powerTransition`.
    func powerTransitionMirror(session: RobotSession, isPreview: Bool) -> some View {
        onChange(
            of: RobotPowerFacts(transition: session.powerTransition, error: session.robotError)
        ) { old, new in
            guard !isPreview, let write = RobotPowerMirror.write(from: old, to: new) else { return }
            let transitions = RobotPowerTransitionStore()
            switch write {
            // `.session`, which is what exempts the marker from being superseded by
            // the snapshot this very session writes three seconds later.
            case let .begin(transition): transitions.begin(transition, writer: .session)
            case .succeed: transitions.succeed()
            case let .fail(message): transitions.fail(message: message)
            }
            // `widgetReload` cannot cover this: a transition beginning changes
            // neither `isAwake` nor the running app, so nothing there would fire.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
