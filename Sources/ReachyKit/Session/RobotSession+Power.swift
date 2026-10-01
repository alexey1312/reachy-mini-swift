import Foundation

/// Both transitions are multi-step protocols against the daemon, not single
/// calls: `/move/play/wake_up` and `/move/play/goto_sleep` only play animations
/// and never touch the motor control mode, and they answer 503 while the robot
/// backend is down. Enabling and cutting motor power is the caller's job.
///
/// `wake()` here and `RobotPower.resume()` answer the same question — waking a
/// robot whose backend `powerOff()` took away — and stay separate because only
/// this one has a screen: it waits the 90 s start out under `powerTransition`,
/// where an intent can only ask for it and say so. Neither may lose that
/// behaviour without the other gaining it, or the ladder goes one-way again.
public extension RobotSession {
    /// The branch is picked from a freshly fetched status rather than `lastStatus`,
    /// which may be a poll interval out of date — long enough to send motor
    /// commands at a backend that is already gone.
    ///
    /// A deliberate wake is also the user taking the robot back: whatever this
    /// session woke it *for* no longer owns it (see ``RobotSession/appLifecycle``).
    ///
    /// It does **not** tell the robot it has met its owner any more. #157 had it do
    /// that after the first wake this app performed; the first run wakes the robot
    /// partway through, so the flag is written where that run ends instead
    /// (``finishFirstRun()``, `RobotSession+FirstRun`).
    func wake() async {
        guard let client, powerTransition == nil else { return }
        robotError = nil
        // Claimed before the first suspension point: `@MainActor` re-enters on
        // every `await`, so a later latch would let a double tap through.
        powerTransition = .wakingUp
        appLifecycle.releaseWakeOwnership()
        do {
            try await runWake(client: client, startingBackend: true)
        } catch {
            report(error)
            powerTransition = nil
            return
        }
        powerTransition = nil
    }

    /// Mirror image of wake: the animation must finish *before* power is cut,
    /// otherwise the head drops wherever it happens to be.
    ///
    /// **The app holding the robot is stopped first**, which is the same rule
    /// `powerOff` follows one rung further down the ladder and for the same reason:
    /// `move/play/goto_sleep` is an animation and `motors/set_mode/disabled` is a
    /// switch, so neither tells the app manager anything. An app left running has
    /// the motors taken out from under it and dies on its next command — a
    /// traceback nobody asked for, in place of the app the user deliberately left
    /// running. `releaseRunningApp()` is where the waiting is explained.
    ///
    /// **From 1.10.0 that stop is itself a sleep (#166).** Freeing the app slot
    /// schedules the daemon's `reset_to_sleep()` 1.5 s later, and no motion or
    /// motor route cancels it — so a `goto_sleep` of our own would not replace it,
    /// it would run beside it, and `set_mode/disabled` could cut the torque while
    /// the daemon's trajectory is still moving. Where ``daemonParksAfterApps``
    /// holds, the sleep is therefore the daemon's, watched under the
    /// `.goingToSleep` already claimed here. Unlike the parking after an app, a
    /// reset that never comes is chased: the user asked for sleep, and nobody else
    /// has taken the robot. One who has — an app holding it again — keeps it.
    func sleep() async {
        guard let client, powerTransition == nil else { return }
        robotError = nil
        // Claimed before the first suspension point, like `wake()`: stopping the
        // app is a suspension point too, and a second tap during it would otherwise
        // start a second sleep.
        powerTransition = .goingToSleep
        defer { powerTransition = nil }
        appLifecycle.releaseWakeOwnership()
        let attemptID = connectionAttemptID
        do {
            try assertSupportedDaemon()
            await releaseMove()
            if await releaseRunningApp(), daemonParksAfterApps {
                guard await watchIdleReset(client: client, attemptID: attemptID) == .timedOut else { return }
            }
            try await RobotPower(client: client, configuration: configuration).sleep()
        } catch {
            report(error)
        }
    }

