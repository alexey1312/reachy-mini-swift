import ReachyDesign
import ReachyKit
import SwiftUI
import WebKit

/// An app's own settings page, served by the app process itself.
///
/// A web view rather than a native screen, and that is forced rather than
/// chosen: the daemon exposes no route for any of an app's own configuration —
/// `extra["custom_app_url"]` names a port and nothing else — so every app's
/// settings live behind a page it renders. A native screen could only be built
/// against Conversation App 1.0's `/rpc` (`personalities.*`, `voices.*`,
/// `backend.config`) and would leave every other app with no settings at all.
///
/// The only `WKWebView` in a shipped build — the hosted JS apps of ADR 0006 are a
/// `DEBUG` prototype. `WebAuthenticationBrowser` is not one either: that is
/// `ASWebAuthenticationSession`, which runs out of process precisely so this app
/// never holds the account's Hugging Face credential in a web view. A hosted JS app
/// is handed a narrow one of its own (ADR 0006), and this page none at all.
struct AppSettingsScreen: View {
    /// What the page is doing. `ready` carries nothing because the web view is
    /// the whole of it.
    enum Phase: Equatable {
        case loading
        case ready
        /// The reason as WebKit gave it — a runtime string, so it stays a
        /// `String` rather than becoming a resource (project rule 9).
        case failed(String)
    }

    let url: URL

    @State private var phase: Phase
    /// Bumped by Try Again. The `switch` below already tears the web view down on
    /// a failure, so a retry gets a fresh one either way — but a web view that
    /// survived would sit on `loadedURL == url` and quietly do nothing, and a
    /// button that silently does nothing is the worse failure.
    @State private var attempt = 0
    @Environment(\.reachyPreviewMode) private var previewMode

    /// `phase` is injectable for the same reason every other screen here takes a
    /// frozen model: a preview must be final on its first frame.
    init(url: URL, phase: Phase = .loading) {
        self.url = url
        _phase = State(initialValue: phase)
    }

    var body: some View {
        content
            .navigationTitle(.reachy("Settings"))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case let .failed(reason):
            ContentUnavailableView {
                Label(.reachy("Settings unavailable"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(reason)
            } actions: {
                Button(.reachy("Try again")) {
                    attempt += 1
                    phase = .loading
                }
            }
        case .loading, .ready:
            page
                .contentLoading(isPresented: phase == .loading, title: .reachy("Loading settings…"))
        }
    }

    /// Nothing at all under `reachyPreviewMode`: a preview must not dial an
    /// address that does not exist while the image is being captured. It also
    /// makes `.ready` render empty, which is honest — see the note on coverage in
    /// `AppSettingsPreviews`.
    @ViewBuilder
    private var page: some View {
        if previewMode {
            Color.clear
        } else {
            AppSettingsWebView(url: url, phase: $phase)
                .id(attempt)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// `WKWebView` behind whichever representable the platform has.
///
/// Written by hand because SwiftUI's own `WebView` is iOS 26 / macOS 26 and this
/// app's floor is iOS 18 / macOS 15.
private struct AppSettingsWebView {
    let url: URL
    @Binding var phase: AppSettingsScreen.Phase

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var phase: Binding<AppSettingsScreen.Phase>?
        /// What this web view was last asked to load. Without it every SwiftUI
        /// update reloads the page, and the page is a form someone is filling in.
        var loadedURL: URL?

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            phase?.wrappedValue = .ready
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
            report(error)
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
            report(error)
        }

        /// A cancelled navigation is not a failure — it is a load being replaced
        /// by the next one, and it arrives as `NSURLErrorCancelled`, whose whole
        /// localized description is the word "cancelled". Printing that under
        /// "Settings unavailable" is the exact bug `RobotSession.message(for:)`
        /// exists to prevent, so this goes through it rather than around it:
        /// `describe` does not filter, and the one log line for a failed call is
        /// on the other side of that funnel. Recognised by code, never by text.
        private func report(_ error: any Error) {
            guard let message = RobotSession.message(for: error) else { return }
            phase?.wrappedValue = .failed(message)
        }
    }

    @MainActor
    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = coordinator
        // The page is the app's own and carries no history the user can reach by
        // any other route, so a swipe back would leave them on a blank web view
        // with no way forward. Navigation belongs to the sheet around it.
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    @MainActor
    private func load(into webView: WKWebView, _ coordinator: Coordinator) {
        coordinator.phase = $phase
        guard coordinator.loadedURL != url else { return }
        coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    /// `@MainActor` because `Coordinator` is — the representable protocols isolate
    /// this requirement to the main actor, but a nonisolated witness would satisfy
    /// them and then fail to construct one.
    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
}

#if os(iOS)
    extension AppSettingsWebView: UIViewRepresentable {
        func makeUIView(context: Context) -> WKWebView {
            makeWebView(context.coordinator)
        }

        func updateUIView(_ webView: WKWebView, context: Context) {
            load(into: webView, context.coordinator)
        }
    }
#else
    extension AppSettingsWebView: NSViewRepresentable {
        func makeNSView(context: Context) -> WKWebView {
            makeWebView(context.coordinator)
        }

        func updateNSView(_ webView: WKWebView, context: Context) {
            load(into: webView, context.coordinator)
        }
    }
#endif
