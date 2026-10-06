import Foundation
import GameController
import SwiftUI

/// The game controller, handed to whichever teleop surface owns it (#160).
///
/// **One controller, one owner, and that is why this is shared.** Every surface with a
/// pad keeps a `TeleopDriver` of its own, and more than one can be on screen at once —
/// an iPad under a sidebar shows the Controller screen *and* the viewport column with
/// its pad. A finger only ever lands on one of them; a controller would reach every
/// driver listening, each pushing its own target over its own channel. So surfaces
/// claim it (`gamepadTeleop(_:priority:standDown:isActive:)`), and the one that drives
/// is the highest priority, the most recent among equals. When the owner changes, the
/// one losing it gets its look released, so a stick held through the hand-over does
/// not leave the old driver turning the body under nobody's thumb.
///
/// **Everything goes into `TeleopDriver`, never past it.** The controller is one more
/// writer of the target the pad and the sliders already write, so the slew limiter and
/// the daemon's own limits apply unchanged (project rule 2).
///
/// It polls rather than listening to value changes, because what matters most is what
/// is *held*: a turn integrates for as long as the stick stays over, and a change
/// handler fires only when the stick moves. The poll runs only while somebody claims
/// the controller, one is connected and the app is in front — 60 Hz of nothing
/// otherwise.
@MainActor
@Observable
final class GamepadTeleop {
    enum Priority: Int, Comparable {
        /// A pad drawn over a picture.
        case overlay
        /// The Controller screen, which exists to drive the robot.
        case screen

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    static let shared = GamepadTeleop(observesControllers: true)

    /// The connected controller's name, or `nil` when there is none worth driving
    /// with — a micro gamepad has no second stick, so it is not counted.
    private(set) var controllerName: String?

    let mapping: GamepadMapping

    @ObservationIgnored private var claims: [Claim] = []
    @ObservationIgnored private var drivenBy: UUID?
    @ObservationIgnored private var previous = GamepadReading.neutral
    @ObservationIgnored private var pad: GCExtendedGamepad?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Whether this app is the one in front. See `setAppActive(_:)`.
    @ObservationIgnored private var isAppActive = true

    private static let tick = Duration.milliseconds(16)

    private struct Claim {
        let id: UUID
        let driver: TeleopDriver
        let priority: Priority
        let standDown: TeleopStandDown?
    }

    /// `controllerName` is the preview seam: a preview shows the legend for a
    /// controller nobody connected. Only `shared` watches for real ones.
    init(mapping: GamepadMapping = GamepadMapping(), controllerName: String? = nil, observesControllers: Bool = false) {
        self.mapping = mapping
        self.controllerName = controllerName
        if observesControllers {
            observeControllers()
            observeAppActivity()
        }
    }

    /// The driver a controller would move right now.
    var owner: TeleopDriver? {
        currentClaim?.driver
    }

    func claim(_ driver: TeleopDriver, priority: Priority, standDown: TeleopStandDown?) -> UUID {
        let id = UUID()
        claims.append(Claim(id: id, driver: driver, priority: priority, standDown: standDown))
        reconcilePolling()
        return id
    }

    func release(_ id: UUID) {
        if id == drivenBy, let claim = claims.first(where: { $0.id == id }) {
            letGo(of: claim.driver)
        }
        claims.removeAll { $0.id == id }
        reconcilePolling()
    }

    /// One tick, with the reading already copied out of the controller. The poll
    /// calls this; so do tests, which have no controller to read.
    func tick(_ reading: GamepadReading, seconds: Double) {
        // The poll can take one more turn after it is cancelled, with the reading the
        // controller froze at when the app lost the front.
        guard isAppActive, let claim = currentClaim else {
            drivenBy = nil
            previous = .neutral
            return
        }
        if claim.id != drivenBy {
            if let old = claims.first(where: { $0.id == drivenBy }) {
                letGo(of: old.driver)
            }
            drivenBy = claim.id
            // From neutral, so whatever is already held reaches the new owner now
            // rather than at its next change.
            previous = .neutral
        }
        let last = previous
        previous = reading
        guard let step = mapping.step(from: last, to: reading, seconds: seconds) else { return }
        claim.driver.steer(step)
        claim.standDown?()
    }

    /// This app gaining or losing the front.
    ///
    /// The scene phase cannot say this: a Mac window that is still visible stays
    /// `.active` while another app is in front. The system then stops sending this app
    /// the controller's input (`shouldMonitorBackgroundEvents` is false), so the last
    /// reading stays as it was and the poll would go on applying it — a held turn
    /// would go on turning the body with nobody at the controls. So the controller lets
    /// go and drives nothing until the app is in front again.
    func setAppActive(_ isActive: Bool) {
        guard isActive != isAppActive else { return }
        isAppActive = isActive
        if !isActive, let driving = claims.first(where: { $0.id == drivenBy }) {
            letGo(of: driving.driver)
        }
        reconcilePolling()
    }

    /// The controller leaving a driver, whichever way it leaves — a hand-over, the
    /// surface going away, the controller disconnecting. A look held into the rotation
    /// zone is the one thing that outlives the hand: the driver's own ticker would go
    /// on turning the body, so it is released the way lifting a thumb releases the pad.
    /// A look that was already centred is left alone, since it may be a finger's.
    private func letGo(of driver: TeleopDriver) {
        if mapping.look(previous) != .zero {
            driver.steer(TeleopStep(look: .zero))
        }
        drivenBy = nil
        previous = .neutral
    }

