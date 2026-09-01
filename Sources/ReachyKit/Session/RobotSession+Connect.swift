import Foundation

/// The two ways into a robot. Both end in the same place — `settle` — because a
/// session does not care how its client reaches the robot, only that it does.
public extension RobotSession {
    /// Connects manually by default. Automatic attempts respect a preceding explicit Disconnect.
    @discardableResult
    func connect(to address: RobotAddress, automatically: Bool = false) async -> Bool {
        guard !automatically || automaticConnectionAllowed else { return false }
        if !automatically {
            automaticConnectionAllowed = true
        }

        let attemptID = beginAttempt(over: .lan(address))
        let client: any RobotAPIClient
        do {
            client = try makeClient(address)
        } catch {
            return failAttempt(.connect, error: error, link: .lan(address), automatically: automatically)
        }
        return await settle(
            client: client,
            link: .lan(address),
            attemptID: attemptID,
            automatically: automatically
        )
    }

    /// Connects through a transport built elsewhere.
    ///
    /// A remote session has no address to dial: its client speaks over the data
    /// channel of a WebRTC session that was negotiated through the Hugging Face
    /// relay, and by the time it gets here it is already talking to the robot.
    @discardableResult
    func connect(using client: any RobotAPIClient) async -> Bool {
        await connect(client, over: .remote)
    }

    /// Connects to a simulator running inside this process.
    ///
    /// Separate from `connect(using:)` rather than a defaulted parameter on it,
    /// because the link is the whole difference and a default would let a caller
    /// pick the wrong one by saying nothing. What follows from `.remote` is a
    /// camera the simulator does not have and a caption naming a relay it never
    /// touched — see `Link.simulated`.
    @discardableResult
    func connect(simulating client: any RobotAPIClient) async -> Bool {
        await connect(client, over: .simulated)
    }

    private func connect(_ client: any RobotAPIClient, over link: Link) async -> Bool {
        // Picking a robot off a list is as explicit as typing an address.
        automaticConnectionAllowed = true
        let attemptID = beginAttempt(over: link)
        return await settle(client: client, link: link, attemptID: attemptID, automatically: false)
    }

    private func beginAttempt(over link: Link) -> UUID {
        let attemptID = UUID()
        connectionAttemptID = attemptID
        resetConnectionState()
        self.link = link
        phase = .connecting(.handshaking)
        robotError = nil
        return attemptID
    }

    /// Everything from the handshake on, shared by both ways in. Only the parts
    /// that name an address are conditional — the rest of a session does not care
    /// how its client reaches the robot.
    private func settle(
        client: any RobotAPIClient,
        link: Link,
        attemptID: UUID,
        automatically: Bool
    ) async -> Bool {
        do {
            let handshake = try await client.handshake()
            guard connectionAttemptID == attemptID, !Task.isCancelled else {
                if connectionAttemptID == attemptID {
                    resetConnectionState()
                }
                return false
            }
            // Claimed before the readiness stage so `startBackend()` has something
            // to talk to while the attempt sits on `.backendUnavailable`. Only the
            // stepper is mounted then, so the rest of the surface stays unreachable.
            self.client = client
            lastStatus = handshake.status
            compatibilityWarning = handshake.compatibility.warningMessage
            // A property of the daemon, not of how it was reached. The relay's
            // handshake reports false because no HTTP route answers there, and
            // daemon 1.10.0 put `set_robot_name` on the data channel — so the
            // transport is the second half of the answer, and the version is the
            // third: an older relayed daemon has no such command.
            supportsRename = handshake.supportsRename
                || (client is any RobotRenameClient && !predatesRelayCommands)
            if case let .lan(address) = link {
                KnownRobots.lastAddress = address
                KnownRobots.remember(identity: handshake.identity, address: address)
                // A robot set up over Bluetooth has arrived under its own identity. This is
                // the only place that sees a handshake, and identity is all there is to match
                // on — it was provisioned at one address and turns up at another (rule 4).
                if KnownRobots.pendingProvisionedHardwareID == handshake.identity.hardwareID {
                    KnownRobots.pendingProvisionedHardwareID = nil
                }
            }
            if case let .unsupported(reported, minimum) = handshake.compatibility {
                return haltOnUnsupportedDaemon(
                    identity: handshake.identity,
                    requirement: DaemonUpdateRequirement(
                        reported: reported,
                        minimum: minimum,
                        canSelfUpdate: handshake.status.wirelessVersion
                    )
                )
            }
            // Before the gate comes down, so the tab shell's models are built over
            // catalogues that are already in memory. See `warmCatalogues`.
            await warmCatalogues(for: handshake.identity, attemptID: attemptID)
            guard isAttemptLive(attemptID) else { return false }
            phase = .connecting(.checkingBackend(handshake.identity))
            return await settleReadiness(
                identity: handshake.identity,
                status: handshake.status,
                client: client,
                attemptID: attemptID,
                automatically: automatically
            )
        } catch {
            guard connectionAttemptID == attemptID else { return false }
            guard !Task.isCancelled else {
                resetConnectionState()
                return false
            }
            return failAttempt(.connect, error: error, link: link, automatically: automatically)
        }
    }

