import Foundation

/// A Hugging Face credential held by *this app*, as opposed to the copy a robot
/// keeps once it is linked.
public struct HFToken: Sendable, Equatable, Codable {
    public let accessToken: String
    /// The Hub does not always issue one. Without it an expired session cannot be
    /// renewed silently — see `needsReauth(at:)`.
    public let refreshToken: String?
    public let expiresAt: Date?
    public let username: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, username: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.username = username
    }

    /// A minute of headroom: a token that expires while a request is in flight
    /// fails in a way that reads as a network error rather than a sign-in one.
    public func isExpired(at now: Date, headroom: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-headroom) <= now
    }

    /// Expired and unrenewable. The user has to sign in again — which, through
    /// Safari's shared cookies, is usually a single tap.
    public func needsReauth(at now: Date) -> Bool {
        isExpired(at: now) && refreshToken == nil
    }

    public func named(_ username: String?) -> HFToken {
        HFToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, username: username)
    }
}

/// Somewhere to keep the token between launches.
///
/// A protocol so the account model can be exercised without a Keychain — and so
/// previews can run against an inert one.
public protocol HFTokenStoring: Sendable {
    func load() throws -> HFToken?
    func save(_ token: HFToken) throws
    func clear() throws
}

/// In-memory custody, for previews and tests.
public final class InMemoryHFTokenStore: HFTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: HFToken?

    public init(token: HFToken? = nil) {
        self.token = token
    }

    public func load() throws -> HFToken? {
        lock.withLock { token }
    }

    public func save(_ token: HFToken) throws {
        lock.withLock { self.token = token }
    }

    public func clear() throws {
        lock.withLock { token = nil }
    }
}

/// A token printed anywhere — a log line, a test failure, `dump` — is a token
/// leaked, so every way of printing one names what it holds and never the value.
extension HFToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "HFToken(username: \(username ?? "nil"), refreshable: \(refreshToken != nil), <redacted>)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["username": username as Any, "expiresAt": expiresAt as Any], displayStyle: .struct)
    }
}
