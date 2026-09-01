import Foundation

/// How one frame off the channel is recognised before it is delivered.
///
/// Split out of `RemoteControlChannel.swift`, which is at SwiftLint's length
/// limit — the same reason `RobotConnection` has its `+Wireless` and `+Apps`
/// files. Nothing here is channel state; it is a reader over whatever arrived.
/// Just enough of a message to route it, without modelling every shape the
/// daemon can send.
struct Envelope: Decodable {
    let type: String?
    let command: String?
    let keys: Set<String>
    /// JSON-RPC 2.0, which daemon 1.10.0 carries on this channel beside the
    /// `{type, command}` protocol. Answered by `id`; a frame without one is a
    /// notification from the running app.
    let isRPC: Bool
    let rpcID: Int?
    let method: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        keys = Set(container.allKeys.map(\.stringValue))
        type = try? container.decodeIfPresent(String.self, forKey: AnyKey("type"))
        command = try? container.decodeIfPresent(String.self, forKey: AnyKey("command"))
        isRPC = keys.contains("jsonrpc")
        rpcID = try? container.decodeIfPresent(Int.self, forKey: AnyKey("id"))
        method = try? container.decodeIfPresent(String.self, forKey: AnyKey("method"))
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init(_ value: String) {
            stringValue = value
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue _: Int) {
            nil
        }
    }
}
