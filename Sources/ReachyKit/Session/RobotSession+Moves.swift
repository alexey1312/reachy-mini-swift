import Foundation

/// Recorded moves: the library index, playback, and what happens when a move ends.
///
/// A file of its own for the reason `RobotSession+Apps` and `RobotSession+Power`
/// are: `RobotSession` reached SwiftLint's length limit. The three phases of
/// `MoveActivity` and every rule about the daemon's single move slot live here.
extension RobotSession {
    /// The transport's playback surface, or nil where it has none.
    ///
    /// `canPlayMoves` asks the same question and this is the answer it gets, so a
    /// screen that offers the library and a session that refuses the play cannot
    /// disagree.
    var movesClient: (any MovePlaybackClient)? {
        client as? any MovePlaybackClient
    }

    func withMovesClient<T>(_ call: (any MovePlaybackClient) async throws -> T) async throws -> T {
        guard let client else { throw ReachyKitError.notConnected }
        guard let moves = client as? any MovePlaybackClient else {
            throw ReachyKitError.movesUnavailable
        }
        return try await call(moves)
    }

    /// Returns a session-scoped cached dataset index. Actual move assets stay daemon-side.
    public func moves(in dataset: String, refresh: Bool = false) async throws -> [String] {
        if !refresh, let cached = moveCache[dataset] {
            return cached
        }
        guard let client = movesClient else { throw ReachyKitError.movesUnavailable }
        // Asked of the transport rather than read off the error it throws: a
        // sentinel `URLError` used to stand in for this, and any unrelated one
        // would have served a week-old list in place of a refusal the daemon made.
        guard client.offersMoveIndex else {
            // The relay's data channel plays moves and cannot list them. It still
            // has the list this app read off the same robot on its own network and
            // kept on disk: up to a week stale, and a dance the robot no longer
            // holds simply refuses to play, which beats a screen with nothing on it.
            guard let cached = moveCache[dataset] else { throw ReachyKitError.movesUnavailable }
            // The list came off disk, so the robot may never have been asked for
            // this dataset in this session. Warming it keeps the first tap from
            // being a download the user waits through.
            //
            // Awaited, and cheap because of what the ack means: the robot answers
            // as soon as it has started fetching, not when it has finished. A
            // detached `Task` here would outlive the call that made it and reach
            // the session from off the main actor — which showed up as a layout
            // assertion in an unrelated snapshot test, three hundred tests later.
            try? await client.preload(dataset: dataset)
            return cached
        }
        let moves = try await client.listMoves(dataset: dataset)
        moveCache[dataset] = moves
        await persistMoveIndex()
        return moves
    }

    /// Throws rather than reporting: a move that would not play is the moves
    /// screen's news, and `MovesModel` is what puts it on screen.
    public func playMove(dataset: String, move: String) async throws {
        guard let client = movesClient else { throw ReachyKitError.movesUnavailable }
        // Whatever the robot is doing has to be off the daemon's task list before
        // the new move is asked for. The daemon does not refuse a play over a
        // running move — both run, and both write the head target — so a floor
        // that will not clear throws here and the play is never sent.
        try await clearTheFloor(client: client)
        let identity = MovePlayback.Identity(dataset: dataset, move: move)
        let uuid: String
        do {
            uuid = try await client.playMove(dataset: dataset, move: move)
        } catch {
            // A timeout is not a refusal. The daemon answers a play only after it
            // has loaded the dataset, and it starts the move whether or not anybody
            // still waits for the reply — so the robot is asked first.
            guard Self.isTimeout(error), await adoptTimedOutPlay(identity, client: client) else { throw error }
            return
        }
        follow(MovePlayback(uuid: uuid, identity: identity), client: client)
    }

