import Foundation
import ReachyDesign
import ReachyKit

/// Playing one sound, with no session around it.
///
/// The twin of `SoundboardModel.play`, and deliberately not the same code — the split
/// `RobotAppLauncher` records at length. That one holds a library it can send from and
/// reports each failure onto a screen; this has neither, so it asks the robot and has
/// one sentence to answer with.
///
/// **Three things it deliberately does not do, each of which its move-playing sibling
/// must.** `RobotMovePlayer` wakes the robot, empties the daemon's one move slot and
/// parks afterwards, because a play route accepts a move over disabled motors and
/// `play_move` drops the second caller in silence. None of that applies to a sound: the
/// speaker is not a motor, so a parked robot plays perfectly well; a sound is not a move
/// task, so it occupies no slot and there is nothing to park. It also needs no readiness
/// probe — a torn-down backend answers `play_sound` with an honest 503, which is the one
/// refusal on this surface that reports itself.
///
/// **What it does have to check is presence**, and that is the whole reason this type
/// exists rather than a bare call: `play_sound` answers `{"status": "ok"}` for a name
/// that matches nothing, and uploads live in `/tmp`. So a shortcut naming a sound the
/// robot lost over a restart would otherwise report success into silence, for ever.
public struct RobotSoundPlayer: Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        /// The robot does not have this sound any more — almost always because it
        /// restarted. The sentence names the sound and where to fix it, because nothing
        /// in this process can: sending it again means reading bytes out of the device's
        /// library and posting 25 MiB, which is not what a control's few seconds are for.
        case notOnRobot(String)

        public var errorDescription: String? {
            switch self {
            case let .notOnRobot(name):
                String(localized: .reachy("Reachy Mini no longer has \(name). Send it again from the Sounds screen."))
            }
        }
    }

    /// The whole command, handshake included. A request timeout bounds one period of
    /// inactivity; this bounds the sequence — the same budget `RobotMoveCommand` takes.
    static let executionTimeout: Duration = .seconds(15)

    private let library: any SoundboardClient

    public init(client: any SoundboardClient) {
        library = client
    }

    /// Verifies the robot still holds the sound, then plays it.
    ///
    /// The listing is the only extra round trip and it replaces the readiness read its
    /// move-playing sibling makes — one request either way, spent on the failure that is
    /// silent rather than on the one that answers 503.
    public func play(named filename: String) async throws {
        let available = try await library.sounds()
        guard available.contains(where: { $0.filename == filename }) else {
            throw Failure.notOnRobot(RobotSound.displayName(filename))
        }
        try await library.playSound(named: filename)
    }

    /// Ends whatever the daemon's media player is playing, which may be a recorded
    /// move's music rather than a soundboard tap — one player, one Stop.
    ///
    /// Nothing reports whether anything was playing, so unlike `RobotMovePlayer.stop()`
    /// this cannot answer "there was nothing to stop". Sending it over silence is free,
    /// and claiming to know would not be.
    public func stop() async throws {
        try await library.stopSound()
    }
}

public extension RobotSoundPlayer {
    /// Opens a connection to the robot the caller named and hands over a player.
    ///
    /// **This is where a `RobotSoundCommand` would be, and there is not one.** Its three
    /// siblings — `RobotAppCommand`, `RobotPowerCommand`, `RobotMoveCommand` — exist to
    /// write a snapshot, file a pending marker or reload a timeline. A sound is none of
    /// those: `RobotWidgetContent` has no place for one, playing wakes nothing, and
    /// there is no equivalent of `MovePlaybackRecord` to keep because no route reports a
    /// sound as playing. So the connection budget is all that was left, and it lives on
    /// the player rather than in a type with nothing else in it.
    static func perform<T: Sendable>(
        robot: String?,
        _ work: @escaping @Sendable (RobotSoundPlayer) async throws -> T
    ) async throws -> T {
        try await RobotIntentTarget.withTimeout(executionTimeout) {
            let target = try await RobotIntentTarget.connection(to: robot, timeout: 6)
            return try await work(RobotSoundPlayer(client: target.client))
        }
    }
}
