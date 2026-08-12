import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// The robot half of a move intent. Every test here is about one of the two ways
/// the daemon fails silently: a play route that does not touch the motor mode, and
/// a `_try_start_move` guard that refuses without saying so.
@Suite("Robot move player", .timeLimit(.minutes(1)))
struct RobotMovePlayerTests {
    private let dataset = "pollen-robotics/reachy-mini-dances-library"
    private let move = "happy_dance"

    /// A wake whose animation resolves quickly, so the tests are about ordering
    /// rather than about waiting.
    private func configuration(moveCompletion: Duration = .milliseconds(50)) -> RobotSession.Configuration {
        var configuration = RobotSession.Configuration.widgetIntent
        configuration.moveCompletionTimeout = moveCompletion
        configuration.movePollInterval = .milliseconds(5)
        configuration.motorSettleDelay = .milliseconds(1)
        return configuration
    }

    private func player(_ client: StubMovesClient, assumeAwake: Bool? = nil) -> RobotMovePlayer {
        RobotMovePlayer(client: client, configuration: configuration(), assumeAwake: assumeAwake)
    }

    // MARK: - Waking

    /// The whole reason this type exists. A play route never touches the motor
    /// mode, so an asleep robot accepts the call, makes the sound and does not
    /// move — and the intent would have reported success over it.
    @Test("an asleep robot is woken before the move is played")
    func wakesBeforePlaying() async throws {
        let client = StubMovesClient()
        client.isAwake = false

        _ = try await player(client).play(dataset: dataset, move: move)

        let calls = client.calls
        let wake = try #require(calls.firstIndex(of: .setMotorMode(.enabled)))
        let play = try #require(calls.firstIndex(of: .playMove(dataset: dataset, move: move)))
        #expect(wake < play)
        #expect(calls.contains(.wakeUp))
    }

    @Test("an awake robot is not woken")
    func leavesAnAwakeRobotAlone() async throws {
        let client = StubMovesClient()

        _ = try await player(client).play(dataset: dataset, move: move)

        #expect(client.calls.contains(.wakeUp) == false)
        #expect(client.calls.contains(.setMotorMode(.enabled)) == false)
    }

    /// The wake animation is itself a move task, so it holds the very slot the
    /// dance needs. Someone who asked for a dance asked for the dance.
    @Test("a wake animation still in flight is stopped rather than played over")
    func stopsItsOwnWakeAnimation() async throws {
        let client = StubMovesClient()
        client.isAwake = false

        _ = try await player(client, assumeAwake: nil).play(dataset: dataset, move: move)

        let calls = client.calls
        #expect(calls.contains(.playMove(dataset: dataset, move: move)))
        // Either the animation finished inside the completion budget, or it was
        // cleared — both end with an empty slot, which is the invariant. What must
        // never happen is a play issued while it is still there.
        let play = try #require(calls.firstIndex(of: .playMove(dataset: dataset, move: move)))
        let lastRunningCheck = try #require(calls.lastIndex(of: .runningMoves))
        #expect(lastRunningCheck < play)
    }

    /// A cold backend start is ninety seconds and this process has fifteen, so the
    /// move is refused rather than raced — the same answer `RobotAppLauncher` gives.
    @Test("a torn-down backend is started and the move refused")
    func refusesWhileTheBackendStarts() async throws {
        let client = StubMovesClient()
        client.isBackendRunning = false

        await #expect(throws: RobotMovePlayer.Failure.startingBackend) {
            _ = try await player(client).play(dataset: dataset, move: move)
        }

        #expect(client.calls.contains(.startDaemon(wakeUp: true)))
        #expect(client.calls.contains {
            if case .playMove = $0 {
                true
            } else {
                false
            }
        } == false)
    }

    /// A snapshot may be believed when it says awake and never when it says asleep:
    /// `isAwake` is false for a parked robot *and* for a torn-down backend, and the
    /// two need opposite sequences.
    @Test("a reading that says awake saves the round trip; one that says asleep does not")
    func trustsOnlyTheAwakeReading() async throws {
        let trusted = StubMovesClient()
        _ = try await player(trusted, assumeAwake: true).play(dataset: dataset, move: move)
        #expect(trusted.calls.contains(.daemonStatus) == false)

        let doubted = StubMovesClient()
        _ = try await player(doubted, assumeAwake: false).play(dataset: dataset, move: move)
        #expect(doubted.calls.contains(.daemonStatus))
    }

    // MARK: - The move slot

    /// `play_move` takes its guard non-blocking and answers with a plausible UUID
    /// either way, so a play over a running move is accepted and moves nothing.
    @Test("a running move is stopped before the new one is played")
    func clearsTheSlotFirst() async throws {
        let client = StubMovesClient()
        client.running = ["old-uuid"]

        _ = try await player(client).play(dataset: dataset, move: move)

        let calls = client.calls
        let stop = try #require(calls.firstIndex(of: .stopMove("old-uuid")))
        let play = try #require(calls.firstIndex(of: .playMove(dataset: dataset, move: move)))
        #expect(stop < play)
    }

    /// A stop that answered 200 is the proof the slot is free, so a stop that threw
    /// means it is not — and playing into it would be accepted and do nothing.
    @Test("a refused stop aborts the play rather than issuing it anyway")
    func refusesToPlayIntoABusySlot() async throws {
        let client = StubMovesClient()
        client.running = ["old-uuid"]
        client.stopMoveFails = true

        await #expect(throws: StubMovesClient.Refused.self) {
            _ = try await player(client).play(dataset: dataset, move: move)
        }

        #expect(client.calls.contains {
            if case .playMove = $0 {
                true
            } else {
                false
            }
        } == false)
    }

    /// A `goto` is a move task of its own, so parking between two dances would
    /// occupy the slot the second one needs.
    @Test("replacing a move does not park in between")
    func neverParksBetweenTwoMoves() async throws {
        let client = StubMovesClient()
        client.running = ["old-uuid"]

        _ = try await player(client).play(dataset: dataset, move: move)

        #expect(client.calls.contains(.gotoNeutral) == false)
    }

    // MARK: - Stopping

    @Test("stopping parks the robot at zero")
    func parksAfterAStop() async throws {
        let client = StubMovesClient()
        client.running = ["old-uuid"]

        #expect(try await player(client).stop())

        let calls = client.calls
        let stop = try #require(calls.firstIndex(of: .stopMove("old-uuid")))
        let park = try #require(calls.firstIndex(of: .gotoNeutral))
        #expect(stop < park)
    }

    /// Not a failure — the caller has a different sentence for it.
    @Test("stopping nothing answers false and touches neither the motors nor the sound")
    func stopsNothingQuietly() async throws {
        let client = StubMovesClient()

        #expect(try await player(client).stop() == false)

        #expect(client.calls == [.runningMoves])
    }

    /// The daemon's media player owns recorded audio separately from the move task,
    /// so a move out of the music library goes on playing over the silence.
    @Test("stopping a move stops its sound too")
    func stopsTheSoundAsWell() async throws {
        let client = StubMovesClient()
        client.running = ["old-uuid"]

        _ = try await player(client).stop()

        #expect(client.calls.contains(.stopSound))
    }
}
