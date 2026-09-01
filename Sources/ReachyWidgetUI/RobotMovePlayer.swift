import Foundation
import ReachyDesign
import ReachyKit

/// Playing one recorded move, with no session around it.
///
/// The twin of `RobotSession.playMove`, and deliberately not the same code — the
/// split `RobotAppLauncher` records at length. That one clears the floor against
/// state it is already holding and reports each failure onto the Moves screen;
/// this has neither, so it asks the daemon and has one sentence to answer with.
///
/// **Two daemon facts shape the whole sequence, and both fail silently.** A play
/// route does not touch the motor mode, so an asleep robot accepts it, makes the
/// sound and does not move; and `play_move` takes its guard non-blocking
/// (`backend/abstract.py`), so a play issued over a running move is accepted,
/// answered with a fresh UUID, and moves nothing. Waking and clearing the slot are
/// therefore not politeness — without either, the intent reports success over a
/// robot that did nothing at all.
public struct RobotMovePlayer: Sendable {
    public struct Outcome: Equatable, Sendable {
        /// The daemon's task id, which is the only handle on a running move —
        /// `MovePlaybackRecord` is what turns it back into a name.
        public let uuid: String
        /// True when this call found the robot asleep and woke it. The snapshot the
        /// widget reads is wrong by exactly that much until someone writes it down.
        public let woke: Bool
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// The backend was down and has been started, with `wake_up=true`. A cold
        /// start is ninety seconds and this process has fifteen, so the move is not
        /// attempted — the same refusal `RobotAppLauncher` gives, for the same
        /// reason, and the next attempt lands on a robot that is up.
        case startingBackend

        public var errorDescription: String? {
            switch self {
            case .startingBackend:
                String(localized: .reachy("Reachy Mini was off. It's starting up — try again in a moment."))
            }
        }
    }

    /// Optional because the surface moved off ``RobotAPIClient``: an intent only
    /// ever runs against a LAN connection, which carries it, and a transport that
    /// does not is refused where the play is asked for rather than at construction
    /// — an initialiser that can fail would spread through every intent.
    private let moves: (any MovePlaybackClient)?
    private let power: RobotPower
    private let readiness: @Sendable () async throws -> RobotAppLauncher.Readiness
    private let recentreDuration: TimeInterval

    /// `assumeAwake` carries the same asymmetry it does in `RobotAppLauncher`: a
    /// snapshot may be believed when it says awake and never when it says asleep,
    /// because `isAwake` is false for a parked robot *and* for a torn-down backend
    /// and the two need opposite sequences.
    public init(
        client: any RobotAPIClient,
        configuration: RobotSession.Configuration = .widgetIntent,
        assumeAwake: Bool?
    ) {
        moves = client as? any MovePlaybackClient
        power = RobotPower(client: client, configuration: configuration)
        recentreDuration = configuration.recentreDuration
        readiness = {
            if assumeAwake == true {
                return .awake
            }
            return try await RobotAppLauncher.Readiness(client.daemonStatus())
        }
    }

    /// Test seam, the shape `RobotAppLauncher`'s has.
    init(
        moves: any MovePlaybackClient,
        power: RobotPower,
        readiness: @escaping @Sendable () async throws -> RobotAppLauncher.Readiness,
        recentreDuration: TimeInterval = 1
    ) {
        self.moves = moves
        self.power = power
        self.readiness = readiness
        self.recentreDuration = recentreDuration
    }

    /// Wakes the robot if it is asleep, frees the daemon's one move slot, then
    /// plays.
    ///
    /// **A wake-up animation still in flight is stopped like anything else.**
    /// `RobotPower.wake()` waits for it, but that wait is bounded and returns
    /// normally when the budget passes — and someone who asked for a dance asked
    /// for the dance, not for the stretch in front of it.
    public func play(dataset: String, move: String) async throws -> Outcome {
        var woke = false
        switch try await readiness() {
        case .awake:
            break
        case .asleep:
            try await power.wake()
            woke = true
        case .backendDown:
            try await power.startBackendWaking()
            throw Failure.startingBackend
        }

        try Task.checkCancellation()
        try await clearTheFloor(parking: false)
        guard let moves else { throw ReachyKitError.movesUnavailable }
        return try await Outcome(uuid: moves.playMove(dataset: dataset, move: move), woke: woke)
    }

    /// Stops whatever is playing and parks the robot at zero.
    ///
    /// `false` when there was nothing to stop, which is not a failure — the caller
    /// has a different sentence for it, exactly as `RobotAppLauncher.stop()` does.
    @discardableResult
    public func stop() async throws -> Bool {
        try await clearTheFloor(parking: true)
    }

    /// Empties the daemon's move slot, and says whether anything was in it.
    ///
    /// **Parking is skipped between two moves on purpose.** A `goto` is a move task
    /// of its own, so parking here would occupy the very slot the play about to be
    /// issued needs — the same rule `RobotSession.clearTheFloor` follows, and the
    /// reason a stop and a replacement cannot share one path without the flag.
    ///
    /// The sound is stopped alongside the motion because the daemon's media player
    /// owns it separately: a move out of the music library goes on playing over the
    /// silence otherwise. Its failure is swallowed — the motors are what was asked
    /// about.
    @discardableResult
    private func clearTheFloor(parking: Bool) async throws -> Bool {
        guard let moves else { throw ReachyKitError.movesUnavailable }
        let running = try await moves.runningMoveUUIDs()
        guard !running.isEmpty else { return false }
        for uuid in running {
            // Not `try?`: `POST /api/move/stop` awaits the cancellation before it
            // answers, so a 200 is the proof the slot is free and a throw means it
            // is not. A play issued into a busy slot is accepted and does nothing.
            try await moves.stopMove(uuid: uuid)
        }
        try? await moves.stopSound()
        if parking {
            // One request and no wait: the daemon answers with a task id and plays
            // the move afterwards, which is what fits the budget where a
            // `goto_sleep` plus its animation would not.
            _ = try? await moves.gotoNeutral(duration: recentreDuration)
        }
        return true
    }
}
