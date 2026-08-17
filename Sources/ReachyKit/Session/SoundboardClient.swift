import Foundation

/// The robot's sound library: what it holds, what it plays, and what it forgets.
///
/// A protocol of its own rather than four more methods on ``RobotAPIClient``, for the
/// reason ``PresenceClient`` is one: conforming *is* the capability, so a session over
/// the Hugging Face relay — whose control channel carries none of `/api/media/*` —
/// reports it unavailable instead of failing a button somebody just tapped.
///
/// Three facts from `routers/media.py` shape everything above this, and none of them
/// is visible in the OpenAPI document:
///
/// - **The robot's copy is temporary.** Uploads land in `/tmp/reachy_mini_sounds`,
///   and ``sounds()`` lists that directory alone. A reboot empties it, so the
///   device's own library is the durable one (``SoundLibraryStore``) and the robot is
///   a cache in front of it.
/// - **``playSound(named:)`` cannot fail for a file that is not there.** The media
///   server logs the miss and returns; the route answers `{"status": "ok"}`
///   regardless — the same shape as `wobbling/enable`. So a caller that has not just
///   listed the library has not established that anything will be heard, which is
///   why every play in this app is preceded by a list.
/// - **Only playing needs a backend.** `play_sound` and `stop_sound` sit behind the
///   `get_backend` check and answer 503 without one; `sounds`, `upload` and `delete`
///   take no daemon dependency at all and work on a robot whose motors were never
///   enabled.
public protocol SoundboardClient: Sendable {
    /// The names in the robot's temporary sound directory, as it sorted them.
    ///
    /// A daemon that does not mount these routes answers with an empty library
    /// rather than throwing — see the implementation for why that is a 404 and not a
    /// version check.
    func sounds() async throws -> [RobotSound]

    /// Plays a sound by name, resolved against the upload directory and then the
    /// robot's built-in assets. Answers before the sound has finished — and answers
    /// the same way when the name matches nothing at all.
    func playSound(named filename: String) async throws

    /// Sends a file to the robot's temporary sound directory, overwriting a
    /// same-named one.
    ///
    /// The reply's absolute path is deliberately discarded: it points into `/tmp`,
    /// where it stops being true at the next reboot, and the bare name is what
    /// ``playSound(named:)`` wants anyway.
    func uploadSound(named filename: String, data: Data) async throws

    /// Removes one sound from the robot, leaving the device's copy alone.
    func deleteSound(named filename: String) async throws

    /// Ends whatever the daemon's media player is playing.
    ///
    /// **Also a ``RobotAPIClient`` requirement, and deliberately restated here.** One
    /// method satisfies both — `RobotConnection` writes it once — and having it on this
    /// protocol is what lets an intent hold a single value it can both play and stop
    /// through. It was on `RobotAPIClient` first because a recorded move's music needed
    /// stopping long before there was a soundboard, and there is one player behind both.
    func stopSound() async throws
}

public extension RobotSession {
    /// False over the relay, whose data channel carries no media routes.
    var canManageSounds: Bool {
        client is any SoundboardClient
    }

    func sounds() async throws -> [RobotSound] {
        try await withSoundboardClient { try await $0.sounds() }
    }

    /// - Important: a 200 here is not evidence anything is audible; see
    ///   ``SoundboardClient``. `SoundboardModel` lists before it plays for that
    ///   reason, and so does `RobotSoundPlayer` on the intent side.
    func playSound(named filename: String) async throws {
        try await withSoundboardClient { try await $0.playSound(named: filename) }
    }

    func uploadSound(named filename: String, data: Data) async throws {
        try await withSoundboardClient { try await $0.uploadSound(named: filename, data: data) }
    }

    func deleteSound(named filename: String) async throws {
        try await withSoundboardClient { try await $0.deleteSound(named: filename) }
    }

    /// Ends whatever the daemon's media player is playing — a soundboard tap or the
    /// music a recorded move started, which are one player and one Stop.
    ///
    /// On ``RobotAPIClient`` rather than on ``SoundboardClient`` because it was
    /// already there: `RobotSession+Moves` sends it when a dance ends, since nothing
    /// on the robot stops a track that outlives its move.
    func stopSound() async throws {
        try await withClient { try await $0.stopSound() }
    }
}

extension RobotSession {
    /// Throws and says nothing else — a soundboard failure belongs to the screen that
    /// asked, and `robotError` is the robot's connection and power alone
    /// (`RobotSessionErrorOwnershipTests`).
    func withSoundboardClient<T>(_ call: (any SoundboardClient) async throws -> T) async throws -> T {
        guard let client else { throw ReachyKitError.notConnected }
        guard let soundboard = client as? any SoundboardClient else {
            throw ReachyKitError.soundboardUnavailable
        }
        return try await call(soundboard)
    }
}
