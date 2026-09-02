import Foundation
import HuggingFaceAuth
import Observation
import ReachyDesign

/// Opens the sign-in page and hands the callback back.
///
/// A seam rather than a direct call: `ASWebAuthenticationSession` needs a real
/// window to present from, cannot run in a test, and must never open during a
/// snapshot.
@MainActor
protocol HFWebAuthenticating: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// The sign-in half of the Hugging Face account card.
///
/// `HFAccount` owns the protocol and the token; this owns what the user sees
/// while it happens — which button is available, what is spinning, and what went
/// wrong in words.
@MainActor
@Observable
final class HFSignInModel {
    /// Thrown by the browser seam when the user closed the sheet. Not an error to
    /// report: showing one tells the user off for changing their mind.
    struct Cancelled: Error {}

    var pastedToken = ""
    private(set) var isBusy = false
    private(set) var errorText: String?

    /// Signing out is one tap and signing back in is a browser round trip, so it
    /// asks. Unlinking is a separate decision, and this dialog does not offer it.
    static let signOutConfirmation = Confirmation(
        title: .reachy("Sign out of Hugging Face?"),
        message: .reachy("Your Reachies and private Spaces stay out of reach until you sign in again."),
        confirm: .reachy("Sign out")
    )

    let account: HFAccount
    private let browser: any HFWebAuthenticating

    init(account: HFAccount, browser: (any HFWebAuthenticating)? = nil) {
        self.account = account
        self.browser = browser ?? WebAuthenticationBrowser()
    }

    /// False until the OAuth app is registered on the Hub. The pasted-token path
    /// stays open either way, which is why this is a question worth asking rather
    /// than a button that fails.
    var offersBrowserSignIn: Bool {
        account.canSignInWithBrowser
    }

    func signInWithBrowser() async {
        guard offersBrowserSignIn else { return }
        errorText = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let url = try account.beginSignIn()
            let callback = try await browser.authenticate(
                url: url,
                callbackScheme: HFOAuthConfiguration.callbackScheme
            )
            await account.completeSignIn(callback: callback)
            if case let .failed(reason) = account.state {
                errorText = reason
            }
        } catch is Cancelled {
            account.signOut()
        } catch {
            account.signOut()
            errorText = Self.describe(error)
        }
    }

    func signInWithPastedToken() async {
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        errorText = nil
        isBusy = true
        defer { isBusy = false }

        await account.signIn(pastedToken: token)
        if case let .failed(reason) = account.state {
            // Left in the field on purpose: a token that was mistyped is worth
            // correcting rather than retyping from scratch.
            errorText = reason
        } else {
            pastedToken = ""
        }
    }

    func signOut() {
        account.signOut()
        errorText = nil
        pastedToken = ""
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#if DEBUG
    extension HFSignInModel {
        /// A card parked in one state, with a browser that opens nothing.
        static func preview(
            state: HFAccount.State = .signedOut,
            configuration: HFOAuthConfiguration = .init(
                clientID: "preview-client",
                redirectURI: "reachy-mini-swift://oauth-callback",
                scopes: HFOAuthConfiguration.reachyMiniScopes
            ),
            error: String? = nil
        ) -> HFSignInModel {
            let token: HFToken? = switch state {
            case let .signedIn(username): HFToken(accessToken: "hf_preview", username: username)
            case let .needsReauth(username):
                HFToken(accessToken: "hf_preview", expiresAt: .distantPast, username: username)
            default: nil
            }
            let account = HFAccount(
                configuration: configuration,
                store: InMemoryHFTokenStore(token: token),
                exchanger: InertExchanger()
            )
            account.restore()
            let model = HFSignInModel(account: account, browser: InertBrowser())
            model.errorText = error
            return model
        }
    }

    private struct InertBrowser: HFWebAuthenticating {
        func authenticate(url _: URL, callbackScheme _: String) async throws -> URL {
            throw HFSignInModel.Cancelled()
        }
    }

    private struct InertExchanger: HFTokenExchanging {
        func exchange(code _: String, verifier _: String) async throws -> HFToken {
            throw HFOAuthError.notConfigured
        }

        func refreshing(_ token: HFToken) async throws -> HFToken {
            token
        }

        func username(for _: String) async throws -> String {
            throw HFOAuthError.notConfigured
        }
    }
#endif
