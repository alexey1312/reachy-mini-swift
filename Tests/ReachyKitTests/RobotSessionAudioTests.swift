import Foundation
@testable import ReachyKit
import Testing

private final class AudioRobotClient: RobotAPIClient, AudioLevelClient, TestSoundClient, @unchecked Sendable {
    private let lock = NSLock()
    /// Percents the daemon accepted, in order — the point of the slider tests.
    private(set) var accepted: [Int] = []
    private(set) var testSoundCalls = 0
    var rejectsEverything = false

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

    func volume() async throws -> AudioLevel {
        AudioLevel(percent: 42, platform: "pulseaudio", device: "speaker")
    }

    func setVolume(_ percent: Int) async throws -> AudioLevel {
        try record(percent, device: "speaker")
    }

    func microphoneVolume() async throws -> AudioLevel {
        AudioLevel(percent: 17, platform: "pulseaudio", device: "mic")
    }

    func setMicrophoneVolume(_ percent: Int) async throws -> AudioLevel {
        try record(percent, device: "mic")
    }

    func playTestSound() async throws {
        lock.withLock { testSoundCalls += 1 }
    }

    private func record(_ percent: Int, device: String) throws -> AudioLevel {
        if rejectsEverything {
            throw ReachyKitError.daemonRejected(statusCode: 422)
        }
        lock.withLock { accepted.append(percent) }
        return AudioLevel(percent: percent, platform: "pulseaudio", device: device)
    }
}

/// The relay's shape: the levels ride its data channel, the test sound does not.
private final class LevelsOnlyClient: RobotAPIClient, AudioLevelClient, @unchecked Sendable {
    private let base = AudioRobotClient()

    func handshake() async throws -> RobotConnection.Handshake {
        try await base.handshake()
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        try await base.daemonStatus()
    }

    func wakeUp() async throws -> String {
        try await base.wakeUp()
    }

    func gotoSleep() async throws -> String {
        try await base.gotoSleep()
    }

    func volume() async throws -> AudioLevel {
        try await base.volume()
    }

    func setVolume(_ percent: Int) async throws -> AudioLevel {
        try await base.setVolume(percent)
    }

    func microphoneVolume() async throws -> AudioLevel {
        try await base.microphoneVolume()
    }

    func setMicrophoneVolume(_ percent: Int) async throws -> AudioLevel {
        try await base.setMicrophoneVolume(percent)
    }
}

@MainActor
@Suite("RobotSession audio")
struct RobotSessionAudioTests {
    private func session(_ client: AudioRobotClient) async -> RobotSession {
        var configuration = RobotSession.Configuration()
        configuration.pollInterval = .seconds(60)
        let session = RobotSession(configuration: configuration) { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        return session
    }

    @Test("levels round-trip through the session")
    func roundTrip() async throws {
        let client = AudioRobotClient()
        let session = await session(client)

        #expect(try await session.volume() == AudioLevel(percent: 42, platform: "pulseaudio", device: "speaker"))
        #expect(try await session.microphoneVolume().percent == 17)

        let speaker = try await session.setVolume(65)
        #expect(speaker.percent == 65)
        #expect(speaker.device == "speaker")
        #expect(try await session.setMicrophoneVolume(30).device == "mic")
        #expect(client.accepted == [65, 30])

        try await session.playTestSound()
        #expect(client.testSoundCalls == 1)
        session.disconnect()
    }

    /// The test sound is `POST /api/volume/test-sound`, a LAN route the relay's data
    /// channel has no command for. It used to be a throwing default, so the button
    /// answered with a raw -1002; now the session says it is not there, and the
    /// section does not draw it.
    @Test("a client with levels and no test sound offers the one and not the other")
    func levelsWithoutTestSound() async throws {
        var configuration = RobotSession.Configuration()
        configuration.pollInterval = .seconds(60)
        let session = RobotSession(configuration: configuration) { _ in LevelsOnlyClient() }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))

        #expect(session.canAdjustAudio)
        #expect(!session.canPlayTestSound)
        #expect(try await session.volume().percent == 42)
        await #expect(throws: ReachyKitError.audioLevelsUnavailable) {
            try await session.playTestSound()
        }
        session.disconnect()
    }

    /// The 422 is thrown and nothing more. `robotError` is the robot's connection
    /// and power; a refused slider belongs to the audio card, which fills its own
    /// `errorMessage` from what this throws.
    @Test("a rejected level surfaces as 422 and stays off the robot screen")
    func rejection() async throws {
        let client = AudioRobotClient()
        client.rejectsEverything = true
        let session = await session(client)

        await #expect(throws: ReachyKitError.daemonRejected(statusCode: 422)) {
            _ = try await session.setVolume(150)
        }
        #expect(session.robotError == nil)
        #expect(client.accepted.isEmpty)
        session.disconnect()
    }

    @Test("audio calls without a connection report notConnected")
    func disconnected() async throws {
        let session = RobotSession()
        await #expect(throws: ReachyKitError.notConnected) {
            _ = try await session.volume()
        }
        await #expect(throws: ReachyKitError.notConnected) {
            try await session.playTestSound()
        }
    }
}
