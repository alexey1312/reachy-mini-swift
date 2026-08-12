import Foundation
import ReachyKit

/// Owns the live teleop target for a screen: the joystick's head pose, the sliders,
/// and the body yaw it integrates while the knob sits in a rotation zone.
///
/// The integration lives here rather than in the channel because
/// `ControllerScreen`'s body-yaw slider is bound to this same target — an angle
/// drifting inside the actor would leave the slider disagreeing with the robot.
@MainActor
@Observable
final class TeleopDriver {
    /// The world-frame goal, exactly as it goes on the wire. Every write reaches the
    /// robot as a goal, so a slider jump is as smooth as a joystick release.
    ///
    /// **`yaw` is not the joystick's angle.** The daemon measures `target_head_pose`
    /// from the base rather than from the torso — the Stewart platform is handed
    /// `head_yaw − body_yaw` — so a head meant to keep looking where the body points
    /// has to carry the body's yaw, and one that does not holds its absolute direction
    /// and visually counter-rotates: the camera stops panning at the exact moment the
    /// robot starts turning, which is what this used to do. `yaw` and `bodyYaw` are
    /// therefore one quantity in two fields, and this type is their only writer —
    /// `private(set)` is what makes that true rather than merely intended, since
    /// `@Bindable` would otherwise hand `$driver.target.bodyYaw` to any new slider.
    ///
    /// The composition is exact rather than approximate: `rpy` composes as
    /// `Rz(yaw)·Ry(pitch)·Rx(roll)`, so `Rz(body + head)·Ry·Rx` is the body-frame
    /// orientation pre-multiplied by `Rz(body)`. It stays exact only while `x` and `y`
    /// are zero — they are world-frame too, and driving them would need `Rz(bodyYaw)`
    /// applied to the pair. `z` is on the yaw axis and so is invariant.
    private(set) var target: TeleopTarget {
        didSet { push() }
    }

    let mapping: JoystickMapping
    private(set) var bodyYawRate: Double = 0

    /// The head's yaw in the body's frame — what the joystick asked for.
    /// `target.yaw` is this plus `target.bodyYaw`, always.
    private var relativeHeadYaw: Double

    /// Whether the robot has been left facing somewhere other than forward.
    ///
    /// Body yaw is the only axis a joystick gesture leaves behind: releasing the
    /// knob sends `apply(.zero)`, which puts pitch back at neutral and brings the
    /// head back into line with the body, while a turn integrated in a rotation
    /// zone persists until something clears it. So this is what "not in its default
    /// position" means on a screen that offers nothing but the pad.
    ///
    /// A threshold rather than `!= 0`, because `ControllerScreen` binds a slider to
    /// this same property and a gesture can leave float dust behind. `reset()`
    /// assigns a fresh target, so the reset path is exact either way.
    var isBodyTurned: Bool {
        abs(target.bodyYaw) > Self.turnedThreshold
    }

    /// The URDF's `yaw_body` limit, which is what the daemon clamps `body_yaw` to.
    ///
    /// Mirrored here **not** as a safety limit — those stay in the daemon (project
    /// rule 2) — but because the head's world yaw is computed from this number: a body
    /// yaw the daemon silently truncates would leave the head cocked by exactly the
    /// truncation, which is the bug this file exists to fix. It was ±180°, and on a
    /// real robot that was clipped to about ±105° anyway: the daemon also clamps body
    /// yaw so `|head_yaw − body_yaw| ≤ 65°`, and this app used to send a head held at
    /// −40° forever. Composing the head makes that difference `|relativeHeadYaw|`,
    /// which never exceeds `mapping.headAngle`, so the relative clamp stays inert and
    /// the whole ±160° is reachable.
    static let bodyYawLimit = 160.0 * .pi / 180

    private static let turnedThreshold = 0.5 * .pi / 180
    private static let tick = Duration.milliseconds(20)
    private var client: (any TeleopChannel)?
    private var rotationTask: Task<Void, Never>?

    init(
        target: TeleopTarget = TeleopTarget(),
        mapping: JoystickMapping = JoystickMapping()
    ) {
        self.target = target
        // A world-frame pose like any other, so what the head is doing relative to the
        // body is the difference. Seeding zero would make the first slider nudge snap
        // the head by the body's whole angle.
        relativeHeadYaw = target.yaw - target.bodyYaw
        self.mapping = mapping
    }

