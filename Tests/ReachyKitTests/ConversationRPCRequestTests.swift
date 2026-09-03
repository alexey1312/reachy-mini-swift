import Foundation
import Network
@testable import ReachyKit
import Testing

/// The request half of Conversation App 1.0's JSON-RPC surface — the half the dock's
/// mute and interrupt buttons ride on.
@Suite("Conversation JSON-RPC requests", .timeLimit(.minutes(1)))
struct ConversationRPCRequestTests {
    /// Answers whatever the client asks with `body(id)`, and records the request.
    private func server(
        recording sent: Recorder,
        answering body: @escaping @Sendable (String) -> String
    ) throws -> LocalWebSocketServer {
        try LocalWebSocketServer { connection in
            LocalWebSocketServer.receiveText(over: connection) { text in
                sent.record(text)
                let id = Self.id(in: text) ?? "0"
                LocalWebSocketServer.sendText(body(id), over: connection)
            }
        }
    }

    private static func id(in frame: String) -> String? {
        guard let data = frame.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["id"] as? Int).map(String.init) ?? object["id"] as? String
    }

    private func client(port: UInt16, replyTimeout: Duration = .seconds(5)) throws -> ConversationRPCClient {
        var configuration = ConversationRPCClient.Configuration()
        configuration.replyTimeout = replyTimeout
        return try ConversationRPCClient(
            address: RobotAddress(host: "127.0.0.1"),
            port: Int(port),
            configuration: configuration
        )
    }

    @Test("a mute sends a well-formed JSON-RPC request and returns on the reply")
    func sendsMute() async throws {
        let sent = Recorder()
        let server = try server(recording: sent) { #"{"jsonrpc":"2.0","id":\#($0),"result":{"muted":true}}"# }
        defer { server.stop() }
        let port = try await server.readyPort()

        try await client(port: port).setMicrophoneMuted(true)

        let frame = try #require(sent.first)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["method"] as? String == "conversation.mic")
        #expect(object["id"] != nil)
        #expect((object["params"] as? [String: Any])?["muted"] as? Bool == true)
    }

    /// The socket carries the app's broadcast notifications too, and they arrive
    /// whenever the conversation moves — including in the gap between a request and
    /// its reply. A reader that took the first frame it saw would resolve on one.
    @Test("notifications arriving before the reply are skipped")
    func skipsNotifications() async throws {
        let sent = Recorder()
        let server = try LocalWebSocketServer { connection in
            LocalWebSocketServer.receiveText(over: connection) { text in
                sent.record(text)
                let id = Self.id(in: text) ?? "0"
                LocalWebSocketServer.sendText(
                    #"{"jsonrpc":"2.0","method":"conversation.turn","params":{"state":"thinking"}}"#,
                    over: connection
                ) {
                    LocalWebSocketServer.sendText(#"{"jsonrpc":"2.0","id":\#(id),"result":null}"#, over: connection)
                }
            }
        }
        defer { server.stop() }
        let port = try await server.readyPort()

        try await client(port: port).interrupt()

        #expect(sent.first?.contains("conversation.interrupt") == true)
    }

    /// The one error the caller acts on rather than reports: a build of the app that
    /// never had this method. The control is hidden rather than left to fail.
    @Test("an unknown method is reported as such, not as a generic failure")
    func reportsUnknownMethod() async throws {
        let sent = Recorder()
        let server = try server(recording: sent) {
            #"{"jsonrpc":"2.0","id":\#($0),"error":{"code":-32601,"message":"Method not found"}}"#
        }
        defer { server.stop() }
        let port = try await server.readyPort()

        await #expect(throws: ConversationRPCClient.Failure.methodNotFound) {
            try await client(port: port).interrupt()
        }
    }

    @Test("any other error carries the app's own words")
    func reportsRejection() async throws {
        let sent = Recorder()
        let server = try server(recording: sent) {
            #"{"jsonrpc":"2.0","id":\#($0),"error":{"code":-32000,"message":"No conversation running"}}"#
        }
        defer { server.stop() }
        let port = try await server.readyPort()

        await #expect(throws: ConversationRPCClient.Failure.rejected(
            code: -32000,
            reason: nil,
            message: "No conversation running"
        )) {
            try await client(port: port).interrupt()
        }
    }

    // MARK: One socket

    /// **The test the whole actor exists for.** Three calls, one connection — revert to
    /// a socket per call and this is the only thing in the suite that goes red, because
    /// every other assertion here passes either way.
    ///
    /// It matters beyond tidiness: push-to-talk sends `conversation.mic` on press and
    /// again on release, and a WebSocket handshake between letting go of a button and
    /// the robot ceasing to listen is latency with no explanation a user would accept.
    @Test("three concurrent calls share one socket")
    func multiplexesCallsOntoOneSocket() async throws {
        let sent = Recorder()
        let server = try server(recording: sent) { #"{"jsonrpc":"2.0","id":\#($0),"result":{"muted":true}}"# }
        defer { server.stop() }
        let port = try await server.readyPort()
        let client = try client(port: port)

        async let first = client.microphoneMuted()
        async let second = client.microphoneMuted()
        async let third = client.microphoneMuted()
        _ = try await (first, second, third)

        #expect(sent.all.count == 3)
        #expect(server.acceptedConnections == 1)
    }

    /// The counter's own sensitivity, and the documented trade beside it: a caller that
    /// takes a channel per call pays for a connection per call. Without this the test
    /// above would pass just as well against a server that could only ever count to one.
    ///
    /// This is what the dock does, and it is the right shape there — one connection for
    /// a button somebody presses now and then, against holding a socket open all day.
    @Test("a channel per call costs a connection per call")
    func aChannelPerCallOpensASocketPerCall() async throws {
        let sent = Recorder()
        let server = try server(recording: sent) { #"{"jsonrpc":"2.0","id":\#($0),"result":{"ok":true}}"# }
        defer { server.stop() }
        let port = try await server.readyPort()

        for _ in 0 ..< 3 {
            let channel = try client(port: port)
            try await channel.interrupt()
            await channel.close()
        }

        #expect(sent.all.count == 3)
        #expect(server.acceptedConnections == 3)
    }

    /// The other half of the demand count: a stream and a call on one channel are one
    /// connection, not two. This is what a screen holding a channel for its lifetime
    /// actually buys.
    @Test("a call made while listening reuses the stream's socket")
    func sharesTheSocketWithTheEventStream() async throws {
        let sent = Recorder()
        let server = try LocalWebSocketServer { connection in
            LocalWebSocketServer.sendText(
                #"{"jsonrpc":"2.0","method":"conversation.turn","params":{"state":"listening"}}"#,
                over: connection
            )
            LocalWebSocketServer.receiveText(over: connection) { text in
                sent.record(text)
                let id = Self.id(in: text) ?? "0"
                LocalWebSocketServer.sendText(
                    #"{"jsonrpc":"2.0","id":\#(id),"result":{"muted":false}}"#,
                    over: connection
                )
            }
        }
        defer { server.stop() }
        let port = try await server.readyPort()
        let client = try client(port: port)

        var events = client.events().makeAsyncIterator()
        // Two: the seam marker, then the frame that proves the socket reached the app.
        #expect(await events.next() == .opened)
        #expect(await events.next() == .turn(.listening))

        #expect(try await client.microphoneMuted() == false)
        #expect(server.acceptedConnections == 1)
        await client.close()
    }

    /// A reply cannot outlive the socket that would carry it, so a dropped connection
    /// has to fail its waiters at once rather than let each one sit out its budget.
    ///
    /// The error alone is the assertion here, unlike the timeout test below: the wrong
    /// branch throws `.timedOut`, not this.
    @Test("a socket that dies mid-call fails the call at once")
    func failsWaitersWhenTheSocketDies() async throws {
        let server = try LocalWebSocketServer { connection in
            LocalWebSocketServer.receiveText(over: connection) { _ in
                connection.forceCancel()
            }
        }
        defer { server.stop() }
        let port = try await server.readyPort()
        // Far longer than the test can take, so an elapsed budget cannot be the reason.
        let client = try client(port: port, replyTimeout: .seconds(30))

        await #expect(throws: ConversationRPCClient.Failure.unreachable) {
            try await client.interrupt()
        }
    }

    /// Reading the flag must send **no** `muted` at all. The app writes the microphone
    /// whenever that key is present, so a read spelled `{"muted": false}` would unmute
    /// the robot on the way past — a bug with no symptom on this side of the wire.
    @Test("reading the microphone sends empty parameters")
    func readsTheMicrophoneWithoutWritingIt() async throws {
        let sent = Recorder()
        let server = try server(recording: sent) { #"{"jsonrpc":"2.0","id":\#($0),"result":{"muted":true}}"# }
        defer { server.stop() }
        let port = try await server.readyPort()

        #expect(try await client(port: port).microphoneMuted())

        let frame = try #require(sent.first)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
        #expect(object["method"] as? String == "conversation.mic")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params.isEmpty)
    }

    /// `say` carries a string and `applyPersonality` two booleans beside one — none of
    /// which the old `[String: Bool]` parameter type could express.
    @Test("string and boolean parameters reach the wire as themselves")
    func encodesMixedParameters() async throws {
        let sent = Recorder()
        let server = try server(recording: sent) { #"{"jsonrpc":"2.0","id":\#($0),"result":{"ok":true}}"# }
        defer { server.stop() }
        let port = try await server.readyPort()

        try await client(port: port).applyPersonality(named: "noir_detective", persist: true, force: false)

        let frame = try #require(sent.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["name"] as? String == "noir_detective")
        // `as? Bool` succeeds for a JSON number too, so the type is checked outright:
        // an app reading `bool(params["persist"])` would accept a 1 and this would pass
        // for the wrong reason.
        #expect(params["persist"] is Bool)
        #expect(params["persist"] as? Bool == true)
        #expect(params["force"] as? Bool == false)
    }

    /// **The duration is the assertion here**, not the error: a silent app and a
    /// refused one both end in a throw, and only the budget tells them apart
    /// (project rule 7). Bounded loosely enough that a loaded runner cannot cross it.
    @Test("a silent app gives up on its own budget rather than hanging")
    func timesOut() async throws {
        let server = try LocalWebSocketServer { connection in
            LocalWebSocketServer.receiveText(over: connection) { _ in }
        }
        defer { server.stop() }
        let port = try await server.readyPort()

        let started = ContinuousClock.now
        await #expect(throws: ConversationRPCClient.Failure.timedOut) {
            try await client(port: port, replyTimeout: .milliseconds(300)).interrupt()
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}

/// Collects what the server was sent, across the queue Network.framework calls back on.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String] = []

    var first: String? {
        lock.withLock { frames.first }
    }

    /// Every frame, in arrival order. The multiplexing test counts them against the
    /// server's accepted-connection count, which is the only pair that separates one
    /// socket from three.
    var all: [String] {
        lock.withLock { frames }
    }

    func record(_ frame: String) {
        lock.withLock { frames.append(frame) }
    }
}
