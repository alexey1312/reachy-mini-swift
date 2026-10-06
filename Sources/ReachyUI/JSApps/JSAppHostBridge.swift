import Foundation
import ReachyKit
import WebKit

// The #159 prototype, which ships to nobody (ADR 0006).
#if DEBUG
    /// How a hosted JS app's messages reach Swift (ADR 0006).
    ///
    /// The page is the web view's own top-level document, not an iframe in a page of
    /// ours — there is no page of ours. So the SDK's `window.parent.postMessage` lands
    /// on the page's own window, where a script injected at document start listens
    /// and forwards protocol v1 to a script message handler. The SDK sees that it is
    /// not in an iframe and resolves its credentials from the URL fragment at once
    /// (`awaitHostInit` in `ts/host/src/embed/index.ts`), so `host:init` is never
    /// sent, and no message this host sends carries a secret.
    ///
    /// Only page-to-host types (`embed:*`) are forwarded: the host's own
    /// `host:leaving` arrives on the same window, through the same listener, and must
    /// not come back as if the page had said it. And only what the page posted to
    /// itself: a frame the page embeds can post to this window too, and that frame is
    /// somebody else's code.
    enum JSAppHostBridge {
        static let handlerName = "reachyHost"

        static let script = """
        (function () {
          'use strict';
          var handlers = window.webkit && window.webkit.messageHandlers;
          var handler = handlers && handlers.\(handlerName);
          if (!handler) { return; }
          window.addEventListener('message', function (event) {
            if (event.source !== window || event.origin !== window.location.origin) { return; }
            var data = event.data;
            if (!data || typeof data !== 'object') { return; }
            if (data.source !== '\(JSAppHostProtocol.source)') { return; }
            if (data.version !== \(JSAppHostProtocol.version)) { return; }
            if (typeof data.type !== 'string' || data.type.indexOf('embed:') !== 0) { return; }
            try { handler.postMessage(JSON.stringify(data)); } catch (error) {}
          });
        })();
        """

        /// Whether a script message speaks for the app: it comes from the page's own
        /// document, at the Space's own host. `window.webkit.messageHandlers` is there
        /// in every frame, so a frame the page embeds could post to the handler
        /// directly and never pass through the script above.
        static func admits(isMainFrame: Bool, host: String, allowedHost: String?) -> Bool {
            isMainFrame && host == allowedHost
        }

        /// Posts a host message into the page, where the SDK's own listener reads it.
        /// `json` is an object literal produced by `JSAppHostProtocol`, which is valid
        /// JavaScript as it stands.
        static func post(_ json: String) -> String {
            "window.postMessage(\(json), '*');"
        }

        /// `WKUserContentController` holds its handlers strongly, and the handler is
        /// the coordinator that holds the web view: a weak hop is what lets the pair
        /// be released when the screen closes.
        final class WeakHandler: NSObject, WKScriptMessageHandler {
            private weak var target: (any WKScriptMessageHandler)?

            init(_ target: any WKScriptMessageHandler) {
                self.target = target
            }

            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                target?.userContentController(controller, didReceive: message)
            }
        }
    }
#endif
