import Foundation
@testable import ReachyKit
import Testing

private enum MoveProbe {
    case running(Set<String>)
    case failure
}

private enum MoveFailure: Error, CustomStringConvertible {
    case failed
    var description: String {
        "failed"
    }
}

private final class MoveRobotClient: RobotAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var nextUUID = 0
    private var running: [MoveProbe]
    private var activeUUID: String?
    var failStopMove = false
    var failStopSound = false
    var failGotoNeutral = false
    private(set) var listCalls = 0
    private(set) var events: [String] = []
    private(set) var stopSoundCalls = 0
    private(set) var gotoNeutralCalls = 0
    private(set) var lastGotoUUID: String?

    private let awake: Bool

    init(running: [MoveProbe] = [], awake: Bool = true) {
        self.running = running
        self.awake = awake
    }

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name":"testbot","state":"running","wireless_version":false,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":{"motor_control_mode":"\(awake ? "enabled" : "disabled")","error":null}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: .init(hardwareID: "hw", name: "testbot", daemonVersion: "1.9.0"), status: status)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        status
    }

    func wakeUp() async throws -> String {
        "wake"
    }

    func gotoSleep() async throws -> String {
        lock.withLock { events.append("sleep") }
        return "sleep"
    }

    func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        lock.withLock { events.append("motors:\(mode.rawValue)") }
    }

    func listMoves(dataset _: String) async throws -> [String] {
        lock.withLock { listCalls += 1 }
        return ["happy_move", "wave"]
    }

    func playMove(dataset: String, move: String) async throws -> String {
        lock.withLock {
            nextUUID += 1
            activeUUID = "move-\(nextUUID)"
            events.append("play:\(dataset):\(move)")
            return activeUUID!
        }
    }

    func gotoNeutral(duration _: Double) async throws -> String {
        let shouldFail = lock.withLock {
            nextUUID += 1
            activeUUID = "goto-\(nextUUID)"
            lastGotoUUID = activeUUID
            gotoNeutralCalls += 1
            events.append("goto:\(activeUUID!)")
            return failGotoNeutral
        }
        if shouldFail {
            throw MoveFailure.failed
        }
        return lock.withLock { activeUUID! }
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        let probe = lock.withLock {
            running.isEmpty ? MoveProbe.running(activeUUID.map { [$0] } ?? []) : running.removeFirst()
        }
        switch probe {
        case let .running(uuids): return uuids
        case .failure: throw MoveFailure.failed
        }
    }

    func stopMove(uuid: String) async throws {
        let shouldFail = lock.withLock {
            events.append("stop:\(uuid)")
            activeUUID = nil
            return failStopMove
        }
        if shouldFail {
            throw MoveFailure.failed
        }
    }

    func stopSound() async throws {
        let shouldFail = lock.withLock {
            stopSoundCalls += 1
            events.append("sound")
            return failStopSound
        }
        if shouldFail {
            throw MoveFailure.failed
        }
    }
}

