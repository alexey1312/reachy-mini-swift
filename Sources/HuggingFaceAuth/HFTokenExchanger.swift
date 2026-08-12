import Foundation
import ReachyJSON

/// The network half of the sign-in: swapping a code for a token, renewing one,
/// and asking the Hub who a token belongs to.
public protocol HFTokenExchanging: Sendable {
    func exchange(code: String, verifier: String) async throws -> HFToken
    func refreshing(_ token: HFToken) async throws -> HFToken
    /// Validates a token — a pasted personal access token, or one just issued —
    /// and answers with the account it belongs to.
    func username(for token: String) async throws -> String
}

public struct HFTokenExchanger: HFTokenExchanging {
    private let configuration: HFOAuthConfiguration
    private let session: URLSession

    public init(configuration: HFOAuthConfiguration = .reachyMini, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func exchange(code: String, verifier: String) async throws -> HFToken {
        try await token(form: [
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "code": code,
            "redirect_uri": configuration.redirectURI,
            // PKCE stands in for the client secret a public client cannot keep.
            "code_verifier": verifier,
        ])
    }

    public func refreshing(_ token: HFToken) async throws -> HFToken {
        guard let refreshToken = token.refreshToken else {
            throw HFOAuthError.notRefreshable
        }
        let renewed = try await self.token(form: [
            "grant_type": "refresh_token",
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
        ])
        return renewed.named(renewed.username ?? token.username)
    }

    public func username(for token: String) async throws -> String {
        guard let url = URL(string: HFOAuth.whoamiEndpoint) else {
            throw HFOAuthError.notConfigured
        }
        var request = URLRequest(url: url)
        // Header, never a query parameter: a token in a URL ends up in access logs
        // on every hop between here and the Hub.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HFOAuthError.invalidToken
        }
        guard http.statusCode == 200 else {
            throw http.statusCode == 401 || http.statusCode == 403
                ? HFOAuthError.invalidToken
                : HFOAuthError.exchangeFailed(statusCode: http.statusCode)
        }
        struct Whoami: Decodable {
            let name: String
        }
        guard let whoami = try? JSONCodec.web.decode(Whoami.self, from: data), !whoami.name.isEmpty else {
            throw HFOAuthError.invalidToken
        }
        return whoami.name
    }

    private func token(form: [String: String]) async throws -> HFToken {
        guard let url = URL(string: HFOAuth.tokenEndpoint) else {
            throw HFOAuthError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.encoded(form).utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HFOAuthError.exchangeFailed(statusCode: -1)
        }
        guard http.statusCode == 200 else {
            throw HFOAuthError.exchangeFailed(statusCode: http.statusCode)
        }
        return try Self.decodeToken(data)
    }

    /// `URLComponents` does the percent-encoding, but its rules for a *query* let
    /// `+` through — and in a form body a `+` decodes as a space, which silently
    /// corrupts a verifier or a refresh token.
    static func encoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    /// The Hub answers with `accessToken` often enough that the daemon reads both
    /// spellings; so does this.
    static func decodeToken(_ data: Data) throws -> HFToken {
        struct Payload: Decodable {
            let accessToken: String?
            let accessTokenSnake: String?
            let refreshToken: String?
            let refreshTokenSnake: String?
            let expiresIn: Double?
            let expiresInSnake: Double?

            enum CodingKeys: String, CodingKey {
                case accessToken
                case accessTokenSnake = "access_token"
                case refreshToken
                case refreshTokenSnake = "refresh_token"
                case expiresIn
                case expiresInSnake = "expires_in"
            }
        }

        guard let payload = try? JSONCodec.web.decode(Payload.self, from: data),
              let accessToken = payload.accessTokenSnake ?? payload.accessToken,
              !accessToken.isEmpty
        else {
            throw HFOAuthError.exchangeFailed(statusCode: 200)
        }
        let lifetime = payload.expiresInSnake ?? payload.expiresIn
        return HFToken(
            accessToken: accessToken,
            refreshToken: payload.refreshTokenSnake ?? payload.refreshToken,
            expiresAt: lifetime.map { Date().addingTimeInterval($0) }
        )
    }
}
