import AuthenticationServices
import Foundation
import HuggingFaceAuth
@testable import ReachyUI
import Testing

/// Stands in for `ASWebAuthenticationSession`, which cannot run in a test.
///
/// By default it answers the way the Hub does: with the same `state` the
/// authorize URL carried. A fake that forgot to echo it would make every test
/// here pass through the CSRF check by accident.
private final class FakeBrowser: HFWebAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var opened: [URL] = []
    var result: Result<URL, any Error>?

    func authenticate(
        url: URL,
        callbackScheme _: String,
        presentingWindow _: ASPresentationAnchor?
    ) async throws -> URL {
        lock.withLock { opened.append(url) }
        if let result {
            return try result.get()
        }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "reachy-mini-swift://oauth-callback?code=abc&state=\(state)")!
    }
}

private final class FakeExchanger: HFTokenExchanging, @unchecked Sendable {
    var username = "alexey1312"
    var rejectsTokens = false

    func exchange(code _: String, verifier _: String) async throws -> HFToken {
        HFToken(accessToken: "hf_new", expiresAt: Date().addingTimeInterval(3600))
    }

    func refreshing(_ token: HFToken) async throws -> HFToken {
        token
    }

    func username(for _: String) async throws -> String {
        if rejectsTokens {
            throw HFOAuthError.invalidToken
        }
        return username
    }
}

@MainActor
@Suite("Hugging Face sign-in", .timeLimit(.minutes(1)))
struct HFSignInModelTests {
    private let configuration = HFOAuthConfiguration(
        clientID: "client-1",
        redirectURI: "reachy-mini-swift://oauth-callback",
        scopes: HFOAuthConfiguration.reachyMiniScopes
    )

    private func model(
        browser: FakeBrowser = FakeBrowser(),
        exchanger: FakeExchanger = FakeExchanger(),
        configuration: HFOAuthConfiguration? = nil
    ) -> (HFSignInModel, HFAccount) {
        let account = HFAccount(
            configuration: configuration ?? self.configuration,
            store: InMemoryHFTokenStore(),
            exchanger: exchanger
        )
        return (HFSignInModel(account: account, browser: browser), account)
    }

    /// The whole point of `ASWebAuthenticationSession`: it shares Safari's cookies,
    /// so a user already signed in to the Hub taps once and is back.
    @Test("a browser round trip signs the user in")
    func signsInThroughTheBrowser() async {
        let browser = FakeBrowser()
        let (model, account) = model(browser: browser)

        await model.signInWithBrowser()

        #expect(browser.opened.first?.host == "huggingface.co")
        #expect(account.state == .signedIn(username: "alexey1312"))
        #expect(model.errorText == nil)
    }

    /// A callback carrying a state this app did not issue must not sign anyone in.
    /// `HFAccount` enforces that; this proves the UI does not paper over it.
    @Test("a foreign callback ends as an error, not a session")
    func refusesAForeignCallback() async throws {
        let browser = FakeBrowser()
        browser
            .result = try .success(#require(URL(string: "reachy-mini-swift://oauth-callback?code=abc&state=elsewhere")))
        let (model, account) = model(browser: browser)

        await model.signInWithBrowser()

        #expect(model.errorText != nil)
        if case .signedIn = account.state {
            Issue.record("a foreign callback signed the user in")
        }
    }

    /// Closing the sheet is not a failure. Showing an error for it is how an app
    /// tells its user off for changing their mind.
    @Test("cancelling shows nothing at all")
    func cancellingIsSilent() async {
        let browser = FakeBrowser()
        browser.result = .failure(HFSignInModel.Cancelled())
        let (model, _) = model(browser: browser)

        await model.signInWithBrowser()

        #expect(model.errorText == nil)
        #expect(model.isBusy == false)
    }

    @Test("a browser that fails says why")
    func reportsBrowserFailure() async {
        let browser = FakeBrowser()
        browser.result = .failure(URLError(.networkConnectionLost))
        let (model, _) = model(browser: browser)

        await model.signInWithBrowser()

        #expect(model.errorText != nil)
    }

    /// A fork that has not registered its own OAuth app has no client id, and
    /// opening a browser would land the user on Hugging Face's error page.
    @Test("without a client id the browser is never opened")
    func refusesToOpenUnconfigured() async {
        let browser = FakeBrowser()
        let (model, _) = model(browser: browser, configuration: .unregistered)

        #expect(model.offersBrowserSignIn == false)
        await model.signInWithBrowser()

        #expect(browser.opened.isEmpty)
    }

    @Test("a pasted token is accepted once the Hub confirms it")
    func signsInWithAPastedToken() async {
        let (model, account) = model()
        model.pastedToken = "  hf_pasted  "

        await model.signInWithPastedToken()

        #expect(account.state == .signedIn(username: "alexey1312"))
        // Cleared as soon as it is spent: a token left in a field is a token in a
        // screenshot.
        #expect(model.pastedToken.isEmpty)
    }

    @Test("a token the Hub rejects leaves the field alone to be corrected")
    func keepsARejectedToken() async {
        let exchanger = FakeExchanger()
        exchanger.rejectsTokens = true
        let (model, _) = model(exchanger: exchanger)
        model.pastedToken = "nope"

        await model.signInWithPastedToken()

        #expect(model.errorText != nil)
        #expect(model.pastedToken == "nope")
    }

    @Test("signing out forgets the session")
    func signsOut() async {
        let (model, account) = model()
        await model.signInWithBrowser()

        model.signOut()

        #expect(account.state == .signedOut)
    }
}
