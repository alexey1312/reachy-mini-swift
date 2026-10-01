import Foundation

/// The first wake-up flag, over the relay.
///
/// Both commands echo their name and carry the stored value under `is_completed`
/// (`process_command` in `daemon/backend/abstract.py`). A daemon before 1.10.0
/// answers neither — its `{"error": "Invalid command: …"}` names no command, so the
/// waiter is never matched and the call sits out its whole reply budget. That is
/// why ``RobotSession`` asks only once `predatesRelayCommands` is false.
extension RemoteRobotConnection: FirstWakeUpClient {
    public func firstWakeUpCompleted() async throws -> Bool {
        try await control.perform("get_first_wake_up", expecting: FirstWakeUpReply.self).isCompleted
    }

    /// The reply carries no `error` when the write fails — it says `"status":
    /// "error"` and hands back the value still on disk — so the answer is what the
    /// robot holds, read rather than assumed from the request.
    @discardableResult
    public func setFirstWakeUpCompleted(_ completed: Bool) async throws -> Bool {
        try await control.perform(
            "set_first_wake_up",
            payload: ["is_completed": .bool(completed)],
            expecting: FirstWakeUpReply.self
        ).isCompleted
    }
}

private struct FirstWakeUpReply: Decodable {
    let isCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case isCompleted = "is_completed"
    }
}
