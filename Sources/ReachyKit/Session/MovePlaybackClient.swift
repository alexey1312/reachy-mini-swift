import Foundation

/// Playing the robot's recorded moves: the library index, the play, and the two
/// things that end one.
///
/// Split out of ``RobotAPIClient`` so that carrying these routes is a property of
/// the transport rather than six throwing defaults every client inherits — the
/// arrangement ``RobotAppsClient`` and ``SoundboardClient`` already have.
///
/// `RobotSession.canPlayMoves` still asks whether the session has an address, and
/// deliberately: the simulator conforms here because parking and the power path
/// need `gotoNeutral` and `runningMoveUUIDs`, while its move *library* is empty —
/// so conformance and "there are dances to offer" are not yet the same question.
/// Making them one is the step that gives the relay its own conformance.
///
/// `runningMoveUUIDs` lives here rather than on the connection surface even though
/// waking and sleeping wait on it too — those are move tasks like any dance, and a
/// transport that cannot list them cannot wait for them either. See
/// `RobotSession.waitForMoveToFinish`, which now says so.
public protocol MovePlaybackClient: Sendable {
    func listMoves(dataset: String) async throws -> [String]
    func playMove(dataset: String, move: String) async throws -> String
    func runningMoveUUIDs() async throws -> Set<String>
    func stopMove(uuid: String) async throws
    /// Walks the robot back to its zero pose; returns the move task's UUID.
    func gotoNeutral(duration: TimeInterval) async throws -> String
    /// A move's music is a separate daemon task and outlives the motion, so ending
    /// playback means ending both.
    func stopSound() async throws
}

/// Defaults keep test doubles focused on the behaviour they exercise, the way
/// ``RobotAppsClient``'s do. Declaring the conformance is still the capability —
/// `canPlayMoves` asks whether the type conforms, not whether it answers.
public extension MovePlaybackClient {
    func listMoves(dataset _: String) async throws -> [String] {
        throw URLError(.unsupportedURL)
    }

    func playMove(dataset _: String, move _: String) async throws -> String {
        throw URLError(.unsupportedURL)
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        throw URLError(.unsupportedURL)
    }

    func stopMove(uuid _: String) async throws {
        throw URLError(.unsupportedURL)
    }

    func gotoNeutral(duration _: TimeInterval) async throws -> String {
        throw URLError(.unsupportedURL)
    }

    func stopSound() async throws {
        throw URLError(.unsupportedURL)
    }
}
