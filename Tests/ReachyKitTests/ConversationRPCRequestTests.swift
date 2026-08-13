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
            message: "No conversation running"
        )) {
            try await client(port: port).interrupt()
        }
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

    func record(_ frame: String) {
        lock.withLock { frames.append(frame) }
    }
}
