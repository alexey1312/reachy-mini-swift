import CryptoKit
import Foundation

/// Where this app's Hugging Face sign-in points, and as whom.
///
/// A **public** OAuth client: there is no secret, because a secret shipped inside
/// an app is not one. PKCE is what takes its place, and it is also what the daemon
/// uses for its own browser flow — so both ends speak the same protocol to the
/// same endpoints.
public struct HFOAuthConfiguration: Sendable, Equatable {
    public let clientID: String
    /// Registered with the OAuth app on the Hub. A custom scheme rather than a
    /// universal link: the robot is on a LAN, and this callback must resolve with
    /// no server of ours involved.
    public let redirectURI: String
    public let scopes: String

    public init(clientID: String, redirectURI: String, scopes: String) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// The same set the robot asks for (`HF_OAUTH_SCOPES` in the daemon), so one
    /// token covers everything either end does: reading the app store, installing
    /// from a private Space, and reaching central.
    public static let reachyMiniScopes = "openid profile read-repos write-repos manage-repos inference-api"

    public static let callbackScheme = "reachy-mini-swift"

    /// This app's registered client, public and therefore checked in: the id
    /// travels in the authorize URL of every sign-in, so it is an identifier
    /// rather than a credential. What actually binds the flow to this app is the
    /// redirect registered beside it — Hugging Face answers 400 to any other one,
    /// so an authorization code has nowhere to go but back here.
    ///
    /// A fork registers its own at `huggingface.co/settings/applications/new`.
    /// With an empty id `isConfigured` is false, the browser button is absent
    /// rather than broken, and the personal-access-token path still works — which
    /// is why that path is not a second-class citizen.
    public static let reachyMini = Self(
        clientID: "72717a74-aeb7-4bf3-b80a-2679ebbdd96a",
        redirectURI: "\(callbackScheme)://oauth-callback",
        scopes: reachyMiniScopes
    )

    /// What a hosted JS app is handed, and nothing more (ADR 0006): who the user is,
    /// which is all central asks of a token. The account's own token also carries
    /// `write-repos` and `manage-repos`, and a page from a stranger's Space has no
    /// business with either.
    ///
    /// Same client, same redirect, a second authorization: the Hub issues a token
    /// for exactly the scopes requested, and Safari's session makes it a consent
    /// rather than a password.
    public static let webAppScopes = "openid profile"

    /// The narrow sign-in for hosted web apps. Its token is held in memory only,
    /// by whoever asked for it — never in the Keychain beside the account's.
    public static let reachyMiniWebApps = Self(
        clientID: reachyMini.clientID,
        redirectURI: reachyMini.redirectURI,
        scopes: webAppScopes
    )

    /// A build that has not registered an OAuth app of its own — a fork, or this
    /// one before the client id above existed. Named rather than spelled out at
    /// each use so previews and tests can reach it with a leading dot: Prefire
    /// copies a preview body into a generated file that imports neither this
    /// module nor any other, where a written-out type name stops resolving.
    public static let unregistered = Self(
        clientID: "",
        redirectURI: "\(callbackScheme)://oauth-callback",
        scopes: reachyMiniScopes
    )

    public var isConfigured: Bool {
        !clientID.isEmpty
    }
}

public enum HFOAuthError: Error, Equatable, Sendable {
    /// The callback carried a state this app did not issue. The only thing
    /// standing between it and a code obtained by somebody else.
    case stateMismatch
    /// The Hub refused, usually because the user did.
    case denied(String)
    case missingCode
    case exchangeFailed(statusCode: Int)
    /// Expired with no refresh token. Not an error the app can fix — the user
    /// signs in again, which Safari's cookies usually make instant.
    case notRefreshable
    case invalidToken
    case notConfigured
}

extension HFOAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .stateMismatch:
            "The sign-in reply did not match this request"
        case let .denied(reason):
            "Hugging Face refused the sign-in (\(reason))"
        case .missingCode:
            "The sign-in reply carried no authorization code"
        case let .exchangeFailed(statusCode):
            "Hugging Face rejected the sign-in (HTTP \(statusCode))"
        case .notRefreshable:
            "This session has expired — sign in again"
        case .invalidToken:
            "Hugging Face does not recognise this token"
        case .notConfigured:
            "One-tap sign-in is not available in this build"
        }
    }
}

/// The parts of the flow that are pure: a PKCE pair, the authorize URL, and
/// reading the callback. Everything here is testable without a browser.
public enum HFOAuth {
    public static let authorizationEndpoint = "https://huggingface.co/oauth/authorize"
    public static let tokenEndpoint = "https://huggingface.co/oauth/token"
    /// What both the daemon and the central server validate a token with.
    public static let whoamiEndpoint = "https://huggingface.co/api/whoami-v2"

    /// Proof-key pair for a public client: the verifier stays in this process, and
    /// only its SHA-256 digest travels with the authorization request.
    public struct PKCE: Sendable, Equatable {
        public let verifier: String
        public let method = "S256"

        public var challenge: String {
            Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        /// 32 random bytes, base64url-encoded — 43 characters, the RFC's minimum
        /// and a comfortable amount of entropy.
        public init() {
            var bytes = [UInt8](repeating: 0, count: 32)
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max)
            }
            verifier = Self.base64URL(Data(bytes))
        }

        public init(verifier: String) {
            self.verifier = verifier
        }

        /// Unpadded, URL-safe — a `+`, `/` or `=` here is rejected by the Hub as an
        /// invalid grant, with no hint as to why.
        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    public static func authorizationURL(
        configuration: HFOAuthConfiguration,
        pkce: PKCE,
        state: String
    ) -> URL? {
        guard var components = URLComponents(string: authorizationEndpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
        ]
        return components.url
    }

    /// Reads the authorization code out of the callback, refusing anything whose
    /// state this app did not issue.
    public static func code(in url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

        if let error = query["error"], !error.isEmpty {
            throw HFOAuthError.denied(error)
        }
        guard query["state"] == expectedState else {
            throw HFOAuthError.stateMismatch
        }
        guard let code = query["code"], !code.isEmpty else {
            throw HFOAuthError.missingCode
        }
        return code
    }
}
