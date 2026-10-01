import Foundation
@testable import ReachyKit
import Testing

/// The first wake-up flag over the relay: daemon 1.10.0 keeps it on the data
/// channel and nowhere else. Reply shapes are `process_command`'s in
/// `daemon/backend/abstract.py`, 1.11.0 and `main` alike.
@Suite("First wake-up over the relay", .timeLimit(.minutes(1)))
struct RemoteRobotFirstWakeUpTests {
    @Test("the flag is read off the echoed reply", arguments: [true, false])
    func readsTheFlag(_ completed: Bool) async throws {
        let channel = FakeDataChannel(replies: [
            "get_first_wake_up": #"{"command":"get_first_wake_up","is_completed":\#(completed)}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        #expect(try await connection.firstWakeUpCompleted() == completed)
    }

    /// The field name is the daemon's — `SetFirstWakeUpCmd.is_completed` — and a
    /// misspelt one would not fail anything: the model's default is `True`, so the
    /// robot would store "completed" whatever was asked for.
    @Test("the write names the field the daemon reads")
    func writesTheFlag() async throws {
        let channel = FakeDataChannel(replies: [
            "set_first_wake_up": #"{"command":"set_first_wake_up","status":"ok","is_completed":false}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        let stored = try await connection.setFirstWakeUpCompleted(false)

        #expect(stored == false)
        let sent = try JSONSerialization.jsonObject(with: Data(#require(channel.sent.first).utf8)) as? [String: Any]
        #expect(sent?["type"] as? String == "set_first_wake_up")
        #expect(sent?["is_completed"] as? Bool == false)
    }

    /// A failed write is not an `error` reply: the daemon answers `"status":
    /// "error"` with the value still on disk, so the answer is what the robot
    /// holds rather than what was asked for.
    @Test("a write the robot could not store answers the value it kept")
    func reportsWhatTheRobotKept() async throws {
        let channel = FakeDataChannel(replies: [
            "set_first_wake_up": #"{"command":"set_first_wake_up","status":"error","is_completed":false}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        #expect(try await connection.setFirstWakeUpCompleted(true) == false)
    }
}
