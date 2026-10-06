import Foundation

/// Taking on a move this session did not see start: one already running at
/// connect, and one whose play timed out.
///
/// Split from `RobotSession+Moves` when that file reached SwiftLint's length
/// limit. `follow`, `startMonitoring` and `adoptTimedOutPlay` are internal only
/// because the two files share them.
extension RobotSession {
    /// Adopts whatever the daemon is already playing.
    ///
    /// `currentMove` is this process's memory of a command it issued, and a move
    /// outlives the process: force-quit the app mid-dance and the robot is still
    /// going on the next launch. The missing animation is the visible half. The
    /// other half is that `play_move` takes its guard non-blocking
    /// (`backend/abstract.py`), so a play issued over a move nobody here knows
    /// about returns a fresh UUID and moves nothing — the screen would name a
    /// dance the robot never started.
    ///
    /// `/api/move/running` carries UUIDs alone, so an adopted move has no
    /// `identity` and the screen says so rather than guessing a name.
    func restoreActiveMove(client: any MovePlaybackClient) {
        moveRestoreTask?.cancel()
        // `wake_up` and `goto_sleep` reach the daemon through `create_move_task`
        // exactly as a dance does, so `/api/move/running` cannot tell them apart.
        // A transition this session is driving is the one case where the answer is
        // known to be ours and known not to be playback.
        guard powerTransition == nil else { return }
        let attemptID = connectionAttemptID
        moveRestoreTask = Task {
            guard let running = try? await client.runningMoveUUIDs() else { return }
            guard !Task.isCancelled, connectionAttemptID == attemptID,
                  powerTransition == nil, currentMove == nil
            else { return }
            guard let playback = adoptable(from: running) else {
                playbacks.clear()
                return
            }
            if playback.identity == nil {
                // Adopted anonymously, so the stored record described something the
                // daemon has since forgotten. Keeping it risks naming the *next*
                // stranger after it.
                playbacks.clear()
            }
            moveActivity = .playing(playback)
            startMonitoring(.playing(playback), client: client)
        }
    }

    /// Which of the daemon's running tasks to adopt, and whether it can be named.
    ///
    /// The persisted record is consulted first: a UUID this app wrote is the only
    /// evidence anywhere that ties a running task to a dataset and a move name.
    /// Anything else is adopted anonymously — sorted rather than "first", because
    /// a `Set` has no order and two tasks can overlap for an instant
    /// (`_try_start_move` refuses the second one's *work*, but `create_move_task`
    /// files it either way).
    private func adoptable(from running: Set<String>) -> MovePlayback? {
        if let record = playbacks.current,
           record.robotID == connectedRobotID,
           running.contains(record.uuid)
        {
            return MovePlayback(
                uuid: record.uuid,
                identity: .init(dataset: record.dataset, move: record.move)
            )
        }
        guard let uuid = running.sorted().first else { return nil }
        return MovePlayback(uuid: uuid, identity: nil)
    }

    /// Takes on the move a timed-out play started, the way `restoreActiveMove`
    /// takes on one found at connect, so the screen offers Stop and no error.
    ///
    /// The floor was cleared just before the play, so a lone running task is that
    /// play and carries its name. Two or more are adopted without one, as
    /// `restoreActiveMove` would adopt a stranger. One re-read only: a download
    /// still running past the reply budget is missed, as before.
    func adoptTimedOutPlay(
        _ identity: MovePlayback.Identity,
        client: any MovePlaybackClient
    ) async -> Bool {
        guard let running = try? await client.runningMoveUUIDs(),
              let uuid = running.sorted().first,
              moveActivity == nil, powerTransition == nil
        else { return false }
        follow(MovePlayback(uuid: uuid, identity: running.count == 1 ? identity : nil), client: client)
        return true
    }

    /// Puts a playing move on screen, writes down its name, and watches it end.
    func follow(_ playback: MovePlayback, client: any MovePlaybackClient) {
        moveActivity = .playing(playback)
        if let robotID = connectedRobotID, let identity = playback.identity {
            playbacks.write(.init(
                robotID: robotID,
                uuid: playback.uuid,
                dataset: identity.dataset,
                move: identity.move
            ))
        }
        startMonitoring(.playing(playback), client: client)
    }
}
