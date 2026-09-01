import Foundation
@testable import ReachyKit
import Testing

@Suite("Remote control channel", .timeLimit(.minutes(1)))
struct RemoteControlChannelTests {
    private func channel(
        _ replies: [String: String] = [:],
        timeout: Duration = .seconds(5),
        openingTimeout: Duration = .seconds(5),
        isOpen: Bool = true
    ) -> (RemoteControlChannel, FakeDataChannel) {
        let fake = FakeDataChannel(replies: replies, isOpen: isOpen)
        return (
            RemoteControlChannel(channel: fake, timeout: timeout, openingTimeout: openingTimeout),
            fake
        )
    }

    /// The robot answers by echoing the command back. There is no request id on
    /// this channel — the echoed `command` is the whole of the correlation.
    @Test("a command is matched to its reply by the command it echoes")
    func matchesByEchoedCommand() async throws {
        let (control, fake) = channel([
            "wake_up": #"{"status":"ok","command":"wake_up","completed":true}"#,
        ])

        try await control.perform("wake_up")

        let sent = try #require(fake.sent.first)
        #expect(sent.contains("\"type\":\"wake_up\"") || sent.contains("\"type\" : \"wake_up\""))
    }

    /// A failure comes back on the same channel, as a field rather than a status
    /// code, and carries the robot's own words.
    @Test("an error reply is thrown with the robot's own message")
    func throwsTheRobotsError() async {
        let (control, _) = channel([
            "wake_up": #"{"error":"Backend not running","command":"wake_up"}"#,
        ])

        await #expect(throws: RemoteControlChannel.Failure.robot("Backend not running")) {
            try await control.perform("wake_up")
        }
    }

    /// The robot broadcasts things nobody asked for — move progress, for one — and
    /// a reply to a command still in flight must not be lost among them.
    @Test("an unsolicited message does not satisfy a pending command")
    func ignoresUnrelatedMessages() async throws {
        let (control, fake) = channel()

        async let reply = control.perform("wake_up")
        // The recorded send is what proves the waiter is registered — it is
        // fired only after the continuation is filed — so polling for it (rule
        // 7) replaces a fixed pause a starved runner could beat, where the
        // reply became "an answer nobody asked for" and the test rode out the
        // whole command timeout.
        await waitUntil("the command is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"type":"play_uploaded_move","upload_id":"u1","finished":true}"#)
        fake.emit(#"{"status":"ok","command":"goto_sleep","completed":true}"#)
        fake.emit(#"{"status":"ok","command":"wake_up","completed":true}"#)

        _ = try await reply
    }

    /// Nothing on this channel says how long a command may take, and a caller left
    /// awaiting forever is worse than one told the robot went quiet.
    @Test("a command the robot never answers gives up")
    func timesOut() async {
        let (control, _) = channel(timeout: .milliseconds(100))

        await #expect(throws: RemoteControlChannel.Failure.timedOut) {
            try await control.perform("wake_up")
        }
    }

    /// Over the relay the robot opens the channel, and only once signaling, ICE and
    /// DTLS are through — so a command issued before that waits for a session as
    /// well as for a reply, and gets its own budget for it.
    @Test("a command sent before the channel opens waits on the opening budget")
    func spendsTheOpeningBudgetBeforeTheChannelOpens() async {
        let (control, _) = channel(
            timeout: .seconds(30), openingTimeout: .milliseconds(100), isOpen: false
        )

        await expectTimeout {
            try await control.perform("get_version", correlation: .replyKey("version"))
        }
    }

    /// Once it is open, a robot that says nothing is just a robot that says nothing.
    @Test("an open channel puts a command on the reply budget")
    func spendsTheReplyBudgetOnceOpen() async {
        let (control, _) = channel(timeout: .milliseconds(100), openingTimeout: .seconds(30))

        await expectTimeout { try await control.perform("wake_up") }
    }

    /// And it is a question about now, not a stage the channel grows out of. An ICE
    /// failure replaces the peer under a session that has been up for hours, and
    /// the command after it waits out a whole negotiation again.
    @Test("a channel that lost its peer is back on the opening budget")
    func returnsToTheOpeningBudgetWhenThePeerGoes() async {
        let (control, fake) = channel(timeout: .seconds(30), openingTimeout: .milliseconds(100))
        fake.losePeer()

        await expectTimeout { try await control.perform("wake_up") }
    }

    /// Both budgets end in `.timedOut`, so the error alone proves nothing about
    /// which one was in force — the 100 ms budget answering 30 s late is still a
    /// `.timedOut`. Only the elapsed time tells them apart, so it is asserted:
    /// generously, since it is separating milliseconds from tens of seconds, and a
    /// loaded runner cannot stretch one into the other.
    private func expectTimeout(_ command: () async throws -> Void) async {
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: RemoteControlChannel.Failure.timedOut) { try await command() }
        #expect(clock.now - started < .seconds(5))
    }

    /// Not every reply echoes a command: `get_version` answers a bare
    /// `{"version": …}`, `get_hardware_id` a bare `{"hardware_id": …}`. The caller
    /// says which key identifies its reply, because nothing on the wire does.
    @Test("a reply that echoes no command is matched by the key it carries")
    func matchesByReplyKey() async throws {
        let (control, _) = channel(["get_version": #"{"version":"1.9.0"}"#])

        struct Reply: Decodable {
            let version: String
        }

        let reply = try await control.perform(
            "get_version",
            correlation: .replyKey("version"),
            expecting: Reply.self
        )

        #expect(reply.version == "1.9.0")
    }

    /// Telemetry always names a `type` and never a `command`. One of those
    /// broadcasts carries a `state` of its own, so a caller waiting on `get_state`
    /// must not take the first message that happens to hold the key.
    @Test("a broadcast is not mistaken for the keyed reply it resembles")
    func ignoresABroadcastCarryingTheSameKey() async throws {
        let (control, fake) = channel()

        async let reply = control.perform("get_state", correlation: .replyKey("state"))
        // Same shape as above: the send on the wire is the proof the waiter is
        // registered and the broadcasts below cannot arrive ahead of it.
        await waitUntil("the command is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"type":"daemon_status","robot_name":"reachy","state":"running"}"#)
        fake.emit(#"{"state":{"body_yaw":0.5}}"#)

        let data = try await reply
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["type"] == nil)
    }

    @Test("a reply with a payload comes back decoded")
    func decodesAPayload() async throws {
        let (control, _) = channel([
            "get_state": #"""
            {"command":"get_state","state":{"body_yaw":0.5,"motor_mode":"enabled","is_move_running":false}}
            """#,
        ])

        struct State: Decodable, Equatable {
            let bodyYaw: Double
            let motorMode: String

            enum CodingKeys: String, CodingKey {
                case bodyYaw = "body_yaw"
                case motorMode = "motor_mode"
            }
        }
        struct Reply: Decodable {
            let state: State
        }

        let reply = try await control.perform("get_state", expecting: Reply.self)

        #expect(reply.state == State(bodyYaw: 0.5, motorMode: "enabled"))
    }

    /// Two commands of the same name cannot be told apart on the wire, so they are
    /// not allowed to be in flight together — the second would take the first's
    /// reply.
    @Test("the same command twice runs one after the other")
    func serialisesIdenticalCommands() async throws {
        let (control, fake) = channel([
            "wake_up": #"{"status":"ok","command":"wake_up","completed":true}"#,
        ])

        async let first = control.perform("wake_up")
        async let second = control.perform("wake_up")
        _ = try await first
        _ = try await second

        #expect(fake.sent.count == 2)
    }

    /// A WebRTC session is re-negotiated in place: the peer connection is replaced,
    /// its data channel with it, while the control channel above stays the same
    /// object. The first close must not deafen it for good.
    @Test("a channel that closed serves commands again once it reopens")
    func readsAgainAfterTheStreamEnds() async throws {
        let (control, fake) = channel([
            "wake_up": #"{"status":"ok","command":"wake_up","completed":true}"#,
        ], timeout: .seconds(2))

        let inFlight = Task { try await control.perform("get_version", correlation: .replyKey("version")) }
        while !fake.isListening {
            await Task.yield()
        }
        fake.close()
        await #expect(throws: RemoteControlChannel.Failure.closed) { _ = try await inFlight.value }

        try await control.perform("wake_up")
    }

    /// Commands carry parameters, and the robot's models name them its way.
    @Test("a payload is sent alongside the command type")
    func sendsAPayload() async throws {
        let (control, fake) = channel([
            "set_volume": #"{"status":"ok","command":"set_volume","completed":true}"#,
        ])

        try await control.perform("set_volume", payload: ["volume": .number(42)])

        let sent = try #require(fake.sent.first)
        let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        #expect(object?["type"] as? String == "set_volume")
        #expect(object?["volume"] as? Double == 42)
    }

    /// Daemon 1.10.0 answers `get_imu` with the same `imu_data` frame the robot also
    /// publishes on its own, so a `type` stopped being proof that nobody asked.
    @Test("a reply that names a type answers the command waiting on it")
    func matchesByReplyType() async throws {
        let (control, fake) = channel()

        async let reply: Data = control.perform("get_imu", correlation: .typed("imu_data"))
        await waitUntil("the command is on the wire") { !fake.sent.isEmpty }
        // Routing is by `type` alone, so the frame carries nothing else: what the
        // payload decodes into is `RemoteRobotConnection`'s business, not this one's.
        fake.emit(#"{"type":"imu_data","temperature":30}"#)

        let payload = try await reply
        #expect(!payload.isEmpty)
    }

    /// And everything else keeps going to subscribers: the type-matched path may
    /// only claim a frame somebody is actually waiting for.
    @Test("a broadcast nobody waits on still reaches its subscribers")
    func leavesUnclaimedBroadcastsToListeners() async {
        let (control, fake) = channel()
        // The stream buffers, so subscribing before the emit is enough — no second
        // task, and nothing to race against.
        var lines = await control.broadcasts(ofType: "log_line").makeAsyncIterator()
        fake.emit(#"{"type":"log_line","line":"hello"}"#)
        #expect(await lines.next() != nil)
    }

    /// Daemon 1.10.0 puts the apps API behind JSON-RPC on this same channel. Its
    /// replies name neither a command nor a type, so the id is the whole of the
    /// correlation.
    @Test("a JSON-RPC reply is matched to its call by id")
    func matchesRPCByID() async throws {
        let (control, fake) = channel()

        async let reply: Data = control.call("apps.status")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        let sent = try #require(fake.sent.first)
        #expect(sent.contains("\"method\""))
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"state":"idle"}}"#)

        #expect(try await !reply.isEmpty)
    }

    /// The failure is an object here, not the `error` string the other protocol
    /// uses, and the daemon's own `reason` is what tells a busy robot from a broken
    /// one.
    @Test("a JSON-RPC error carries the robot's reason")
    func throwsRPCErrorWithReason() async {
        let (control, fake) = channel()

        let call = Task { try await control.call("apps.start", params: ["name": .string("busy")]) }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"#
                + #""message":"an app holds the robot","data":{"reason":"already_running"}}}"#
        )

        await #expect(throws: RemoteControlChannel.Failure.robot(
            "an app holds the robot (already_running)"
        )) {
            _ = try await call.value
        }
    }

    /// A frame with no id is the running app talking, fanned out by the daemon.
    @Test("a JSON-RPC notification reaches its subscribers")
    func deliversRPCNotifications() async {
        let (control, fake) = channel()
        var turns = await control.broadcasts(ofType: "conversation.turn").makeAsyncIterator()

        fake.emit(#"{"jsonrpc":"2.0","method":"conversation.turn","params":{"state":"listening"}}"#)

        #expect(await turns.next() != nil)
    }
}

/// Nonisolated, unlike `ConnectProgressModelTests`' copy: every condition here
/// closes over an `@unchecked Sendable` fake, not main-actor state.
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
