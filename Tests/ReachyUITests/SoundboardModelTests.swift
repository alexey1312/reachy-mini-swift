import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The daemon double for the soundboard. It keeps a library so the model's own picture
/// can be compared against the robot's, and records every call in order — which is what
/// the upload-then-play sequence is asserted on.
private class SoundlessUIClient: RobotAPIClient, @unchecked Sendable {
    /// Set before the session connects: the model reads `isAwake` off the status the
    /// handshake captured.
    var motorMode = "enabled"

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name":"testbot","state":"running","wireless_version":false,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":{"motor_control_mode":"\(motorMode)","error":null}}
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

    /// Declared here rather than left to the protocol's throwing default, so the
    /// subclass can override it — a class cannot override a protocol extension.
    func stopSound() async throws {
        throw URLError(.unsupportedURL)
    }
}

private final class SoundUIClient: SoundlessUIClient, SoundboardClient {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    var onRobot: [String] = []
    /// Thrown by the next upload alone, which is how a half-finished send is tested.
    var uploadFailure: (any Error)?
    var deleteFailure: (any Error)?

    func sounds() async throws -> [RobotSound] {
        lock.withLock { calls.append("list") }
        return lock.withLock { onRobot }.map(RobotSound.init(filename:))
    }

    func playSound(named filename: String) async throws {
        lock.withLock { calls.append("play:\(filename)") }
    }

    func uploadSound(named filename: String, data: Data) async throws {
        lock.withLock { calls.append("upload:\(filename):\(data.count)") }
        if let uploadFailure {
            throw uploadFailure
        }
        lock.withLock {
            if !onRobot.contains(filename) {
                onRobot.append(filename)
            }
        }
    }

    func deleteSound(named filename: String) async throws {
        lock.withLock { calls.append("delete:\(filename)") }
        if let deleteFailure {
            throw deleteFailure
        }
        lock.withLock { onRobot.removeAll { $0 == filename } }
    }

    override func stopSound() async throws {
        lock.withLock { calls.append("stop") }
    }
}