    /// Re-reads the daemon's move list at once rather than waiting for the poll.
    ///
    /// The poll is the only thing that notices a dance ending, and it sleeps with
    /// the process — so a phone locked mid-dance comes back to a Stop button over
    /// a move the daemon has already forgotten, and pressing it is a 500 (see
    /// `stopMove`). It is also what silences the music: `play_move` fires
    /// `play_sound` and never waits for it, so a track longer than its dance plays
    /// on until this client says otherwise, and nothing on the robot will.
    ///
    /// One miss settles it here, against the poll's two: this is asked after a gap
    /// rather than in the moments a play is still being registered.
    public func refreshMoveActivity() async {
        // A parking with no uuid yet is `recentre`'s, awaiting its own reply.
        guard let client = movesClient, let activity = moveActivity, let uuid = activity.uuid,
              !isStoppingMove
        else { return }
        guard let running = try? await client.runningMoveUUIDs() else { return }
        guard moveActivity?.uuid == uuid, !running.contains(uuid) else { return }
        await finish(activity, client: client)
    }

    /// Frees the daemon's move slot before a power transition claims it.
    ///
    /// `goto_sleep` is a move task like any dance, and the daemon runs it beside
    /// one that is playing: the two write the head target in turn, and
    /// `set_mode/disabled` cuts the motors a moment later, mid-pose. This is the
    /// motion half of what `releaseRunningApp()` does for a running app — hand the
    /// robot back before parking it. Parking is skipped here because the
    /// transition *is* the parking.
    ///
    /// Asked even when this session remembers no move, because the daemon may run
    /// one it never heard of. Best effort: a move that will not stop is no reason
    /// to leave the robot awake.
    func releaseMove() async {
        guard let client = movesClient else { return }
        try? await clearTheFloor(client: client)
    }

