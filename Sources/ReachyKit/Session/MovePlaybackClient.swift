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
/// hid a relayed robot: the relay has no address and plays perfectly well.
///
/// `runningMoveUUIDs` lives here rather than on the connection surface even though
/// waking and sleeping wait on it too — those are move tasks like any dance, and a
/// transport that cannot list them cannot wait for them either — see
/// `RobotSession.waitForMoveToFinish`.
public protocol MovePlaybackClient: Sendable {
    /// Whether this transport can offer a move library at all.
    ///
    /// Conformance alone does not answer it: the simulator conforms because
    /// parking and the power path need `gotoNeutral` and `runningMoveUUIDs`, and
    /// it has no daemon to fetch a Hugging Face dataset with. The relay answers
    /// true with no index route — it plays from the list this app kept, which is
    /// a library it has, just not one it can refresh. See ``offersMoveIndex``.
    var offersMoveLibrary: Bool { get }

    /// Whether this transport can *list* a dataset's moves.
    ///
    /// A narrower question than ``offersMoveLibrary``, which decides whether the
    /// screen opens at all. The relay opens it and answers this false: it plays
    /// from the list this app kept off the robot's own network, and there is no
    /// index route on the data channel to refresh that list with.
    var offersMoveIndex: Bool { get }

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
/// ``RobotAppsClient``'s do. They throw a described error rather than a sentinel:
/// a default that reached a screen used to read there as "unsupported URL".
public extension MovePlaybackClient {
    /// True unless a transport says otherwise: every real robot has a library.
    var offersMoveLibrary: Bool {
        true
    }

    /// True unless a transport says otherwise: a daemon that serves the play route
    /// serves the index beside it.
    var offersMoveIndex: Bool {
        true
    }

    /// Nothing to warm. The HTTP play route fetches the dataset itself and answers
    /// only once it has, so there is no window to fill there.
    func preload(dataset _: String) async throws {}

    func listMoves(dataset _: String) async throws -> [String] {
        throw ReachyKitError.movesUnavailable
    }

    func playMove(dataset _: String, move _: String) async throws -> String {
        throw ReachyKitError.movesUnavailable
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        throw ReachyKitError.movesUnavailable
    }

    func stopMove(uuid _: String) async throws {
        throw ReachyKitError.movesUnavailable
    }

    func gotoNeutral(duration _: TimeInterval) async throws -> String {
        throw ReachyKitError.movesUnavailable
    }

    func stopSound() async throws {
        throw ReachyKitError.movesUnavailable
    }
}
