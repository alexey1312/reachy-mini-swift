import ReachyDesign
import ReachyKit
import ReachyUI
import SwiftUI

/// Hey Reachy on Apple Vision Pro: the iPad app's screens in a window, and the
/// headset's own pose to steer the robot's head while the reader watches its camera.
///
/// A target of its own rather than a destination of `ReachyMini`, because the two
/// need different scene manifests (`Apps/Project.swift` says why). It shares
/// everything else through `ReachyUI`, so this file only declares the scenes.
@main
struct ReachyVisionApp: App {
    init() {
        // The phrases with a parameter resolve against values the system captured last;
        // `ReachyMiniApp` says why launch is where this belongs.
        ReachyShortcuts.updateAppShortcutParameters()
        // Before launch finishes, or a tap that launched the app is never delivered.
        JobNotificationResponder.install()
        // Skipped in the smoke run for the reason `ReachyMiniApp` skips it: a test must
        // not pull the developer's iCloud state into its fixture.
        if !ProcessInfo.processInfo.arguments.contains("--reachy-smoke") {
            let mirror = CloudSettingsMirror(
                defaults: KnownRobots.defaults,
                cloud: NSUbiquitousKeyValueStore.default,
                keys: [KnownRobotStore.knownRobotsKey, ThemeStore.key, TwinPaint.key]
            )
            mirror.start()
            CloudSettingsMirror.shared = mirror
        }
    }

    var body: some Scene {
        WindowGroup {
            // The camera is the Live tab, as on every other platform; the window is
            // what the reader places and sizes, so the viewport stays in it
            // (`FloatingViewportModel.offersSecondPlace`).
            ReachyRootView {
                DeviceCheckView()
            }
            .reachyPreviewMode(ProcessInfo.processInfo.arguments.contains("--reachy-smoke"))
            .reachyThemeFromSettings()
            .headsetTrackingSpace()
        }
        // Wider than the Mac's first size, because the camera fills the Live tab and
        // the robot sends 16:9. A guess until a headset shows it; visionOS keeps the
        // size the reader gives the window from then on.
        .defaultSize(width: 1100, height: 720)
        .commands {
            RobotCommands()
        }

        // Empty, and open only while the head is followed: ARKit gives the device
        // pose to an app with an immersive space open and to no other.
        ImmersiveSpace(id: HeadsetTrackingSpace.id) {
            HeadsetTrackingSpace()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
