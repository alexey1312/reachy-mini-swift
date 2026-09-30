import Foundation
@testable import ReachyKit
@testable import ReachyUI
import Testing

private final class AudioStubClient: RobotAPIClient, AudioLevelClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var speakerWrites: [Int] = []
    private(set) var microphoneWrites: [Int] = []
    /// Simulates a daemon that refuses to go past this, so the slider has to
    /// follow the robot rather than its own last position.
    var ceiling = 100

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
        AudioLevel(percent: 40, platform: "pulseaudio", device: "speaker")
    }

    func microphoneVolume() async throws -> AudioLevel {
        AudioLevel(percent: 20, platform: "pulseaudio", device: "mic")
    }

    func setVolume(_ percent: Int) async throws -> AudioLevel {
        lock.withLock { speakerWrites.append(percent) }
        return AudioLevel(percent: min(percent, ceiling), platform: "pulseaudio", device: "speaker")
    }

    func setMicrophoneVolume(_ percent: Int) async throws -> AudioLevel {
        lock.withLock { microphoneWrites.append(percent) }
        return AudioLevel(percent: min(percent, ceiling), platform: "pulseaudio", device: "mic")
    }
}

@MainActor
@Suite("Audio settings model")
struct AudioSettingsModelTests {
    private func session(_ client: AudioStubClient) async -> RobotSession {
        var configuration = RobotSession.Configuration()
        configuration.pollInterval = .seconds(60)
        let session = RobotSession(configuration: configuration) { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        return session
    }

    @Test("loading seeds the sliders from the robot")
    func loadSeedsSliders() async {
        let client = AudioStubClient()
        let session = await session(client)
        let model = AudioSettingsModel()

        await model.load(session: session)
        #expect(model.speakerPercent == 40)
        #expect(model.microphonePercent == 20)
        #expect(model.speaker?.device == "speaker")
        #expect(model.microphone?.device == "mic")
        // A second appearance must not re-seed and stomp on a value in flight.
        await model.load(session: session)
        session.disconnect()
    }

    @Test("dragging sends nothing; only the end of the gesture writes")
    func draggingIsSilent() async {
        let client = AudioStubClient()
        let session = await session(client)
        let model = AudioSettingsModel()
        await model.load(session: session)

        for percent in stride(from: 41.0, through: 70.0, by: 1) {
            model.speakerPercent = percent
        }
        #expect(client.speakerWrites.isEmpty)

        await model.commitSpeaker(session: session)
        #expect(client.speakerWrites == [70])
        session.disconnect()
    }

    @Test("committing an unchanged level does not fire the daemon's test sound")
    func unchangedLevelIsNotSent() async {
        let client = AudioStubClient()
        let session = await session(client)
        let model = AudioSettingsModel()
        await model.load(session: session)

        await model.commitSpeaker(session: session)
        await model.commitMicrophone(session: session)
        #expect(client.speakerWrites.isEmpty)
        #expect(client.microphoneWrites.isEmpty)

        model.speakerPercent = 55
        await model.commitSpeaker(session: session)
        await model.commitSpeaker(session: session)
        #expect(client.speakerWrites == [55])
        session.disconnect()
    }

    @Test("a clamped answer pulls the slider back")
    func clampedAnswerWins() async {
        let client = AudioStubClient()
        client.ceiling = 60
        let session = await session(client)
        let model = AudioSettingsModel()
        await model.load(session: session)

        model.speakerPercent = 95
        await model.commitSpeaker(session: session)
        #expect(client.speakerWrites == [95])
        #expect(model.speakerPercent == 60)
        session.disconnect()
    }
}
