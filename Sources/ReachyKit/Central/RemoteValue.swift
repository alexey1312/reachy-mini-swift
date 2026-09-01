import Foundation

/// A JSON value, for command payloads whose shape the caller decides.
public enum RemoteValue: Equatable, Sendable, Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([RemoteValue])
    case object([String: RemoteValue])
    case null

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(values): try container.encode(values)
        case let .object(values): try container.encode(values)
        case .null: try container.encodeNil()
        }
    }
}
