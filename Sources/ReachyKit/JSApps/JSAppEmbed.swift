import Foundation
import ReachyJSON

/// Where a JS app is opened, and what it is handed to reach the robot.
///
/// Pollen's own host builds the same address (`buildEmbedUrl.ts` in
/// `reachy_mini_mobile_app`, read as a specification): the Space's runtime host,
/// `embedded=1` and a theme in the query, and the credentials in the
/// **fragment**, as base64 of a JSON object, percent-encoded. A fragment never
/// travels with the request, and the page's SDK wipes it from the address bar
/// before it does anything else (`ts/host/src/embed/index.ts` in `reachy_mini`).
///
/// The keys are the SDK's, spelled exactly; it is lenient about `userName`'s case
/// and nothing else.
public enum JSAppEmbed {
    public enum Theme: String, Sendable, Equatable {
        case light
        case dark
    }

    /// What the page needs to open its own session to the robot through central.
    ///
    /// **`hfToken` is handed to third-party code**, which is the decision ADR 0006
    /// is mostly about: the host gives it a token minted for `openid profile`
    /// alone, never the account's own.
    public struct Credentials: Sendable, Equatable {
        public let hfToken: String
        public let userName: String
        /// Central's id for the robot right now. It rotates whenever the robot
        /// reconnects to central, so the page re-resolves it by hardware id before
        /// dialling; this one is the fallback.
        public let robotPeerID: String
        public let robotHardwareID: String?
        public let signalingURL: URL
        public let theme: Theme
        /// How the page names its host. Upstream's says "Reachy Mini"; this one
        /// says what it is.
        public let hostName: String
        public let appName: String

        public init(
            hfToken: String,
            userName: String,
            robotPeerID: String,
            robotHardwareID: String?,
            signalingURL: URL,
            theme: Theme,
            hostName: String = "Hey Reachy",
            appName: String
        ) {
            self.hfToken = hfToken
            self.userName = userName
            self.robotPeerID = robotPeerID
            self.robotHardwareID = robotHardwareID
            self.signalingURL = signalingURL
            self.theme = theme
            self.hostName = hostName
            self.appName = appName
        }
    }

    /// `owner/My_App` → `owner-my-app`: lower-cased, then `_` and `/` both become
    /// `-`. Hugging Face's own rule for a Space's subdomain.
    public static func slug(for spaceID: String) -> String {
        spaceID.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    /// The Space's runtime origin — the only origin the host lets the page
    /// navigate within. A static Space is served from a host of its own; every
    /// other SDK from the plain one.
    public static func origin(of app: JSApp) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        let slug = slug(for: app.id)
        components.host = switch app.sdk {
        case .static: "\(slug).static.hf.space"
        case .server: "\(slug).hf.space"
        }
        return components.url
    }

    /// The address to open. No cache-busting `_t` as upstream adds: the host's
    /// web view keeps no data between apps, so there is no cache to bust.
    public static func url(for app: JSApp, credentials: Credentials) throws -> URL {
        guard let origin = origin(of: app),
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "embedded", value: "1"),
            URLQueryItem(name: "theme", value: credentials.theme.rawValue),
        ]
        components.percentEncodedFragment = try "creds=" + percentEncoded(base64(credentials))
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    /// The bundle as the SDK decodes it: JSON, UTF-8, standard base64 — not
    /// base64url, which is why it still has to be percent-encoded.
    static func base64(_ credentials: Credentials) throws -> String {
        try JSONCodec.web.encode(Wire(credentials)).base64EncodedString()
    }

    /// `encodeURIComponent` for the base64 alphabet: `+`, `/` and `=` are the
    /// three characters in it that are not left alone.
    static func percentEncoded(_ base64: String) -> String {
        base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64
    }

    /// The wire shape. `config` and a missing hardware id are written as `null`
    /// rather than left out, as upstream writes them.
    private struct Wire: Encodable {
        let credentials: Credentials

        init(_ credentials: Credentials) {
            self.credentials = credentials
        }

        private enum Keys: String, CodingKey {
            case hfToken, userName, robotPeerId, robotHardwareId, signalingUrl, theme, config, hostName, appName
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(credentials.hfToken, forKey: .hfToken)
            try container.encode(credentials.userName, forKey: .userName)
            try container.encode(credentials.robotPeerID, forKey: .robotPeerId)
            try container.encode(credentials.robotHardwareID, forKey: .robotHardwareId)
            try container.encode(credentials.signalingURL.absoluteString, forKey: .signalingUrl)
            try container.encode(credentials.theme.rawValue, forKey: .theme)
            try container.encodeNil(forKey: .config)
            try container.encode(credentials.hostName, forKey: .hostName)
            try container.encode(credentials.appName, forKey: .appName)
        }
    }
}
