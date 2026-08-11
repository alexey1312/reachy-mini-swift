import Foundation

/// Recorded moves: the library index, playback, and what happens when a move ends.
///
/// A file of its own for the reason `RobotSession+Apps` and `RobotSession+Power`
/// are: `RobotSession` reached SwiftLint's length limit. The three phases of
/// `MoveActivity` and every rule about the daemon's single move slot live here.
extension RobotSession {
    /// Returns a session-scoped cached dataset index. Actual move assets stay daemon-side.
    public func moves(in dataset: String, refresh: Bool = false) async throws -> [String] {
        if !refresh, let cached = moveCache[dataset] {
            return cached
        }
        let moves = try await withClient { try await $0.listMoves(dataset: dataset) }
        moveCache[dataset] = moves
        await persistMoveIndex()
        return moves
    }

    /// Throws rather than reporting: a move that would not play is the moves
    /// screen's news, and `MovesModel` is what puts it on screen.
    public func playMove(dataset: String, move: String) async throws {
        guard let client else { throw ReachyKitError.notConnected }
        // Whatever the robot is doing has to be off the daemon's task list before
        // the new move is asked for: `play_move` takes its guard non-blocking
        // (`backend/abstract.py`) and simply returns when something else is
        // running, so a play issued over one is accepted, filed, and moves nothing.
        await clearTheFloor(client: client)
        let uuid = try await client.playMove(dataset: dataset, move: move)
        let playback = MovePlayback(uuid: uuid, identity: .init(dataset: dataset, move: move))
        moveActivity = .playing(playback)
        if let robotID = connectedRobotID {
            playbacks.write(.init(robotID: robotID, uuid: uuid, dataset: dataset, move: move))
        }
        startMonitoring(.playing(playback), client: client)
    }

    /// Frees the daemon's move slot before a power transition claims it.
    ///
    /// `goto_sleep` is a move task like any dance, so `_try_start_move` refuses it
    /// while one is playing: the animation is skipped without a word and
    /// `set_mode/disabled` cuts the motors a moment later, mid-pose. This is the
    /// motion half of what `releaseRunningApp()` does for a running app — hand the
    /// robot back before parking it. Parking is skipped here because the
    /// transition *is* the parking.
    func releaseMove() async {
        guard moveActivity != nil, let client else { return }
        await clearTheFloor(client: client)
    }

    /// Ends whatever is running so a new move is not silently dropped.
    ///
    /// Parking is deliberately skipped: it is a move task of its own, so returning
    /// to neutral here would occupy the robot for a second and have the daemon
    /// refuse the very play this is clearing the way for.
    private func clearTheFloor(client: any RobotAPIClient) async {
        switch moveActivity {
        case .playing, .stopping:
            _ = await stopMove(parking: false)
        case let .recentring(uuid):
            try? await client.stopMove(uuid: uuid)
            movePollTask?.cancel()
            movePollTask = nil
            moveActivity = nil
        case nil:
            break
        }
    }

    /// Stops both daemon tasks: motion and the separately-owned sound player, and
    /// answers with whatever refused — empty when both stopped.
    ///
    /// Returned rather than thrown because the two are stopped in parallel and
    /// both are seen through: parking the motors matters more than reporting, so
    /// there is no single failure to throw. The caller decides what to do with
    /// the list; `MovesModel.stop` joins it into its own error slot.
    @discardableResult
    public func stopMove() async -> [String] {
        await stopMove(parking: true)
    }

    /// `parking: false` is the internal path taken when another move is about to
    /// start — see `clearTheFloor`.
    @discardableResult
    private func stopMove(parking: Bool) async -> [String] {
        guard let client, let playback = currentMove, !isStoppingMove else { return [] }
        moveActivity = .stopping(playback)
        movePollTask?.cancel()
        movePollTask = nil

        let errors = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            group.addTask {
                do {
                    try await client.stopMove(uuid: playback.uuid)
                    return nil
                } catch {
                    return "Move: \(error)"
                }
            }
            group.addTask {
                do {
                    try await client.stopSound()
                    return nil
                } catch {
                    return "Sound: \(error)"
                }
            }

            var errors: [String] = []
            for await error in group {
                if let error {
                    errors.append(error)
                }
            }
            return errors
        }

        guard moveActivity?.uuid == playback.uuid else { return errors.sorted() }
        moveActivity = nil
        playbacks.clear()
        // A move that refused to stop is still running, and `_try_start_move` would
        // drop the parking anyway — so the only thing sending it would add is a
        // phase on screen over a robot that never left the dance.
        let stopped = !errors.contains { $0.hasPrefix("Move:") }
        guard parking, stopped, isAwake else { return errors.sorted() }
        let parkingErrors = await recentre(client: client)
        return (errors + parkingErrors).sorted()
    }

    /// Walks the robot back to its zero pose and follows that task to its end.
    ///
    /// The daemon does this for itself after an app releases the robot
    /// (`apps/manager.py`, "Returning robot to zero position"); a recorded move
    /// gets no such treatment and simply stops wherever its last frame left the
    /// head — which for a cancelled move is any pose at all.
    private func recentre(client: any RobotAPIClient) async -> [String] {
        do {
            let uuid = try await client.gotoNeutral(duration: configuration.recentreDuration)
            // Anything that claimed the robot while the request was in flight owns
            // it now; adopting the parking task over that would hide a real move.
            guard moveActivity == nil else { return [] }
            moveActivity = .recentring(uuid: uuid)
            startMonitoring(.recentring(uuid: uuid), client: client)
            return []
        } catch {
            return ["Neutral: \(error)"]
        }
    }

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
    func restoreActiveMove(client: any RobotAPIClient) {
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

    /// Polls the daemon's authoritative running-task list so natural completion
    /// clears the UI. Two misses avoid racing task registration just after play.
    ///
    /// Parking is followed the same way rather than timed against
    /// `recentreDuration`: a `goto` can be cancelled or fail, and the phase has to
    /// end when the task does, not when its nominal duration is up.
    private func startMonitoring(_ activity: MoveActivity, client: any RobotAPIClient) {
        movePollTask?.cancel()
        let uuid = activity.uuid
        movePollTask = Task { [configuration] in
            var consecutiveMisses = 0
            while !Task.isCancelled, moveActivity?.uuid == uuid {
                try? await Task.sleep(for: configuration.movePollInterval)
                guard !Task.isCancelled, moveActivity?.uuid == uuid else { return }
                do {
                    let running = try await client.runningMoveUUIDs()
                    guard !Task.isCancelled, moveActivity?.uuid == uuid else { return }
                    if running.contains(uuid) {
                        consecutiveMisses = 0
                    } else {
                        consecutiveMisses += 1
                        if consecutiveMisses >= 2 {
                            await finish(activity, client: client)
                            return
                        }
                    }
                } catch {
                    // A transient status failure must not claim that playback ended.
                }
            }
        }
    }

    /// What the end of a daemon task means, which depends on which task it was.
    private func finish(_ activity: MoveActivity, client: any RobotAPIClient) async {
        switch activity {
        case .playing:
            // The sound player is a separate daemon task and outlives the motion,
            // so music keeps going over a dance that has finished.
            try? await client.stopSound()
            guard moveActivity?.uuid == activity.uuid else { return }
            moveActivity = nil
            playbacks.clear()
            movePollTask = nil
            guard isAwake else { return }
            _ = await recentre(client: client)
        case .recentring:
            guard moveActivity?.uuid == activity.uuid else { return }
            moveActivity = nil
            movePollTask = nil
        case .stopping:
            // `stopMove` owns this one and is awaiting the daemon's reply.
            break
        }
    }
}
