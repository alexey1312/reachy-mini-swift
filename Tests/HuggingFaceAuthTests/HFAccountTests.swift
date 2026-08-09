import Foundation
@testable import HuggingFaceAuth
import Testing

/// Scripted stand-in for the Hub. Records what it was asked so a test can prove a
/// token was validated rather than trusted.
private final class FakeExchanger: HFTokenExchanging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var exchanged: [(code: String, verifier: String)] = []
    private(set) var refreshCalls = 0
    private(set) var validated: [String] = []
    var username = "alexey1312"
    var rejectsTokens = false
    /// A gate a test can hold shut to keep a renewal in flight while it acts.
    var onRefresh: (@Sendable () async -> Void)?

    func exchange(code: String, verifier: String) async throws -> HFToken {
        lock.withLock { exchanged.append((code, verifier)) }
        return HFToken(accessToken: "hf_new", refreshToken: "r1", expiresAt: Date().addingTimeInterval(3600))
    }

    func refreshing(_ token: HFToken) async throws -> HFToken {
        lock.withLock { refreshCalls += 1 }
        await onRefresh?()
        guard token.refreshToken != nil else { throw HFOAuthError.notRefreshable }
        return HFToken(
            accessToken: "hf_refreshed",
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(3600),
            username: token.username
        )
    }

    func username(for token: String) async throws -> String {
        lock.withLock { validated.append(token) }
        if rejectsTokens {
            throw HFOAuthError.invalidToken
        }
        return username
    }
}

@MainActor
@Suite("Hugging Face account", .timeLimit(.minutes(1)))
struct HFAccountTests {
    private let configuration = HFOAuthConfiguration(
        clientID: "client-1",
        redirectURI: "reachy-mini-swift://oauth-callback",
        scopes: HFOAuthConfiguration.reachyMiniScopes
    )

    private func account(
        store: any HFTokenStoring = InMemoryHFTokenStore(),
        exchanger: FakeExchanger = FakeExchanger(),
        configuration: HFOAuthConfiguration? = nil
    ) -> HFAccount {
        HFAccount(
            configuration: configuration ?? self.configuration,
            store: store,
            exchanger: exchanger
        )
    }

    @Test("a fresh install is signed out")
    func startsSignedOut() {
        let account = account()
        account.restore()

        #expect(account.state == .signedOut)
    }

    @Test("a stored token signs the user straight back in")
    func restoresAStoredToken() {
        let store = InMemoryHFTokenStore(
            token: HFToken(accessToken: "hf_old", expiresAt: .distantFuture, username: "alexey1312")
        )
        let account = account(store: store)

        account.restore()

        #expect(account.state == .signedIn(username: "alexey1312"))
    }

    /// Expired with nothing to renew it. Worth its own state rather than a plain
    /// signed-out: the app knows whose session lapsed, and signing in again through
    /// Safari's cookies is one tap.
    @Test("an expired token with nothing to renew it asks for a new sign-in")
    func reportsNeedsReauth() {
        let store = InMemoryHFTokenStore(
            token: HFToken(accessToken: "hf_old", refreshToken: nil, expiresAt: .distantPast, username: "alexey1312")
        )
        let account = account(store: store)

        account.restore()

        #expect(account.state == .needsReauth(username: "alexey1312"))
    }

