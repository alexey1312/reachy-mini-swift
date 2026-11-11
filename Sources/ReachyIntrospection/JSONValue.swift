#if DEBUG
    import Foundation
    import ReachyJSON

    /// Any JSON value: the state a node shows and the input an action takes.
    ///
    /// `RemoteValue` in ReachyKit is not this type. It only encodes, and this target
    /// does not link ReachyKit.
    public enum JSONValue: Hashable, Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        /// The JSON form of an `Encodable` value.
        public init(encoding value: some Encodable) throws {
            self = try JSONCodec.web.decode(JSONValue.self, from: JSONCodec.web.encode(value))
        }

        /// Reads this value as a `Decodable` type. An action uses it to read its input.
        public func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONCodec.web.decode(type, from: JSONCodec.web.encode(self))
        }

        public subscript(key: String) -> JSONValue? {
            guard case let .object(members) = self else { return nil }
            return members[key]
        }
    }

    extension JSONValue: Codable {
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            // `Bool` before `Double`: the order decides nothing for JSONDecoder, which
            // refuses to read `true` as a number, but another decoder can accept it.
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = try .object(container.decode([String: JSONValue].self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case let .bool(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .string(value): try container.encode(value)
            case let .array(value): try container.encode(value)
            case let .object(value): try container.encode(value)
            }
        }
    }
#endif
