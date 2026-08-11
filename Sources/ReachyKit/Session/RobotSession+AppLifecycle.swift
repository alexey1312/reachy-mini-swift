import Foundation

/// What this session did to the robot's power *on an app's behalf*, and what it
/// therefore owes the robot once that app lets go.
///
/// Two facts in one value rather than two stored properties: they are read
/// together at every decision point, and `RobotSession` is at SwiftLint's type
/// limit — new session state arrives here as one member.
struct AppLifecycleState: Equatable, Sendable {
    /// The app this session woke the robot for, or nil when the robot was already
    /// awake.
    ///
    /// The two take opposite parking sequences, which is the whole reason the flag
    /// exists: a robot woken for an app goes back to sleep when the app ends, one
    /// the user woke stays awake in the zero pose. Any deliberate power action
    /// clears it — once somebody has pressed Wake up, Go to sleep or Power off,
    /// the robot's state is theirs and no longer an app's to undo.
    private(set) var wakeOwner: String?

    /// True for the length of `restart-current-app`, which is stop-then-start
    /// daemon-side. A poll landing between the two halves reads an idle robot, and
    /// parking it there would send the head to zero underneath the app that is
    /// about to come back.
    var isRestarting = false

    mutating func claimWakeOwnership(of name: String) {
        wakeOwner = name
    }

    mutating func releaseWakeOwnership() {
        wakeOwner = nil
    }

    /// Takes the ownership rather than reading it. Parking happens once per app
    /// run; a flag left set is how the *next* stop would put an already-parked
    /// robot to sleep a second time.
    mutating func takeWakeOwnership() -> String? {
        defer { wakeOwner = nil }
        return wakeOwner
    }
}

/// Waking the robot so a starting app can move it, and putting the robot back
/// when that app lets go.
///
/// **Neither half is the daemon's, and the reasons differ.** `apps/start-app` is
/// not behind the `get_backend` dependency, so it answers 200 at a robot with no
/// backend at all and starts the app over disabled motors at a sleeping one —
/// where every motion command is accepted and silently swallowed. And while
/// `AppManager.stop_current_app` ends with a return-to-zero of its own, it is not
/// observed on hardware, and the crash path has none at all: `monitor_process`
/// releases the robot-app lock in its `finally` and does nothing else.
extension RobotSession {
    /// Takes the robot on behalf of an app that is about to start, and reports
    /// whether that meant waking it.
    ///
    /// Two steps, and the first is easy to leave out. **The move slot is freed
    /// first**, because the daemon has exactly one and `play_move` takes its guard
    /// non-blocking: an app started over a running dance has its first motion
    /// accepted, answered with a plausible UUID and dropped in silence. `sleep()`
    /// opens with the same `releaseMove()` for the same reason, and the wake
    /// animation would collide with the dance too.
    ///
    /// The widget's launcher has read the same readiness since it shipped
    /// (`RobotAppLauncher.startFreeRobot`); this is the screen's half of it, and
    /// the two deliberately answer a stopped backend differently. An intent kicks
    /// `daemon/start?wake_up=true` and says so, because it has seconds. A screen
    /// refuses and offers the decision as a button, because 90 s inside somebody's
    /// Start tap is not a wait, it is a hang.
    func claimRobotForApp() async throws -> Bool {
        guard let client else { throw ReachyKitError.notConnected }
        await releaseMove()
        // A snapshot may be believed when it says "awake" and never when it says
        // "asleep": `isAwake` is false for a parked robot *and* for a torn-down
        // backend, and those two take opposite sequences. The same asymmetry
        // `RobotAppLauncher.assumeAwake` is built on.
        if isAwake {
            return false
        }
        guard powerTransition == nil else { throw ReachyKitError.powerTransitionInFlight }
        // Claimed before the first suspension point, the same latch `wake()`
        // describes.
        powerTransition = .wakingUp
        defer { powerTransition = nil }
        try await runWake(client: client, startingBackend: false)
        return true
    }

    /// Puts the robot back where it was before an app took it.
    ///
    /// One entry point for three events that are the same event: the user pressed
    /// Stop, the app exited, or the app crashed. `noteAppReleased` decides when,
    /// and does so from a reading that arrived.
    func parkAfterApp() async {
        // A power transition parks the robot itself, and both rungs of it reach
        // here through their own `releaseRunningApp()`. Sending a `goto` into that
        // puts two motions on one robot, where `play_move` takes its guard
        // non-blocking and drops one of them without a word.
        guard let client, powerTransition == nil else {
            appLifecycle.releaseWakeOwnership()
            return
        }
        if appLifecycle.takeWakeOwnership() != nil {
            await sleep()
        } else {
            await returnToBase(client: client)
        }
    }

    /// The zero pose, for a robot somebody else woke.
    ///
    /// Every refusal here is a guard rather than a reported failure, and they are
    /// guards for the same reason: none of them has a screen to land on. The app
    /// whose model would have owned the message is the one that just ended.
    /// - an asleep robot's `goto` travels nowhere, motors being disabled — the
    ///   reason parking is already skipped after a recorded move;
    /// - a robot that has started something else owns the one move slot;
    /// - a remote session has no `goto` at all, `RemoteRobotConnection` leaving it
    ///   to the throwing default in `RobotAPIClient`.
    private func returnToBase(client: any RobotAPIClient) async {
        guard isAwake, !isRemote, moveActivity == nil else { return }
        _ = await recentre(client: client)
    }

    /// Notices an app letting go of the robot, from one reading to the next.
    ///
    /// This sits on the one bottleneck every *successful* status read passes
    /// through, which is what makes it fire exactly once per app run: the
    /// transition is `busy → not busy`, so the poll that follows sees a reading
    /// that was already idle and concludes nothing. A failed read never gets here
    /// at all — `refreshCurrentApp` leaves the last status standing rather than
    /// blanking it, the rule a Wi-Fi blip once broke by being timed as a wedge.
    func noteAppReleased(was previous: RobotAppStatus?, is current: RobotAppStatus?) {
        if let current, current.isBusy {
            // Something else holds the robot now. Whatever this session woke it for
            // is not what is driving it, and putting it to sleep under the new app
            // would be worse than leaving it awake — so the promise is dropped
            // rather than paid to the wrong app.
            if let owner = appLifecycle.wakeOwner, current.app.name != owner {
                appLifecycle.releaseWakeOwnership()
            }
            return
        }
        guard previous?.isBusy == true else { return }
        // `restart-current-app` is stop-then-start behind one request, so the gap
        // between its halves is not an app letting go.
        guard !appLifecycle.isRestarting else { return }
        Task { await parkAfterApp() }
    }
}
