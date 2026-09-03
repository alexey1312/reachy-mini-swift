import Foundation
import Network

/// Minimal in-process WebSocket server for transport tests.
/// Accepts connections on an ephemeral port, hands each one to `onConnection`.
final class LocalWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalWebSocketServer")

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    private let accepted = Counter()

    /// How many connections this server has accepted.
    ///
    /// The one thing that separates a multiplexed client from one opening a socket per
    /// call: both answer every request correctly, and only the count tells them apart.
    var acceptedConnections: Int {
        accepted.value
    }

    init(onConnection: @escaping @Sendable (NWConnection) -> Void) throws {
        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        let accepted = accepted
        listener.newConnectionHandler = { connection in
            accepted.increment()
            connection.start(queue: DispatchQueue(label: "LocalWebSocketServer.connection"))
            onConnection(connection)
        }
        listener.start(queue: queue)
    }

    /// Counted on the listener's own queue and read from a test, so it locks by hand.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }
    }

    /// Waits until the listener is ready and returns its port.
    func readyPort() async throws -> UInt16 {
        while listener.state != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        return port
    }

    /// `then` runs once the frame is actually on the wire. A test that tears the
    /// connection down straight after the call would otherwise race the send and
    /// drop the very frame it is asserting on.
    static func sendText(_ text: String, over connection: NWConnection, then onSent: (@Sendable () -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: onSent.map { sent in .contentProcessed { _ in sent() } } ?? .idempotent
        )
    }

    /// Hands each text frame the client sends to `onText`, until the connection ends.
    ///
    /// One `receiveMessage` per frame is the whole API — it does not repeat — so a
    /// server that answers more than one request has to re-arm itself.
    static func receiveText(over connection: NWConnection, onText: @escaping @Sendable (String) -> Void) {
        connection.receiveMessage { data, _, _, error in
            guard error == nil, let data, let text = String(data: data, encoding: .utf8) else { return }
            onText(text)
            receiveText(over: connection, onText: onText)
        }
    }

    /// Fires once the client closes: a WebSocket close frame, or the connection
    /// failing under it. A client that merely stops reading never gets here, which
    /// is exactly the distinction a cancellation test needs to draw.
    static func whenClosed(_ connection: NWConnection, run onClosed: @escaping @Sendable () -> Void) {
        connection.receiveMessage { _, context, _, error in
            let metadata = context?
                .protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                onClosed()
            } else {
                whenClosed(connection, run: onClosed)
            }
        }
    }

    func stop() {
        listener.cancel()
    }
}

/// A cross-queue flag for a Network.framework callback to raise and a test to
/// poll. Tests wait on conditions, not durations (project rule 7).
final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.withLock { raised }
    }

    func raise() {
        lock.withLock { raised = true }
    }

    /// Polls until raised, or gives up and reports it never was.
    func waitRaised(within budget: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if isRaised {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return isRaised
    }
}
