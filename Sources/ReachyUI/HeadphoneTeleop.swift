import CoreMotion
import Foundation
import Observation
import ReachyKit

/// Headphones that track the listener's head, steering the robot's (the AirPods spike).
///
/// **Everything goes into `TeleopDriver`, never past it** — the game controller's rule,
/// for the controller's reason: the slew limiter and the daemon's own limits apply
/// unchanged (project rule 2). `TeleopDriver.aim(_:)` is the one door.
///
/// **One screen drives with it, so there is no shared hub.** The Controller screen owns
/// an instance and attaches its driver only while the robot can be driven — awake, with
/// no power transition under way and the scene in front. A stream of targets right after
/// the motors come on can take the daemon down (pollen-robotics/reachy_mini#1430), and
/// readings taken in the background would drive a robot nobody watches.
///
/// **The head starts from where the reader is looking.** Core Motion reports a
/// headphone's attitude in a frame of its own, so the first reading after a switch-on,
/// an attach or `recentre()` becomes the reference and everything after it is relative
/// to that. Nothing asks the reader to look anywhere first; the footer says to look
/// straight ahead, and Recentre is there for when they did not.
///
/// **Losing the headphones puts the head back.** Readings stop with no event at all
/// when an AirPod leaves an ear or the headphones disconnect, so silence for
/// `staleAfter` is the signal: the robot's head returns to neutral and the next
/// reading is a fresh reference. The same release happens on detach and on switch-off,
/// the way the game controller lets go of a look it was holding.
@MainActor
@Observable
final class HeadphoneTeleop {
    enum Status: Equatable {
        /// This device cannot read headphone motion, or nobody has asked yet. The
        /// screen offers nothing — which is every Mac, every simulator and every capture.
        case unsupported
        case off
        /// Switched on, and no reading has arrived since.
        case waiting
        /// Readings arrive, and reach the robot while a driver is attached.
        case following
        /// Motion & Fitness access was refused, at the prompt or in Settings.
        case denied
    }

    /// Which earbud's sensors Core Motion reads. It reads one at a time and can change
    /// to the other, for example when an AirPod leaves an ear. The two buds are mirror
    /// images, so a reference taken on one is wrong for the other.
    enum Source: Equatable {
        case left
        case right
        case unknown
    }

    private(set) var status: Status
    let mapping: HeadphoneMotionMapping

    /// The last reading, relative to the reference and before the mapping, for the
    /// screen to show. Which head motion moves which of the three angles is still a
    /// device question, and this line is how a reader answers it.
    private(set) var reading: HeadAttitude?
    private(set) var source: Source?

    /// The next reading becomes the reference. Set by a switch-on, an attach, a
    /// recentre and a loss; read and cleared by the Core Motion half.
    @ObservationIgnored private(set) var needsReference = true

    @ObservationIgnored private weak var driver: TeleopDriver?
    @ObservationIgnored private var lastReading: ContinuousClock.Instant?
    @ObservationIgnored private var manager: CMHeadphoneMotionManager?
    @ObservationIgnored private var reference: CMAttitude?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    /// Long enough to ride out a reading or two the headphones skip, short enough that
    /// a head left turned reads as a robot left turned only briefly.
    static let staleAfter = Duration.seconds(1)

    /// `status` is the preview seam: a capture hands in the state it shows, and only
    /// `observeHeadphones()` ever reads the device.
    init(
        mapping: HeadphoneMotionMapping = HeadphoneMotionMapping(),
        status: Status = .unsupported,
        reading: HeadAttitude? = nil,
        source: Source? = nil
    ) {
        self.mapping = mapping
        self.status = status
        self.reading = reading
        self.source = source
    }

    #if DEBUG
        /// A capture's hub. A followed head shows its live reading, so that state carries
        /// one: the pose of `Controller — following a head`'s driver, before the mapping
        /// flips pitch.
        static func preview(status: Status) -> HeadphoneTeleop {
            let following = status == .following
            return HeadphoneTeleop(
                status: status,
                reading: following ? HeadAttitude(yaw: 0.35, pitch: -0.2, roll: 0.12) : nil,
                source: following ? .left : nil
            )
        }
    #endif

    var isOn: Bool {
        status == .waiting || status == .following
    }

