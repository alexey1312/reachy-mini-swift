import CoreMotion
import Foundation
import Observation
import ReachyKit
import ReachyTeleop
import SwiftUI

/// Headphones that track the listener's head, steering the robot's (the AirPods spike).
///
/// **Everything goes into `TeleopDriver`, never past it** — the game controller's rule,
/// for the controller's reason: the slew limiter and the daemon's own limits apply
/// unchanged (project rule 2). `TeleopDriver.aim(_:)` is the one door.
///
/// **One pair of headphones, one owner, and that is why this is shared** — the game
/// controller's shape (`GamepadTeleop`). The first device run switched it off on the way
/// to the camera, which is where a head is worth following: the Controller screen owned
/// it then. Now each surface with a driver claims it (`headphoneTeleop(_:priority:isActive:)`)
/// while the robot can be driven — awake, with no power transition under way and the
/// scene in front — and the highest priority drives, the most recent among equals. A
/// stream of targets right after the motors come on can take the daemon down
/// (pollen-robotics/reachy_mini#1430), and readings taken in the background would drive
/// a robot nobody watches. Switching on and off belongs to the hub, so it survives a
/// change of screen.
///
/// **The head starts from where the reader is looking.** Core Motion reports a
/// headphone's attitude in a frame of its own, so the first reading after a switch-on
/// or `recentre()` becomes the reference and everything after it is relative to that.
/// A hand-over keeps it, so the next surface starts from the straight ahead the reader
/// already had. Nothing asks the reader to look anywhere first; the footer says to look
/// straight ahead, and Recentre is there for when they did not.
///
/// **Losing the headphones puts the head back.** Readings stop with no event at all
/// when an AirPod leaves an ear or the headphones disconnect, so silence for
/// `staleAfter` is the signal: the robot's head returns to neutral and the next
/// reading is a fresh reference. The same release happens on switch-off and to a
/// surface that loses the head, the way the game controller lets go of a look it was
/// holding.
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
        /// Readings arrive, and reach the robot while a surface claims the hub.
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

    /// The next reading becomes the reference. Set by a switch-on, a recentre, a loss
    /// and a change of earbud; read and cleared by the Core Motion half.
    @ObservationIgnored private(set) var needsReference = true

    typealias Priority = GamepadTeleop.Priority

    /// The driver a head moves right now: the highest priority claim, the most recent
    /// among equals. Observed, so a pad can go out while a head drives its target.
    private(set) var owner: TeleopDriver?

    @ObservationIgnored private var claims: [Claim] = []
    @ObservationIgnored private var lastReading: ContinuousClock.Instant?
    @ObservationIgnored private var manager: CMHeadphoneMotionManager?
    @ObservationIgnored private var reference: CMAttitude?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    private struct Claim {
        let id: UUID
        let driver: TeleopDriver
        let priority: Priority
    }

    /// The hub every surface claims. Built on first use, and only a host outside
    /// `reachyPreviewMode` reaches it, so no capture reads the device.
    static let shared: HeadphoneTeleop = {
        let hub = HeadphoneTeleop()
        hub.observeHeadphones()
        return hub
    }()

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

    func claim(_ driver: TeleopDriver, priority: Priority) -> UUID {
        let id = UUID()
        claims.append(Claim(id: id, driver: driver, priority: priority))
        reconcileOwner()
        return id
    }

    func release(_ id: UUID) {
        claims.removeAll { $0.id == id }
        reconcileOwner()
    }

    /// Whether a head is steering `driver` now, which is when its own pad goes out.
    func drives(_ driver: TeleopDriver) -> Bool {
        status == .following && owner === driver
    }

    /// The surface that loses the head gets it back at neutral before the next one
    /// takes it. The reference stays, so the new owner starts from the same straight
    /// ahead; its first reading takes the fast limiter (`receive`).
    private func reconcileOwner() {
        let top = claims.map(\.priority).max()
        let next = claims.last { $0.priority == top }?.driver
        guard next !== owner else { return }
        releaseHead()
        owner = next
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
        owner?.useLimiter(.headTracking)
        owner?.aim(mapping.aim(attitude))
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
        owner?.useLimiter(TargetSlewLimiter())
        owner?.aim(.zero)
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

extension View {
    /// Lets headphones that track a head drive `driver` while `isActive`: awake, with no
    /// power transition under way. Released when the view goes away. `hub` is `nil` for
    /// the shared one, and a capture claims nothing at all.
    func headphoneTeleop(
        _ driver: TeleopDriver,
        priority: HeadphoneTeleop.Priority,
        isActive: Bool,
        hub: HeadphoneTeleop? = nil
    ) -> some View {
        modifier(HeadphoneClaim(driver: driver, priority: priority, isActive: isActive, hub: hub))
    }
}

/// `GamepadClaim`'s shape, for `GamepadClaim`'s reasons.
private struct HeadphoneClaim: ViewModifier {
    let driver: TeleopDriver
    let priority: HeadphoneTeleop.Priority
    let isActive: Bool
    /// Resolved here rather than defaulted at the call, because a main-actor default
    /// fails the `Apps/` build (`ReachyUI/AGENTS.md`).
    let hub: HeadphoneTeleop?
    @Environment(\.reachyPreviewMode) private var previewMode
    @Environment(\.scenePhase) private var scenePhase

    private var holdsClaim: Bool {
        isActive && scenePhase == .active && !previewMode
    }

    func body(content: Content) -> some View {
        content.task(id: holdsClaim) {
            guard holdsClaim else { return }
            let hub = hub ?? .shared
            let id = hub.claim(driver, priority: priority)
            // The claim lives exactly as long as this task: the view leaving, `isActive`
            // turning false or the scene leaving the front cancels it.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
            hub.release(id)
        }
    }
}

private struct HeadTrackingMayDriveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether a head may drive the robot from a surface that does not see the robot's
    /// session itself, such as the pad over the camera. `ViewportView` sets it from its
    /// `robotSession`; anywhere else it is false, so nothing claims the headphones.
    var headTrackingMayDrive: Bool {
        get { self[HeadTrackingMayDriveKey.self] }
        set { self[HeadTrackingMayDriveKey.self] = newValue }
    }
}
