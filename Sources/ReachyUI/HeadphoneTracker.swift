#if os(iOS)
    import CoreMotion
    import Foundation

    /// AirPods or Beats that track the listener's head, through Core Motion (the
    /// AirPods spike). iOS only for now: `HeadphoneTeleop.observeDevice()` says why.
    ///
    /// **Readings are relative to the first one.** Core Motion reports a headphone's
    /// attitude in a frame of its own, so the first reading after the hub asks for a
    /// reference becomes it, and `CMAttitude.multiply(byInverseOf:)` gives every
    /// reading after it.
    ///
    /// **Core Motion reads one earbud at a time** and can change to the other, a
    /// mirror image, so each reading reports its earbud and a change takes a new
    /// reference (`HeadphoneTeleop.noteSource(_:)`).
    @MainActor
    final class HeadphoneTracker: HeadTracker {
        let mapping = HeadphoneMotionMapping()
        private let manager = CMHeadphoneMotionManager()
        private var reference: CMAttitude?

        var isAvailable: Bool {
            manager.isDeviceMotionAvailable
        }

        var isDenied: Bool {
            switch CMHeadphoneMotionManager.authorizationStatus() {
            case .denied, .restricted: true
            default: false
            }
        }

        func start(into hub: HeadphoneTeleop) {
            // The main queue, so the handler runs on the main actor in all but name.
            manager.startDeviceMotionUpdates(to: .main) { [weak self, weak hub] motion, error in
                nonisolated(unsafe) let motion = motion
                let failed = error != nil
                MainActor.assumeIsolated {
                    guard let hub else { return }
                    self?.handle(motion, failed: failed, hub: hub)
                }
            }
        }

        func stop() {
            manager.stopDeviceMotionUpdates()
            reference = nil
        }

        private func handle(_ motion: CMDeviceMotion?, failed: Bool, hub: HeadphoneTeleop) {
            if failed {
                if isDenied {
                    hub.trackerWasRefused()
                }
                return
            }
            guard let motion else { return }
            let attitude = motion.attitude
            hub.noteSource(Self.source(of: motion.sensorLocation))
            let isDue = hub.takeReferenceRequest()
            if isDue || reference == nil {
                reference = attitude.copy() as? CMAttitude
                hub.receive(.level, at: .now)
                return
            }
            guard let reference, let relative = attitude.copy() as? CMAttitude else { return }
            relative.multiply(byInverseOf: reference)
            hub.receive(HeadAttitude(yaw: relative.yaw, pitch: relative.pitch, roll: relative.roll), at: .now)
        }

        private static func source(of location: CMDeviceMotion.SensorLocation) -> HeadphoneTeleop.Source {
            switch location {
            case .headphoneLeft: .left
            case .headphoneRight: .right
            default: .unknown
            }
        }
    }
#endif
