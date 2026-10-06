#if DEBUG
    import JavaScriptCore
    import ReachyKit
    @testable import ReachyUI
    import Testing

    /// What the bridge lets through to the model, without WebKit: the injected script
    /// runs in a bare `JSContext` over a stand-in `window`, and the frame check is a
    /// plain function.
    @Suite("JS app host bridge")
    struct JSAppHostBridgeTests {
        private static let origin = "https://tfrere-reachy-mini-sdkjs-demo-static.static.hf.space"

        /// A `window` that records the listener the script adds and what it forwards
        /// to the handler, with the bridge's script run over it.
        private func page() throws -> JSContext {
            let context = try #require(JSContext())
            context.evaluateScript("""
            var forwarded = [];
            var listener = null;
            var window = {
              location: { origin: '\(Self.origin)' },
              webkit: { messageHandlers: { \(JSAppHostBridge.handlerName): {
                postMessage: function (body) { forwarded.push(body); }
              } } },
              addEventListener: function (type, handler) { if (type === 'message') { listener = handler; } }
            };
            var frame = {};
            """)
            context.evaluateScript(JSAppHostBridge.script)
            return context
        }

        /// Delivers one `embed:ready` and answers how many messages reached the handler.
        private func deliver(to context: JSContext, source: String, origin: String) -> Int32 {
            context.evaluateScript("""
            listener({
              source: \(source),
              origin: '\(origin)',
              data: {
                source: '\(JSAppHostProtocol.source)',
                version: \(JSAppHostProtocol.version),
                type: 'embed:ready'
              }
            });
            """)
            return context.evaluateScript("forwarded.length").toInt32()
        }

        @Test("the page's own message reaches the host")
        func forwardsThePage() throws {
            let context = try page()

            #expect(deliver(to: context, source: "window", origin: Self.origin) == 1)
        }

        /// An iframe the page embeds can post to the page's window, and it is
        /// somebody else's code.
        @Test("a message from another frame is dropped")
        func dropsAnotherFrame() throws {
            let context = try page()

            #expect(deliver(to: context, source: "frame", origin: Self.origin) == 0)
        }

        @Test("a message from another origin is dropped")
        func dropsAnotherOrigin() throws {
            let context = try page()

            #expect(deliver(to: context, source: "window", origin: "https://example.com") == 0)
        }

        /// `window.webkit.messageHandlers` is there in every frame, so a frame can skip
        /// the script and post to the handler itself.
        @Test("only the main frame at the Space's own host speaks for the app")
        func admitsTheMainFrameAlone() {
            let host = "tfrere-reachy-mini-sdkjs-demo-static.static.hf.space"

            #expect(JSAppHostBridge.admits(isMainFrame: true, host: host, allowedHost: host))
            #expect(!JSAppHostBridge.admits(isMainFrame: false, host: host, allowedHost: host))
            #expect(!JSAppHostBridge.admits(isMainFrame: true, host: "example.com", allowedHost: host))
            #expect(!JSAppHostBridge.admits(isMainFrame: true, host: host, allowedHost: nil))
        }
    }
#endif