    /// The shape a fork is in before it registers its own OAuth app. Named
    /// explicitly rather than taken from `.reachyMini`, which is configured.
    @Test("without a registered client id there is nothing to open")
    func refusesToStartUnconfigured() {
        let account = account(configuration: .unregistered)

        #expect(account.canSignInWithBrowser == false)
        #expect(throws: HFOAuthError.notConfigured) {
            try account.beginSignIn()
        }
    }

    @Test("starting a sign-in produces the URL to open")
    func beginsSignIn() throws {
        let account = account()

        let url = try account.beginSignIn()

        #expect(url.absoluteString.hasPrefix("https://huggingface.co/oauth/authorize?"))
        #expect(account.state == .signingIn)
    }

    /// A callback carrying somebody else's state must not become a session — and
    /// must not leave a token behind either.
    @Test("a callback this app did not ask for is refused")
    func refusesAForeignCallback() async throws {
        let store = InMemoryHFTokenStore()
        let exchanger = FakeExchanger()
        let account = account(store: store, exchanger: exchanger)
        _ = try account.beginSignIn()

        try await account.completeSignIn(
            callback: #require(URL(string: "reachy-mini-swift://oauth-callback?code=abc&state=someone-else"))
        )

        #expect(exchanger.exchanged.isEmpty)
        #expect(try store.load() == nil)
        if case .failed = account.state {} else {
            Issue.record("expected a failed sign-in, got \(account.state)")
        }
    }

    @Test("a successful callback stores the token and names the account")
    func completesSignIn() async throws {
        let store = InMemoryHFTokenStore()
        let exchanger = FakeExchanger()
        let account = account(store: store, exchanger: exchanger)
        let url = try account.beginSignIn()
        let state = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value)

        try await account.completeSignIn(
            callback: #require(URL(string: "reachy-mini-swift://oauth-callback?code=abc&state=\(state)"))
        )

        #expect(account.state == .signedIn(username: "alexey1312"))
        #expect(exchanger.exchanged.first?.code == "abc")
        #expect(try store.load()?.accessToken == "hf_new")
        #expect(try store.load()?.username == "alexey1312")
    }

    /// The fallback path, and the only one that works until the OAuth app exists.
    @Test("a pasted token is validated before it is kept")
    func acceptsAValidatedPastedToken() async throws {
        let store = InMemoryHFTokenStore()
        let exchanger = FakeExchanger()
        let account = account(store: store, exchanger: exchanger)

        await account.signIn(pastedToken: "hf_pasted")

        #expect(exchanger.validated == ["hf_pasted"])
        #expect(account.state == .signedIn(username: "alexey1312"))
        #expect(try store.load()?.accessToken == "hf_pasted")
    }

    @Test("a pasted token the Hub rejects is not kept")
    func rejectsAnInvalidPastedToken() async throws {
        let store = InMemoryHFTokenStore()
        let exchanger = FakeExchanger()
        exchanger.rejectsTokens = true
        let account = account(store: store, exchanger: exchanger)

        await account.signIn(pastedToken: "nope")

        #expect(try store.load() == nil)
        if case .failed = account.state {} else {
            Issue.record("expected a failed sign-in, got \(account.state)")
        }
    }

    @Test("signing out forgets the token")
    func signsOut() throws {
        let store = InMemoryHFTokenStore(token: HFToken(accessToken: "hf_old", expiresAt: .distantFuture))
        let account = account(store: store)
        account.restore()

        account.signOut()

        #expect(account.state == .signedOut)
        #expect(try store.load() == nil)
    }

    /// Renewal happens on the way to a request, not on a timer: nothing else knows
    /// when the token is about to be needed.
    @Test("an expiring token is renewed on use and the renewal is kept")
    func refreshesOnDemand() async throws {
        let store = InMemoryHFTokenStore(
            token: HFToken(accessToken: "hf_old", refreshToken: "r1", expiresAt: .distantPast, username: "alexey1312")
        )
        let exchanger = FakeExchanger()
        let account = account(store: store, exchanger: exchanger)
        account.restore()

        let token = await account.currentToken()

        #expect(token == "hf_refreshed")
        #expect(exchanger.refreshCalls == 1)
        #expect(try store.load()?.accessToken == "hf_refreshed")
        #expect(account.state == .signedIn(username: "alexey1312"))
    }

    /// The Hub can rotate refresh tokens, so spending one twice fails the second
    /// exchange and knocks a freshly renewed session into needsReauth.
    @Test("overlapping renewals spend the refresh token once")
    func coalescesOverlappingRenewals() async {
        let store = InMemoryHFTokenStore(
            token: HFToken(accessToken: "hf_old", refreshToken: "r1", expiresAt: .distantPast, username: "alexey1312")
        )
        let exchanger = FakeExchanger()
        let account = account(store: store, exchanger: exchanger)
        account.restore()

        async let first = account.currentToken()
        async let second = account.currentToken()
        let tokens = await [first, second]

        #expect(tokens == ["hf_refreshed", "hf_refreshed"])
        #expect(exchanger.refreshCalls == 1)
    }

    /// The user asked to be signed out; a renewal that was already in flight must
    /// not write a fresh token back into the Keychain over that decision.
    @Test("a sign-out during a renewal is not resurrected")
    func signOutDuringRenewalStays() async throws {
        let store = InMemoryHFTokenStore(
            token: HFToken(accessToken: "hf_old", refreshToken: "r1", expiresAt: .distantPast, username: "alexey1312")
        )
        let exchanger = FakeExchanger()
        let (gate, opener) = AsyncStream.makeStream(of: Void.self)
        exchanger.onRefresh = {
            var opened = gate.makeAsyncIterator()
            await opened.next()
        }
        let account = account(store: store, exchanger: exchanger)
        account.restore()

        let renewal = Task { await account.currentToken() }
        await waitUntil("the renewal is in flight") { exchanger.refreshCalls == 1 }
        account.signOut()
        opener.yield(())
        let token = await renewal.value

        #expect(token == nil)
        #expect(account.state == .signedOut)
        #expect(try store.load() == nil)
    }

    @Test("a token that is still good is used as it is")
    func usesAValidTokenUnchanged() async {
        let store = InMemoryHFTokenStore(
            token: HFToken(accessToken: "hf_good", expiresAt: .distantFuture, username: "alexey1312")
        )
        let exchanger = FakeExchanger()
        let account = account(store: store, exchanger: exchanger)
        account.restore()

        #expect(await account.currentToken() == "hf_good")
        #expect(exchanger.refreshCalls == 0)
    }

    @Test("a signed-out app has no token to offer")
    func offersNoTokenWhenSignedOut() async {
        let account = account()
        account.restore()

        #expect(await account.currentToken() == nil)
    }
}

/// `@MainActor` because every condition closes over main-actor state — the same
/// shape as `ConnectProgressModelTests`' copy.
@MainActor
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
