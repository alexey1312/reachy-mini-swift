import ReachyUI
import SwiftUI

@main
struct ReachyMiniApp: App {
    // Carries the Home Screen quick actions and nothing else. The menu they appear
    // in is UIKit's, and a scene delegate is the only way to be told one was
    // tapped — `ReachyQuickAction` says why App Shortcuts cannot cover it.
    #if os(iOS)
        @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            // The tab bar is `ReachyRootView`'s: which tabs exist depends on the
            // size class, and the robot tabs share one session. This screen is not
            // one of them — it is handed to Settings → Advanced, where a phase 0
            // device check belongs now that connecting is a first-class flow.
            ReachyRootView {
                DeviceCheckView()
            }
            // The smoke test's seam: frozen like a preview, so the launched app
            // starts no Bonjour browse and no sockets while under XCUITest.
            .reachyPreviewMode(ProcessInfo.processInfo.arguments.contains("--reachy-smoke"))
            .reachyThemeFromSettings()
        }
    }
}
