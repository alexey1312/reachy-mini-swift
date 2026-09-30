import Foundation

/// A Hugging Face sign-in the *robot* is running, which a person approves in a
/// browser.
///
/// The device-code flow daemon 1.10.0 mounts at `/api/hf-auth/oauth/device/*`
/// (pollen-robotics/reachy_mini#1223). The robot asks the Hub for a code, the
/// person approves that code on huggingface.co, and the robot polls the Hub
/// itself until it holds a token. Two things follow, and both are why this is the
/// better way to link a robot than `save-token`:
///
/// - **No token crosses the local network.** The robot talks to the Hub over
///   HTTPS; this app only relays a code a person reads anyway.
/// - **The robot's token can be renewed.** The flow issues a refresh token, where
///   `save-token` stores whatever access token it is handed and nothing to renew it
///   with — so a copied token drops the robot off central when it expires.
public struct RobotDeviceLogin: Sendable, Equatable, Decodable {
    public let sessionID: String
    /// What the person types, or confirms, on the approval page.
    public let userCode: String
    public let verificationURI: URL
    /// The approval page with the code already filled in, when the Hub offers one.
    public let verificationURIComplete: URL?
    /// How often the robot polls the Hub. Asking the robot more often learns nothing.
    public let interval: Duration
    /// How long the code stays valid.
    public let expiresIn: Duration

    /// The page to open: the pre-filled one where there is one.
    public var approvalURL: URL {
        verificationURIComplete ?? verificationURI
    }

    public init(
        sessionID: String,
        userCode: String,
        verificationURI: URL,
        verificationURIComplete: URL? = nil,
        interval: Duration = .seconds(5),
        expiresIn: Duration = .seconds(900)
    ) {
        self.sessionID = sessionID
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.interval = interval
        self.expiresIn = expiresIn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        userCode = try container.decode(String.self, forKey: .userCode)
        verificationURI = try container.decode(URL.self, forKey: .verificationURI)
        verificationURIComplete = try? container.decodeIfPresent(URL.self, forKey: .verificationURIComplete)
        // The daemon fills both from the Hub's answer with defaults of 5 and 900,
        // so an absent one means the same here.
        let interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 5
        let expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 900
        self.interval = .seconds(max(1, interval))
        self.expiresIn = .seconds(max(1, expiresIn))
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case interval
        case expiresIn = "expires_in"
    }
}

/// Where a robot's device-code sign-in stands.
///
/// `GET /api/hf-auth/oauth/device/status/{id}` answers `status` plus `username`
/// once approved or `message` on a failure. A session the daemon no longer knows
/// reads `expired`, the same word as a code that ran out — to a caller they are
/// one fact: start again.
public enum RobotDeviceLoginStatus: Sendable, Equatable, Decodable {
    case pending
    case authorized(username: String?)
    case expired(message: String?)
    case failed(message: String?)
    case cancelled
    /// A word this client has not heard. Kept rather than guessed at (rule 3), and
    /// treated as still pending until the code's own expiry settles it.
    case unknown(String)

    public var isFinished: Bool {
        switch self {
        case .pending, .unknown: false
        case .authorized, .expired, .failed, .cancelled: true
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        self = switch status {
        case "pending": .pending
        case "authorized": try .authorized(username: container.decodeIfPresent(String.self, forKey: .username))
        case "expired": .expired(message: message)
        case "error": .failed(message: message)
        case "cancelled": .cancelled
        case let other: .unknown(other)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case status, username, message
    }
}
