import ReachyKit
import SwiftUI
import WebKit

// The #159 prototype, which ships to nobody (ADR 0006).
#if DEBUG
    /// A hosted JS app's page, in a `WKWebView` built for a stranger's code
    /// (ADR 0006).
    ///
    /// Four things set it apart from `AppSettingsScreen`'s web view, which shows a
    /// page the robot's own app serves:
    /// - **A non-persistent data store.** The page keeps the token it was handed in
    ///   `sessionStorage`; with nothing persisted, it dies with this view, and no app
    ///   can read what another left behind.
    /// - **The Space's origin and nothing else.** A main-frame navigation anywhere
    ///   else, and every `window.open`, goes to the system browser instead — which is
    ///   also where an app's own "sign in with Hugging Face" fallback lands, rather
    ///   than a password field inside this app.
    /// - **The microphone may be asked for, the camera never.** Telepresence speaks
    ///   through the phone's microphone; this app's camera usage string promises it
    ///   never records with the phone's camera, and a page from a Space does not get
    ///   to break that promise for it.
    /// - **The bridge** (`JSAppHostBridge`) carries the page's messages to `model`.
    struct JSAppWebView {
        let model: JSAppHostModel
        let openExternally: (URL) -> Void

        @MainActor
        final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
            let model: JSAppHostModel
            let openExternally: (URL) -> Void
            private let allowedHost: String?

            init(model: JSAppHostModel, openExternally: @escaping (URL) -> Void) {
                self.model = model
                self.openExternally = openExternally
                allowedHost = JSAppEmbed.origin(of: model.app)?.host
            }

            func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
                guard JSAppHostBridge.admits(
                    isMainFrame: message.frameInfo.isMainFrame,
                    host: message.frameInfo.securityOrigin.host,
                    allowedHost: allowedHost
                ),
                    let body = message.body as? String,
                    let decoded = JSAppHostProtocol.pageMessage(from: Data(body.utf8))
                else { return }
                model.receive(decoded)
            }

            func webView(
                _: WKWebView,
                decidePolicyFor action: WKNavigationAction,
                decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
            ) {
                // Subframes are the page's business; only where the page itself goes
                // is ours.
                guard action.targetFrame?.isMainFrame ?? false, let url = action.request.url else {
                    decisionHandler(.allow)
                    return
                }
                if url.scheme == "about" || url.host == allowedHost {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                if url.scheme == "https" || url.scheme == "http" {
                    openExternally(url)
                }
            }

            /// `window.open` and `target=_blank`: never a second web view.
            func webView(
                _: WKWebView,
                createWebViewWith _: WKWebViewConfiguration,
                for action: WKNavigationAction,
                windowFeatures _: WKWindowFeatures
            ) -> WKWebView? {
                if let url = action.request.url, url.scheme == "https" {
                    openExternally(url)
                }
                return nil
            }

            func webView(
                _: WKWebView,
                requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                initiatedByFrame _: WKFrameInfo,
                type: WKMediaCaptureType,
                decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
            ) {
                let fromTheApp = origin.host == allowedHost
                decisionHandler(fromTheApp && type == .microphone ? .prompt : .deny)
            }

            func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
                report(error)
            }

            func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
                report(error)
            }

            func webViewWebContentProcessDidTerminate(_: WKWebView) {
                model.pageFailed(String(localized: .reachy("The app's page stopped unexpectedly.")))
            }

            /// Through the one filter that knows a cancelled load is not a failure.
            private func report(_ error: any Error) {
                guard let message = RobotSession.message(for: error) else { return }
                model.pageFailed(message)
            }
        }

        @MainActor
        func makeCoordinator() -> Coordinator {
            Coordinator(model: model, openExternally: openExternally)
        }

        @MainActor
        static func configuration(handler: any WKScriptMessageHandler) -> WKWebViewConfiguration {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let controller = WKUserContentController()
            controller.addUserScript(WKUserScript(
                source: JSAppHostBridge.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            controller.add(JSAppHostBridge.WeakHandler(handler), name: JSAppHostBridge.handlerName)
            configuration.userContentController = controller
            configuration.mediaTypesRequiringUserActionForPlayback = []
            #if os(iOS)
                configuration.allowsInlineMediaPlayback = true
            #endif
            return configuration
        }

        @MainActor
        private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
            let webView = WKWebView(frame: .zero, configuration: Self.configuration(handler: coordinator))
            webView.navigationDelegate = coordinator
            webView.uiDelegate = coordinator
            webView.allowsBackForwardNavigationGestures = false
            #if DEBUG
                // The prototype is measured with Safari's Web Inspector attached.
                webView.isInspectable = true
            #endif
            model.evaluate = { [weak webView] script in
                webView?.evaluateJavaScript(script)
            }
            webView.load(URLRequest(url: model.url))
            return webView
        }

        @MainActor
        private static func tearDown(_ webView: WKWebView) {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: JSAppHostBridge.handlerName)
        }
    }

    #if os(iOS)
        extension JSAppWebView: UIViewRepresentable {
            func makeUIView(context: Context) -> WKWebView {
                makeWebView(context.coordinator)
            }

            func updateUIView(_: WKWebView, context _: Context) {}

            static func dismantleUIView(_ webView: WKWebView, coordinator _: Coordinator) {
                tearDown(webView)
            }
        }
    #else
        extension JSAppWebView: NSViewRepresentable {
            func makeNSView(context: Context) -> WKWebView {
                makeWebView(context.coordinator)
            }

            func updateNSView(_: WKWebView, context _: Context) {}

            static func dismantleNSView(_ webView: WKWebView, coordinator _: Coordinator) {
                tearDown(webView)
            }
        }
    #endif
#endif