@MainActor
@Suite("SoundboardModel", .timeLimit(.minutes(1)))
struct SoundboardModelTests {
    /// A library root per test: there are no suites for a file system, and the default
    /// store is the app group's real one.
    private func withModel(
        _ client: any RobotAPIClient,
        stored: [String] = [],
        body: (SoundboardModel, RobotSession) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundboardModelTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SoundLibraryStore(root: root)
        for name in stored {
            try await library.add(Data([0x00, 0x01]), named: name)
        }
        var configuration = RobotSession.Configuration()
        configuration.pollInterval = .seconds(60)
        let session = RobotSession(configuration: configuration) { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        try await body(SoundboardModel(library: library), session)
        session.disconnect()
    }

    @Test("a load says which copy of each sound exists")
    func mergesBothLibraries() async throws {
        let client = SoundUIClient()
        client.onRobot = ["airhorn.wav", "tada.m4a"]
        try await withModel(client, stored: ["airhorn.wav", "rimshot.ogg"]) { model, session in
            await model.load(session: session)

            #expect(model.rows.map(\.id) == ["airhorn.wav", "rimshot.ogg", "tada.m4a"])
            #expect(model.rows.map(\.presence) == [.both, .deviceOnly, .robotOnly])
            #expect(model.hasListed)
            #expect(!model.isContentLoading)
        }
    }

    /// **The order is the feature.** The robot forgets its `/tmp` on a restart, so a tap
    /// on a sound it no longer has must send the file before playing — `play_sound`
    /// answers `{"status":"ok"}` for a name that matches nothing, so the alternative is a
    /// tap that reports success into silence.
    @Test("playing a sound the robot lost sends it first")
    func sendsBeforePlaying() async throws {
        let client = SoundUIClient()
        try await withModel(client, stored: ["airhorn.wav"]) { model, session in
            await model.load(session: session)
            let row = try #require(model.rows.first)
            #expect(row.presence == .deviceOnly)

            await model.play(row, session: session)

            #expect(client.calls == ["list", "upload:airhorn.wav:2", "play:airhorn.wav"])
            #expect(model.rows.first?.presence == .both)
            #expect(model.lastPlayed == "airhorn.wav")
            #expect(model.lastError == nil)
        }
    }

    @Test("playing a sound the robot already has sends nothing")
    func skipsTheUploadWhenItIsThere() async throws {
        let client = SoundUIClient()
        client.onRobot = ["airhorn.wav"]
        try await withModel(client, stored: ["airhorn.wav"]) { model, session in
            await model.load(session: session)
            let row = try #require(model.rows.first)

            await model.play(row, session: session)

            #expect(client.calls == ["list", "play:airhorn.wav"])
        }
    }

    /// A sound only the robot has cannot be sent — no route returns the bytes — so a play
    /// must not try, and the row says so rather than offering a repair that cannot work.
    @Test("a sound only the robot has is played without a send")
    func playsARobotOnlySound() async throws {
        let client = SoundUIClient()
        client.onRobot = ["tada.m4a"]
        try await withModel(client) { model, session in
            await model.load(session: session)
            let row = try #require(model.rows.first)
            #expect(row.presence == .robotOnly)

            await model.play(row, session: session)

            #expect(client.calls == ["list", "play:tada.m4a"])
        }
    }

    /// The reason belongs to this screen. `robotError` is the robot's connection and
    /// power, and a refused sound is neither — the line `RobotSessionErrorOwnershipTests`
    /// holds in `ReachyKit` and every model here has to keep.
    @Test("a refused send leaves the row unsent and the reason on the model")
    func reportsARefusedSend() async throws {
        let client = SoundUIClient()
        client.uploadFailure = ReachyKitError.daemonRefused(
            statusCode: 400,
            detail: "Unsupported or invalid audio file"
        )
        try await withModel(client, stored: ["airhorn.wav"]) { model, session in
            await model.load(session: session)
            let row = try #require(model.rows.first)

            await model.play(row, session: session)

            #expect(client.calls == ["list", "upload:airhorn.wav:2"])
            #expect(model.rows.first?.presence == .deviceOnly)
            #expect(model.lastError?.contains("Unsupported or invalid audio file") == true)
            #expect(session.robotError == nil)
        }
    }

    /// **A listing that failed is not evidence the robot is missing anything**, so the
    /// rows stay on screen as `unknown` rather than claiming a device-only library.
    @Test("a failed listing leaves the device's library on screen and claims nothing")
    func keepsTheLibraryWhenTheRobotIsSilent() async throws {
        try await withModel(SoundlessUIClient(), stored: ["airhorn.wav"]) { model, session in
            await model.load(session: session)

            #expect(model.rows.map(\.presence) == [.unknown])
            #expect(!model.hasListed)
            #expect(model.hasAttempted)
            // The spinner has to come down even though nothing was ever listed, or the
            // reason underneath it is never read.
            #expect(!model.isContentLoading)
            #expect(model.lastError != nil)
        }
    }

    @Test("deleting the robot's copy keeps this device's")
    func deletesOnlyTheRobotsCopy() async throws {
        let client = SoundUIClient()
        client.onRobot = ["airhorn.wav"]
        try await withModel(client, stored: ["airhorn.wav"]) { model, session in
            await model.load(session: session)
            let row = try #require(model.rows.first)

            await model.deleteFromRobot(row, session: session)

            #expect(model.rows.map(\.presence) == [.deviceOnly])
            #expect(model.lastError == nil)
        }
    }

    /// Measured on 2026-08-17: `delete_sound` answers 404 for a name it does not have.
    /// That is the outcome the tap asked for, so it may not surface as a failure.
    @Test("deleting a sound that is already gone is not a failure")
    func swallowsAMissingSound() async throws {
        let client = SoundUIClient()
        client.onRobot = ["airhorn.wav"]
        client.deleteFailure = ReachyKitError.daemonRefused(statusCode: 404, detail: "File not found")
        try await withModel(client, stored: ["airhorn.wav"]) { model, session in
            await model.load(session: session)
            let row = try #require(model.rows.first)

            await model.deleteFromRobot(row, session: session)

            #expect(model.lastError == nil)
            #expect(model.rows.map(\.presence) == [.deviceOnly])
        }
    }

    @Test("forgetting this device's copy leaves the robot's alone")
    func removesOnlyTheDeviceCopy() async throws {
        let client = SoundUIClient()
        client.onRobot = ["airhorn.wav"]
        try await withModel(client, stored: ["airhorn.wav"]) { model, session in
            await model.load(session: session)
            let row = try #require(model.rows.first)

            await model.removeFromDevice(row)

            #expect(model.rows.map(\.presence) == [.robotOnly])
        }
    }

    /// Sequential, and it stops at the first refusal: the daemon probes each upload with
    /// GStreamer before answering, and a phone throwing six at that in parallel is how a
    /// well-meaning refresh times out.
    @Test("sending everything missing stops at the first refusal")
    func sendsMissingUntilOneFails() async throws {
        let client = SoundUIClient()
        try await withModel(client, stored: ["airhorn.wav", "rimshot.ogg"]) { model, session in
            await model.load(session: session)
            #expect(model.missingFromRobot.count == 2)
            client.uploadFailure = ReachyKitError.daemonRejected(statusCode: 503)

            await model.sendMissing(session: session)

            #expect(client.calls == ["list", "upload:airhorn.wav:2"])
            #expect(model.missingFromRobot.count == 2)
        }
    }

    /// Playing needs a backend and the capability, and **not** an awake robot: a speaker
    /// is not a motor, so a parked robot plays perfectly well and gating these rows on
    /// `isAwake` would refuse something that works. Delete the `isAwake` absence from
    /// `rowsAreEnabled` — that is, add one — and the middle expectation goes red.
    @Test("rows are enabled by the backend and the capability, never by the motors")
    func gatesOnTheBackendAlone() async throws {
        let parked = SoundUIClient()
        parked.motorMode = "disabled"
        try await withModel(parked, stored: ["airhorn.wav"]) { model, session in
            #expect(!session.isAwake)
            #expect(model.rowsAreEnabled(session))
        }
        // A relayed session carries no `/api/media/*`, so there is nothing to enable.
        try await withModel(SoundlessUIClient()) { model, session in
            #expect(!model.rowsAreEnabled(session))
        }
    }

    /// **A `confirmationDialog` captures as nothing** — recorded twice for `RobotScreen`'s
    /// power-off dialog and byte-identical both times — so its wording is covered here or
    /// nowhere. Each sentence has to say what *survives*, because that is the only
    /// difference between the two deletions.
    @Test("each confirmation says what survives it")
    func confirmationCopySaysWhatSurvives() async throws {
        let client = SoundUIClient()
        client.onRobot = ["airhorn.wav", "tada.m4a"]
        try await withModel(client, stored: ["airhorn.wav", "rimshot.ogg"]) { model, session in
            await model.load(session: session)
            let both = try #require(model.rows.first { $0.presence == .both })
            let deviceOnly = try #require(model.rows.first { $0.presence == .deviceOnly })
            let robotOnly = try #require(model.rows.first { $0.presence == .robotOnly })

            model.confirming = .robot(both)
            #expect(String(localized: model.confirmationTitle) == "Delete from the robot?")
            #expect(resolve(model.confirmationMessage(for: .robot(both))).contains("can be sent again"))
            #expect(resolve(model.confirmationMessage(for: .robot(robotOnly))).contains("cannot be undone"))

            model.confirming = .device(both)
            // A title that differs from its button by more than punctuation: the catalogue
            // derives one Swift symbol per key, so `Remove from this device?` beside the
            // button's `Remove from this device` is a build error.
            #expect(String(localized: model.confirmationTitle) == "Forget this sound?")
            #expect(resolve(model.confirmationMessage(for: .device(both))).contains("stays on the robot"))
            #expect(resolve(model.confirmationMessage(for: .device(deviceOnly))).contains("cannot be undone"))
        }
    }

    /// The catalogue carries no translations, so a resource resolves to its own key with
    /// the arguments substituted — which is exactly the English sentence.
    private func resolve(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }

    @Test("an imported file is copied here and sent in one action")
    func importsAndSends() async throws {
        let client = SoundUIClient()
        let picked = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: picked)
        defer { try? FileManager.default.removeItem(at: picked) }

        try await withModel(client) { model, session in
            await model.load(session: session)

            await model.importFile(at: picked, session: session)

            let name = picked.lastPathComponent
            #expect(client.calls == ["list", "upload:\(name):4"])
            #expect(model.rows.map(\.id) == [name])
            #expect(model.rows.first?.presence == .both)
        }
    }
}
