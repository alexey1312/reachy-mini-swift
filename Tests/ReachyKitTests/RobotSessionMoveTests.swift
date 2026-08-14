import Foundation
@testable import ReachyKit
import Testing

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

    /// The daemon pops a move's uuid the moment its task ends and then answers a
    /// stop for it with a bare `KeyError` — a 500, not a 404 (`routers/move.py`,
    /// `stop_move_task`), which is what a phone locked through the end of a dance
    /// comes back to: a live Stop button over a move nobody is running. Refusing
    /// to park after it was the expensive half — the head stays wherever the last
    /// frame left it.
    @Test("a stop refused because the move already ended is not a failure")
    func stopOverFinishedMoveIsNotAFailure() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "wave")
        client.finishMove()
        client.failStopMove = true
        let failures = await session.stopMove()
        #expect(failures.isEmpty)
        #expect(client.gotoNeutralCalls == 1)
        #expect(session.currentMove == nil)
        session.disconnect()
    }

    /// `movePollInterval` is five seconds here on purpose: the poll cannot be what
    /// notices this, so what the test asserts is the explicit ask. It is the phone
    /// coming back from a locked screen — and the sound is why it is worth a call
    /// of its own, since a recorded move's audio is a daemon task that outlives the
    /// motion and only this client ever stops it.
    @Test("returning to the app notices a move that ended while it slept")
    func refreshNoticesTheEndOfAMove() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "wave")
        client.finishMove()
        await session.refreshMoveActivity()
        #expect(session.currentMove == nil)
        #expect(client.stopSoundCalls == 1)
        #expect(client.gotoNeutralCalls == 1)
        session.disconnect()
    }

    /// The interpolated `\(error)` printed the generated client's whole
    /// `UndocumentedPayload` dump on screen, and would have printed the word
    /// "cancelled" just as faithfully. `RobotSession.message(for:)` is the one
    /// filter, and this is the half of it no other test can see.
    @Test("a cancelled stop reports nothing")
    func cancelledStopSaysNothing() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        try await session.playMove(dataset: "library", move: "wave")
        client.cancelStopMove = true
        let failures = await session.stopMove()
        #expect(failures.isEmpty)
        #expect(session.currentMove?.uuid == "move-1")
        #expect(client.gotoNeutralCalls == 0)
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
