#if os(visionOS)
    import ARKit
    import Foundation
    import OSLog
    import QuartzCore

    /// Apple Vision Pro's own pose, through ARKit: the reader turns their head and the
    /// robot turns its own.
    ///
    /// **It reads only while an immersive space is open.** ARKit gives no device pose
    /// to an app in the Shared Space, so the app opens an empty, mixed space while the
    /// hub is on (`HeadsetTrackingSpace`), and closes it when the hub goes off. Until
    /// the space opens the hub waits, as it does for headphones that have sent nothing.
    /// A device pose needs no authorization, so this tracker is never refused.
    ///
    /// **It polls, at 50 Hz.** A device anchor is something to ask for, not an update
    /// ARKit sends, and `queryDeviceAnchor` at the current time predicts nothing.
    ///
    /// **Readings are relative to a reference**, the headphones' rule, so the reader
    /// does not have to face the robot to start. `HeadsetAttitude` says how.
    @MainActor
    final class HeadsetTracker: HeadTracker {
        let mapping = HeadphoneMotionMapping.headset
        let isDenied = false
        private var polling: Task<Void, Never>?
        private var reference: simd_float4x4?

        private static let interval = Duration.milliseconds(20)
        private static let log = Logger(subsystem: "com.alexey1312.ReachyMini", category: "HeadsetTracker")

        var isAvailable: Bool {
            WorldTrackingProvider.isSupported
        }

        func start(into hub: HeadphoneTeleop) {
            polling?.cancel()
            polling = Task { [weak self, weak hub] in
                let session = ARKitSession()
                guard let provider = await Self.run(session) else { return }
                while !Task.isCancelled {
                    if provider.state == .running,
                       let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
                       anchor.isTracked
                    {
                        guard let self, let hub else { break }
                        handle(anchor.originFromAnchorTransform, hub: hub)
                    }
                    try? await Task.sleep(for: Self.interval)
                }
                session.stop()
            }
        }

        func stop() {
            polling?.cancel()
            polling = nil
            reference = nil
        }

        /// The hub switches on before the space it needs has opened, and a session run
        /// outside one can be refused, so a refusal is retried until the task ends. A
        /// provider runs once, so each try takes a new one.
        private static func run(_ session: ARKitSession) async -> WorldTrackingProvider? {
            while !Task.isCancelled {
                let provider = WorldTrackingProvider()
                do {
                    try await session.run([provider])
                    return provider
                } catch {
                    log.notice("World tracking did not start: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            return nil
        }

        private func handle(_ pose: simd_float4x4, hub: HeadphoneTeleop) {
            let isDue = hub.takeReferenceRequest()
            if isDue || reference == nil {
                reference = pose
                hub.receive(.level, at: .now)
                return
            }
            guard let reference else { return }
            hub.receive(HeadsetAttitude.attitude(of: pose, from: reference), at: .now)
        }
    }
#endif
