import Foundation
@testable import ReachyKit
import Testing

/// Wake and sleep are multi-step protocols against the daemon, and the order is
/// not a detail: cutting motor power before the sleep animation finishes drops
/// the head wherever it happens to be.
@Suite("Robot power", .timeLimit(.minutes(1)))
struct RobotPowerTests {
    /// The progress the wait reports, collected off whatever executor each poll
    /// resumes on.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [Double] = []

        var values: [Double] {
            lock.lock()
            defer { lock.unlock() }
            return collected
        }

        func append(_ fraction: Double) {
            lock.lock()
            collected.append(fraction)
            lock.unlock()
        }
    }

    private final class Client: RobotAPIClient, MovePlaybackClient, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var running: Set<String> = []
        var wakeFailure: (any Error)?
        /// What `daemon/status` answers. `.stopped` is what `daemon/stop` — the
        /// app's Power off — leaves behind, with the daemon's HTTP server still up.
        var state: Components.Schemas.DaemonState = .running
        /// A backend that changes state under a poll, which is the only shape
        /// `waitForBackendRunning` can be asked anything about. Consumed from the
        /// front; `state` answers once it runs out, so a sequence names only the
        /// steps that matter.
        var states: [Components.Schemas.DaemonState] = []

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        private func record(_ call: String) {
            lock.lock()
            calls.append(call)
            lock.unlock()
        }

        func handshake() async throws -> RobotConnection.Handshake {
            try await .init(identity: .preview, status: daemonStatus())
        }

        func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
            record("daemonStatus")
            return .preview(state: nextState())
        }

        /// Synchronous for the reason `stillRunning()` is: `NSLock` is `noasync`.
        private func nextState() -> Components.Schemas.DaemonState {
            lock.lock()
            defer { lock.unlock() }
            return states.isEmpty ? state : states.removeFirst()
        }

        func startDaemon(wakeUp: Bool) async throws {
            record("startDaemon:wakeUp=\(wakeUp)")
        }

        func wakeUp() async throws -> String {
            if let wakeFailure {
                throw wakeFailure
            }
            record("wakeUp")
            return "move-wake"
        }

        func gotoSleep() async throws -> String {
            record("gotoSleep")
            return "move-sleep"
        }

        func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
            record("motors:\(mode.rawValue)")
        }

        /// Synchronous on purpose: `NSLock` is `noasync`, because a lock held
        /// across a suspension is a deadlock waiting for the right scheduling.
        private func stillRunning() -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return running
        }

        func runningMoveUUIDs() async throws -> Set<String> {
            stillRunning()
        }
    }

    private func power(_ client: Client) -> RobotPower {
        var configuration = RobotSession.Configuration()
        // The real delays are for a robot, not for a test runner.
        configuration.motorSettleDelay = .milliseconds(1)
        configuration.movePollInterval = .milliseconds(1)
        configuration.moveCompletionTimeout = .milliseconds(50)
        return RobotPower(client: client, configuration: configuration)
    }

    /// Motors first: the play route never touches the control mode, so an asleep
    /// robot would otherwise accept the command, play the sound and not move.
    @Test("waking enables the motors before playing the animation")
    func wakesInOrder() async throws {
        let client = Client()

        try await power(client).wake()

        #expect(client.recorded == ["motors:enabled", "wakeUp"])
    }

    /// The mirror image, and the one that matters for the hardware.
    @Test("sleeping finishes the animation before cutting power")
    func sleepsInOrder() async throws {
        let client = Client()

        try await power(client).sleep()

        #expect(client.recorded == ["gotoSleep", "motors:disabled"])
    }

    /// A move still running holds the sequence up — otherwise sleep would cut
    /// power mid-animation.
    @Test("sleeping waits for the animation the daemon is still running")
    func waitsForTheAnimation() async throws {
        let client = Client()
        client.running = ["move-sleep"]

        try await power(client).sleep()

        // The wait times out rather than hanging: parking the motors matters more
        // than proof the animation ran to the end.
        #expect(client.recorded == ["gotoSleep", "motors:disabled"])
    }

    /// `motors/set_mode` sits behind `get_backend` and answers 503 once the backend
    /// is torn down, which is exactly the state Power off leaves the robot in. So
    /// the way back up is `daemon/start`, not a motor command.
    @Test("resuming a stopped backend starts it instead of sending motor commands")
    func resumeStartsAStoppedBackend() async throws {
        let client = Client()
        client.state = .stopped

        let resumption = try await power(client).resume()

        #expect(resumption == .startingBackend)
        // `wakeUp=true` is what makes this one call enough: the daemon enables the
        // motors and plays the animation itself once the backend is up.
        #expect(client.recorded == ["daemonStatus", "startDaemon:wakeUp=true"])
    }

    @Test("resuming a running backend is the ordinary wake protocol")
    func resumeWakesARunningBackend() async throws {
        let client = Client()

        let resumption = try await power(client).resume()

        #expect(resumption == .woke)
        #expect(client.recorded == ["daemonStatus", "motors:enabled", "wakeUp"])
    }

    /// A second `daemon/start` answers 409 while a job runs, so a start already in
    /// flight is reported rather than raced.
    @Test("resuming a backend already starting asks for nothing")
    func resumeLeavesAStartInFlightAlone() async throws {
        let client = Client()
        client.state = .starting

        let resumption = try await power(client).resume()

        #expect(resumption == .startingBackend)
        #expect(client.recorded == ["daemonStatus"])
    }

    // MARK: - Waiting a cold start out

    /// The budget a `LongRunningIntent` buys the time for. Poll fast, because the
    /// real interval is for a robot rather than a test runner.
    private func patientPower(_ client: Client, budget: Duration = .seconds(10)) -> RobotPower {
        var configuration = RobotSession.Configuration()
        configuration.pollInterval = .milliseconds(1)
        configuration.daemonStartTimeout = budget
        return RobotPower(client: client, configuration: configuration)
    }

    @Test("a backend that comes up is waited out, and reported on the way")
    func waitsForAStartToFinish() async {
        let client = Client()
        client.states = [.starting, .starting, .running]
        let reported = Reports()

        let running = await patientPower(client).waitForBackendRunning { reported.append($0) }

        #expect(running)
        // The system ends a background extension whose intent stops reporting, so
        // a poll that reports nothing is the failure mode this asserts against.
        #expect(reported.values.count == 3)
        #expect(reported.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    /// `.error` is a finished job, not a slow one — the daemon records a failed
    /// start that way and stops. Both branches answer `false`, so the assertion has
    /// to be the *duration*: the wrong one returns the same verdict ten seconds
    /// later, and the suite would pass green with only `test_time` grown
    /// (project rule 7).
    @Test("a failed start ends the wait rather than spending the budget")
    func aFailedStartIsNotATimeout() async {
        let client = Client()
        // Still `.starting` after the failure, so `.error` is the only thing that
        // can end this wait early — otherwise a later `.running` would, and the
        // mutation that deletes the branch would still pass.
        client.states = [.starting, .error]
        client.state = .starting
        let started = ContinuousClock.now

        let running = await patientPower(client).waitForBackendRunning()

        #expect(running == false)
        #expect(started.duration(to: .now) < .seconds(1))
    }

    /// The other half of that pair: a backend that never arrives is bounded, and
    /// the boundary is the one the robot's own start budget names.
    @Test("a start that never finishes is given up on")
    func theBudgetEndsTheWait() async {
        let client = Client()
        client.state = .starting

        let running = await patientPower(client, budget: .milliseconds(50)).waitForBackendRunning()

        #expect(running == false)
    }

    /// An intent has no screen to put an error on, so it has to be thrown rather
    /// than swallowed the way a session stores it for a view.
    @Test("a refused wake-up is thrown, not swallowed")
    func throwsOnFailure() async {
        let client = Client()
        client.wakeFailure = ReachyKitError.backendNotRunning

        await #expect(throws: ReachyKitError.backendNotRunning) {
            try await power(client).wake()
        }
    }
}
