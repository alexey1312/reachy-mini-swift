import Foundation
@testable import ReachyUI
import Testing

/// The settings sheet has no address bar, so the page must not be able to put
/// somebody else's site under its "Settings" title.
@Suite("An app's settings page stays on its own origin")
struct AppSettingsNavigationTests {
    private let page = URL(string: "http://10.0.0.7:7860/")!

    @Test(
        "the main frame may go only where the page already is",
        arguments: [
            ("http://10.0.0.7:7860/personalities", AppSettingsNavigation.allow),
            ("HTTP://10.0.0.7:7860/", .allow),
            ("about:blank", .allow),
            ("http://10.0.0.7:8000/api/daemon/status", .openExternally),
            ("https://10.0.0.7:7860/", .openExternally),
            ("https://huggingface.co/login", .openExternally),
            ("http://evil.example/", .openExternally),
            ("file:///etc/passwd", .refuse),
            ("data:text/html,hello", .refuse),
        ]
    )
    func mainFrame(target: String, expected: AppSettingsNavigation) {
        #expect(AppSettingsNavigation.decide(URL(string: target), isMainFrame: true, page: page) == expected)
    }

    @Test("a subframe is the page's own business")
    func subframe() {
        let elsewhere = URL(string: "https://evil.example/")
        #expect(AppSettingsNavigation.decide(elsewhere, isMainFrame: false, page: page) == .allow)
    }

    @Test("a port left implicit is the scheme's default")
    func implicitPort() throws {
        let page = try #require(URL(string: "https://robot.local/"))
        let explicit = URL(string: "https://robot.local:443/settings")
        #expect(AppSettingsNavigation.decide(explicit, isMainFrame: true, page: page) == .allow)
    }
}
