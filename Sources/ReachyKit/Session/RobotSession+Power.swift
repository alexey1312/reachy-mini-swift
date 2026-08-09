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
    func wake() async {
        guard let client, powerTransition == nil else { return }
        robotError = nil
        // Claimed before the first suspension point: `@MainActor` re-enters on
        // every `await`, so a later latch would let a double tap through.
        powerTransition = .wakingUp
        defer { powerTransition = nil }
        do {
            try assertSupportedDaemon()
            let status = try await client.daemonStatus()
            lastStatus = status
            guard status.state == .running else {
                // `wake_up=true` has the daemon enable the motors and play the
                // animation itself once the backend is up.
                _ = await runBackendStart(wakeUp: true, client: client)
                return
            }
            try await RobotPower(client: client, configuration: configuration).wake()
        } catch {
            report(error)
        }
    }

    /// Mirror image of wake: the animation must finish *before* power is cut,
    /// otherwise the head drops wherever it happens to be.
    func sleep() async {
        guard let client, powerTransition == nil else { return }
        robotError = nil
        powerTransition = .goingToSleep
        defer { powerTransition = nil }
        do {
            try assertSupportedDaemon()
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
    /// parked either way, and that is the half that matters.
    ///
    /// What comes back is the daemon's own HTTP server, which survives all of this —
    /// and that is also why `phase` stays `.connected` and the connect gate is never
    /// shown again. `startBackend()` is therefore *not* the way up from here: it
    /// guards on `.connecting(.backendUnavailable(…))`, which only a fresh connect
    /// reaches. `wake()` is, because it starts a stopped backend itself.
    func powerOff() async {
        guard let client, powerTransition == nil else { return }
        robotError = nil
        // Claimed before the first suspension point, like `wake()`.
        powerTransition = .stoppingBackend
        defer { powerTransition = nil }
        do {
            try assertSupportedDaemon()
            if runningApp?.isBusy == true {
                do {
                    try await stopCurrentApp()
                } catch {
                    report(error)
                }
            }
            try await client.stopDaemon(gotoSleep: true)
        } catch {
            report(error)
            return
        }
        if await !waitForDaemonStopped(client: client) {
            robotError = "Robot backend did not stop within \(configuration.daemonStopTimeout)."
        }
    }
}

extension RobotSession {
    /// Polls the daemon's authoritative running-move list until `uuid` is gone.
    /// A timeout returns normally: parking the motors matters more than proof
    /// that the animation ran to completion.
    func waitForMoveToFinish(_ uuid: String, client: any RobotAPIClient) async {
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
