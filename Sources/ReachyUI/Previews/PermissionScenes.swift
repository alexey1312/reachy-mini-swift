import ReachyKit
@testable import ReachyUI
import SwiftUI

/// Preview wrapper for the privacy screen.
///
/// Split out of `PreviewScenes.swift` only because that file is at its length limit —
/// the same reason `PreviewAppScenes.swift` exists. Same rules: not `private`, because
/// Prefire copies each preview body into a generated file and anything a body names has
/// to be visible target-wide.
@MainActor
extension PreviewScene {
    /// The model is always injected, and that is what makes the screen inert: its
    /// `onAppear` refreshes only when it had to build one itself, so no preview reads a
    /// real authorization or starts a browser.
    static func permissions(
        bluetooth: PermissionState = .granted,
        localNetwork: PermissionState = .granted,
        microphone: PermissionState = .granted,
        notifications: PermissionState = .granted,
        availability: BLEAvailability? = nil
    ) -> some View {
        NavigationHost {
            PermissionsScreen(
                model: .preview(
                    bluetooth: bluetooth,
                    localNetwork: localNetwork,
                    microphone: microphone,
                    notifications: notifications,
                    availability: availability
                )
            )
        }
        .preview()
    }
}
