import Foundation
import ReachyKit
@testable import ReachySimulator
import Testing

/// What a session gets when it connects to nothing.
@MainActor
@Suite("Simulated robot client", .timeLimit(.minutes(1)))
struct SimulatedRobotClientTests {
    /// Held still: with a real tick the walk finishes in a fraction of a second, and
    /// a move slot is only observable while the walk holding it is unfinished.
    private func stillClient() throws -> SimulatedRobotClient {
        try #require(SimulatedRobotClient(tick: .seconds(30)))
    }

    /// The opposite errand: a client whose pose actually advances, for the two
    /// tests that need a move still running.
    private func walkingClient() throws -> SimulatedRobotClient {
        try #require(SimulatedRobotClient(tick: .milliseconds(5)))
    }

    /// Walks the **pose** away from neutral, which sending a target does not do on
    /// its own: a teleop send moves the goal, and "go to neutral" moves it straight
    /// back — so a robot that never left settles the instant it is asked to return
    /// and drops the slot before anything can read it. Waits on the state stream
    /// rather than on a duration, and picks `z` because 0.05 m/s is the slowest
    /// axis the limiter has, which makes the walk back the widest window on offer.
    /// The threshold sits under the platform's own 23 mm of lift — `held(_:)` in
    /// `SimulatedRobotCore` clamps a pure-z target there, so the goal of 0.05 is
    /// unreachable on purpose and 0.04 would wait forever.
    private func moveAwayFromNeutral(_ client: SimulatedRobotClient) async {
        await client.makeTeleopChannel().send(TeleopTarget(z: 0.05))
        for await update in client.updates(.visualization) {
            if let z = update.frame?.headPose?.transform?.translation.z, z > 0.02 {
                break
            }
        }
    }

    // MARK: - What it claims to be

    /// The identity a robot cannot supply: no hardware, so no id, and
    /// `deduplicationKey` falls back to the name — which is what its own doc comment
    /// anticipates for exactly this case.
    @Test("the handshake claims the supported baseline and no hardware")
    func handshakeIsHonest() async throws {
        let client = try stillClient()
        defer { client.shutDown() }

        let handshake = try await client.handshake()

        #expect(handshake.identity.hardwareID == nil)
        #expect(handshake.identity.name == "Simulator")
        #expect(handshake.identity.daemonVersion == "1.9.0")
        // No `daemon/robot-name` route, because there is no daemon.
        #expect(handshake.supportsRename == false)
    }

    /// **The payload is what earns everything Track A wrote.** `mockup_sim_enabled`
    /// makes `flavour` answer `.mockup`, which carries the "Simulation (no physics)"
    /// caption and the sentence explaining the absent Wi-Fi, update and maintenance
    /// cards; an empty `camera_specs_name` makes `hasCamera` false with no branch
    /// anywhere. Asserted through a session rather than on the JSON, because the
    /// session is what reads it.
    @Test("a connected session names it a mockup simulator with no camera")
    func sessionSeesAMockupSimulator() async throws {
        let client = try stillClient()
        defer { client.shutDown() }
        let session = RobotSession { _ in
            Issue.record("a simulated client must not be rebuilt from an address")
            throw ReachyKitError.notConnected
        }

        let connected = await session.connect(simulating: client)

        #expect(connected)
        #expect(session.flavour == .mockup)
        #expect(session.hasCamera == false)
        #expect(session.supportsWirelessFeatures == false)
        #expect(session.address == nil)
    }

    @Test("the motors start disabled and waking enables them")
    func wakingEnablesTheMotors() async throws {
        let client = try stillClient()
        defer { client.shutDown() }

        let asleep = try await client.daemonStatus().motorControlMode
        #expect(asleep == .disabled)

        _ = try await client.wakeUp()
        let awake = try await client.daemonStatus().motorControlMode
        #expect(awake == .enabled)

        _ = try await client.gotoSleep()
        let backToSleep = try await client.daemonStatus().motorControlMode
        #expect(backToSleep == .disabled)
    }

    // MARK: - What it serves

    @Test("geometry comes out of the bundle, whole")
    func servesItsGeometry() async throws {
        let client = try stillClient()
        defer { client.shutDown() }

        let document = try await URDFParser.parse(client.urdf())
        for name in document.visualMeshFilenames {
            #expect(try await !client.stlAsset(named: name).isEmpty, "\(name)")
        }
    }

    /// The analytical engine, which is what a daemon runs unless started with
    /// `--kinematics-engine Placo`. So the client solves the 21 passive joints
    /// itself, exactly as it does against a real robot.
    @Test("it reports the engine that does not compute passive joints")
    func reportsTheAnalyticalEngine() async throws {
        let client = try stillClient()
        defer { client.shutDown() }

        let info = try await client.kinematicsInfo()

        #expect(info.providesPassiveJoints == false)
    }

    // MARK: - One move slot

    /// Recorded behaviour: a second `play_move` while one runs is accepted, answered
    /// with a plausible UUID through `create_move_task`, and moves nothing. A
    /// simulator that queued instead would make `RobotSession+Moves`' guards
    /// untestable against it.
    @Test("a second move is answered with an id it never files")
    func secondMoveIsAnsweredAndIgnored() async throws {
        let client = try walkingClient()
        defer { client.shutDown() }
        await moveAwayFromNeutral(client)

        let first = try await client.gotoNeutral(duration: 1)
        let second = try await client.gotoNeutral(duration: 1)

        let running = try await client.runningMoveUUIDs()
        #expect(first != second)
        #expect(running == [first])
    }

    @Test("stopping the running move empties the slot")
    func stoppingEmptiesTheSlot() async throws {
        let client = try walkingClient()
        defer { client.shutDown() }
        await moveAwayFromNeutral(client)
        let uuid = try await client.gotoNeutral(duration: 1)

        try await client.stopMove(uuid: uuid)

        let running = try await client.runningMoveUUIDs()
        #expect(running.isEmpty)
    }

    // MARK: - Teleop

    @Test("a teleop target reaches the state stream")
    func teleopDrivesTheStream() async throws {
        let client = try #require(SimulatedRobotClient(tick: .milliseconds(5)))
        defer { client.shutDown() }

        await client.makeTeleopChannel().send(TeleopTarget(bodyYaw: 0.6))

        var last = 0.0
        for await update in client.updates(.visualization) {
            last = try #require(update.frame?.bodyYaw)
            if last > 0.3 {
                break
            }
        }

        #expect(last > 0.3)
    }
}

private extension SimulatedRobotClient {
    /// `makeTeleop` throws by protocol; every call here is on a client that has one.
    func makeTeleopChannel() -> any TeleopChannel {
        // swiftlint:disable:next force_try
        try! makeTeleop()
    }
}
