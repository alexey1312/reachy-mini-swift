import Foundation
import Network

/// A plain HTTP/1.1 server on an ephemeral port that answers each request late.
///
/// `StubURLProtocol` cannot stand in for it: a test session replaces every
/// budget `RobotConnection` sets, and here the budget is what is under test.
final class SlowHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SlowHTTPServer")

    /// `body` maps a request path to the JSON that answers it.
    init(delay: Duration, body: @escaping @Sendable (String) -> String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "SlowHTTPServer.connection"))
            Self.readHead(of: connection, buffer: Data()) { path in
                let json = Data(body(path).utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(json.count)\r\nConnection: close\r\n\r\n"
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    connection.send(
                        content: Data(head.utf8) + json,
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                }
            }
        }
        listener.start(queue: queue)
    }

    /// Waits until the listener is ready and returns its port.
    func readyPort() async throws -> UInt16 {
        while listener.state != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        return listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

    /// Reads up to the blank line that ends the request head, then hands over the
    /// path. The move routes carry no body, so the head is the whole request.
    private static func readHead(
        of connection: NWConnection,
        buffer: Data,
        then answer: @escaping @Sendable (String) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            let received = buffer + (data ?? Data())
            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                let head = String(bytes: received, encoding: .utf8) ?? ""
                let parts = (head.split(separator: "\r\n").first ?? "").split(separator: " ")
                answer(parts.count > 1 ? String(parts[1]) : "")
                return
            }
            guard error == nil, !isComplete else { return }
            readHead(of: connection, buffer: received, then: answer)
        }
    }
}
