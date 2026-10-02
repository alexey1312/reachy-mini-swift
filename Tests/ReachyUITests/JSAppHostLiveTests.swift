#if DEBUG && canImport(WebKit)
    import Foundation
    import ReachyKit
    @testable import ReachyUI
    import Testing
    import WebKit

    /// The hosting design against a real Space, in a real `WKWebView` — the one
    /// thing no stub can say: that a page loaded on its own, not in an iframe,
    /// boots from the fragment and that its messages reach Swift through the
    /// bridge (ADR 0006).
    ///
    /// **Gated on `REACHY_JS_APP_LIVE`**, the way `SimulatorIntegrationTests` is
    /// gated on `REACHY_SIM_HOST`: it needs the network and a Space that is up, so
    /// a plain run skips it and reports green. The credentials are made up, so the
    /// page gets as far as asking Hugging Face who the token belongs to and no
    /// further — which is past everything this test is about.
    ///
    /// `REACHY_JS_APP_LIVE=1 swift test --filter JSAppHostLiveTests`
    ///
    /// **It runs on iOS as well, which `swift test` cannot reach.** iOS is where the
    /// hosting ships first, and its WebKit is a different build from the Mac's.
    /// `xcodebuild` forwards a `TEST_RUNNER_`-prefixed variable to the test process
    /// with the prefix dropped:
    ///
    /// ```
    /// TEST_RUNNER_REACHY_JS_APP_LIVE=1 xcodebuild test -scheme ReachyMini-Package \
    ///   -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    ///   -only-testing:ReachyUITests/JSAppHostLiveTests \
    ///   -skipPackagePluginValidation -skipMacroValidation
    /// ```
    @MainActor
    @Suite(
        "JS app host, live",
        .enabled(if: ProcessInfo.processInfo.environment["REACHY_JS_APP_LIVE"] != nil),
        .timeLimit(.minutes(1))
    )
    struct JSAppHostLiveTests {
        @MainActor
        private final class Recorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
            var messages: [JSAppHostProtocol.PageMessage] = []
            var loadError: String?

            func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let body = message.body as? String,
                      let decoded = JSAppHostProtocol.pageMessage(from: Data(body.utf8))
                else { return }
                messages.append(decoded)
            }

            func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
                loadError = error.localizedDescription
            }
        }

        @Test("a top-level page boots from the fragment and its messages reach Swift")
        func bridgeCarriesTheProtocol() async throws {
            let app = JSApp(id: "tfrere/reachy-mini-sdkjs-demo-static", title: "Reachy Mini Hello World")
            let url = try JSAppEmbed.url(for: app, credentials: JSAppEmbed.Credentials(
                hfToken: "hf_not_a_real_token",
                userName: "nobody",
                robotPeerID: "no-such-peer",
                robotHardwareID: nil,
                signalingURL: CentralRelayClient.defaultBaseURL,
                theme: .dark,
                appName: app.title
            ))
            let recorder = Recorder()
            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                configuration: JSAppWebView.configuration(handler: recorder)
            )
            webView.navigationDelegate = recorder
            webView.load(URLRequest(url: url))

            let deadline = ContinuousClock.now + .seconds(45)
            while ContinuousClock.now < deadline, recorder.loadError == nil,
                  !recorder.messages.contains(where: Self.isPastReady)
            {
                try await Task.sleep(for: .milliseconds(100))
            }

            #expect(recorder.loadError == nil)
            #expect(recorder.messages.contains(.ready))
            // Booted without `host:init`, which nothing here sent: the page moved on
            // to reaching the robot, or failed doing so with the made-up token.
            #expect(recorder.messages.contains(where: Self.isPastReady))
            // The fragment was wiped before the page did anything else.
            let fragment = try await webView.evaluateJavaScript("window.location.hash") as? String
            #expect(fragment?.contains("creds") != true)
        }

        private static func isPastReady(_ message: JSAppHostProtocol.PageMessage) -> Bool {
            switch message {
            case .appState, .error: true
            case .ready, .requestLeave, .left, .other: false
            }
        }
    }
#endif
