import Foundation
import Observation

/// This app's own Hugging Face session: what it holds, and how it got it.
///
/// Deliberately separate from a robot's account. Signing in here is what makes
/// "Your Reachies" possible at all — it is how central knows whose robots to
/// list — and linking a robot is a second, explicit act.
///
/// The browser is not here. Opening a URL and receiving the callback belongs to
/// the UI layer, which has `ASWebAuthenticationSession`; this owns the parts that
/// have to be right whether or not a browser is involved.
@MainActor
@Observable
public final class HFAccount {
    public enum State: Equatable, Sendable {
        case signedOut
        case signingIn
        case signedIn(username: String)
        /// The session lapsed and cannot be renewed silently. The username is kept
        /// so the prompt can name whose session it was.
        case needsReauth(username: String?)
        case failed(String)
    }

    public private(set) var state: State = .signedOut

    private let configuration: HFOAuthConfiguration
    private let store: any HFTokenStoring
    private let exchanger: any HFTokenExchanging
    private let now: @Sendable () -> Date
    private var token: HFToken?
    /// The PKCE pair and state of the sign-in currently in flight. Held here so a
    /// callback can be checked against what this app actually asked for.
    private var pending: (pkce: HFOAuth.PKCE, state: String)?
    /// The renewal in flight, shared so overlapping callers do not spend the same
    /// refresh token twice — the Hub can rotate them, and the second exchange
    /// would then fail and knock a freshly renewed session into `needsReauth`.
    private var renewal: Task<String?, Never>?

    public init(
        configuration: HFOAuthConfiguration = .reachyMini,
        store: any HFTokenStoring = InMemoryHFTokenStore(),
        exchanger: (any HFTokenExchanging)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.store = store
        self.exchanger = exchanger ?? HFTokenExchanger(configuration: configuration)
        self.now = now
    }

    /// False until the OAuth app is registered on the Hub. The pasted-token path
    /// stays available either way, which is what makes this an honest question for
    /// a screen to ask rather than a dead button.
    public var canSignInWithBrowser: Bool {
        configuration.isConfigured
    }

    public var username: String? {
        switch state {
        case let .signedIn(username): username
        case let .needsReauth(username): username
        default: nil
        }
    }

    /// Reads whatever the last launch left behind. Cheap and offline — the token's
    /// own expiry is enough to decide, with no call to the Hub.
    public func restore() {
        token = try? store.load()
        guard let token else {
            state = .signedOut
            return
        }
        state = token.needsReauth(at: now())
            ? .needsReauth(username: token.username)
            : .signedIn(username: token.username ?? "")
    }

    /// The URL to open in the browser. Remembers the PKCE pair the callback will
    /// be checked against.
    public func beginSignIn() throws -> URL {
        guard configuration.isConfigured else { throw HFOAuthError.notConfigured }
        let pkce = HFOAuth.PKCE()
        let state = UUID().uuidString
        guard let url = HFOAuth.authorizationURL(configuration: configuration, pkce: pkce, state: state) else {
            throw HFOAuthError.notConfigured
        }
        pending = (pkce, state)
        self.state = .signingIn
        return url
    }

    /// Finishes what `beginSignIn()` started. Refuses a callback whose state this
    /// app did not issue, and never stores a token it could not attribute.
    public func completeSignIn(callback: URL) async {
        guard let pending else {
            state = .failed(HFOAuthError.stateMismatch.localizedDescription)
            return
        }
        self.pending = nil
        do {
            let code = try HFOAuth.code(in: callback, expectedState: pending.state)
            let issued = try await exchanger.exchange(code: code, verifier: pending.pkce.verifier)
            let username = try await exchanger.username(for: issued.accessToken)
            try keep(issued.named(username))
            state = .signedIn(username: username)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// The personal-access-token path: the way in without a registered OAuth app,
    /// and the way in for anyone who would rather not use a browser at all.
    public func signIn(pastedToken: String) async {
        let trimmed = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed(HFOAuthError.invalidToken.localizedDescription)
            return
        }
        state = .signingIn
        do {
            // Validated against the Hub rather than pattern-matched: a token that
            // looks right and is not would fail later, somewhere less explicable.
            let username = try await exchanger.username(for: trimmed)
            try keep(HFToken(accessToken: trimmed, username: username))
            state = .signedIn(username: username)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// Forgets this app's token. A robot that was linked keeps its own copy — that
    /// is a separate act to undo, and doing it silently here would leave the user
    /// believing a robot went offline when it did not.
    public func signOut() {
        try? store.clear()
        token = nil
        pending = nil
        state = .signedOut
    }

    /// The token to put in an `Authorization` header, renewed first if it is due.
    ///
    /// Renewal happens here rather than on a timer because this is the only moment
    /// that knows the token is about to be used.
    public func currentToken() async -> String? {
        guard let token else { return nil }
        guard token.isExpired(at: now()) else { return token.accessToken }
        if let renewal {
            return await renewal.value
        }
        let renewal = Task { await renew(token) }
        self.renewal = renewal
        defer { self.renewal = nil }
        return await renewal.value
    }

    private func renew(_ expired: HFToken) async -> String? {
        do {
            let renewed = try await exchanger.refreshing(expired)
            // The user may have signed out — or into another account — while the
            // exchange was in flight. Their decision wins: writing the renewed
            // token back would resurrect a session they just ended.
            guard token?.accessToken == expired.accessToken else { return nil }
            try keep(renewed)
            state = .signedIn(username: renewed.username ?? "")
            return renewed.accessToken
        } catch {
            guard token?.accessToken == expired.accessToken else { return nil }
            state = .needsReauth(username: expired.username)
            return nil
        }
    }

    private func keep(_ token: HFToken) throws {
        try store.save(token)
        self.token = token
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