    /// Sleep's bigger sibling: tear the robot backend down, so the camera, the
    /// state stream and the motors all go rather than only the motors.
    ///
    /// **The parking is the daemon's, not ours.** `stop?goto_sleep=true` enables the
    /// motors, awaits the sleep animation and only then cuts power — which is more
    /// than `RobotPower.sleep()` does, since that one never enables them first. So
    /// this asks for it rather than performing its own sequence beforehand.
    ///
    /// The running app is stopped here because the daemon will not do it: its
    /// teardown drops the media server and the JSON-RPC relay and never touches the
    /// app manager, leaving the app running against a backend that has gone. A
    /// failure to stop it is reported and does not abort — the robot's body is
    /// parked either way, and that is the half that matters. `releaseRunningApp()`
    /// is that step, and it waits: the daemon parks the robot as part of this
    /// teardown, and doing so while the app is still handing it back is what the
    /// wait exists to prevent.
    ///
    /// **From 1.10.0 that release also schedules the daemon's own sleep, and here
    /// the stop is what cancels it** — `Daemon.stop` unwires the free-slot hook and
    /// sets `is_shutting_down`, which ends a reset still inside its 1.5 s debounce.
    /// The stop leaves two round trips after the slot clears (the stop's own
    /// re-read, then this request), so on any network this app is usable on it
    /// lands inside that window. A reset already moving when it arrives is not
    /// cancelled and runs beside the teardown's own `reset_to_sleep()`; that takes
    /// a stop delayed past 1.5 s, and is a sentence here rather than a wait (#166).
    ///
    /// What comes back is the daemon's own HTTP server, which survives all of this —
    /// and that is also why `phase` stays `.connected` and the connect gate is never
    /// shown again. `startBackend()` is therefore *not* the way up from here: it
    /// guards on `.connecting(.backendUnavailable(…))`, which only a fresh connect
    /// reaches. `wake()` is, because it starts a stopped backend itself.
    ///
    /// **This is the teardown, unconditionally.** With an app set to start on
    /// wake-up it also switches off the antenna touch that starts it, which is why
    /// a caller that cannot ask first goes through `powerOff(_:)` and a
    /// ``PowerOffPlan`` instead.
    func powerOff() async {
        guard let client, powerTransition == nil else { return }
        robotError = nil
        // Claimed before the first suspension point, like `wake()`.
        powerTransition = .stoppingBackend
        defer { powerTransition = nil }
        appLifecycle.releaseWakeOwnership()
        do {
            try assertSupportedDaemon()
            await releaseMove()
            await releaseRunningApp()
            try await client.stopDaemon(gotoSleep: true)
        } catch {
            report(error)
            return
        }
        if await !waitForDaemonStopped(client: client) {
            robotError = "Robot backend did not stop within \(configuration.daemonStopTimeout)."
        }
    }

    /// What powering this robot off should be right now, read from the robot
    /// rather than off `lastStatus` — ``PowerOffPlan/read(from:)`` says why each
    /// failure lands where it does.
    func powerOffPlan() async -> PowerOffPlan {
        guard let client else { return .stopBackend }
        return await PowerOffPlan.read(from: client)
    }

    /// Power off from a door with nobody to ask which kind: the Home Screen menu.
    ///
    /// The Robot screen asks instead, and calls `sleep()` or `powerOff()` by name —
    /// so `powerOff()` stays the teardown it always was, and only a caller that
    /// cannot put the choice to anyone takes the plan's word for it.
    func powerOff(_ plan: PowerOffPlan) async {
        switch plan {
        case .stopBackend: await powerOff()
        case .sleep: await sleep()
        }
    }
}

extension RobotSession {
    /// The wake protocol itself, thrown to the caller instead of reported onto
    /// `robotError`.
    ///
    /// It exists because starting an app has to wake the robot too, and an Apps
    /// failure belongs in the model behind the screen that asked — `robotError`
    /// holds the robot's connection and power and is not a fallback for anything
    /// (`ReachyUI/AGENTS.md`). Splitting the body rather than writing a second
    /// sequence is the point: `wake()` and `RobotPower.resume()` are already two
    /// answers to one question, and a third would be the one that drifts.
    ///
    /// **The caller owns `powerTransition`**, claiming it before its own first
    /// suspension point — the same latch `wake()` describes.
    ///
    /// `startingBackend: false` refuses a torn-down backend outright rather than
    /// spending the 90 s start budget inside somebody's Start button. The app page
    /// offers that as a decision of its own.
    func runWake(client: any RobotAPIClient, startingBackend: Bool) async throws {
        try assertSupportedDaemon()
        let status = try await client.daemonStatus()
        lastStatus = status
        guard status.state == .running else {
            guard startingBackend else { throw ReachyKitError.backendNotRunning }
            // `wake_up=true` has the daemon enable the motors and play the
            // animation itself once the backend is up.
            _ = await runBackendStart(wakeUp: true, client: client)
            return
        }
        try await RobotPower(client: client, configuration: configuration).wake()
        // One extra request, and it buys an honest `isAwake` immediately rather
        // than up to a poll interval later: the status above was read *before* the
        // motors were enabled, so everything derived from `lastStatus` — the
        // parking guard, the widget snapshot's `isAwake` — would otherwise still
        // report a sleeping robot for seconds after it stood up.
        // A failed re-read is not a failed wake: the robot is awake either way and
        // the poll corrects this within one interval.
        if let settled = try? await client.daemonStatus() {
            lastStatus = settled
        }
    }

