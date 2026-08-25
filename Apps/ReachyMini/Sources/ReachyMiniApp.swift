import AppIntents
import ReachyDesign
import ReachyKit
import ReachyUI
import SwiftUI
import WidgetKit

@main
struct ReachyMiniApp: App {
    // Carries the Home Screen quick actions and nothing else. The menu they appear
    // in is UIKit's, and a scene delegate is the only way to be told one was
    // tapped — `ReachyQuickAction` says why App Shortcuts cannot cover it.
    #if os(iOS)
        @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var appDelegate
    #endif

    init() {
        // The parameterized phrases ("Start \(\.$app) on …") resolve against entity
        // values the system captured last, and the App Intents contract is that the
        // app calls this whenever those values may have changed — launch is the one
        // moment that always precedes Shortcuts being opened. It is also the only
        // registration nudge an install Xcode did not push (TestFlight) ever gets
        // from this app: an Xcode install registers the shortcuts itself, which is
        // how the gap stayed invisible on every development build.
        ReachyShortcuts.updateAppShortcutParameters()
        // Skipped in the smoke run, off the same argument `reachyPreviewMode` below reads:
        // a UI test must not pull the developer's iCloud state into its fixture.
        if !ProcessInfo.processInfo.arguments.contains("--reachy-smoke") {
            let mirror = CloudSettingsMirror(
                defaults: KnownRobots.defaults,
                cloud: NSUbiquitousKeyValueStore.default,
                keys: [KnownRobotStore.knownRobotsKey, ThemeStore.key],
                onDidApplyExternalChange: {
                    // The widget reads the same suite in its own process; a theme or robot
                    // that arrived from another device needs the same nudge the picker gives.
                    #if !os(macOS)
                        WidgetCenter.shared.reloadAllTimelines()
                    #endif
                }
            )
            mirror.start()
            CloudSettingsMirror.shared = mirror
        }
    }

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
        // Only a first launch reads this — macOS persists the frame afterwards, so
        // a window already on screen keeps the size its reader gave it.
        #if os(macOS)
        .defaultSize(Metrics.window)
        #endif

        // The robot in the menu bar. A second scene rather than anything inside the
        // window, because the point of it is to still be there once the window is
        // closed — which is also why it reads the App Group stores instead of the
        // session, whose lifetime is the window's.
        #if os(macOS)
            ReachyMenuBarScene()
        #endif
    }
}