    func disconnect() {
        automaticConnectionAllowed = false
        connectionAttemptID = UUID()
        resetConnectionState()
        robotError = nil
        // Here rather than in `resetConnectionState`, which also runs on a failed
        // attempt: a robot that could not be reached this time is not a robot the
        // user let go of, and blanking the widget over it loses a good reading.
        snapshots.clear()
    }
}

/// What the current daemon status says about driving the robot.
private enum ReadinessVerdict {
    case ready
    /// `state` is ahead of `backend.ready` — the one case worth waiting out.
    case keepWaiting
    case backendDown
    case failed(Error)
}

public extension RobotSession {
    /// Starts the backend from the readiness step, then re-runs the gate.
    ///
    /// `wakeUp: false` is the safety contract of this button: `wake_up=true` has
    /// the daemon enable the motors and play the wake-up animation by itself, and
    /// the user asked to start the backend, not to move the robot.
    func startBackend() async {
        guard let client, powerTransition == nil,
              case let .connecting(.backendUnavailable(identity, _)) = phase
        else { return }
        let attemptID = connectionAttemptID
        robotError = nil
        powerTransition = .startingBackend
        defer { powerTransition = nil }

        guard await runBackendStart(wakeUp: false, client: client) else { return }
        // `runBackendStart` only returns true once `waitForDaemonRunning` has seen
        // `.running`, so `lastStatus` is both fresh and in the right state.
        guard isAttemptLive(attemptID), let status = lastStatus else { return }
        phase = .connecting(.checkingBackend(identity))
        _ = await settleReadiness(
            identity: identity,
            status: status,
            client: client,
            attemptID: attemptID,
            automatically: false
        )
    }

    /// Escape hatch from the readiness step. The daemon log console and the status
    /// screen are exactly what you need to work out why a backend won't start, so
    /// refusing to connect would lock the user out of the diagnosis.
    func proceedWithoutBackend() {
        guard case let .connecting(.backendUnavailable(identity, _)) = phase else { return }
        _ = finishConnected(identity: identity)
    }
}

extension RobotSession {
    /// Connect-time readiness gate.
    ///
    /// `state == .running` flips before the backend has finished coming up, so the
    /// only honest signal is a 200 from the `get_backend`-guarded `/api/state/full`.
    /// Unlike upstream this loop is bounded and asymmetric: we never start a backend
    /// during connect, so a stopped or faulted one is reported at once instead of
    /// being retried at 2 Hz. Only the `running`-but-still-503 window actually spins.
    func settleReadiness(
        identity: RobotIdentity,
        status: Components.Schemas.DaemonStatus,
        client: any RobotAPIClient,
        attemptID: UUID,
        automatically: Bool
    ) async -> Bool {
        var status = status
        let deadline = ContinuousClock.now + configuration.readinessTimeout

        while isAttemptLive(attemptID) {
            let verdict = await readinessVerdict(for: status, client: client)
            guard isAttemptLive(attemptID) else { return false }

            switch verdict {
            case .ready:
                return finishConnected(identity: identity)
            case .backendDown:
                return haltOnUnavailableBackend(identity: identity)
            case let .failed(error):
                return failAttempt(.backend, error: error, link: link, automatically: automatically)
            case .keepWaiting:
                guard ContinuousClock.now < deadline else {
                    return haltOnUnavailableBackend(identity: identity)
                }
                guard let refreshed = await refreshedStatus(
                    client: client, attemptID: attemptID, current: status
                ) else { return false }
                status = refreshed
            }
        }
        return false
    }

