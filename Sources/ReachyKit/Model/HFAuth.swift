import Foundation

/// Whether the *robot* holds a Hugging Face token, and whose it is.
///
/// Nothing to do with whether this app is signed in: the two custody points are
/// separate on purpose (see the token-custody ADR). The daemon answers this by
/// running `whoami` against the Hub on every single call, so it is slow enough to
/// be worth caching and never worth polling.
public struct HFAuthStatus: Sendable, Equatable, Decodable {
    public let isLoggedIn: Bool
    public let username: String?

    public init(isLoggedIn: Bool, username: String? = nil) {
        self.isLoggedIn = isLoggedIn
        self.username = username
    }

    private enum CodingKeys: String, CodingKey {
        case isLoggedIn = "is_logged_in"
        case username
    }
}

/// The robot's connection to the Hugging Face relay — what makes it reachable
/// from outside the LAN at all.
public struct RelayStatus: Sendable, Equatable, Decodable {
    public enum State: Sendable, Equatable, Decodable {
        case stopped
        case waitingForToken
        case connecting
        case connected
        case reconnecting
        case error
        /// Not one of the relay's own six states: the router substitutes this for
        /// a Lite robot, and for a daemon whose build ships no relay module.
        /// There is nothing the user can do about either.
        case unavailable
        case unknown(String)

        public init(from decoder: any Decoder) throws {
            switch try decoder.singleValueContainer().decode(String.self) {
            case "stopped": self = .stopped
            case "waiting_for_token": self = .waitingForToken
            case "connecting": self = .connecting
            case "connected": self = .connected
            case "reconnecting": self = .reconnecting
            case "error": self = .error
            case "unavailable": self = .unavailable
            case let other: self = .unknown(other)
            }
        }
    }

    public let state: State
    /// The relay's own words for the state — worth showing verbatim when it is an
    /// error, since it is the only detail the daemon offers.
    public let message: String?
    /// The daemon's own verdict rather than a comparison against `state`: it is
    /// what the relay instance reports, and a state this client has not heard of
    /// must not silently read as disconnected.
    public let isConnected: Bool

    public init(state: State, message: String? = nil, isConnected: Bool) {
        self.state = state
        self.message = message
        self.isConnected = isConnected
    }

    private enum CodingKeys: String, CodingKey {
        case state, message
        case isConnected = "is_connected"
    }
}

/// The answer to `POST /api/hf-auth/refresh-relay`.
///
/// The distinction matters more than it looks: on `skipped` the daemon started
/// nothing at all, so a caller that goes on to wait for `relay-status` to change
/// waits forever. The daemon's own docstring calls that trap out by name.
public struct RelayRefresh: Sendable, Equatable, Decodable {
    public let status: String
    public let tokenAvailable: Bool
    /// `relay_not_running` (no relay instance — no token, or the daemon is still
    /// coming up) or `relay_unavailable` (a build with no relay module at all).
    public let reason: String?

    /// Whether a reconnect was actually kicked off. Only then is waiting for a
    /// state change meaningful.
    public var didStart: Bool {
        status == "requested"
    }

    public init(status: String, tokenAvailable: Bool, reason: String? = nil) {
        self.status = status
        self.tokenAvailable = tokenAvailable
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case status, reason
        case tokenAvailable = "token_available"
    }
}

/// The robot's view of central's robot list, fetched on our behalf.
///
/// The daemon proxies this route rather than handing out the token, so on the LAN
/// this is how the app learns which of the user's robots are online without ever
/// seeing a credential.
public struct CentralRobotStatusProxy: Sendable, Equatable, Decodable {
    /// Why the proxy could not answer. Every case means "unknown" rather than
    /// "no robots" — the daemon's own docstring says callers must not block on it.
    public enum Reason: Sendable, Equatable, Decodable {
        case notAuthenticated
        case tokenInvalid
        case unreachable
        /// Daemon 1.11.0 validates the central URL it would send the token to, and
        /// refuses to proxy at all when that URL is not HTTPS.
        case invalidConfiguration
        case http(Int)
        case unknown(String)

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "not_authenticated": self = .notAuthenticated
            case "token_invalid": self = .tokenInvalid
            case "unreachable": self = .unreachable
            case "invalid_configuration": self = .invalidConfiguration
            default:
                if raw.hasPrefix("http_"), let code = Int(raw.dropFirst("http_".count)) {
                    self = .http(code)
                } else {
                    self = .unknown(raw)
                }
            }
        }
    }

    public let isAvailable: Bool
    public let robots: [CentralRobot]
    public let reason: Reason?

    public init(isAvailable: Bool, robots: [CentralRobot] = [], reason: Reason? = nil) {
        self.isAvailable = isAvailable
        self.robots = robots
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case robots, reason
        case isAvailable = "available"
    }
}

/// One robot as the central signaling server lists it.
///
/// Reached two ways — proxied by a robot on the LAN, or read straight from
/// central once this app holds a token — and the shape is the same either way.
public struct CentralRobot: Sendable, Equatable, Identifiable, Decodable {
    public enum Transport: Sendable, Equatable, Decodable {
        case wifi
        case usb
        case unknown(String)

        public init(from decoder: any Decoder) throws {
            switch try decoder.singleValueContainer().decode(String.self) {
            case "wifi": self = .wifi
            case "usb": self = .usb
            case let other: self = .unknown(other)
            }
        }
    }

    public struct Meta: Sendable, Equatable, Decodable {
        public let name: String?
        public let transport: Transport?
        /// `sha256(usb serial)[:16]` — the same string the daemon serves at
        /// `/api/daemon/hardware-id` and advertises over mDNS, which is what makes
        /// a central listing joinable to a LAN one (project rule 4).
        public let hardwareID: String?
        /// Announced by the relay as a future field; daemon 1.9.0 never sends it.
        public let installID: String?

        private enum CodingKeys: String, CodingKey {
            case name, transport
            case hardwareID = "hardware_id"
            case installID = "install_id"
        }
    }

    public let peerID: String
    public let robotName: String?
    public let isBusy: Bool
    /// What is holding the robot — a local app or another listener's session.
    public let activeApp: String?
    public let meta: Meta?
    public let lastSeenAgeSeconds: Double?

    /// The most stable identifier the robot actually sent. `peerId` changes on
    /// every relay reconnect, so it is the last resort, not the key.
    public var id: String {
        meta?.installID ?? meta?.hardwareID ?? peerID
    }

    public var hardwareID: String? {
        meta?.hardwareID
    }

    public var transport: Transport? {
        meta?.transport
    }

    public var displayName: String {
        robotName ?? meta?.name ?? peerID
    }

    private enum CodingKeys: String, CodingKey {
        case peerID = "peerId"
        case robotName
        case busy
        case activeApp
        case meta
        case lastSeenAgeSeconds = "last_seen_age_seconds"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        peerID = try container.decode(String.self, forKey: .peerID)
        robotName = try container.decodeIfPresent(String.self, forKey: .robotName)
        isBusy = try container.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        activeApp = try container.decodeIfPresent(String.self, forKey: .activeApp)
        meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
        lastSeenAgeSeconds = try container.decodeIfPresent(Double.self, forKey: .lastSeenAgeSeconds)
    }
}