@MainActor
@Suite("RobotSession moves")
struct RobotSessionMoveTests {
    /// Every session gets a store of its own unless a test deliberately shares one:
    /// `--parallel` runs suites concurrently against a single `UserDefaults` table.
    private func session(
        _ client: MoveRobotClient,
        movePoll: Duration = .seconds(5),
        playbacks: MovePlaybackStore? = nil
    ) async throws -> RobotSession {
        var configuration = RobotSession.Configuration()
        configuration.pollInterval = .seconds(60)
        configuration.movePollInterval = movePoll
        let session = try RobotSession(
            configuration: configuration,
            playbacks: playbacks ?? isolatedPlaybacks()
        ) { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        return session
    }

    private func isolatedPlaybacks() throws -> MovePlaybackStore {
        try MovePlaybackStore(
            defaults: #require(UserDefaults(suiteName: "RobotSessionMoveTests.\(UUID().uuidString)"))
        )
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("dataset results are cached until an explicit refresh")
    func cacheAndRefresh() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        #expect(try await session.moves(in: "library") == ["happy_move", "wave"])
        _ = try await session.moves(in: "library")
        #expect(client.listCalls == 1)
        _ = try await session.moves(in: "library", refresh: true)
        #expect(client.listCalls == 2)
        session.disconnect()
    }

    @Test("replacing playback stops the old move before starting the new one")
    func replacementOrdering() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "first")
        try await session.playMove(dataset: "library", move: "second")
        let events = client.events
        #expect(events.first == "play:library:first")
        #expect(try #require(events.firstIndex(of: "stop:move-1")) < events.firstIndex(of: "play:library:second")!)
        #expect(session.currentMove?.uuid == "move-2")
        session.disconnect()
    }

    @Test("stop reports deterministic partial failures and clears playback")
    func stopFailures() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "first")
        client.failStopMove = true
        client.failStopSound = true
        // Returned rather than reported: both tasks are seen through, so there is
        // no single failure to throw and nothing for the session to hold.
        let failures = await session.stopMove()
        #expect(session.currentMove == nil)
        #expect(failures == ["Move: failed", "Sound: failed"])
        #expect(session.robotError == nil)
        session.disconnect()
    }

    @Test("connecting to a robot already playing restores the activity without a name")
    func restoresUnidentifiedPlayback() async throws {
        let client = MoveRobotClient(running: [.running(["stranger"])])
        let session = try await session(client)
        await waitUntil(session.currentMove != nil)
        #expect(session.currentMove?.uuid == "stranger")
        #expect(session.currentMove?.identity == nil)
        session.disconnect()
    }

    @Test("a relaunch names the move this app started")
    func restoresIdentifiedPlayback() async throws {
        let playbacks = try isolatedPlaybacks()
        let first = try await session(MoveRobotClient(), playbacks: playbacks)
        try await first.playMove(dataset: "library", move: "wave")
        let uuid = try #require(first.currentMove?.uuid)

        // The process dies mid-dance: nothing is stopped and nothing is torn down,
        // which is exactly what a force-quit looks like from the robot's side.
        let second = try await session(
            MoveRobotClient(running: [.running([uuid])]),
            playbacks: playbacks
        )
        await waitUntil(second.currentMove != nil)
        #expect(second.currentMove?.identity == .init(dataset: "library", move: "wave"))
        second.disconnect()
        first.disconnect()
    }

    /// `wake_up` and `goto_sleep` are `create_move_task` calls like any dance, so
    /// `/api/move/running` cannot tell them apart. Adopting one would report the
    /// robot's own standing-up animation as something the user put on.
    @Test("a move task belonging to a power transition is not adopted")
    func skipsAdoptionDuringPowerTransition() async throws {
        let client = MoveRobotClient(running: [.running([]), .running(["wake-up-task"])])
        let session = try await session(client)
        session.powerTransition = .wakingUp
        session.restoreActiveMove(client: client)
        await waitUntil(session.currentMove != nil)
        #expect(session.currentMove == nil)
        session.disconnect()
    }

    @Test("stopping a move parks the robot at neutral")
    func stopReturnsToNeutral() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "wave")
        let failures = await session.stopMove()
        #expect(failures.isEmpty)
        #expect(client.gotoNeutralCalls == 1)
        #expect(session.isRecentring)
        #expect(session.currentMove == nil)
        session.disconnect()
    }

    /// A move that would not stop is still running, and `_try_start_move` would
    /// refuse the parking anyway. Sending it would only add a phase over a robot
    /// that never left the dance.
    @Test("a refused stop does not park the robot")
    func refusedStopSkipsNeutral() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "wave")
        client.failStopMove = true
        _ = await session.stopMove()
        #expect(client.gotoNeutralCalls == 0)
        #expect(session.isRecentring == false)
        session.disconnect()
    }

    @Test("an asleep robot is not parked")
    func asleepRobotSkipsNeutral() async throws {
        let client = MoveRobotClient(awake: false)
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "wave")
        _ = await session.stopMove()
        #expect(client.gotoNeutralCalls == 0)
        session.disconnect()
    }

    /// The parking is a move task of its own, so sending it between two dances
    /// would have `_try_start_move` refuse the second one.
    @Test("starting the next move stops the old one without parking")
    func replacementSkipsNeutral() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "first")
        try await session.playMove(dataset: "library", move: "second")
        #expect(client.gotoNeutralCalls == 0)
        session.disconnect()
    }

    @Test("a move started while parking cancels the parking first")
    func playCancelsRecentring() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "wave")
        _ = await session.stopMove()
        let parkingUUID = try #require(client.lastGotoUUID)
        #expect(session.isRecentring)

        try await session.playMove(dataset: "library", move: "nod")
        let events = client.events
        #expect(try #require(events.firstIndex(of: "stop:\(parkingUUID)")) < events.count - 1)
        #expect(events.last == "play:library:nod")
        #expect(session.isRecentring == false)
        session.disconnect()
    }

    @Test("a move that ends on its own parks the robot")
    func naturalCompletionParks() async throws {
        let client = MoveRobotClient(running: [.running([]), .running([]), .running([])])
        let session = try await session(client, movePoll: .milliseconds(20))
        try await session.playMove(dataset: "library", move: "wave")
        await waitUntil(client.gotoNeutralCalls == 1)
        #expect(client.gotoNeutralCalls == 1)
        #expect(client.stopSoundCalls == 1)
        session.disconnect()
    }

    @Test("a refused parking is reported alongside the stop")
    func parkingFailureIsReported() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "wave")
        client.failGotoNeutral = true
        let failures = await session.stopMove()
        #expect(failures == ["Neutral: failed"])
        #expect(session.isRecentring == false)
        session.disconnect()
    }

    /// `goto_sleep` is a move task, so `_try_start_move` refuses it while a dance
    /// is running — the animation is silently skipped and the motors go anyway.
    /// The move has to be off the daemon's list first, exactly as the running app
    /// is handed back first.
    @Test("sleeping stops a running move before the parking animation")
    func sleepStopsMove() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "wave")
        await session.sleep()
        let events = client.events
        let stopIndex = try #require(events.firstIndex(of: "stop:move-1"))
        let sleepIndex = try #require(events.firstIndex(of: "sleep"))
        #expect(stopIndex < sleepIndex)
        // The sleep animation is the parking; a neutral goto would only fight it.
        #expect(client.gotoNeutralCalls == 0)
        #expect(session.currentMove == nil)
        session.disconnect()
    }

    @Test("transient poll errors and a hit reset completion hysteresis")
    func naturalCompletionHysteresis() async throws {
        let client = MoveRobotClient(running: [
            // The connect-time adoption probe consumes the first answer.
            .running([]),
            .failure, .running([]), .running(["move-1"]), .running([]), .running([]),
        ])
        let session = try await session(client, movePoll: .milliseconds(20))
        try await session.playMove(dataset: "library", move: "first")
        await waitUntil(session.currentMove == nil)
        #expect(session.currentMove == nil)
        #expect(client.stopSoundCalls == 1)
        session.disconnect()
    }
}
