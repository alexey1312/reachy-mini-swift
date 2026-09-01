import Foundation
@testable import ReachyKit
@testable import ReachyUI
import Testing

/// The update is the one flow whose success cannot be read off the wire: the daemon
/// restarts before it can report `done`. Everything here pins how that is inferred.
private final class UpdateStubClient: RobotAPIClient, DaemonUpdateClient, @unchecked Sendable {
    private let lock = NSLock()
    private let availability: DaemonUpdateAvailability
    private let startError: Error?
    private var starts: [Bool] = []
    /// What `/update/info` answers, one status per call. An exhausted script throws,
    /// which is the daemon going down — the ordinary end of an update.
    private var jobStatuses: [DaemonJob.Status]
    /// Keeps answering the last scripted status instead of running out, which is a
    /// job that outlives the client's whole budget.
    private let repeatsLastStatus: Bool
    private var infoCalls = 0

    init(
        availability: DaemonUpdateAvailability,
        startError: Error? = nil,
        jobStatuses: [DaemonJob.Status] = [],
        repeatsLastStatus: Bool = false
    ) {
        self.availability = availability
        self.startError = startError
        self.jobStatuses = jobStatuses
        self.repeatsLastStatus = repeatsLastStatus
    }

    var startedPreReleaseFlags: [Bool] {
        lock.withLock { starts }
    }

    var updateInfoCalls: Int {
        lock.withLock { infoCalls }
    }

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name": "testbot", "state": "running", "wireless_version": true,
         "desktop_app_daemon": false, "version": "1.9.0", "backend_status": null}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: RobotIdentity(hardwareID: "hw", name: "testbot", daemonVersion: "1.9.0"), status: status)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        status
    }

    func wakeUp() async throws -> String {
        "uuid"
    }

    func gotoSleep() async throws -> String {
        "uuid"
    }

    func availableUpdate(preRelease _: Bool) async throws -> DaemonUpdateAvailability {
        availability
    }

    func startUpdate(preRelease: Bool) async throws -> String {
        if let startError {
            throw startError
        }
        lock.withLock { starts.append(preRelease) }
        return "job-1"
    }

    func updateInfo(jobID _: String) async throws -> DaemonUpdateJob {
        let next: DaemonJob.Status? = lock.withLock {
            infoCalls += 1
            if repeatsLastStatus, jobStatuses.count == 1 {
                return jobStatuses[0]
            }
            return jobStatuses.isEmpty ? nil : jobStatuses.removeFirst()
        }
        guard let next else { throw URLError(.cannotConnectToHost) }
        return DaemonJob(command: "update", status: next, logs: [])
    }
}

@MainActor
@Suite("SystemUpdateModel")
struct SystemUpdateModelTests {
    private func makeSession(_ client: UpdateStubClient) async -> RobotSession {
        let session = RobotSession { _ in client }
        await session.connect(to: RobotAddress(host: "10.0.0.9"))
        return session
    }

    private func makeModel(
        _ client: UpdateStubClient,
        events: [UpdateLogEvent] = [.closed],
        reconnectsAs version: String? = "1.10.0",
        jobPollInterval: Duration = .zero,
        jobPollBudget: Duration = .seconds(20 * 60)
    ) async -> SystemUpdateModel {
        let session = await makeSession(client)
        return SystemUpdateModel(
            session: session,
            events: { _ in
                AsyncStream { continuation in
                    events.forEach { continuation.yield($0) }
                    continuation.finish()
                }
            },
            reconnect: { version },
            jobPollInterval: jobPollInterval,
            jobPollBudget: jobPollBudget
        )
    }

    @Test("a robot that cannot reach PyPI is reported as offline, not as a failed check")
    func reportsRobotOffline() async {
        let model = await makeModel(UpdateStubClient(availability: .robotOffline(current: "1.9.0")))

        await model.check(preRelease: false)

        #expect(model.state == .robotOffline(current: "1.9.0"))
    }

    @Test("the beta toggle is carried into the daemon call")
    func passesPreReleaseToTheDaemon() async {
        let client = UpdateStubClient(availability: .available(current: "1.9.0", latest: "1.10.0rc1"))
        let model = await makeModel(client)

        await model.check(preRelease: true)
        await model.install(preRelease: true)

        #expect(client.startedPreReleaseFlags == [true])
    }

    @Test("the socket closing is success — the daemon restarts before it can report done")
    func treatsSocketCloseAsCompletion() async {
        let model = await makeModel(
            UpdateStubClient(availability: .available(current: "1.9.0", latest: "1.10.0")),
            events: [.line("Collecting reachy-mini"), .status(.inProgress), .closed],
            reconnectsAs: "1.10.0"
        )

        await model.check(preRelease: false)
        await model.install(preRelease: false)

        #expect(model.state == .finished(version: "1.10.0"))
        #expect(model.log.entries.map(\.text) == ["Collecting reachy-mini"])
    }

