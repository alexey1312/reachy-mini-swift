import Foundation

/// Recorded moves, over the relay.
///
/// **The handles here are this app's, not the daemon's.** `play_recorded_move`
/// is fire-and-forget: the ack means "dispatched", and nothing comes back to
/// name the run. `stop_move` needs no name either — it interrupts whatever is
/// playing, whoever started it. So a handle is minted here to answer the one
/// question the session asks with it, "is the thing I started still going", and
/// it is never sent anywhere. `is_move_running` is what answers it, and it says
/// *whether*, never *which*.
///
/// A file of its own because `RemoteRobotConnection.swift` reached SwiftLint's
/// length limit; `playbackHandle` stays there, as an extension cannot store it.
public extension RemoteRobotConnection {
    /// No index route on this channel: the library comes off what this app kept
    /// from the robot's own network. See ``MovePlaybackClient/offersMoveIndex``.
    nonisolated var offersMoveIndex: Bool {
        false
    }

    /// The one place this transport is *ahead* of the HTTP one: a play there
    /// blocks until the dataset is on the robot, while `play_recorded_move` is
    /// fire-and-forget and would simply take a long time to start moving. Warming
    /// first turns that into a wait the user does not sit through.
    func preload(dataset: String) async throws {
        try await control.perform("preload_dataset", payload: ["dataset_name": .string(dataset)])
    }

    func playMove(dataset: String, move: String) async throws -> String {
        try await control.perform("play_recorded_move", payload: [
            "move_name": .string(move),
            "dataset_name": .string(dataset),
        ])
        let handle = UUID().uuidString
        playbackHandle = handle
        return handle
    }

    /// The handle this connection dispatched, while the robot reports a move
    /// running. Empty otherwise — including for a handle from a previous launch,
    /// which nothing here can recognise.
    func runningMoveUUIDs() async throws -> Set<String> {
        guard let handle = playbackHandle else { return [] }
        let running = try await isMoveRunning()
        // The `await` above is a suspension point, and this is an actor: `stopMove`
        // and `playMove` both run inside it. Answering for a handle that has since
        // been replaced would clear the new dance's handle and let its monitor
        // count two misses while the robot is still moving.
        guard playbackHandle == handle else { return [] }
        // `nil` is a daemon that cannot say, which is not "not running": treating
        // the two alike ends playback the instant it starts.
        guard let running else { return [handle] }
        if !running {
            playbackHandle = nil
        }
        return running ? [handle] : []
    }

    /// Stops whatever is playing. The handle is not sent — there is nowhere to send
    /// it — so this stops a move somebody else started too, which is what the
    /// command does and what the session wants of it.
    ///
    /// Awaited by its echoed command, not by its `stopped` key. The ack is
    /// `{"status": "ok", "command": "stop_move", "stopped": …}`, and the channel
    /// routes a frame by `command` before it looks at any other key — so a wait on
    /// `stopped` never matched and sat out the whole reply budget.
    func stopMove(uuid _: String) async throws {
        try await control.perform("stop_move")
        playbackHandle = nil
    }

    /// Asks whether the robot runs any move, and stops it when it does.
    ///
    /// The default lists handles, and this transport holds only the one it
    /// minted, so a move from the widget, another device or an earlier launch
    /// would pass unseen. `is_move_running` sees every move task, and `stop_move`
    /// stops every one of them. `nil` is a daemon that cannot say, and the stop is
    /// sent then too: the daemon acks it as a no-op when nothing runs.
    ///
    /// The ack does not wait for the move to end. The move's loop reads the stop
    /// flag every 10 ms, which is well inside the round trip before the next play
    /// arrives.
    func stopRunningMoves() async throws -> Bool {
        guard try await isMoveRunning() != false else { return false }
        try await stopMove(uuid: "")
        return true
    }

    /// Walks the head, body and antennas back to the pose `gotoNeutral` sends over
    /// HTTP — the same numbers, since the neutral is the robot's, not the route's.
    func gotoNeutral(duration: TimeInterval) async throws -> String {
        try await control.perform("goto_target", payload: [
            "head": .array([.number(0), .number(0), .number(0), .number(0), .number(0), .number(0)]),
            "antennas": .array([.number(-0.1745), .number(0.1745)]),
            "body_yaw": .number(0),
            "duration": .number(duration),
        ])
        let handle = UUID().uuidString
        playbackHandle = handle
        return handle
    }

    /// Nothing to send: `stop_move` silences the move's own sound as it interrupts
    /// it, so by the time this is reached the player is already quiet.
    func stopSound() async throws {}

    /// `get_state`'s `is_move_running`: any move task at all, with no way to ask
    /// which one.
    private func isMoveRunning() async throws -> Bool? {
        try await control.perform(
            "get_state",
            correlation: .replyKey("state"),
            expecting: StateReply.self
        ).state.isMoveRunning
    }
}
