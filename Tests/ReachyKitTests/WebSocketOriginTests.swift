import Foundation
import Network
@testable import ReachyKit
import Testing

/// Daemon 1.12 refuses a state-changing request whose `Origin` is not local, and it
/// counts every WebSocket handshake as state-changing
/// (pollen-robotics/reachy_mini#1423). A request with no `Origin` at all passes,
/// which is what a native client sends — this holds that it still does.
@Suite("A socket to the daemon carries no Origin")
struct WebSocketOriginTests {
    @Test("the handshake has a Host and no Origin", .timeLimit(.minutes(1)))
    func sendsNoOrigin() async throws {
        let recorder = try HandshakeRecorder()
        defer { recorder.stop() }
        let port = try await recorder.readyPort()
        let client = try StateStreamClient(address: .init(host: "127.0.0.1", port: Int(port)))
        let reading = Task {
            for await _ in client.updates() {}
        }
        defer { reading.cancel() }

        let request = try #require(await recorder.firstRequest(within: .seconds(30)))
        let lines = request.lowercased().components(separatedBy: "\r\n")

        #expect(lines.contains("upgrade: websocket"))
        #expect(lines.contains("host: 127.0.0.1:\(port)"))
        #expect(!lines.contains { $0.hasPrefix("origin:") })
        // Daemon 1.13.0 reads this off every handshake as well as every request.
        #expect(lines.contains("x-reachy-client: \(ReachyClientHeader.value.lowercased())"))
    }
}

/// A bare TCP listener that keeps the first HTTP request it reads and closes the
/// connection. A WebSocket server would hide the request headers this test is about.
private final class HandshakeRecorder: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var requests: [String] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue(label: "HandshakeRecorder.connection"))
            self?.read(connection, into: Data())
        }
        listener.start(queue: DispatchQueue(label: "HandshakeRecorder"))
    }

    func readyPort() async throws -> UInt16 {
        while listener.state != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        return listener.port?.rawValue ?? 0
    }

    /// Polls for the condition rather than sleeping a fixed time (project rule 7).
    func firstRequest(within budget: Duration) async -> String? {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if let first = lock.withLock({ requests.first }) {
                return first
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func stop() {
        listener.cancel()
    }

    private func read(_ connection: NWConnection, into buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                lock.withLock { requests.append(text) }
                connection.cancel()
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                read(connection, into: buffer)
            }
        }
    }
}
