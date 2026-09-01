import Foundation

/// Playing the robot's recorded moves: the library index, the play, and the two
/// things that end one.
///
/// Split out of ``RobotAPIClient`` so that carrying these routes is a property of
/// the transport rather than six throwing defaults every client inherits — the
/// arrangement ``RobotAppsClient`` and ``SoundboardClient`` already have.
///
/// `RobotSession.canPlayMoves` reads ``offersMoveLibrary`` off the conformer
/// rather than testing the session's address, which used to stand in for it and
/// answered wrongly in both directions: the relay has no address and can play, the
/// simulator has no library and would have been offered one.
///
/// `runningMoveUUIDs` lives here rather than on the connection surface even though
/// waking and sleeping wait on it too — those are move tasks like any dance, and a
/// transport that cannot list them cannot wait for them either. See
/// `RobotSession.waitForMoveToFinish`, which now says so.
public protocol MovePlaybackClient: Sendable {
    /// Whether this transport can offer a move library at all.
    ///
    /// Conformance alone does not answer it: the simulator conforms because
    /// parking and the power path need `gotoNeutral` and `runningMoveUUIDs`, and
    /// it has no daemon to fetch a Hugging Face dataset with. The relay conforms
    /// with no index route and answers true anyway — it plays from the list this
    /// app kept, which is a library it has, just not one it can refresh.
    var offersMoveLibrary: Bool { get }

    func listMoves(dataset: String) async throws -> [String]
    /// Asks the robot to fetch a dataset before anything is played from it.
    ///
    /// Idempotent and cache-first on the robot, and worth sending only where the
    /// first play would otherwise block on a Hugging Face download the user is
    /// waiting through. A transport with nothing to warm does nothing.
    func preload(dataset: String) async throws
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
    /// True unless a transport says otherwise: every real robot has a library.
    var offersMoveLibrary: Bool {
        true
    }

    /// Nothing to warm. The HTTP play route fetches the dataset itself and answers
    /// only once it has, so there is no window to fill there.
    func preload(dataset _: String) async throws {}

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
