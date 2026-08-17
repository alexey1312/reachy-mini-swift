import Foundation
@testable import ReachyKit
import Testing

/// A client that speaks the soundboard, and one that does not — the pair is what the
/// capability gate is tested with.
private class SoundlessRobotClient: RobotAPIClient, @unchecked Sendable {
    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name":"testbot","state":"running","wireless_version":false,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":{"motor_control_mode":"enabled","error":null}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: .init(hardwareID: "hw", name: "testbot", daemonVersion: "1.9.0"), status: status)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        status
    }

    func wakeUp() async throws -> String {
        "wake"
    }

    func gotoSleep() async throws -> String {
        "sleep"
    }

    /// Declared here rather than left to `RobotAPIClient`'s throwing default: a class
    /// cannot override a protocol extension, and the subclass below has to.
    func stopSound() async throws {
        throw URLError(.unsupportedURL)
    }
}

private final class SoundRobotClient: SoundlessRobotClient, SoundboardClient {
    private let lock = NSLock()
    /// Every call in order, which is what the upload-then-play sequence is asserted on.
    private(set) var calls: [String] = []
    var library = ["airhorn.wav"]
    var rejectsEverything = false

    func sounds() async throws -> [RobotSound] {
        try note("list")
        return library.map(RobotSound.init(filename:))
    }

    func playSound(named filename: String) async throws {
        try note("play:\(filename)")
    }

    func uploadSound(named filename: String, data: Data) async throws {
        try note("upload:\(filename):\(data.count)")
        lock.withLock {
            if !library.contains(filename) {
                library.append(filename)
            }
        }
    }

    func deleteSound(named filename: String) async throws {
        try note("delete:\(filename)")
        lock.withLock { library.removeAll { $0 == filename } }
    }

    override func stopSound() async throws {
        try note("stop")
    }

    private func note(_ call: String) throws {
        if rejectsEverything {
            throw ReachyKitError.daemonRejected(statusCode: 503)
        }
        lock.withLock { calls.append(call) }
    }
}

@MainActor
@Suite("RobotSession sounds", .timeLimit(.minutes(1)))
struct RobotSessionSoundsTests {
    private func session(_ client: any RobotAPIClient) async -> RobotSession {
        var configuration = RobotSession.Configuration()
        configuration.pollInterval = .seconds(60)
        let session = RobotSession(configuration: configuration) { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        return session
    }

    @Test("the four routes round-trip through the session")
    func roundTrip() async throws {
        let client = SoundRobotClient()
        let session = await session(client)

        #expect(session.canManageSounds)
        #expect(try await session.sounds().map(\.filename) == ["airhorn.wav"])
        try await session.uploadSound(named: "tada.m4a", data: Data([0x00, 0x01]))
        try await session.playSound(named: "tada.m4a")
        try await session.stopSound()
        try await session.deleteSound(named: "tada.m4a")

        #expect(client.calls == ["list", "upload:tada.m4a:2", "play:tada.m4a", "stop", "delete:tada.m4a"])
        session.disconnect()
    }

    /// A relayed session's data channel carries no `/api/media/*` at all, so the screen
    /// is never offered rather than being offered and failing.
    @Test("a connection that does not speak the soundboard reports it unavailable")
    func gatesOnTheCapability() async throws {
        let session = await session(SoundlessRobotClient())

        #expect(!session.canManageSounds)
        await #expect(throws: ReachyKitError.soundboardUnavailable) {
            _ = try await session.sounds()
        }
        session.disconnect()
    }

    /// `robotError` is the robot's connection and power, and a refused sound is neither —
    /// the line `RobotSessionErrorOwnershipTests` holds for every other feature.
    @Test("a refused sound throws and stays off the robot screen")
    func failureStaysWithTheCaller() async throws {
        let client = SoundRobotClient()
        client.rejectsEverything = true
        let session = await session(client)

        await #expect(throws: ReachyKitError.daemonRejected(statusCode: 503)) {
            try await session.playSound(named: "airhorn.wav")
        }
        #expect(session.robotError == nil)
        session.disconnect()
    }
}
