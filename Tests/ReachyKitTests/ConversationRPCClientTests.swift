import Foundation
@testable import ReachyKit
import Testing

@Suite("Conversation JSON-RPC client")
struct ConversationRPCClientTests {
    @Test("receives turns and reconnects after the app socket drops", .timeLimit(.minutes(1)))
    func reconnectsAfterDrop() async throws {
        let frame = #"{"jsonrpc":"2.0","method":"conversation.turn","params":{"state":"speaking"}}"#
        let server = try LocalWebSocketServer { connection in
            LocalWebSocketServer.sendText(frame, over: connection) {
                connection.forceCancel()
            }
        }
        defer { server.stop() }
        let port = try await server.readyPort()

        var configuration = ConversationRPCClient.Configuration()
        configuration.initialBackoff = .milliseconds(50)
        configuration.maxBackoff = .milliseconds(200)
        let client = try ConversationRPCClient(
            address: RobotAddress(host: "127.0.0.1"),
            port: Int(port),
            configuration: configuration
        )

        var received = 0
        for await turn in client.turns() {
            #expect(turn == .speaking)
            received += 1
            if received == 2 {
                break
            }
        }
        #expect(received == 2)
    }

    @Test("builds the app URL with URLComponents, falling back to 7860")
    func buildsAppURL() throws {
        let client = try ConversationRPCClient(address: .init(host: "fe80::1%en0"))
        #expect(client.url.absoluteString == "ws://[fe80::1%25en0]:7860/rpc")
    }

    /// `URLSessionWebSocketTask.receive()` ignores task cancellation, so without an
    /// explicit socket cancel the reader parks in it and the connection to the
    /// robot outlives the consumer — once per backgrounding, in the dock's case.
    /// A silent socket is the whole point here: nothing else would end the wait.
    @Test("dropping the consumer closes the socket on a silent robot", .timeLimit(.minutes(1)))
    func closesTheSocketWhenTheConsumerGoesAway() async throws {
        let frame = #"{"jsonrpc":"2.0","method":"conversation.turn","params":{"state":"listening"}}"#
        let closed = Signal()
        let server = try LocalWebSocketServer { connection in
            LocalWebSocketServer.whenClosed(connection) { closed.raise() }
            LocalWebSocketServer.sendText(frame, over: connection)
        }
        defer { server.stop() }
        let port = try await server.readyPort()

        let client = try ConversationRPCClient(address: RobotAddress(host: "127.0.0.1"), port: Int(port))
        for await turn in client.turns() {
            #expect(turn == .listening)
            break
        }

        #expect(await closed.waitRaised())
    }

    /// The robot's host, the app's port. Reversing either half dials the wrong
    /// machine: the daemon's port is the REST API, and `custom_app_url`'s host is
    /// `0.0.0.0` (see ``RobotApp/customAppPort``).
    ///
    /// The app here is deliberately **not** on 7860 — on the declared port this
    /// would pass just as well with the port argument dropped entirely.
    @Test("keeps the robot's host and takes only the app's port")
    func combinesRobotHostWithAppPort() throws {
        let relocated = RobotApp.preview(
            name: "reachy_mini_conversation_app",
            installed: true,
            customAppURL: "http://0.0.0.0:8123/"
        )
        let client = try ConversationRPCClient(
            address: RobotAddress(host: "reachy-mini.local", port: 8000),
            port: relocated.customAppPort
        )
        #expect(client.url.absoluteString == "ws://reachy-mini.local:8123/rpc")
    }
}
