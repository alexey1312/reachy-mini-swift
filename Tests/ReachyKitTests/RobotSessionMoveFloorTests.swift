import Foundation
@testable import ReachyKit
import Testing

/// What the session does about moves it did not see start: ones from elsewhere,
/// and one whose play timed out.
///
/// The daemon guards its one move slot with a re-entrant lock, taken on the one
/// event-loop thread every route runs on, so it never refuses a second play: both
/// moves run and both write the head target. A file of its own because
/// `RobotSessionMoveTests` is at SwiftLint's length limit.
@MainActor
@Suite("RobotSession move floor", .timeLimit(.minutes(1)))
struct RobotSessionMoveFloorTests {
    private func session(_ client: MoveRobotClient) async throws -> RobotSession {
        var configuration = RobotSession.Configuration()
        configuration.pollInterval = .seconds(60)
        configuration.movePollInterval = .seconds(5)
        let playbacks = try MovePlaybackStore(
            defaults: #require(UserDefaults(suiteName: "RobotSessionMoveFloorTests.\(UUID().uuidString)"))
        )
        let session = RobotSession(configuration: configuration, playbacks: playbacks) { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        // The adoption on connect reads the list first. A move started after it is
        // one this session has never heard of, which is the case under test.
        await waitUntil(client.runningReads >= 1)
        return session
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a play stops a move this session never started")
    func playStopsAMoveFromElsewhere() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        client.startElsewhere("widget-move")

        try await session.playMove(dataset: "library", move: "wave")

        let events = client.events
        let stop = try #require(events.firstIndex(of: "stop:widget-move"))
        let play = try #require(events.firstIndex(of: "play:library:wave"))
        #expect(stop < play)
        // Its music is a daemon task of its own and would play on under the new move.
        #expect(client.stopSoundCalls == 1)
        session.disconnect()
    }

    @Test("a play is not sent over a move that will not stop")
    func refusedStopHoldsThePlay() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        client.startElsewhere("widget-move")
        client.failStopMove = true

        await #expect(throws: MoveFailure.self) {
            try await session.playMove(dataset: "library", move: "wave")
        }

        #expect(!client.events.contains("play:library:wave"))
        #expect(session.currentMove == nil)
        session.disconnect()
    }

    /// `stop_move_task` raises a bare `KeyError` for a uuid that has just ended,
    /// so that refusal says nothing about the robot.
    @Test("a move that ends before its stop does not hold the play")
    func moveThatEndedDoesNotHoldThePlay() async throws {
        // The adoption on connect, the floor's listing, and its check after the refusal.
        let client = MoveRobotClient(running: [.running([]), .running(["ended"]), .running([])])
        let session = try await session(client)
        client.failStopMove = true

        try await session.playMove(dataset: "library", move: "wave")

        #expect(client.events.contains("stop:ended"))
        #expect(client.events.last == "play:library:wave")
        session.disconnect()
    }

    /// The daemon loads the dataset before it answers a play, and a cold download
    /// can outlast the request. It starts the move all the same, so reporting the
    /// timeout would leave a dancing robot with no Stop button.
    @Test("a play that timed out but started is adopted, under its own name")
    func timedOutPlayThatStartedIsAdopted() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        client.playTimeout = .afterStarting

        try await session.playMove(dataset: "library", move: "wave")

        #expect(session.currentMove?.uuid == "move-1")
        #expect(session.currentMove?.identity == .init(dataset: "library", move: "wave"))
        session.disconnect()
    }

    @Test("a play that timed out and started nothing reports the timeout")
    func timedOutPlayThatStartedNothingThrows() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        client.playTimeout = .beforeStarting

        await #expect(throws: URLError.self) {
            try await session.playMove(dataset: "library", move: "wave")
        }

        #expect(session.currentMove == nil)
        session.disconnect()
    }

    @Test("sleeping stops a move this session never started")
    func sleepStopsAMoveFromElsewhere() async throws {
        let client = MoveRobotClient()
        let session = try await session(client)
        client.startElsewhere("widget-move")

        await session.sleep()

        let events = client.events
        let stop = try #require(events.firstIndex(of: "stop:widget-move"))
        let sleep = try #require(events.firstIndex(of: "sleep"))
        #expect(stop < sleep)
        session.disconnect()
    }
}