    /// Hands the robot back before either transition parks it.
    ///
    /// **Neither half of this is the daemon's.** `Daemon.stop` drops the media
    /// server and the JSON-RPC relay and never touches the app manager, and
    /// `move/play/goto_sleep` only plays an animation — so an app is still driving
    /// the robot at the moment the motors go, and dies on its next command. That
    /// belongs to both rungs of the ladder rather than to powering off alone, which
    /// is why this sits between them instead of inside `powerOff`.
    ///
    /// **The wait is the point, not politeness.** A 200 from `stop-current-app`
    /// does not mean the app is gone: the daemon sets `stopping` before any I/O and
    /// clears its own slot on the last line of `stop_current_app`, past the
    /// return-to-zero it performs on the app's behalf (`apps/manager.py:283`,
    /// `:355`). Parking on top of that hand-back puts two motions on one robot, and
    /// `play_move` takes its guard non-blocking (`backend/abstract.py:412`) — so
    /// one of the two silently does nothing, and which one is not ours to choose.
    ///
    /// Neither a refusal nor a timeout aborts anything. Parking the robot matters
    /// more than proof that the app let go, the same trade `waitForMoveToFinish`
    /// makes; the failure goes on the screen and the transition carries on.
    ///
    /// Answers whether an app let go of the robot because of this call — the one
    /// case in which a 1.10.0 daemon has a sleep of its own on the way.
    @discardableResult
    func releaseRunningApp() async -> Bool {
        guard runningApp?.isBusy == true else { return false }
        do {
            try await stopCurrentApp()
        } catch {
            report(error)
            return false
        }
        return await waitForRunningAppToStop()
    }

    /// Polls until the daemon stops naming an app as holding the robot.
    ///
    /// Reads `runningApp` rather than the client, because `stopCurrentApp` and
    /// `refreshCurrentApp` are what write it — so the common case, where the stop's
    /// own re-read already found the slot clear, costs no further request at all.
    ///
    /// **Only a reading that arrived may reach a verdict.** `refreshCurrentApp`
    /// leaves the last status in place when it throws, so an unreachable poll keeps
    /// waiting rather than concluding that the app is gone — the rule
    /// `RunningAppModel` learned the hard way, where timing a stale reading turned a
    /// Wi-Fi blip into a wedged daemon.
    ///
    /// Answers whether the slot was seen clear.
    func waitForRunningAppToStop() async -> Bool {
        let deadline = ContinuousClock.now + configuration.appStopTimeout
        while runningApp?.isBusy == true, !Task.isCancelled {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: configuration.appStopPollInterval)
            try? await refreshCurrentApp()
        }
        return runningApp?.isBusy != true
    }

    /// Polls the daemon's authoritative running-move list until `uuid` is gone.
    /// A timeout returns normally: parking the motors matters more than proof
    /// that the animation ran to completion.
    ///
    /// A transport that cannot list moves cannot wait for one either, and returns
    /// at once — which is right rather than a shortcut: such a transport answers
    /// `wake_up` only once the animation has finished, so there is nothing left to
    /// wait for by the time this could be called. `RobotPower` keeps the same guard.
    func waitForMoveToFinish(_ uuid: String, client: any RobotAPIClient) async {
        guard let client = client as? any MovePlaybackClient else { return }
        let deadline = ContinuousClock.now + configuration.moveCompletionTimeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: configuration.movePollInterval)
            guard let running = try? await client.runningMoveUUIDs() else { continue }
            if !running.contains(uuid) {
                return
            }
        }
    }

    /// Starts the backend and waits it out. Deliberately does not claim
    /// `powerTransition` as a latch — the caller owns that and its `defer`,
    /// because `wake()` has already claimed it before its first suspension point.
    func runBackendStart(wakeUp: Bool, client: any RobotAPIClient) async -> Bool {
        powerTransition = .startingBackend
        do {
            try await client.startDaemon(wakeUp: wakeUp)
        } catch {
            report(error)
            return false
        }
        guard await waitForDaemonRunning(client: client) else {
            robotError = "Robot backend did not start within \(configuration.daemonStartTimeout)."
            return false
        }
        return true
    }

    /// Waits out the background stop job, refreshing `lastStatus` as it goes.
    ///
    /// `.error` is a finished job too, not a reason to keep polling: the daemon
    /// records the sleep animation failing that way and goes on tearing the backend
    /// down regardless. Reporting it as a timeout would name the wrong cause.
    func waitForDaemonStopped(client: any RobotAPIClient) async -> Bool {
        let deadline = ContinuousClock.now + configuration.daemonStopTimeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: configuration.pollInterval)
            guard let status = try? await client.daemonStatus() else { continue }
            lastStatus = status
            switch status.state {
            case .stopped, .error: return true
            default: continue
            }
        }
        return false
    }

    /// Waits out the background start job, refreshing `lastStatus` as it goes.
    func waitForDaemonRunning(client: any RobotAPIClient) async -> Bool {
        let deadline = ContinuousClock.now + configuration.daemonStartTimeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: configuration.pollInterval)
            guard let status = try? await client.daemonStatus() else { continue }
            lastStatus = status
            switch status.state {
            case .running: return true
            case .error, .stopped: return false
            default: continue
            }
        }
        return false
    }
}
