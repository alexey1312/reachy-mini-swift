import Foundation

/// Following a job, over the LAN's socket or the relay's notifications, and the
/// relay's store from daemon 1.13.0.
public extension RobotSession {
    /// Whether the relay carries the robot's own store: the installed list,
    /// installs by Space id, removals, updates, restart and followed jobs
    /// (pollen-robotics/reachy_mini#1471, #1477).
    ///
    /// On a version known to be 1.13.0 or newer, and withheld otherwise: unlike
    /// ``canControlRunningApp`` this gate needs the evidence, because a robot that
    /// lacks these verbs answers each with `-32601` while `apps.install` still works
    /// for it. The startup app, the update summary and the lock stay HTTP.
    var hasRelayAppStore: Bool {
        guard (client as? any RobotAppsClient)?.carriesRelayAppStore == true else { return false }
        return DaemonCompatibilityPolicy.isKnownAtLeast("1.13.0", reported: lastStatus?.version)
    }

    /// Follows one job to its end over the socket *and* the poll — see
    /// `AppJobMonitor` for why neither alone is enough.
    ///
    /// Over the relay the socket's part is played by `apps.job_progress`, which
    /// the connection records from the job's first line (`RelayAppJobLedger`).
    /// Each poll there returns the whole log, so it runs every two seconds, and the
    /// budget is the relay install's three minutes: a phone's link is slower.
    func appJobEvents(
        jobID: String,
        configuration: AppJobMonitor.Configuration = .install
    ) throws -> AsyncStream<AppJobMonitor.Event> {
        guard let client = client as? any RobotAppsClient else { throw ReachyKitError.appsUnavailable }
        if let relay = client as? any RelayAppJobClient {
            return AppJobMonitor(
                configuration: .init(pollInterval: .seconds(2), timeout: max(configuration.timeout, .seconds(180))),
                logs: { Self.relayLog(of: jobID, from: relay) },
                job: { try await client.appJob(id: jobID) }
            ).events()
        }
        guard let address else { throw ReachyKitError.notConnected }
        return AppJobMonitor(
            configuration: configuration,
            logs: {
                (try? JobLogStreamClient.appsManager(address: address, jobID: jobID).events())
                    ?? AsyncStream { $0.finish() }
            },
            job: { try await client.appJob(id: jobID) }
        ).events()
    }

    /// One app's update over the relay. Nil where the relay has no such verb.
    func appUpdateCheck(named name: String) async throws -> AppUpdateCheck? {
        guard hasRelayAppStore else { return nil }
        return try await withAppsClient { try await $0.appUpdateCheck(named: name) }
    }
}

private extension RobotSession {
    /// The monitor takes its log synchronously and the ledger is an actor, so this
    /// forwards one into the other. `makeStream`, not the builder: a closure that
    /// keeps its escaping continuation is the shape that hangs the compiler.
    nonisolated static func relayLog(of jobID: String, from relay: any RelayAppJobClient) -> AsyncStream<JobLogEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: JobLogEvent.self)
        let forwarding = Task {
            for await event in await relay.jobLog(id: jobID) {
                continuation.yield(event)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in forwarding.cancel() }
        return stream
    }
}
