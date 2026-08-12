import Foundation
import ReachyKit
import WidgetKit

/// Everything an intent has to do around `RobotMovePlayer`, once.
///
/// The third of the trio with `RobotAppCommand` and `RobotPowerCommand`, and it
/// keeps less bookkeeping than either — deliberately. A move is not a state the
/// widget draws: `RobotWidgetContent` reports power and the running app, and
/// nothing in it has a place for a dance. So there is no pending marker here and
/// no timeline reload for the move itself.
///
/// **What it does write is `MovePlaybackRecord`**, which is the app's only way to
/// name a move that is already playing. `GET /api/move/running` answers with UUIDs
/// and nothing else, so without this a dance started from Siri would show up in the
/// app as "A move is running on the robot" with no row highlighted.
public struct RobotMoveCommand: Sendable {
    public enum Operation: Equatable, Sendable {
        case play(dataset: String, move: String)
        case stop
    }

    /// What the robot did. `.nothingToStop` is a distinct answer rather than an
    /// absent one because the caller speaks a different sentence for it, and a
    /// `nil` would have to mean both that and "a stop succeeded".
    public enum Report: Equatable, Sendable {
        case playing(uuid: String)
        case stopped
        case nothingToStop
    }

    /// The whole command, handshake included. A request timeout bounds one period
    /// of inactivity; this bounds the sequence.
    static let executionTimeout: Duration = .seconds(15)

    private let operation: Operation
    /// `RobotEntity.id` where the caller named a robot. See `RobotPowerCommand`.
    private let robot: String?

    public init(_ operation: Operation, robot: String? = nil) {
        self.operation = operation
        self.robot = robot
    }

    @discardableResult
    public func perform() async throws -> Report {
        // A reading inside its window and about *this* robot is worth a round trip
        // saved; anything else, ask. `freshReading(for:)` is where the second half
        // lives — there is one snapshot and an intent may name a robot other than
        // the one it describes. `RobotMovePlayer` treats nil as "find out", and
        // treats a reading that says asleep as nothing at all.
        //
        // The store itself is not `Sendable`, so it is read here and rebuilt inside
        // `record` rather than carried into the closure — the same shape
        // `RobotPowerCommand` has.
        let assumeAwake = RobotSnapshotStore().freshReading(for: robot)?.isAwake

        let operation = operation
        let robot = robot
        return try await RobotIntentTarget.withTimeout(Self.executionTimeout) {
            let target = try await RobotIntentTarget.connection(to: robot, timeout: 6)
            let player = RobotMovePlayer(client: target.client, assumeAwake: assumeAwake)
            switch operation {
            case let .play(dataset, move):
                let outcome = try await player.play(dataset: dataset, move: move)
                Self.record(outcome, dataset: dataset, move: move, robot: target.robot)
                return .playing(uuid: outcome.uuid)
            case .stop:
                guard try await player.stop() else { return .nothingToStop }
                // The record names the move that *is* playing; after a stop there
                // is none, and leaving it would let the next anonymous task the
                // daemon reports be adopted under this move's name.
                MovePlaybackStore().clear()
                return .stopped
            }
        }
    }

    /// Two records, and only one of them is about the move.
    ///
    /// The playback record is what names a running move later. The snapshot is
    /// written **only when this call woke the robot** — a play over an already
    /// awake robot learned nothing new about the motors, and re-stating a reading
    /// is how a stale one gets a fresh date on it.
    private static func record(
        _ outcome: RobotMovePlayer.Outcome,
        dataset: String,
        move: String,
        robot: KnownRobot
    ) {
        MovePlaybackStore().write(
            MovePlaybackRecord(robotID: robot.key, uuid: outcome.uuid, dataset: dataset, move: move)
        )
        guard outcome.woke else { return }
        RobotSnapshotStore().recordPower(isAwake: true, robotID: robot.key, robotName: robot.name)
        WidgetCenter.shared.reloadTimelines(ofKind: ReachyWidgetKind.status)
    }
}
