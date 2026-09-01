import Foundation

/// How one frame off the channel is recognised before it is delivered.
///
/// Nothing here is channel state; it is a reader over whatever arrived — just
/// enough of a message to route it, without modelling every shape the daemon can
/// send. The whole routing decision is ``Route``, taken once here rather than
/// re-derived by the reader out of six independent optionals.
struct Envelope: Decodable {
    /// Where a frame goes, and the only answers there are.
    enum Route: Equatable {
        /// A JSON-RPC reply, answered by the id it echoes back.
        case rpcReply(id: Int)
        /// JSON-RPC with no id: a notification the running app pushed, which the
        /// daemon fans out to every client.
        case rpcNotification(method: String)
        /// JSON-RPC naming neither. Legal on the wire and unattributable here, so
        /// it is dropped loudly rather than mistaken for one of the shapes below.
        case rpcUnattributable
        /// Names a `type`, the way a broadcast does.
        case typed(String)
        /// Echoes the command name back. The common case.
        case command(String)
        /// Names nothing at all; a waiting caller's own key is the whole of the
        /// correlation left.
        case keyed(Set<String>)
    }

    let route: Route

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let type = try? container.decodeIfPresent(String.self, forKey: AnyKey("type"))
        let command = try? container.decodeIfPresent(String.self, forKey: AnyKey("command"))
        let method = try? container.decodeIfPresent(String.self, forKey: AnyKey("method"))
        // JSON-RPC first: it names neither a `type` nor a `command`, and its own keys
        // — `jsonrpc`, `result`, `id` — would otherwise fall to the key match at the
        // bottom and answer whichever waiter happened to be tokened `result`.
        if keys.contains("jsonrpc") {
            if let id = Self.rpcID(in: container) {
                route = .rpcReply(id: id)
            } else if let method {
                route = .rpcNotification(method: method)
            } else {
                route = .rpcUnattributable
            }
        } else if let type {
            route = .typed(type)
        } else if let command {
            route = .command(command)
        } else {
            route = .keyed(keys)
        }
    }

    /// JSON-RPC 2.0 permits a string id. This client always sends a number, but a
    /// daemon that echoes it back quoted would otherwise match no waiter at all and
    /// leave every call to sit out its whole deadline.
    private static func rpcID(in container: KeyedDecodingContainer<AnyKey>) -> Int? {
        if let number = try? container.decodeIfPresent(Int.self, forKey: AnyKey("id")) {
            return number
        }
        guard let text = try? container.decodeIfPresent(String.self, forKey: AnyKey("id")) else {
            return nil
        }
        return Int(text)
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