    @Test("a daemon that comes back on the old version means the update did not land")
    func failsWhenTheVersionDidNotChange() async {
        let model = await makeModel(
            UpdateStubClient(availability: .available(current: "1.9.0", latest: "1.10.0")),
            reconnectsAs: "1.9.0"
        )

        await model.check(preRelease: false)
        await model.install(preRelease: false)

        guard case let .failed(message) = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
        #expect(message.contains("1.9.0"))
    }

    @Test("a daemon that never comes back is a failure, not an endless restart")
    func failsWhenTheDaemonNeverReturns() async {
        let model = await makeModel(
            UpdateStubClient(availability: .available(current: "1.9.0", latest: "1.10.0")),
            reconnectsAs: nil
        )

        await model.check(preRelease: false)
        await model.install(preRelease: false)

        guard case let .failed(message) = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
        #expect(message.contains("Power-cycle"))
    }

    @Test("an explicit failed status stops the run without waiting for a restart")
    func stopsOnAFailedStatus() async {
        let model = await makeModel(
            UpdateStubClient(availability: .available(current: "1.9.0", latest: "1.10.0")),
            events: [.line("ERROR: no matching distribution"), .status(.failed), .closed],
            reconnectsAs: "1.10.0"
        )

        await model.check(preRelease: false)
        await model.install(preRelease: false)

        #expect(model.state == .failed("The robot reported that the update failed."))
    }

    @Test("install does nothing unless a check found something to install")
    func refusesToInstallWithoutAnAvailableUpdate() async {
        let client = UpdateStubClient(availability: .upToDate(current: "1.9.0"))
        let model = await makeModel(client)

        await model.check(preRelease: false)
        await model.install(preRelease: false)

        #expect(model.state == .upToDate(current: "1.9.0"))
        #expect(client.startedPreReleaseFlags.isEmpty)
    }

    /// A Wi-Fi blip closes the same socket a restart does. The register is the only
    /// thing that can tell them apart, so a job still running is followed rather
    /// than announced as a restart.
    @Test("a socket that closes while the job runs is followed, not believed")
    func followsAJobThatOutlivesItsSocket() async {
        let client = UpdateStubClient(
            availability: .available(current: "1.9.0", latest: "1.10.0"),
            jobStatuses: [.inProgress, .inProgress]
        )
        let model = await makeModel(client)
        await model.check(preRelease: false)
        await model.install(preRelease: false)
        #expect(model.state == .finished(version: "1.10.0"))
        #expect(client.updateInfoCalls == 3)
    }

    /// Twenty minutes of `pip install` is a job still running, not a robot that
    /// restarted. Announcing the restart reconnected to a daemon that had never gone
    /// down, read back the old version, and blamed the release for it.
    @Test("a job still running when the budget runs out stays installing")
    func keepsInstallingWhenTheBudgetRunsOut() async {
        let client = UpdateStubClient(
            availability: .available(current: "1.9.0", latest: "1.10.0"),
            jobStatuses: [.inProgress],
            repeatsLastStatus: true
        )
        let model = await makeModel(client, jobPollBudget: .milliseconds(20))

        await model.check(preRelease: false)
        await model.install(preRelease: false)

        #expect(model.state == .installing)
    }

    /// A cancelled call leaves the state exactly as it was — the rule `fail(on:)`
    /// keeps, and the one this path used to break by telling the user to power-cycle
    /// a robot in the middle of an install.
    @Test("cancelling the install reports nothing")
    func cancellingTheInstallChangesNothing() async {
        let client = UpdateStubClient(
            availability: .available(current: "1.9.0", latest: "1.10.0"),
            jobStatuses: [.inProgress],
            repeatsLastStatus: true
        )
        let model = await makeModel(
            client,
            jobPollInterval: .milliseconds(20),
            jobPollBudget: .seconds(30)
        )
        await model.check(preRelease: false)

        let install = Task { await model.install(preRelease: false) }
        await waitUntil("the job register has been asked") { client.updateInfoCalls > 0 }
        install.cancel()
        await install.value

        #expect(model.state == .installing)
    }

    @Test("a register that reports the job failed stops the run")
    func failsWhenTheRegisterReportsAFailure() async {
        let client = UpdateStubClient(
            availability: .available(current: "1.9.0", latest: "1.10.0"),
            jobStatuses: [.failed]
        )
        let model = await makeModel(client)
        await model.check(preRelease: false)
        await model.install(preRelease: false)
        #expect(model.state == .failed(String(localized: .reachy("The robot reported that the update failed."))))
    }
}
