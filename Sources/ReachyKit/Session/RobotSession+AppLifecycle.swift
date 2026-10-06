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
/// **The start is never the daemon's, and the release was not until 1.10.0.**
/// `apps/start-app` is not behind the `get_backend` dependency, so it answers 200
/// at a robot with no backend at all and starts the app over disabled motors at a
/// sleeping one — where every motion command is accepted and silently swallowed.
/// And while `AppManager.stop_current_app` ends with a return-to-zero of its own,
/// it is not observed on hardware, and before 1.10.0 the crash path has none at
/// all: `monitor_process` releases the robot-app lock in its `finally` and does
/// nothing else. From 1.10.0 that release schedules the daemon's own sleep, which
/// is what ``daemonParksAfterApps`` is about.
extension RobotSession {
    /// Whether `restart-current-app` is between its two halves.
    ///
    /// Public because a surface that ends on "the app let go" has to tell a real
    /// release from this gap: the daemon stops the app and starts it again behind
    /// one request, so a poll landing in between reads an idle robot. The in-app
    /// dock never noticed because it draws what the session holds, but the Live
    /// Activity ends a card on that edge, and ending here is a false "stopped"
    /// followed by a new card 1.5 s later.
    public var isRestartingApp: Bool {
        appLifecycle.isRestarting
    }

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
        // The daemon is about to put the robot to sleep whoever woke it, so the
        // promise is paid either way — and anything sent from here would be the
        // same two-motions bug, one level down. Taken rather than dropped: the
        // status cannot prove that the daemon has a loop to run the reset on, and
        // a robot this session woke is not left awake with its torque on when the
        // reset never comes.
        if daemonParksAfterApps {
            let owner = appLifecycle.takeWakeOwnership()
            guard await followDaemonParking(client: client) == .timedOut, owner != nil else { return }
            await sleep()
            return
        }
        if appLifecycle.takeWakeOwnership() != nil {
            await sleep()
        } else {
            await returnToBase(client: client)
        }
    }

    /// Whether the daemon puts the robot to sleep by itself once an app lets go.
    ///
    /// Only an app starting, a remote session taking the slot or a data-channel
    /// frame cancels that sleep — no motion or motor route does — so a `goto` or a
    /// sleep sent from here over the LAN does not replace that motion, it runs
    /// alongside it.
    ///
    /// The version and the media server are the status's to say
    /// (`resetsToSleepAfterApps`); the transport is the session's:
    /// - **Not over the relay.** There every command is a data-channel frame, and
    ///   `_handle_webrtc_message` cancels a pending or running reset before it does
    ///   anything else, so the session's own parking pre-empts the daemon's cleanly
    ///   instead of racing it. Watching the reset would cancel it as well: the
    ///   relayed status is a `get_state` frame.
    var daemonParksAfterApps: Bool {
        !isRemote && lastStatus?.resetsToSleepAfterApps == true
    }

    /// Shows the daemon's own parking as the transition it is, and sends nothing.
    ///
    /// Without it the screen goes on saying "Awake" for the seven-odd seconds the
    /// daemon takes and up to a poll interval after — with Go to sleep, the
    /// joystick and the moves all live, and every one of them a second motion the
    /// reset will not yield to. `.goingToSleep` is what the robot is visibly doing,
    /// and it holds those controls off and reaches the widget through the same
    /// mirror as a sleep somebody asked for.
    ///
    /// Ends on the first reading that says asleep, on an app holding the robot
    /// again — starting one cancels the reset daemon-side — or at
    /// `Configuration.idleResetTimeout`. A robot still awake by then is one the
    /// daemon chose to leave alone, or one it had no loop to reset: the caller
    /// leaves it alone unless this session woke it for the app, since parking it
    /// late would put the head down under whoever cancelled the reset.
    private func followDaemonParking(client: any RobotAPIClient) async -> IdleResetWatch {
        let attemptID = connectionAttemptID
        // Read afresh rather than off `lastStatus`, which can be a poll interval
        // old: an app that put the robot to sleep itself leaves the daemon nothing
        // to do (`_already_idle`), and announcing a transition over that would be
        // the stale state this exists to remove, inverted.
        guard let status = try? await client.daemonStatus(), isAttemptLive(attemptID) else { return .abandoned }
        lastStatus = status
        guard status.isAwake else { return .asleep }
        guard powerTransition == nil else { return .abandoned }
        powerTransition = .goingToSleep
        defer {
            // A disconnect has already cleared it, and a new attempt may own it now.
            if connectionAttemptID == attemptID {
                powerTransition = nil
            }
        }
        return await watchIdleReset(client: client, attemptID: attemptID)
    }

    /// How waiting for the daemon's own sleep ended.
    enum IdleResetWatch: Equatable {
        /// A reading said the motors are off — the reset ran, or there was nothing
        /// left for it to do.
        case asleep
        /// An app holds the robot again, which cancels the reset daemon-side, or
        /// this session is no longer the one connected.
        case abandoned
        /// `idleResetTimeout` passed with the robot still awake.
        case timedOut
    }

    /// Reads the status until the daemon's reset has cut the motors, under a
    /// transition the caller already holds.
    ///
    /// The loop both callers share: the parking after an app, which lets a
    /// timeout go, and a deliberate sleep, which chases one. Which of the two is
    /// right is the caller's decision, so the outcome says why the wait ended
    /// rather than whether the robot slept.
    func watchIdleReset(client: any RobotAPIClient, attemptID: UUID) async -> IdleResetWatch {
        let deadline = ContinuousClock.now + configuration.idleResetTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: configuration.appStopPollInterval)
            guard isAttemptLive(attemptID), runningApp?.isBusy != true else { return .abandoned }
            // A reading that never arrived is not evidence either way.
            guard let status = try? await client.daemonStatus() else { continue }
            guard isAttemptLive(attemptID) else { return .abandoned }
            lastStatus = status
            if !status.isAwake {
                return .asleep
            }
        }
        return .timedOut
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
        guard let moves = client as? any MovePlaybackClient else { return }
        _ = await recentre(client: moves)
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
