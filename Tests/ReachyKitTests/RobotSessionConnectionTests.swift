import Foundation
@testable import ReachyKit
import Testing

/// Daemon whose state sequence and readiness probes are both scripted, so the
/// connect-time gate can be driven through every branch.
private final class ReadinessMockClient: RobotAPIClient, @unchecked Sendable {
    enum ProbeResult {
        case ok
        case notReady
        case broken
        case slow
    }

    enum Step: Equatable {
        case startDaemon(wakeUp: Bool)
        case motorMode(Components.Schemas.MotorControlMode)
        case wakeUp
    }

    let identity = RobotIdentity(hardwareID: "hw-1", name: "testbot", daemonVersion: "1.9.0")

    private let lock = NSLock()
    private var states: [Components.Schemas.DaemonState]
    private var probeResults: [ProbeResult]
    private var steps: [Step] = []
    private var probeCount = 0
    private let daemonError: String?
    private let handshakeError: Error?
    private let startKeepsStateStopped: Bool
    private var statusFails = false

    /// `states` is consumed one entry per status read, then the last entry repeats.
    /// `probeResults` behaves the same way for readiness probes.
    init(
        states: [Components.Schemas.DaemonState] = [.running],
        probeResults: [ProbeResult] = [.ok],
        daemonError: String? = nil,
        handshakeError: Error? = nil,
        startKeepsStateStopped: Bool = false
    ) {
        self.states = states
        self.probeResults = probeResults
        self.daemonError = daemonError
        self.handshakeError = handshakeError
        self.startKeepsStateStopped = startKeepsStateStopped
    }

    var probeCalls: Int {
        lock.withLock { probeCount }
    }

    var recordedSteps: [Step] {
        lock.withLock { steps }
    }

    func failStatusFromNowOn() {
        lock.withLock { statusFails = true }
    }

    private func nextState() -> Components.Schemas.DaemonState {
        lock.withLock { states.count > 1 ? states.removeFirst() : (states.first ?? .running) }
    }

