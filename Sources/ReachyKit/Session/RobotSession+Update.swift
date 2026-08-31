import Foundation

/// The daemon's self-update surface, reached through the session so the UI never
/// builds a URL of its own.
///
/// Deliberately not guarded by `assertSupportedDaemon()`: updating is precisely what
/// an unsupported daemon is for. ADR 0001 bars the *command* surface, and version
/// negotiation is not part of it.
public extension RobotSession {
    /// False on a Lite robot, which never mounts `/update/*`.
    var canUpdateDaemon: Bool {
        client is any DaemonUpdateClient && supportsWirelessFeatures
    }

    func availableUpdate(preRelease: Bool) async throws -> DaemonUpdateAvailability {
        try await withUpdateClient { try await $0.availableUpdate(preRelease: preRelease) }
    }

    /// Returns the job id whose log `updateLog(jobID:)` streams.
    func startUpdate(preRelease: Bool) async throws -> String {
        try await withUpdateClient { try await $0.startUpdate(preRelease: preRelease) }
    }

    /// What the job register says about an update in flight.
    ///
    /// Never a success signal — see ``reconnectAfterUpdate(timeout:pollInterval:)``
    /// for why the register cannot survive to report one. It answers the other
    /// question: whether the job is still running.
    func updateInfo(jobID: String) async throws -> DaemonUpdateJob {
        try await withUpdateClient { try await $0.updateInfo(jobID: jobID) }
    }

    func updateLog(jobID: String) throws -> AsyncStream<UpdateLogEvent> {
        guard let address else { throw ReachyKitError.notConnected }
        return try JobLogStreamClient.daemonUpdate(address: address, jobID: jobID).events()
    }

    /// Waits out the `systemctl restart` an update ends with and reports the version
    /// the daemon came back on.
    ///
    /// This is the only honest completion signal: the restart kills the process — and
    /// the in-memory job register with it — before the terminal `done` frame is ever
    /// written, so neither the socket nor `/update/info` can confirm success. `nil`
    /// means the daemon never answered again.
    func reconnectAfterUpdate(
        timeout: Duration = .seconds(120),
        pollInterval: Duration = .seconds(3)
    ) async -> String? {
        guard let address else { return nil }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            if await connect(to: address), let version = lastStatus?.version {
                return version
            }
            // A halted attempt still read the status, so an update that landed but
            // stayed below the baseline reports its real version rather than nothing.
            if case .connecting(.needsDaemonUpdate) = phase, let version = lastStatus?.version {
                return version
            }
        }
        return nil
    }
}

extension RobotSession {
    func withUpdateClient<T>(_ call: (any DaemonUpdateClient) async throws -> T) async throws -> T {
        guard let client else { throw ReachyKitError.notConnected }
        guard let updateClient = client as? any DaemonUpdateClient else {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
        return try await call(updateClient)
    }
}
