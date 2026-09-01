import Foundation
@testable import ReachyKit
import Testing

/// Answers the daemon's own shapes, taken from `process_command` in
/// `daemon/backend/abstract.py` rather than invented.
private final class ScriptedChannel: RemoteDataChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?
    private var pending: [String] = []
    private var recorded: [String] = []
    private let scripted: [String: String]

    init(_ replies: [String: String]) {
        scripted = replies
    }

    var sent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// These tests are about what the commands say, not about how long they may
    /// take, so the channel is simply up throughout.
    let isOpen = true

    func send(_ text: String) async throws {
        guard let reply = record(text) else { return }
        emit(reply)
    }

    private func record(_ text: String) -> String? {
        let command = try? JSONDecoder().decode(TypeOnly.self, from: Data(text.utf8)).type
        lock.lock()
        defer { lock.unlock() }
        recorded.append(text)
        guard let command else { return nil }
        return scripted[command]
    }

    func messages() -> AsyncStream<String> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            let backlog = pending
            pending = []
            lock.unlock()
            for text in backlog {
                continuation.yield(text)
            }
        }
    }

    func emit(_ text: String) {
        lock.lock()
        let listener = continuation
        if listener == nil {
            pending.append(text)
        }
        lock.unlock()
        listener?.yield(text)
    }

    private struct TypeOnly: Decodable {
        let type: String
    }
}

@Suite("Remote robot connection", .timeLimit(.minutes(1)))
struct RemoteRobotConnectionTests {
    private static let identity = [
        "get_version": #"{"version":"1.9.0"}"#,
        "get_hardware_id": #"{"hardware_id":"a1b2c3d4e5f60718"}"#,
    ]

    private func connection(
        _ replies: [String: String] = [:],
        robotName: String? = "reachy-mini"
    ) -> (RemoteRobotConnection, ScriptedChannel) {
        let channel = ScriptedChannel(Self.identity.merging(replies) { _, new in new })
        return (
            RemoteRobotConnection(channel: channel, robotName: robotName, timeout: .seconds(5)),
            channel
        )
    }

    /// Neither command echoes its name back, so both are only findable by the key
    /// they carry — the case the channel's `replyKey` correlation exists for.
    @Test("the handshake reads version and hardware id off the channel")
    func handshakeReadsIdentity() async throws {
        let (connection, _) = connection()

        let handshake = try await connection.handshake()

        #expect(handshake.identity.daemonVersion == "1.9.0")
        #expect(handshake.identity.hardwareID == "a1b2c3d4e5f60718")
    }

    /// The channel cannot report a name — no command answers one — so it comes
    /// from the central listing that got us to this robot in the first place.
    @Test("the robot's name comes from the listing, not the channel")
    func nameComesFromTheListing() async throws {
        let (connection, _) = connection(robotName: "kitchen bot")

        let handshake = try await connection.handshake()

        #expect(handshake.identity.name == "kitchen bot")
        #expect(handshake.status.robotName == "kitchen bot")
    }

    /// `/wifi/*` and `/update/*` are HTTP routes on the robot's own network, so
    /// they are genuinely out of reach here. Reporting the robot as non-wireless
    /// is what closes those screens, and it closes them for a true reason.
    @Test("a remote robot reports no wireless features")
    func reportsNoWirelessFeatures() async throws {
        let (connection, _) = connection()

        let status = try await connection.daemonStatus()

        #expect(status.wirelessVersion == false)
        #expect(status.state == .running)
    }