    private func status(for state: Components.Schemas.DaemonState) -> Components.Schemas.DaemonStatus {
        // A torn-down backend really does answer `backend_status: null`.
        let backend = state == .running
            ? #"{"ready": true, "motor_control_mode": "enabled", "last_alive": null, "control_loop_stats": {}}"#
            : "null"
        let errorField = daemonError.map { #""error": "\#($0)","# } ?? ""
        let json = """
        {"robot_name": "testbot", "state": "\(state.rawValue)", "wireless_version": false,
         "desktop_app_daemon": false, "simulation_enabled": true, "mockup_sim_enabled": false,
         \(errorField)
         "backend_status": \(backend)}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        if let handshakeError {
            throw handshakeError
        }
        return .init(identity: identity, status: status(for: nextState()))
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        if lock.withLock({ statusFails }) {
            throw URLError(.cannotConnectToHost)
        }
        return status(for: nextState())
    }

    func probeBackendReady() async throws {
        let result: ProbeResult = lock.withLock {
            probeCount += 1
            return probeResults.count > 1 ? probeResults.removeFirst() : (probeResults.first ?? .ok)
        }
        switch result {
        case .ok: return
        case .notReady: throw ReachyKitError.backendNotRunning
        case .broken: throw URLError(.timedOut)
        // Outlives the disconnect without stalling the suite: `disconnect()` only
        // invalidates the attempt, it does not cancel a probe already in flight.
        case .slow: try await Task.sleep(for: .milliseconds(300))
        }
    }

    func startDaemon(wakeUp: Bool) async throws {
        lock.withLock {
            steps.append(.startDaemon(wakeUp: wakeUp))
            if !startKeepsStateStopped {
                states = [.running]
            }
        }
    }

    func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        lock.withLock { steps.append(.motorMode(mode)) }
    }

    func wakeUp() async throws -> String {
        lock.withLock { steps.append(.wakeUp) }
        return "wake-uuid"
    }

    func gotoSleep() async throws -> String {
        "sleep-uuid"
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        []
    }
}

@MainActor
@Suite("RobotSession connection stages", .timeLimit(.minutes(1)))
struct RobotSessionConnectionTests {
    private func makeSession(
        client: ReadinessMockClient,
        readinessMs: Int = 200,
        pollMs: Int = 20,
        startTimeoutMs: Int = 200
    ) -> RobotSession {
        var config = RobotSession.Configuration()
        config.pollInterval = .milliseconds(pollMs)
        config.readinessTimeout = .milliseconds(readinessMs)
        config.readinessPollInterval = .milliseconds(10)
        config.daemonStartTimeout = .milliseconds(startTimeoutMs)
        return RobotSession(configuration: config) { _ in client }
    }

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: Duration = .seconds(5)
    ) async {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < timeout {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func backendUnavailableMessage(_ phase: RobotSession.ConnectionPhase) -> String?? {
        guard case let .connecting(.backendUnavailable(_, message)) = phase else { return nil }
        return .some(message)
    }

    // MARK: Readiness gate

    @Test("running backend that answers the probe connects")
    func readyBackendConnects() async {
        let client = ReadinessMockClient()
        let session = makeSession(client: client)

        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        #expect(session.phase == .connected(client.identity))
        #expect(client.probeCalls == 1)
        session.disconnect()
    }

    @Test("a completed handshake records the robot under its identity")
    func remembersRobot() async {
        let client = ReadinessMockClient(states: [.running])
        let session = makeSession(client: client)
        KnownRobots.forget(client.identity.deduplicationKey)

        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        let remembered = KnownRobots.all.first { $0.key == client.identity.deduplicationKey }
        #expect(remembered?.name == "testbot")
        #expect(remembered?.address.host == "10.0.0.9")
        session.disconnect()
        KnownRobots.forget(client.identity.deduplicationKey)
    }

    @Test("stopped backend halts on the readiness step without probing")
    func stoppedBackendHalts() async {
        let client = ReadinessMockClient(states: [.stopped])
        let session = makeSession(client: client)

        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        #expect(session.phase == .connecting(.backendUnavailable(client.identity, daemonMessage: nil)))
        // Nothing to probe: the daemon already said the backend is down.
        #expect(client.probeCalls == 0)
        #expect(KnownRobots.lastAddress?.host == "10.0.0.9")

        // The health poll must not run yet — it would clobber the connecting phase.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(session.phase == .connecting(.backendUnavailable(client.identity, daemonMessage: nil)))
        session.disconnect()
    }

    @Test("a backend stuck behind its ready flag gives up after the budget")
    func neverReadyGivesUp() async {
        let client = ReadinessMockClient(probeResults: [.notReady])
        let session = makeSession(client: client, readinessMs: 150)

        let start = ContinuousClock.now
        await session.connect(to: RobotAddress(host: "10.0.0.9"))
        let elapsed = start.duration(to: .now)

        #expect(backendUnavailableMessage(session.phase) != nil)
        // Retry behavior is covered by `readyRaceResolves`. Here both a premature
        // failure and the real timeout end in the same phase, so duration is the
        // assertion: the former returns immediately, while the latter waits out the
        // configured budget. The upper bound only prevents an unbounded regression.
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(10))
        session.disconnect()
    }

    @Test("the running-before-ready race resolves once the probe passes")
    func readyRaceResolves() async {
        let client = ReadinessMockClient(probeResults: [.notReady, .notReady, .ok])
        // A budget big enough that the deadline can't cut the sequence short on a
        // loaded runner — giving up in time is `neverReadyGivesUp`'s job, not this one.
        let session = makeSession(client: client, readinessMs: 5000)

        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        #expect(session.phase == .connected(client.identity))
        #expect(client.probeCalls == 3)
        session.disconnect()
    }

    @Test("a probe failure that isn't 503 fails the readiness stage")
    func brokenProbeFailsStage() async {
        let client = ReadinessMockClient(probeResults: [.broken])
        let session = makeSession(client: client)

        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        guard case let .connecting(.failed(stage, message)) = session.phase else {
            Issue.record("expected a failed readiness step, got \(session.phase)")
            return
        }
        #expect(stage == .backend)
        #expect(!message.isEmpty)
    }

    @Test("a faulted daemon surfaces its own message immediately")
    func daemonFaultIsReportedAtOnce() async {
        let client = ReadinessMockClient(states: [.error], daemonError: "Power supply not connected")
        let session = makeSession(client: client, readinessMs: 5000)

        let start = ContinuousClock.now
        await session.connect(to: RobotAddress(host: "10.0.0.9"))
        let elapsed = start.duration(to: .now)

        #expect(
            session.phase == .connecting(
                .backendUnavailable(client.identity, daemonMessage: "Power supply not connected")
            )
        )
        // Terminal states must short-circuit rather than burn the whole budget.
        #expect(elapsed < .seconds(1))
        session.disconnect()
    }

    @Test("a starting backend is waited out")
    func startingBackendIsWaitedOut() async {
        let client = ReadinessMockClient(states: [.starting, .starting, .running])
        let session = makeSession(client: client, readinessMs: 2000)

        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        #expect(session.phase == .connected(client.identity))
        session.disconnect()
    }

    // MARK: Actions offered on the readiness step

    @Test("starting the backend from the stepper never moves the robot")
    func startBackendDoesNotMoveTheRobot() async {
        let client = ReadinessMockClient(states: [.stopped])
        let session = makeSession(client: client)
        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        await session.startBackend()

        #expect(client.recordedSteps.contains(.startDaemon(wakeUp: false)))
        // `wake_up=true` would have the daemon power the motors and play the
        // wake-up animation by itself — the user asked for neither.
        #expect(!client.recordedSteps.contains(.wakeUp))
        #expect(!client.recordedSteps.contains(.motorMode(.enabled)))
        #expect(session.phase == .connected(client.identity))
        session.disconnect()
    }

    @Test("a backend that refuses to start stays on the readiness step")
    func startBackendFailureStaysPut() async {
        let client = ReadinessMockClient(states: [.stopped], startKeepsStateStopped: true)
        let session = makeSession(client: client)
        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        await session.startBackend()

        #expect(backendUnavailableMessage(session.phase) != nil)
        #expect(session.robotError != nil)
        #expect(session.powerTransition == nil)
        session.disconnect()
    }

    @Test("proceeding without a backend connects and starts health polling")
    func proceedWithoutBackendStartsPolling() async {
        let client = ReadinessMockClient(states: [.stopped])
        let session = makeSession(client: client)
        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        session.proceedWithoutBackend()
        #expect(session.phase == .connected(client.identity))

        // Only a running poll loop can produce `.unreachable`.
        client.failStatusFromNowOn()
        await waitUntil(session.phase == .unreachable(client.identity))
        #expect(session.phase == .unreachable(client.identity))
        session.disconnect()
    }

    // MARK: Attempt bookkeeping

    @Test("automatic attempts fall back to idle so the candidate sweep continues")
    func automaticFailureReturnsToIdle() async {
        let client = ReadinessMockClient(handshakeError: URLError(.timedOut))
        let session = makeSession(client: client)

        await session.connect(to: RobotAddress(host: "10.0.0.9"), automatically: true)

        // ConnectionScreen's candidate loop and its 10 s rescan both gate on `.idle`;
        // latching here would silently stop the app from ever reconnecting.
        #expect(session.phase == .idle)
        #expect(session.robotError != nil)
    }

    @Test("disconnecting mid-readiness wins over a late probe result")
    func disconnectBeatsLateProbe() async {
        let client = ReadinessMockClient(probeResults: [.slow])
        let session = makeSession(client: client, readinessMs: 5000)

        let attempt = Task { await session.connect(to: RobotAddress(host: "10.0.0.9")) }
        await waitUntil(session.phase == .connecting(.checkingBackend(client.identity)))
        session.disconnect()

        _ = await attempt.value
        #expect(session.phase == .idle)

        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.phase == .idle)
    }

    @Test("a transport failure reports its cause, not the client's wrapper")
    func failureMessageIsReadable() async {
        let client = ReadinessMockClient(handshakeError: URLError(.cannotConnectToHost))
        let session = makeSession(client: client)

        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        guard case let .connecting(.failed(_, message)) = session.phase else {
            Issue.record("expected a failed step, got \(session.phase)")
            return
        }
        // The generated client wraps transport errors in a `ClientError` whose
        // description is ~20 lines of operation context and NSError internals —
        // and the cause itself is reported in this app's sentence, not URLSession's.
        #expect(message == "Nothing answered. Check that the robot is on and on this network.")
        #expect(!message.contains("_kCFStreamError"))
        #expect(message.count < 200)
    }
}
