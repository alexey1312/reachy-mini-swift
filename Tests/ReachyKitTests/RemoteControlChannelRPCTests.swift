import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

/// The JSON-RPC framing daemon 1.10.0 put on the data channel, split out of
/// `RemoteControlChannelTests` when that file reached SwiftLint's 400-line limit.
///
/// A second framing on one channel rather than a second channel, so these cover what
/// the `{type, command}` tests cannot: correlation by `id`, two calls in flight at
/// once, and a frame with no id at all — which is how the daemon fans a running app's
/// own notifications out to every client.
@Suite("Remote control channel — JSON-RPC", .timeLimit(.minutes(1)))
struct RemoteControlChannelRPCTests {
    private func channel(
        _ replies: [String: String] = [:],
        timeout: Duration = .seconds(5),
        openingTimeout: Duration = .seconds(5)
    ) -> (RemoteControlChannel, FakeDataChannel) {
        let fake = FakeDataChannel(replies: replies, isOpen: true)
        return (
            RemoteControlChannel(channel: fake, timeout: timeout, openingTimeout: openingTimeout),
            fake
        )
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
    ///
    /// The **code** is asserted too, and it is the half a caller branches on: the
    /// relay answers `-32000` with `not_running` when no app is running and `-32601`
    /// when the app's build has no such method, and those are different screens. Both
    /// used to arrive as one sentence with the number thrown away.
    @Test("a JSON-RPC error carries the robot's reason and its code")
    func throwsRPCErrorWithReason() async {
        let (control, fake) = channel()

        let call = Task { try await control.call("apps.start", params: ["name": .string("busy")]) }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"#
                + #""message":"an app holds the robot","data":{"reason":"already_running"}}}"#
        )

        await #expect(throws: RemoteControlChannel.Failure.rpc(
            code: -32000,
            message: "an app holds the robot",
            reason: "already_running"
        )) {
            _ = try await call.value
        }
    }

    /// The companion to the one above, and the reason carrying the code cost no
    /// screen anything: `RobotSession.message(for:)` reads `localizedDescription`,
    /// so the sentence a reader sees has to be the one `throwIfRPCError` used to
    /// compose by hand — to the character, reason in parentheses and all.
    @Test("a relayed failure still reads as the sentence it always did")
    func rpcFailureKeepsItsSentence() {
        let withReason = RemoteControlChannel.Failure.rpc(
            code: -32000,
            message: "an app holds the robot",
            reason: "already_running"
        )
        #expect(withReason.localizedDescription == "an app holds the robot (already_running)")

        let bare = RemoteControlChannel.Failure.rpc(code: -32601, message: "Method not found", reason: nil)
        #expect(bare.localizedDescription == "Method not found")
    }

    /// An error object with no `code` is not JSON-RPC-conformant, and it stays the
    /// robot's own words rather than being handed a zero somebody could branch on.
    @Test("a codeless JSON-RPC error is still the robot's words")
    func throwsRobotErrorWithoutACode() async {
        let (control, fake) = channel()

        let call = Task { try await control.call("apps.start", params: ["name": .string("busy")]) }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"error":{"message":"an app holds the robot"}}"#)

        await #expect(throws: RemoteControlChannel.Failure.robot("an app holds the robot")) {
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

    /// The guarantee this framing exists for, and the one a single-call test cannot
    /// see: `apps.install` runs for minutes and a status poll must not queue behind
    /// it, so the id is what pairs a reply with its call. Make `nextRPCID` return a
    /// constant and every other RPC test still passes while these two cross.
    @Test("two calls in flight are answered by id, in either order")
    func matchesConcurrentRPCCallsByID() async throws {
        let (control, fake) = channel()

        async let install: Data = control.call("apps.install")
        await waitUntil("the first call is on the wire") { fake.sent.count == 1 }
        async let status: Data = control.call("apps.status")
        await waitUntil("the second call is on the wire") { fake.sent.count == 2 }

        let ids = try fake.sent.map { try Self.sentRPCID(in: $0) }
        #expect(ids[0] != ids[1])

        // The later call answered first: nothing may serialise behind the install.
        fake.emit(#"{"jsonrpc":"2.0","id":\#(ids[1]),"result":{"state":"idle"}}"#)
        #expect(try await Self.replyState(in: status) == "idle")

        fake.emit(#"{"jsonrpc":"2.0","id":\#(ids[0]),"result":{"state":"installed"}}"#)
        #expect(try await Self.replyState(in: install) == "installed")
    }

    /// JSON-RPC names neither a `type` nor a `command`, and its own keys —
    /// `jsonrpc`, `result`, `id` — are exactly what a `.replyKey` waiter matches on.
    /// Move the RPC branch below the key match in `deliver` and this frame answers
    /// a command that never asked for it.
    @Test("a JSON-RPC frame does not satisfy a waiter keyed on result")
    func rpcFrameDoesNotSatisfyAKeyedWaiter() async throws {
        let (control, fake) = channel(timeout: .milliseconds(200))

        let pending = Task { try await control.perform("some_command", correlation: .replyKey("result")) }
        await waitUntil("the command is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"state":"idle"}}"#)

        await #expect(throws: RemoteControlChannel.Failure.timedOut) { _ = try await pending.value }
    }

    private static func sentRPCID(in frame: String) throws -> Int {
        struct Sent: Decodable {
            let id: Int
        }
        return try JSONCodec.daemon.decode(Sent.self, from: Data(frame.utf8)).id
    }

    private static func replyState(in data: Data) throws -> String {
        struct Reply: Decodable {
            struct Result: Decodable {
                let state: String
            }

            let result: Result
        }
        return try JSONCodec.daemon.decode(Reply.self, from: data).result.state
    }
}

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
