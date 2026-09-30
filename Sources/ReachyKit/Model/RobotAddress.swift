import Foundation

/// Network address of a robot daemon. Port is configurable (upstream hardcodes 8000).
public struct RobotAddress: Hashable, Sendable, Codable {
    public var host: String
    public var port: Int

    public static let defaultPort = 8000

    public init(host: String, port: Int = RobotAddress.defaultPort) {
        self.host = Self.requestHost(host)
        self.port = port
    }

    /// The host as it may appear in a request's `Host` header.
    ///
    /// A fully qualified name's trailing dot (`reachy-mini.local.`) resolves the same
    /// as the name without it, but the daemon's local-network guard
    /// (pollen-robotics/reachy_mini#1423) accepts a name only when it *ends* in
    /// `.local`, so the dot alone turns a working address into a 400. Applied in the
    /// initialiser and again when a URL is built, because a stored address decodes
    /// without passing through here.
    static func requestHost(_ host: String) -> String {
        host.count > 1 && host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// Parses user input: `host`, `host:port`, `[v6]`, `[v6]:port`, or bare IPv6.
    /// Users paste addresses with ports (phase-0 device testing proved it) — a bare
    /// `host` field that treats ":" as IPv6 produces garbage URLs.
    public init?(parsing input: String) {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        if s.hasPrefix("[") {
            guard let end = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex) ..< end])
            let rest = s[s.index(after: end)...]
            if rest.isEmpty {
                self.init(host: host)
            } else if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) {
                self.init(host: host, port: port)
            } else {
                return nil
            }
            return
        }

        switch s.count(where: { $0 == ":" }) {
        case 0:
            self.init(host: s)
        case 1:
            guard let i = s.firstIndex(of: ":"), let port = Int(s[s.index(after: i)...]) else { return nil }
            self.init(host: String(s[..<i]), port: port)
        default:
            // Multiple colons: bare IPv6 literal
            self.init(host: s)
        }
    }

    /// How an address is written for a user: brackets around an IPv6 literal, and
    /// the port only when it is not the default one.
    ///
    /// Lives here rather than beside a screen because `RobotSession.Link` has to
    /// name itself too, and that is a decision about the model, not about a view.
    public var displayString: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return port == Self.defaultPort ? hostPart : "\(hostPart):\(port)"
    }

    /// Root URL of the daemon, e.g. `http://reachy-mini.local:8000`.
    /// Generated OpenAPI operation paths already include the `/api` prefix.
    public var rootURL: URL? {
        url(scheme: "http", path: "")
    }

    /// URL for a WebSocket endpoint, e.g. `ws://host:8000/api/state/ws/full`.
    public func webSocketURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        url(scheme: "ws", path: path, queryItems: queryItems)
    }

    /// URL for a plain HTTP endpoint. Needed where the generated OpenAPI client
    /// cannot be used — it declares `application/json` for every response, so a
    /// binary payload like an STL mesh fails before the bytes are read.
    public func httpURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        url(scheme: "http", path: path, queryItems: queryItems)
    }

    /// Foundation's `URLComponents` rejects bare IPv6 literals in `host` — they must be
    /// pre-bracketed by the caller (upstream issue #269 was exactly this class of bug).
    private func url(scheme: String, path: String, queryItems: [URLQueryItem] = []) -> URL? {
        let host = Self.requestHost(host)
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = port
        components.path = path
        // Staying nil for the empty case keeps existing URLs byte-identical (no "?").
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }
}