    private var currentClaim: Claim? {
        guard let top = claims.map(\.priority).max() else { return nil }
        return claims.last { $0.priority == top }
    }

    // MARK: - The controller

    private func observeControllers() {
        let names: [Notification.Name] = [
            .GCControllerDidConnect,
            .GCControllerDidDisconnect,
            .GCControllerDidBecomeCurrent,
        ]
        let center = NotificationCenter.default
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshController()
                }
            })
        }
        refreshController()
    }

    /// Only `shared` watches, as only it watches for controllers; a test calls
    /// `setAppActive(_:)` itself.
    private func observeAppActivity() {
        #if os(macOS)
            isAppActive = NSApplication.shared.isActive
            let changes = [
                (NSApplication.didResignActiveNotification, false),
                (NSApplication.didBecomeActiveNotification, true),
            ]
        #else
            isAppActive = UIApplication.shared.applicationState == .active
            let changes = [
                (UIApplication.willResignActiveNotification, false),
                (UIApplication.didBecomeActiveNotification, true),
            ]
        #endif
        let center = NotificationCenter.default
        for (name, isActive) in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setAppActive(isActive)
                }
            })
        }
    }

    /// The most recently used controller if it has two sticks, otherwise any that has.
    private func refreshController() {
        let controller = [GCController.current].compactMap(\.self).first { $0.extendedGamepad != nil }
            ?? GCController.controllers().first { $0.extendedGamepad != nil }
        pad = controller?.extendedGamepad
        controllerName = controller.map { $0.vendorName ?? String(localized: .reachy("Game controller")) }
        reconcilePolling()
    }

    private func reconcilePolling() {
        let shouldPoll = pad != nil && !claims.isEmpty && isAppActive
        if shouldPoll, poller == nil {
            poller = Task { [weak self] in await self?.poll() }
        } else if !shouldPoll, let poller {
            poller.cancel()
            self.poller = nil
            if let driving = claims.first(where: { $0.id == drivenBy }) {
                letGo(of: driving.driver)
            }
            drivenBy = nil
            previous = .neutral
        }
    }

    private func poll() async {
        var last = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.tick)
            let now = ContinuousClock.now
            let elapsed = last.duration(to: now).components
            last = now
            guard let pad else { continue }
            tick(GamepadReading(pad), seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18)
        }
    }
}

private extension GamepadReading {
    init(_ pad: GCExtendedGamepad) {
        self.init(
            leftStick: .init(x: Double(pad.leftThumbstick.xAxis.value), y: Double(pad.leftThumbstick.yAxis.value)),
            rightStick: .init(x: Double(pad.rightThumbstick.xAxis.value), y: Double(pad.rightThumbstick.yAxis.value)),
            dpad: .init(x: Double(pad.dpad.xAxis.value), y: Double(pad.dpad.yAxis.value)),
            leftShoulder: pad.leftShoulder.isPressed,
            rightShoulder: pad.rightShoulder.isPressed,
            leftTrigger: Double(pad.leftTrigger.value),
            rightTrigger: Double(pad.rightTrigger.value),
            reset: pad.buttonB.isPressed
        )
    }
}

extension View {
    /// Lets the game controller drive `driver` while `isActive` — the same moments a
    /// thumb could drive it through the pad. Released when the view goes away.
    func gamepadTeleop(
        _ driver: TeleopDriver,
        priority: GamepadTeleop.Priority,
        standDown: TeleopStandDown?,
        isActive: Bool,
        hub: GamepadTeleop? = nil
    ) -> some View {
        modifier(GamepadClaim(driver: driver, priority: priority, standDown: standDown, isActive: isActive, hub: hub))
    }
}

private struct GamepadClaim: ViewModifier {
    let driver: TeleopDriver
    let priority: GamepadTeleop.Priority
    let standDown: TeleopStandDown?
    let isActive: Bool
    /// `nil` is the shared one; resolved here rather than defaulted at the call,
    /// because a main-actor default fails the `Apps/` build (`ReachyUI/AGENTS.md`).
    let hub: GamepadTeleop?
    @Environment(\.reachyPreviewMode) private var previewMode
    @Environment(\.scenePhase) private var scenePhase

    /// Not while the app is in the background: the system stops delivering a
    /// controller's input there, and a stick last read as held would go on turning
    /// the body with nobody at the controls. A window left visible behind another
    /// app keeps the scene `.active`, so the hub watches for that itself
    /// (`GamepadTeleop.setAppActive(_:)`).
    private var holdsClaim: Bool {
        isActive && scenePhase == .active && !previewMode
    }

    func body(content: Content) -> some View {
        content.task(id: holdsClaim) {
            guard holdsClaim else { return }
            let hub = hub ?? .shared
            let id = hub.claim(driver, priority: priority, standDown: standDown)
            // The claim lives exactly as long as this task: a view leaving, `isActive`
            // turning false or the scene leaving the foreground cancels it.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
            hub.release(id)
        }
    }
}
