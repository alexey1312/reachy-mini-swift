import Foundation
import OpenAPIRuntime

/// Recorded moves over HTTP: the dances, emotions and music libraries, and the
/// routes that end or follow them.
///
/// Split from `RobotConnection` the way `RobotConnection+Power` is. The rules that
/// order these calls live one layer up, in `RobotSession+Moves`.
public extension RobotConnection {
    // `listMoves` and `playMove` go through `hubClient`, not the 3.5 s client.
    // Both routes build `RecordedMoves(dataset)` before they answer, and that
    // downloads a dataset the daemon has not cached from Hugging Face. Only the
    // two Pollen libraries are preloaded (`DEFAULT_DATASETS`), and a cold load of
    // the Music one took about 15 s. On the short budget the call timed out while
    // the robot went on to play the move.

    /// Move names available in a HF dataset, e.g. `pollen-robotics/reachy-mini-dances-library`.
    func listMoves(dataset: String) async throws -> [String] {
        try await hubClient.listRecordedMoveDatasetApiMoveRecordedMoveDatasetsListDatasetNameGet(
            path: .init(datasetName: dataset)
        ).ok.body.json
    }

    /// Starts a recorded move; returns its UUID for `stopMove`.
    ///
    /// Throws ``ReachyKitError/moveBusy`` when the move never started, which a 200
    /// does not rule out — see ``requireStarted(_:)``.
    func playMove(dataset: String, move: String) async throws -> String {
        let uuid = try await hubClient.playRecordedMoveDatasetApiMovePlayRecordedMoveDatasetDatasetNameMoveNamePost(
            path: .init(datasetName: dataset, moveName: move)
        ).ok.body.json.uuid
        try await requireStarted(uuid)
        return uuid
    }

    /// Reads back a task the daemon has just accepted.
    ///
    /// **A 200 from a play route is not a move that started.** The route answers
    /// before the task has run a step, and from 1.14.0 a task that finds the move slot
    /// taken fails at once and says so only as `move_failed` on
    /// `/api/move/ws/updates`, a socket this client does not hold. The list can tell:
    /// the route registers the task before it answers, and these moves outlast a
    /// round trip, so a UUID already gone from it never played.
    ///
    /// Only for those moves. `wake_up` ends at once on a robot that needs no
    /// animation, so its absence proves nothing. A failed read proves nothing either,
    /// and the caller's own wait still follows the task.
    internal func requireStarted(_ uuid: String) async throws {
        if let running = try? await runningMoveUUIDs(), !running.contains(uuid) {
            throw ReachyKitError.moveBusy
        }
    }

    /// Authoritative daemon view of tasks still running, used to detect natural completion.
    func runningMoveUUIDs() async throws -> Set<String> {
        let moves = try await client.getRunningMovesApiMoveRunningGet().ok.body.json
        return Set(moves.map(\.uuid))
    }

    /// The daemon's own definition of the zero pose, in the units the `goto` route
    /// takes.
    ///
    /// **The antennas are not vertical, and that is deliberate upstream.**
    /// `reachy_mini.INIT_ANTENNAS_JOINT_POSITIONS` is `[-0.1745, 0.1745]` — ~±10°,
    /// carrying the comment "to reduce shaking at vertical" — and it is what the
    /// daemon sends itself when an app releases the robot. This used to be
    /// `[0.0, 0.0]`, which is a second definition of "base" that no reader could
    /// tell from the first except by watching the antennas twitch.
    internal static let zeroAntennas: [Double] = [-0.1745, 0.1745]

    /// The zero pose, sent as one `goto` rather than as a teleop target: the daemon
    /// ignores `set_target` while a move is running, and this is what runs right
    /// after one. Every axis is named explicitly — an omitted field means "leave
    /// this one where it is", and the whole point is that nothing is left behind.
    func gotoNeutral(duration: TimeInterval) async throws -> String {
        // `head_pose` is an `anyOf` of two pose shapes, which the generator renders
        // as a struct with one optional per branch rather than as an enum — filling
        // `value1` is how the flat XYZRPY form is chosen. `antennas` is a
        // `prefixItems` tuple, and the generator has no type for that either.
        try await client.gotoApiMoveGotoPost(
            body: .json(.init(
                headPose: .init(value1: .init(x: 0, y: 0, z: 0, roll: 0, pitch: 0, yaw: 0)),
                antennas: OpenAPIRuntime.OpenAPIArrayContainer(unvalidatedValue: Self.zeroAntennas),
                bodyYaw: 0,
                duration: duration
            ))
        ).ok.body.json.uuid
    }

    func stopMove(uuid: String) async throws {
        _ = try await client.stopMoveApiMoveStopPost(body: .json(.init(uuid: uuid))).ok
    }

    /// Recorded music is owned by the daemon's media player, separately from the move task.
    func stopSound() async throws {
        _ = try await client.stopSoundApiMediaStopSoundPost().ok
    }
}