    /// Takes a factory rather than an address: over the relay there is no address
    /// to dial, and the channel that carries the targets is the peer connection the
    /// session is already on. Smoothing, the rotation ticker and the slider bindings
    /// are the same either way — they are about the gesture, not the transport.
    func start(_ makeChannel: () throws -> any TeleopChannel) throws {
        guard client == nil else { return }
        let client = try makeChannel()
        self.client = client
        Task { await client.connect() }
    }

    func stop() {
        stopRotation()
        let client = client
        self.client = nil
        Task { await client?.disconnect() }
    }

    /// Head follows the deflection; past the rotation zone the body starts turning.
    ///
    /// Written as one assignment on purpose: `didSet` fires per write, and a gesture
    /// arrives at screen rate, so two writes would double the pushes for nothing.
    func apply(_ deflection: JoystickDeflection) {
        relativeHeadYaw = mapping.headYaw(deflection)
        var next = target
        next.pitch = mapping.headPitch(deflection)
        next.yaw = Self.worldYaw(body: next.bodyYaw, head: relativeHeadYaw)
        target = next
        setRotation(rate: mapping.bodyYawRate(deflection))
    }

    func reset() {
        stopRotation()
        relativeHeadYaw = 0
        target = .init()
    }

    /// One integration step. Called by the ticker, and by tests without one.
    func integrateRotation(seconds: Double) {
        guard bodyYawRate != 0 else { return }
        setBodyYaw(target.bodyYaw + bodyYawRate * seconds)
    }

    /// What `ControllerScreen`'s slider binds to, rather than a binding into `target`:
    /// a slider that moved the body without the head would be the same bug in a second
    /// place, and the ticker and the slider have to clamp alike.
    var bodyYaw: Double {
        get { target.bodyYaw }
        set { setBodyYaw(newValue) }
    }

    /// The other axes a screen may drive. `yaw` and `pitch` are absent on purpose: the
    /// pad owns them, and `yaw` is composed rather than set.
    var roll: Double {
        get { target.roll }
        set { target.roll = newValue }
    }

    var z: Double {
        get { target.z }
        set { target.z = newValue }
    }

    var antennaLeft: Double {
        get { target.antennaLeft }
        set { target.antennaLeft = newValue }
    }

    var antennaRight: Double {
        get { target.antennaRight }
        set { target.antennaRight = newValue }
    }

    /// The one place body yaw is written. One assignment for the same reason `apply`
    /// is one, and the equality guard is not an optimisation: held against the limit,
    /// the ticker would otherwise push an unchanged target fifty times a second.
    private func setBodyYaw(_ angle: Double) {
        var next = target
        next.bodyYaw = angle.clamped(to: -Self.bodyYawLimit ... Self.bodyYawLimit)
        next.yaw = Self.worldYaw(body: next.bodyYaw, head: relativeHeadYaw)
        guard next != target else { return }
        target = next
    }

    /// Clamped rather than wrapped: `TargetSlewLimiter` is linear in the scalar, so a
    /// wrap would walk the head the long way round at `headAngularRate`. The sum does
    /// overrun — turn the body to its limit, then ease the thumb back to the boundary,
    /// where the head asks for its full lead again — and losing a few degrees of lead
    /// at the extreme is the cheap end of that.
    private static func worldYaw(body: Double, head: Double) -> Double {
        (body + head).clamped(to: -.pi ... .pi)
    }

    private func setRotation(rate: Double) {
        bodyYawRate = rate
        guard rate != 0 else {
            stopRotation()
            return
        }
        guard rotationTask == nil else { return }
        rotationTask = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                let now = ContinuousClock.now
                let elapsed = last.duration(to: now)
                last = now
                guard let self else { return }
                integrateRotation(seconds: elapsed.inSeconds)
            }
        }
    }

    private func stopRotation() {
        bodyYawRate = 0
        rotationTask?.cancel()
        rotationTask = nil
    }

    private func push() {
        guard let client else { return }
        let target = target
        Task { await client.send(target) }
    }
}

private extension Duration {
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}
