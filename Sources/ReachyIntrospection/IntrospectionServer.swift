#if DEBUG
    import Foundation
    import Network

    /// Serves one tree to a client on this machine, as newline-delimited JSON.
    ///
    /// Debug builds only: a Release build does not contain this type. The listener
    /// binds the loopback address, so another machine cannot reach it. A simulator
    /// shares the loopback of its Mac, and that is how a client reaches an iOS build.
    @MainActor
    public final class IntrospectionServer {
        private let tree: IntrospectionTree
        private var listener: NWListener?

        public init(tree: IntrospectionTree) {
            self.tree = tree
        }

        /// Starts to listen and returns the port. Port 0 asks the system for a free port.
        @discardableResult
        public func start(port: UInt16 = 0) async throws -> UInt16 {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port) ?? .any
            )
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            let tree = tree
            listener.newConnectionHandler = { connection in
                connection.start(queue: DispatchQueue(label: "IntrospectionServer.connection"))
                Self.read(connection, buffer: LineBuffer(), tree: tree)
            }
            let (states, continuation) = AsyncStream.makeStream(of: NWListener.State.self)
            listener.stateUpdateHandler = { continuation.yield($0) }
            listener.start(queue: DispatchQueue(label: "IntrospectionServer"))
            self.listener = listener
            for await state in states {
                switch state {
                case .ready:
                    return listener.port?.rawValue ?? port
                case let .failed(error):
                    stop()
                    throw error
                case .cancelled:
                    throw CancellationError()
                default:
                    continue
                }
            }
            throw CancellationError()
        }

        public func stop() {
            listener?.cancel()
            listener = nil
        }

        /// Answers the lines of one read in order, then reads again. The next read
        /// waits for the answers, so a client that sends two lines gets two answers
        /// in the order it sent them.
        private nonisolated static func read(_ connection: NWConnection, buffer: LineBuffer, tree: IntrospectionTree) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                var buffer = buffer
                let lines = data.map { buffer.append($0) } ?? []
                let rest = buffer
                let ended = isComplete || error != nil
                Task { @MainActor in
                    for line in lines {
                        var reply = await tree.respond(toLine: line)
                        reply.append(0x0A)
                        connection.send(content: reply, completion: .contentProcessed { _ in })
                    }
                    if ended {
                        connection.cancel()
                    } else {
                        read(connection, buffer: rest, tree: tree)
                    }
                }
            }
        }
    }
#endif
