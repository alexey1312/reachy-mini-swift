import AuthenticationServices
import Foundation
import HuggingFaceAuth

/// The real browser behind `HFWebAuthenticating`.
///
/// `ASWebAuthenticationSession` rather than a `WKWebView` or Safari: it runs the
/// sign-in page **in Safari's own context**, so a user already signed in to the
/// Hub is one tap from done — and this app never sees the page, the password, or
/// the cookies. It is also the only presentation Apple accepts for third-party
/// sign-in.
@MainActor
final class WebAuthenticationBrowser: NSObject, HFWebAuthenticating {
    /// The window the sign-in sheet hangs off, decided **before** the session
    /// starts and simply handed back afterwards.
    ///
    /// It is stored rather than looked up on demand because
    /// `presentationAnchor(for:)` is `nonisolated` and AuthenticationServices calls
    /// it from a queue of its own — see that method for what asking the main actor
    /// there cost. Choosing it here is not a workaround: this is the moment the
    /// user asked to sign in, so it is also the moment "the window they asked
    /// from" is a well-defined thing.
    ///
    /// `nonisolated(unsafe)` because that reader is on another thread and an
    /// `NSWindow` is not `Sendable`. Written on the main actor before `start()` and
    /// only read after, so the race the annotation waives cannot happen.
    ///
    /// Non-optional, and filled in `init` rather than defaulted: a window is built
    /// by a main-actor initialiser, which is exactly what a `nonisolated(unsafe)`
    /// default value may not call. That is the same rule as the crash below, caught
    /// at compile time instead — and it is what keeps the read path from ever
    /// having to build one off the main actor.
    private nonisolated(unsafe) var anchor: ASPresentationAnchor

    override init() {
        anchor = Self.frontmostWindow()
        super.init()
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        anchor = Self.frontmostWindow()
        // The sign-in ran in Safari's context, so the front application is Safari's
        // — and when it closes, macOS hands the front slot to whatever is behind it
        // rather than back to us. Under Stage Manager that is another stage
        // entirely, so the app the reader started from is not merely unfocused, it
        // is off screen. `defer` because a cancellation deserves the way back just
        // as much as a completed sign-in does.
        #if os(macOS)
            // `ignoringOtherApps` is the whole point, and the plain `activate()`
            // shipped here first and did nothing: it takes the front only when no
            // other application holds it, and at this moment Safari still does.
            // `NSRunningApplication.activate(options:)` makes the same conditional
            // promise, so it is not the way round it either.
            defer { NSApplication.shared.activate(ignoringOtherApps: true) }
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { @Sendable callback, error in
                if let error {
                    // The user closing the sheet is the one "failure" that is not
                    // one; everything else is worth showing.
                    let isCancellation = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: isCancellation ? HFSignInModel.Cancelled() : error)
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: HFOAuthError.missingCode)
                    return
                }
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            // Deliberately *not* ephemeral: sharing Safari's cookies is the whole
            // reason this is one tap rather than a password prompt.
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
}

private extension WebAuthenticationBrowser {
    /// Which window a sheet presented now would belong to. `@MainActor`, and it has
    /// to stay that way — every call in it is UI state.
    static func frontmostWindow() -> ASPresentationAnchor {
        #if os(macOS)
            NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}

extension WebAuthenticationBrowser: ASWebAuthenticationPresentationContextProviding {
    /// **This is called on AuthenticationServices' own queue, not on the main one**,
    /// and it used to answer with `MainActor.assumeIsolated`. That is an assertion
    /// rather than a hop: it lowers to `dispatch_assert_queue(main)`, which aborts
    /// the process outright — no Swift error, no `NSException`, nothing in stderr
    /// and no crash report, which is why signing in "just closed the app". The
    /// libdispatch line in the system log is the whole of the evidence:
    /// `BUG IN CLIENT OF LIBDISPATCH: Assertion failed: Block was expected to
    /// execute on queue [com.apple.main-thread]`.
    ///
    /// Hopping to the main actor is not available either — the requirement is
    /// synchronous — and a `@preconcurrency` conformance would only spell the same
    /// trap differently, since it inserts the very check that fired. So the answer
    /// is decided in advance and this reads it.
    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
