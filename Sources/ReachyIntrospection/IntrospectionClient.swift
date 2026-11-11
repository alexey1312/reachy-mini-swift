#if DEBUG
    import Foundation
    import Network
    import ReachyJSON

    /// Sends one request to an app that serves its tree, and reads the answer.
    ///
    /// One connection for each request. The command-line tool is the user of this
    /// type, and it sends one request for each run.
    public struct IntrospectionClient: Sendable {
        public enum Failure: Error, CustomStringConvertible {
            case notListening(port: UInt16, reason: String)
            case closedBeforeAnswer
            /// The connection broke after it opened: the app quit, or its listener closed.
            case connectionLost(reason: String)

            public var description: String {
                switch self {
                case let .notListening(port, reason):
                    """
                    nothing answers on 127.0.0.1:\(port) (\(reason)). \
                    Start a Debug build with --reachy-introspect \(port).
                    """
                case .closedBeforeAnswer:
                    "the app closed the connection before it answered"
                case let .connectionLost(reason):
                    "the connection to the app broke (\(reason))"
                }
            }
        }

        public let port: UInt16

        public init(port: UInt16) {
            self.port = port
        }

        public func send(_ request: IntrospectionRequest) async throws -> IntrospectionResponse {
            try await JSONCodec.web.decode(IntrospectionResponse.self, from: sendLine(JSONCodec.web.encode(request)))
        }

        /// Sends one line and returns the line that answers it, without its newline.
        /// Every transport error arrives as a `Failure`, so the tool prints a sentence.
        public func sendLine(_ line: Data) async throws -> Data {
            do {
                return try await exchange(line)
            } catch let error as NWError {
                throw Failure.connectionLost(reason: String(describing: error))
            }
        }

        private func exchange(_ line: Data) async throws -> Data {
            let connection = NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port) ?? .any,
                using: .tcp
            )
            defer { connection.cancel() }
            let (states, continuation) = AsyncStream.makeStream(of: NWConnection.State.self)
            connection.stateUpdateHandler = { continuation.yield($0) }
            connection.start(queue: DispatchQueue(label: "IntrospectionClient"))
            waiting: for await state in states {
                switch state {
                case .ready:
                    break waiting
                case let .failed(error), let .waiting(error):
                    throw Failure.notListening(port: port, reason: String(describing: error))
                case .cancelled:
                    throw CancellationError()
                default:
                    continue
                }
            }
            var payload = line
            payload.append(0x0A)
            try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        sent.resume(throwing: error)
                    } else {
                        sent.resume()
                    }
                })
            }
            var buffer = LineBuffer()
            while true {
                let chunk = try await Self.receive(from: connection)
                guard let chunk else { throw Failure.closedBeforeAnswer }
                if let answer = buffer.append(chunk).first {
                    return answer
                }
            }
        }

        /// The next bytes, or `nil` when the other end closed.
        private static func receive(from connection: NWConnection) async throws -> Data? {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        }
    }
#endif