    /// Ends every move the daemon runs, so a new one does not play beside it.
    ///
    /// `play_move` guards the daemon's one move slot with a non-blocking
    /// `RLock.acquire` (`backend/abstract.py`), and every HTTP, WebSocket and
    /// data-channel route runs it as a coroutine on the one event-loop thread. The
    /// lock is re-entrant on that thread, so the guard never refuses: a second play
    /// starts, both write the head target at 100 Hz, and its `play_sound` restarts
    /// the music. So `moveActivity` is not enough — a move from the widget, from
    /// another device or from before a relaunch is stopped too. Throws when a move
    /// will not stop, because a play sent over it is that collision.
    ///
    /// Parking is deliberately skipped: it is a move task of its own, so returning
    /// to neutral here would put a `goto` beside the very play this clears the
    /// way for.
    private func clearTheFloor(client: any MovePlaybackClient) async throws {
        switch moveActivity {
        case .playing, .stopping:
            _ = await stopMove(parking: false)
        case let .recentring(uuid):
            if let uuid {
                try? await client.stopMove(uuid: uuid)
            }
            movePollTask?.cancel()
            movePollTask = nil
            moveActivity = nil
        case nil:
            break
        }
        // The sound player is a task of its own and outlives a stopped motion.
        if try await client.stopRunningMoves() {
            try? await client.stopSound()
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
        guard let client = movesClient, let playback = currentMove, !isStoppingMove else { return [] }
        moveActivity = .stopping(playback)
        movePollTask?.cancel()
        movePollTask = nil

        let result = await withTaskGroup(
            of: (failure: String?, moveWasCancelled: Bool).self,
            returning: (failures: [String], moveWasCancelled: Bool).self
        ) { group in
            group.addTask {
                do {
                    try await client.stopMove(uuid: playback.uuid)
                    return (nil, false)
                } catch {
                    // A refusal says nothing on its own. `stop_move_task` raises a
                    // bare `KeyError` for a uuid it no longer holds — a 500 rather
                    // than a 404, and the uuid is popped the instant the move's
                    // coroutine ends — so a dance that finished while nothing was
                    // watching answers exactly like a robot that would not listen.
                    // Who is running tells the two apart, and only the second may
                    // cost the parking.
                    if let running = try? await client.runningMoveUUIDs(),
                       !running.contains(playback.uuid)
                    {
                        return (nil, false)
                    }
                    guard let message = Self.message(for: error) else { return (nil, true) }
                    return ("Move: \(message)", false)
                }
            }
            group.addTask {
                do {
                    try await client.stopSound()
                    return (nil, false)
                } catch {
                    return (Self.message(for: error).map { "Sound: \($0)" }, false)
                }
            }

            var failures: [String] = []
            var moveWasCancelled = false
            for await result in group {
                if let failure = result.failure {
                    failures.append(failure)
                }
                moveWasCancelled = moveWasCancelled || result.moveWasCancelled
            }
            return (failures, moveWasCancelled)
        }

        guard moveActivity?.uuid == playback.uuid else { return result.failures.sorted() }
        // A cancelled stop learned nothing, so it may conclude nothing: the dance is
        // most likely still running, and both a cleared phase and a parking `goto`
        // would be claims about a robot nobody asked. It is the one path back to
        // `.playing`, and the monitor has to be restarted with it — this method
        // cancelled `movePollTask` on its way in, so a phase restored without one is
        // a Stop button that nothing will ever take off the screen.
        if result.moveWasCancelled {
            moveActivity = .playing(playback)
            startMonitoring(.playing(playback), client: client)
            return result.failures.sorted()
        }
        moveActivity = nil
        playbacks.clear()
        // A move that refused to stop is still running, and `_try_start_move` would
        // drop the parking anyway — so the only thing sending it would add is a
        // phase on screen over a robot that never left the dance.
        let stopped = !result.failures.contains { $0.hasPrefix("Move:") }
        guard parking, stopped, isAwake else { return result.failures.sorted() }
        let parkingErrors = await recentre(client: client)
        return (result.failures + parkingErrors).sorted()
    }

    /// Walks the robot back to its zero pose and follows that task to its end.
    ///
    /// The daemon does this for itself after an app releases the robot
    /// (`apps/manager.py`, "Returning robot to zero position"); a recorded move
    /// gets no such treatment and simply stops wherever its last frame left the
    /// head — which for a cancelled move is any pose at all.
    /// Not `private`: an app releasing the robot parks it the same way
    /// (`RobotSession+AppLifecycle`), and a second implementation of "go back to
    /// base" is the one that would drift from the phase this claims on screen.
    ///
    /// The phase is claimed before the `goto` is sent, not when it answers. In
    /// between, the rows were live, and a dance tapped there played beside the
    /// parking, because the daemon runs both. Over the relay that gap was the
    /// whole walk: `goto_target` answers only once it has finished.
    func recentre(client: any MovePlaybackClient) async -> [String] {
        let pending = MoveActivity.recentring(uuid: nil)
        moveActivity = pending
        do {
            let uuid = try await client.gotoNeutral(duration: configuration.recentreDuration)
            // Anything that claimed the robot while the request was in flight owns
            // it now; adopting the parking task over that would hide a real move.
            guard moveActivity == pending else { return [] }
            moveActivity = .recentring(uuid: uuid)
            startMonitoring(.recentring(uuid: uuid), client: client)
            return []
        } catch {
            if moveActivity == pending {
                moveActivity = nil
            }
            guard let message = Self.message(for: error) else { return [] }
            return ["Neutral: \(message)"]
        }
    }

    /// Polls the daemon's authoritative running-task list so natural completion
    /// clears the UI. Two misses avoid racing task registration just after play.
    ///
    /// Parking is followed the same way rather than timed against
    /// `recentreDuration`: a `goto` can be cancelled or fail, and the phase has to
    /// end when the task does, not when its nominal duration is up.
    func startMonitoring(_ activity: MoveActivity, client: any MovePlaybackClient) {
        movePollTask?.cancel()
        guard let uuid = activity.uuid else { return }
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
    private func finish(_ activity: MoveActivity, client: any MovePlaybackClient) async {
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