    /// `motor_mode` is what `RobotSession.isAwake` gates on, and `get_state` is the
    /// only place this channel reports it. While the assembled status left it out,
    /// a remote robot read as permanently asleep however awake it was — which
    /// disabled teleop, moves and the viewport for the whole session.
    @Test("the motor mode is read off get_state")
    func reportsTheMotorMode() async throws {
        let (connection, _) = connection([
            "get_state": #"""
            {"state":{"body_yaw":0.0,"motor_mode":"enabled","is_recording":false,"is_move_running":false}}
            """#,
        ])

        let status = try await connection.daemonStatus()

        #expect(status.backendStatus?.value1?.motorControlMode == .enabled)
    }

    /// A robot parked in `disabled` answers every motion command and stays limp,
    /// so the mode has to come through as it is rather than be assumed awake.
    @Test("a sleeping robot is reported asleep")
    func reportsASleepingRobot() async throws {
        let (connection, _) = connection([
            "get_state": #"{"state":{"motor_mode":"disabled","is_move_running":false}}"#,
        ])

        let status = try await connection.daemonStatus()

        #expect(status.backendStatus?.value1?.motorControlMode == .disabled)
    }

    /// One quiet reply must not drop a working session to `.unreachable`: the
    /// status still says the backend is running, and only the mode is unknown.
    @Test("a get_state that never answers still yields a status")
    func survivesAQuietGetState() async throws {
        let (connection, _) = connection()

        let status = try await connection.daemonStatus()

        #expect(status.state == .running)
        #expect(status.backendStatus == nil)
    }

    /// A timeout can mean an older daemon that does not answer `get_state`; an
    /// ended stream cannot. Once identity is cached, this command is the status
    /// poll's only proof that the remote transport still exists.
    @Test("a closed data channel fails status polling")
    func surfacesAClosedChannel() async throws {
        let channel = FakeDataChannel(replies: Self.identity.merging([
            "get_state": #"{"state":{"motor_mode":"enabled"}}"#,
        ]) { _, new in new })
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        _ = try await connection.daemonStatus()
        channel.removeReply(for: "get_state")
        let sentBeforePolling = channel.sent.count
        let status = Task {
            try await connection.daemonStatus()
        }

        while !channel.isListening
            || channel.sent.count == sentBeforePolling
        {
            await Task.yield()
        }
        channel.close()

        await #expect(throws: RemoteControlChannel.Failure.closed) {
            _ = try await status.value
        }
    }

    /// Neither answer changes for the life of a session and the status poll runs
    /// every three seconds, so asking again would be three commands a tick where
    /// one will do.
    @Test("version and hardware id are asked once and held")
    func cachesIdentityAcrossPolls() async throws {
        let (connection, channel) = connection([
            "get_state": #"{"state":{"motor_mode":"enabled"}}"#,
        ])

        _ = try await connection.daemonStatus()
        _ = try await connection.daemonStatus()

        #expect(channel.sent.count(where: { $0.contains("get_version") }) == 1)
        #expect(channel.sent.count(where: { $0.contains("get_hardware_id") }) == 1)
        #expect(channel.sent.count(where: { $0.contains("get_state") }) == 2)
    }

    /// A name is whatever its owner typed into the Hub, and it reaches the
    /// assembled status through JSON — so a quote in it must not end the string.
    @Test("a robot name carrying a quote survives the assembled status")
    func escapesTheRobotName() async throws {
        let (connection, _) = connection(robotName: #"the "kitchen" bot"#)

        let status = try await connection.daemonStatus()

        #expect(status.robotName == #"the "kitchen" bot"#)
    }

    @Test("waking up sends the command and waits for the move to finish")
    func wakesUp() async throws {
        let (connection, channel) = connection([
            "wake_up": #"{"status":"ok","command":"wake_up","completed":true}"#,
        ])

        _ = try await connection.wakeUp()

        #expect(channel.sent.contains { $0.contains("\"wake_up\"") })
    }

    /// The robot answers a failure on the same channel, as a field rather than a
    /// status code, and the message is its own.
    @Test("a refused wake-up surfaces the robot's message")
    func surfacesARefusal() async {
        let (connection, _) = connection([
            "wake_up": #"{"error":"Backend not running","command":"wake_up"}"#,
        ])

        await #expect(throws: RemoteControlChannel.Failure.robot("Backend not running")) {
            _ = try await connection.wakeUp()
        }
    }

    /// The data channel's volume reply is `{"command": …, "volume": …}` — a level
    /// and nothing else, where the REST route also names the sink.
    @Test("volume comes back without a device to name")
    func readsVolume() async throws {
        let (connection, _) = connection([
            "get_volume": #"{"command":"get_volume","volume":65}"#,
        ])

        let level = try await connection.volume()

        #expect(level.percent == 65)
        #expect(level.device == nil)
        #expect(level.platform == nil)
    }

    /// The daemon answers `set_volume` with the level it settled on, which is not
    /// the requested one when the platform refuses it.
    @Test("a rejected volume comes back at the level the robot kept")
    func reportsTheVolumeTheRobotKept() async throws {
        let (connection, _) = connection([
            "set_volume": #"{"status":"error","command":"set_volume","volume":30}"#,
        ])

        let level = try await connection.setVolume(80)

        #expect(level.percent == 30)
    }

    /// Nothing on this channel serves `/api/kinematics/*`, so the protocol's
    /// throwing default stands rather than a stub that pretends. The description
    /// and its meshes come out of the app instead — see `BundledGeometryClient`.
    @Test("a route the channel does not carry stays unimplemented")
    func leavesUnreachableRoutesAlone() async {
        let (connection, _) = connection()

        await #expect(throws: (any Error).self) {
            _ = try await connection.urdf()
        }
    }

    /// The library index is the one part of playback this channel has no command
    /// for. Everything else it does carry, which is why the conformance is here at
    /// all — `canPlayMoves` asks exactly this question.
    @Test("playback is carried; the library index is not")
    func carriesPlaybackWithoutTheIndex() async {
        let (connection, _) = connection()

        #expect(connection.offersMoveLibrary)
        #expect(!connection.offersMoveIndex)
        await #expect(throws: (any Error).self) {
            _ = try await connection.listMoves(dataset: "pollen-robotics/reachy-mini-dances-library")
        }
    }

    /// Daemon 1.10.0's apps API, over JSON-RPC on the same channel. The three verbs
    /// about the app *already running* are carried; the store is not, which is what
    /// `offersAppStore` says and what keeps the Apps tab honest over the relay.
    @Test("the running app can be read and stopped, and the store cannot be shown")
    func controlsTheRunningAppWithoutAStore() async throws {
        let (connection, fake) = connection()

        // Conformance is static now, so the compiler proves that half. What is
        // worth asserting is the part that decides the screen.
        #expect(!connection.offersAppStore)

        let status = Task { try await connection.currentAppStatus() }
        // The recorded send is what proves the waiter is filed, and this file
        // yields for it rather than sleeping — the idiom above.
        while fake.sent.isEmpty {
            await Task.yield()
        }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"result":{"state":"running","error":null,"#
                + #""info":{"name":"conversation","source_kind":"hf_space","extra":{}}}}"#
        )

        let reported = try await status.value
        #expect(reported?.state == .running)
        #expect(reported?.app.name == "conversation")
    }

    /// Idle is the daemon saying there is no app, not describing one — the same
    /// shape the HTTP route answers with a literal `null`.
    @Test("an idle robot reports no app at all")
    func reportsNoAppWhenIdle() async throws {
        let (connection, fake) = connection()

        let status = Task { try await connection.currentAppStatus() }
        // The recorded send is what proves the waiter is filed, and this file
        // yields for it rather than sleeping — the idiom above.
        while fake.sent.isEmpty {
            await Task.yield()
        }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"state":"idle","info":null,"error":null}}"#)

        #expect(try await status.value == nil)
    }
}
