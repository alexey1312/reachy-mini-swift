#if DEBUG
    import Foundation
    import ReachyJSON

    /// One line a client sends. `{"id":1,"cmd":"ls"}` or
    /// `{"id":2,"cmd":"do","action":"setAddress","input":{"text":"127.0.0.1"}}`.
    public struct IntrospectionRequest: Codable, Equatable, Sendable {
        public enum Command: String, Codable, Sendable {
            case list = "ls"
            case perform = "do"
        }

        public var id: Int?
        public var cmd: Command
        public var action: String?
        public var input: JSONValue?

        public init(id: Int? = nil, cmd: Command, action: String? = nil, input: JSONValue? = nil) {
            self.id = id
            self.cmd = cmd
            self.action = action
            self.input = input
        }
    }

    /// One line the app answers with. A refusal carries `error` and nothing else.
    public struct IntrospectionResponse: Codable, Equatable, Sendable {
        public var id: Int?
        public var ok: Bool
        public var path: [String]?
        public var state: JSONValue?
        public var actions: [IntrospectionSnapshot.Action]?
        public var error: String?

        init(id: Int?, snapshot: IntrospectionSnapshot) {
            self.id = id
            ok = true
            path = snapshot.path
            state = snapshot.state
            actions = snapshot.actions
        }

        init(id: Int?, error: String) {
            self.id = id
            ok = false
            self.error = error
        }
    }

    public extension IntrospectionTree {
        func respond(to request: IntrospectionRequest) async -> IntrospectionResponse {
            do {
                switch request.cmd {
                case .list:
                    return IntrospectionResponse(id: request.id, snapshot: snapshot())
                case .perform:
                    guard let action = request.action else {
                        throw IntrospectionError.invalidRequest("'do' needs an 'action'")
                    }
                    let snapshot = try await perform(action, input: request.input ?? .null)
                    return IntrospectionResponse(id: request.id, snapshot: snapshot)
                }
            } catch {
                return IntrospectionResponse(id: request.id, error: String(describing: error))
            }
        }

        /// One request line in, one response line out, with no trailing newline.
        func respond(toLine line: Data) async -> Data {
            let response: IntrospectionResponse
            do {
                response = try await respond(to: JSONCodec.web.decode(IntrospectionRequest.self, from: line))
            } catch {
                response = IntrospectionResponse(id: nil, error: "invalid request: \(error)")
            }
            // The response type holds strings, numbers and Booleans only, so it encodes.
            return (try? JSONCodec.web.encode(response)) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)
        }
    }

    /// Splits a byte stream into newline-delimited lines.
    ///
    /// TCP keeps no message boundary: one read can hold half a line or three lines.
    public struct LineBuffer: Sendable {
        private var pending = Data()

        public init() {}

        /// Adds bytes and returns each line they complete, without its newline.
        /// An empty line is skipped.
        public mutating func append(_ data: Data) -> [Data] {
            pending.append(data)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex ..< newline]
                pending = Data(pending[pending.index(after: newline)...])
                if !line.isEmpty {
                    lines.append(Data(line))
                }
            }
            return lines
        }
    }
#endif
