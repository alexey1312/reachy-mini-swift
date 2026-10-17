#if os(visionOS)
    import ReachyDesign
    import RealityKit
    import SwiftUI

    /// The immersive space the headset's head tracking reads in (`HeadsetTracker`).
    ///
    /// ARKit gives an app the device pose only while one of its immersive spaces is
    /// open, so this space exists to be open and shows nothing. Its immersion is mixed:
    /// the room stays in view, and so do this app's windows, the camera among them.
    /// The system hides other apps' windows while it is open; that is its rule for any
    /// space, and the section's footer says so.
    ///
    /// The app declares it under `id` and mounts `headsetTrackingSpace()` on its root.
    public struct HeadsetTrackingSpace: View {
        public static let id = "head-tracking"

        public init() {}

        public var body: some View {
            RealityView { _ in }
                // The reader can close the space without the switch, from the Digital
                // Crown. The hub goes off with it, so the switch says what is true.
                .onDisappear { HeadphoneTeleop.shared.setOn(false) }
        }
    }

    public extension View {
        /// Opens `HeadsetTrackingSpace` while the shared hub is on, and dismisses it
        /// when the hub goes off. Mount it once, on the app's root.
        func headsetTrackingSpace() -> some View {
            modifier(HeadsetTrackingSpacePresenter())
        }
    }

    /// The hub is the one truth about on and off, here as on iOS: both switches write
    /// it, and this follows it. So the space can open after the hub switched on, and
    /// the tracker waits for it (`HeadsetTracker.run(_:)`).
    private struct HeadsetTrackingSpacePresenter: ViewModifier {
        @Environment(\.openImmersiveSpace) private var openImmersiveSpace
        @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
        @Environment(\.reachyPreviewMode) private var previewMode
        @State private var isOpen = false

        func body(content: Content) -> some View {
            if previewMode {
                content
            } else {
                content.onChange(of: HeadphoneTeleop.shared.isOn) { _, isOn in
                    Task { await follow(isOn) }
                }
            }
        }

        private func follow(_ isOn: Bool) async {
            let hub = HeadphoneTeleop.shared
            if isOn, !isOpen {
                guard case .opened = await openImmersiveSpace(id: HeadsetTrackingSpace.id) else {
                    // Refused, or a space of another app's kept it closed.
                    hub.setOn(false)
                    return
                }
                isOpen = true
                // Switched off again while the space was opening.
                if !hub.isOn {
                    isOpen = false
                    await dismissImmersiveSpace()
                }
            } else if !isOn, isOpen {
                isOpen = false
                await dismissImmersiveSpace()
            }
        }
    }
#endif
