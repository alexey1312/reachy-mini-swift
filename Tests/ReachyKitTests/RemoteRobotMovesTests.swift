import Foundation
@testable import ReachyKit
import Testing

/// Recorded moves over the relay, against the daemon's own reply shapes
/// (`process_command` and `_handle_stop_move` in `daemon/backend/abstract.py`).
@Suite("Remote robot moves", .timeLimit(.minutes(1)))
struct RemoteRobotMovesTests {
    /// The daemon's `stop_move` ack, as it writes it.
    private static let stopAck = #"{"status": "ok", "command": "stop_move", "stopped": true}"#

    private func connection(moveRunning: Bool) -> (RemoteRobotConnection, FakeDataChannel) {
        let channel = FakeDataChannel(replies: [
            "get_state": #"{"state":{"motor_mode":"enabled","is_move_running":\#(moveRunning)}}"#,
            "stop_move": Self.stopAck,
        ])
        // Short, because a wait on the wrong reply key sits out the whole budget.
        return (RemoteRobotConnection(channel: channel, timeout: .seconds(2)), channel)
    }

    private func commands(_ channel: FakeDataChannel) -> [String] {
        channel.sent.compactMap { text in
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            return object?["type"] as? String
        }
    }

    /// The ack carries `"command": "stop_move"` beside `stopped`, and the channel
    /// routes a frame by its command first. A stop that waited on `stopped` timed
    /// out every time, after the robot had already stopped.
    @Test("a stop is answered by the daemon's own ack")
    func stopReadsTheDaemonsAck() async throws {
        let (connection, channel) = connection(moveRunning: true)

        try await connection.stopMove(uuid: "any")

        #expect(commands(channel) == ["stop_move"])
    }

    /// This connection holds a handle only for a move it started, so the listing
    /// the LAN uses would see nothing here. `is_move_running` sees every move.
    @Test("a move this connection never started is stopped")
    func stopsAMoveItDidNotStart() async throws {
        let (connection, channel) = connection(moveRunning: true)

        let stopped = try await connection.stopRunningMoves()

        #expect(stopped)
        #expect(commands(channel) == ["get_state", "stop_move"])
    }

    @Test("an idle robot is sent no stop")
    func leavesAnIdleRobotAlone() async throws {
        let (connection, channel) = connection(moveRunning: false)

        let stopped = try await connection.stopRunningMoves()

        #expect(!stopped)
        #expect(commands(channel) == ["get_state"])
    }
}
