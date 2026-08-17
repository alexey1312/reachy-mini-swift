import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

private final class StubSoundboard: SoundboardClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    var onRobot: [String]
    var listFailure: (any Error)?
    var playFailure: (any Error)?

    init(onRobot: [String]) {
        self.onRobot = onRobot
    }

    func sounds() async throws -> [RobotSound] {
        lock.withLock { calls.append("list") }
        if let listFailure {
            throw listFailure
        }
        return lock.withLock { onRobot }.map(RobotSound.init(filename:))
    }

    func playSound(named filename: String) async throws {
        lock.withLock { calls.append("play:\(filename)") }
        if let playFailure {
            throw playFailure
        }
    }

    func uploadSound(named filename: String, data: Data) async throws {
        lock.withLock { calls.append("upload:\(filename):\(data.count)") }
    }

    func deleteSound(named filename: String) async throws {
        lock.withLock { calls.append("delete:\(filename)") }
    }

    func stopSound() async throws {
        lock.withLock { calls.append("stop") }
    }
}

/// The headless half: what an intent and a Control Centre button do when they have
/// seconds, one client and one sentence.
@Suite("RobotSoundPlayer", .timeLimit(.minutes(1)))
struct RobotSoundPlayerTests {
    @Test("a sound the robot has is listed once and played")
    func playsWhatIsThere() async throws {
        let robot = StubSoundboard(onRobot: ["airhorn.wav"])

        try await RobotSoundPlayer(client: robot).play(named: "airhorn.wav")

        #expect(robot.calls == ["list", "play:airhorn.wav"])
    }

    /// **The whole reason this type exists.** `play_sound` answers `{"status": "ok"}` for
    /// a name that matches nothing, and uploads live in `/tmp` — so without the check a
    /// shortcut naming a sound the robot lost over a restart reports success into
    /// silence, for ever. Delete the `guard` in `play` and this goes red.
    @Test("a sound the robot has forgotten is refused by name, and never played")
    func refusesWhatIsGone() async throws {
        let robot = StubSoundboard(onRobot: ["airhorn.wav"])

        await #expect(throws: RobotSoundPlayer.Failure.notOnRobot("tada")) {
            try await RobotSoundPlayer(client: robot).play(named: "tada.m4a")
        }

        #expect(robot.calls == ["list"])
    }

    /// The sentence names the sound and where to fix it, because nothing in this process
    /// can: sending it again means 25 MiB and a GStreamer probe, which is not what a
    /// control's few seconds are for.
    @Test("the refusal is a sentence a reader can act on")
    func namesTheSoundAndTheFix() {
        let message = RobotSoundPlayer.Failure.notOnRobot("air horn").errorDescription

        #expect(message?.contains("air horn") == true)
        #expect(message?.contains("Sounds") == true)
    }

    /// One player behind a soundboard tap and a recorded move's music, so this is the one
    /// Stop for both — and it cannot report whether anything was playing, because no route
    /// says. `RobotMovePlayer.stop()` can answer that about a move; this deliberately does
    /// not pretend to.
    @Test("stopping needs no reading and claims none")
    func stopsWithoutAsking() async throws {
        let robot = StubSoundboard(onRobot: [])

        try await RobotSoundPlayer(client: robot).stop()

        #expect(robot.calls == ["stop"])
    }

    /// A torn-down backend answers `play_sound` with an honest 503, which is why this
    /// player needs no readiness probe where `RobotMovePlayer` does — the failure it has
    /// to pre-empt is the silent one, and the listing is what pre-empts it.
    @Test("a refusal from the daemon is passed through as itself")
    func passesTheDaemonsRefusalThrough() async throws {
        let robot = StubSoundboard(onRobot: ["airhorn.wav"])
        robot.playFailure = ReachyKitError.backendNotRunning

        await #expect(throws: ReachyKitError.backendNotRunning) {
            try await RobotSoundPlayer(client: robot).play(named: "airhorn.wav")
        }
    }

    @Test("a listing that failed is not read as a missing sound")
    func doesNotMistakeAFailedListing() async throws {
        let robot = StubSoundboard(onRobot: ["airhorn.wav"])
        robot.listFailure = ReachyKitError.daemonRejected(statusCode: 500)

        await #expect(throws: ReachyKitError.daemonRejected(statusCode: 500)) {
            try await RobotSoundPlayer(client: robot).play(named: "airhorn.wav")
        }

        #expect(robot.calls == ["list"])
    }
}