    func finishConnected(identity: RobotIdentity) -> Bool {
        phase = .connected(identity)
        recordSnapshot(identity: identity)
        startPolling(identity: identity)
        startPathMonitor(identity: identity)
        if let moves = movesClient {
            // Off the connect path on purpose: adopting a move the robot was
            // already playing is worth one round trip, but not a slower gate.
            restoreActiveMove(client: moves)
        }
        return true
    }

    /// Terminal but recoverable, and latched even for automatic attempts: finding
    /// the robot with its backend down *is* a successful search, there is nothing
    /// left to probe, and falling back to `.idle` would have the 10 s rescan
    /// hammer the same robot forever.
    func haltOnUnavailableBackend(identity: RobotIdentity) -> Bool {
        phase = .connecting(.backendUnavailable(identity, daemonMessage: backendFault))
        return false
    }

    /// Latched for the same reason as `haltOnUnavailableBackend`: an old daemon is a
    /// found robot, not a failed search, and the user has something to do about it.
    func haltOnUnsupportedDaemon(identity: RobotIdentity, requirement: DaemonUpdateRequirement) -> Bool {
        phase = .connecting(.needsDaemonUpdate(identity, requirement))
        return false
    }

    /// ADR 0001: an unsupported daemon is never sent a command. The connection gate
    /// already keeps the control screens unmounted, but navigation is a layout
    /// decision, not an enforcement mechanism — this makes the rule fail loudly.
    func assertSupportedDaemon() throws {
        if case let .unsupported(reported, minimum) = DaemonCompatibilityPolicy.evaluate(lastStatus?.version) {
            throw ReachyKitError.unsupportedDaemonVersion(reported: reported, minimum: minimum)
        }
    }

    /// Automatic attempts must land back on `.idle`: the candidate sweep and the
    /// periodic rescan both gate on it, so latching a failure there would silently
    /// stop the app from ever reconnecting.
    func failAttempt(
        _ stage: ConnectionStage,
        error: Error,
        link: Link,
        automatically: Bool
    ) -> Bool {
        let message = Self.describe(error)
        resetConnectionState()
        robotError = message
        guard !automatically else { return false }
        // Restored after the reset so the failure names what was being reached.
        // A remote attempt has no address and still has to show its failure: the
        // user picked that robot off a list, and gating the report on an address
        // would swallow every remote failure there is.
        self.link = link
        phase = .connecting(.failed(stage, message: message))
        return false
    }

    /// A superseded or cancelled attempt must never write back to the session —
    /// the readiness stage suspends several times, and every resumption is a
    /// chance for a stale attempt to resurrect `.connected`.
    func isAttemptLive(_ attemptID: UUID) -> Bool {
        connectionAttemptID == attemptID && !Task.isCancelled
    }
}

private extension RobotSession {
    func readinessVerdict(
        for status: Components.Schemas.DaemonStatus,
        client: any RobotAPIClient
    ) async -> ReadinessVerdict {
        switch status.state {
        case .running:
            do {
                try await client.probeBackendReady()
                return .ready
            } catch ReachyKitError.backendNotRunning {
                return .keepWaiting
            } catch {
                return .failed(error)
            }
        case .error, .stopped, .notInitialized:
            return .backendDown
        default:
            return .keepWaiting // `.starting` / `.stopping` are genuinely in transit
        }
    }

    /// Waits a poll interval and re-reads the status. A transient read failure
    /// keeps the previous one; `nil` means the attempt is dead and the caller bails.
    func refreshedStatus(
        client: any RobotAPIClient,
        attemptID: UUID,
        current: Components.Schemas.DaemonStatus
    ) async -> Components.Schemas.DaemonStatus? {
        try? await Task.sleep(for: configuration.readinessPollInterval)
        guard isAttemptLive(attemptID) else { return nil }
        guard let refreshed = try? await client.daemonStatus() else { return current }
        guard isAttemptLive(attemptID) else { return nil }
        lastStatus = refreshed
        return refreshed
    }
}
