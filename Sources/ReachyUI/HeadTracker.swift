/// What reads a head for `HeadphoneTeleop`: headphones through Core Motion on iOS
/// (`HeadphoneTracker`), and the headset itself through ARKit on visionOS
/// (`HeadsetTracker`).
///
/// A tracker turns its device's readings into attitudes relative to a reference it
/// keeps, and hands each one to `HeadphoneTeleop.receive(_:at:)`. The hub decides
/// the rest: when a new reference is due (`takeReferenceRequest()`), what a reading
/// does to the robot, and when silence means the head is lost. So a new device is a
/// tracker and nothing more, and the claims, the gate and every way back to neutral
/// stay one path.
@MainActor
protocol HeadTracker: AnyObject {
    /// The mapping this device's three angles need. Its signs follow from the frame
    /// the device reports in, so they belong to the tracker, and its reach is the
    /// robot's, so every tracker keeps the measured one.
    var mapping: HeadphoneMotionMapping { get }
    /// Read without asking: whether this device can track a head this way at all.
    var isAvailable: Bool { get }
    /// Read without asking: whether access to the readings was refused.
    var isDenied: Bool { get }
    func start(into hub: HeadphoneTeleop)
    /// Stops the readings and forgets the reference.
    func stop()
}