    /// Reads whether this device can track a head at all. iOS only for now: on a Mac
    /// the same API exists, but the Motion pane a refusal would have to open there has
    /// not been checked by hand, and a wrong pane has no runtime signal
    /// (`PrivacySettingsLink`).
    func observeHeadphones() {
        #if os(iOS)
            guard manager == nil else { return }
            let manager = CMHeadphoneMotionManager()
            self.manager = manager
            if manager.isDeviceMotionAvailable, status == .unsupported {
                status = .off
            }
        #endif
    }

    func setOn(_ isOn: Bool) {
        guard isOn != self.isOn else { return }
        if isOn {
            switchOn()
        } else {
            switchOff(to: .off)
        }
    }

    /// Where the reader looks now becomes straight ahead.
    func recentre() {
        needsReference = true
        releaseHead()
    }

    func attach(_ driver: TeleopDriver) {
        self.driver = driver
        needsReference = true
    }

    func detach() {
        releaseHead()
        driver = nil
    }

    /// One reading, already relative to the reference. The Core Motion half calls this;
    /// so do tests, which have no headphones to read.
    func receive(_ attitude: HeadAttitude, at instant: ContinuousClock.Instant) {
        guard isOn else { return }
        lastReading = instant
        status = .following
        reading = attitude
        // On every reading rather than on the edge into `.following`: Recentre gives the
        // default back while the status stays `.following`, and the next reading has
        // to take the fast one again. The driver ignores a limiter it already has.
        driver?.useLimiter(.headTracking)
        driver?.aim(mapping.aim(attitude))
    }

    /// The watchdog's one step. Called on a timer while switched on, and by tests.
    func checkForSilence(at instant: ContinuousClock.Instant) {
        guard status == .following, let lastReading else { return }
        guard lastReading.duration(to: instant) > Self.staleAfter else { return }
        // Released while still following: `releaseHead` puts back only a head it led.
        releaseHead()
        status = .waiting
        reading = nil
        needsReference = true
    }

    // MARK: - Switching

    private func switchOn() {
        guard status != .unsupported else { return }
        if manager != nil {
            switch CMHeadphoneMotionManager.authorizationStatus() {
            case .denied, .restricted:
                status = .denied
                return
            default:
                break
            }
        }
        status = .waiting
        needsReference = true
        startUpdates()
    }

    private func switchOff(to status: Status) {
        manager?.stopDeviceMotionUpdates()
        watchdog?.cancel()
        watchdog = nil
        reference = nil
        lastReading = nil
        releaseHead()
        self.status = status
        reading = nil
        source = nil
    }

    /// Only a head that was being followed is put back: a driver whose pad is in use
    /// while the headphones wait has a thumb on it, and a release would fight it.
    /// The way back to neutral takes the pad's gentler limiter, because nobody's head
    /// is leading it any more.
    private func releaseHead() {
        guard status == .following else { return }
        driver?.useLimiter(TargetSlewLimiter())
        driver?.aim(.zero)
    }

    // MARK: - Core Motion

    private func startUpdates() {
        guard let manager else { return }
        // The main queue, so the handler runs on the main actor in all but name.
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            nonisolated(unsafe) let motion = motion
            let failed = error != nil
            MainActor.assumeIsolated {
                self?.handle(motion, failed: failed)
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.checkForSilence(at: .now)
            }
        }
    }

    private func handle(_ motion: CMDeviceMotion?, failed: Bool) {
        if failed {
            switch CMHeadphoneMotionManager.authorizationStatus() {
            case .denied, .restricted:
                switchOff(to: .denied)
            default:
                break
            }
            return
        }
        guard let motion else { return }
        let attitude = motion.attitude
        #if os(iOS)
            let source = Self.source(of: motion.sensorLocation)
            if source != self.source {
                self.source = source
                needsReference = true
            }
        #endif
        if needsReference || reference == nil {
            reference = attitude.copy() as? CMAttitude
            needsReference = false
            receive(.level, at: .now)
            return
        }
        guard let reference, let relative = attitude.copy() as? CMAttitude else { return }
        relative.multiply(byInverseOf: reference)
        receive(HeadAttitude(yaw: relative.yaw, pitch: relative.pitch, roll: relative.roll), at: .now)
    }

    #if os(iOS)
        /// `sensorLocation` is iOS only in the SDK, so the Mac reads no source at all.
        private static func source(of location: CMDeviceMotion.SensorLocation) -> Source {
            switch location {
            case .headphoneLeft: .left
            case .headphoneRight: .right
            default: .unknown
            }
        }
    #endif
}
