import Foundation

/// One reading of a game controller, in the controller's own terms: sticks with `y`
/// up, triggers from 0 to 1, the d-pad as two axes of −1, 0 or 1.
///
/// A plain value rather than a `GCExtendedGamepad`, so that everything a controller
/// *means* is decided where a test can reach it. The one type left holding the
/// framework, `GamepadTeleop`, only copies numbers out of it.
struct GamepadReading: Equatable, Sendable {
    struct Stick: Equatable, Sendable {
        var x = 0.0
        var y = 0.0
    }

    var leftStick = Stick()
    var rightStick = Stick()
    var dpad = Stick()
    var leftShoulder = false
    var rightShoulder = false
    var leftTrigger = 0.0
    var rightTrigger = 0.0
    /// The right face button — B on an Xbox controller, ○ on a PlayStation one, A on
    /// a Switch one. Named by position because the letter is not the same anywhere.
    var reset = false

    static let neutral = GamepadReading()
}

/// What one tick of a controller asks of `TeleopDriver`, which writes it as one target.
struct TeleopStep: Equatable, Sendable {
    /// A new deflection for the pad's own mapping, or `nil` to leave the head alone.
    var look: JoystickDeflection?
    /// Radians to turn the body by, signed like `JoystickMapping.bodyYawRate`.
    var bodyYaw = 0.0
    /// Radians to roll the head by.
    var roll = 0.0
    /// Metres to raise the head by.
    var height = 0.0
    /// Absolute angles, each `nil` to leave that antenna where it is. One per side,
    /// because each trigger moves its own antenna: a pair would write the other side
    /// too, and snap an antenna its slider had set to wherever the other trigger rests.
    var antennaLeft: Double?
    var antennaRight: Double?
    var reset = false
}

/// Turns controller readings into teleop steps (#160).
///
/// | Control | Does |
/// | --- | --- |
/// | Right stick | what the touch pad does — look around, and turn the body when held at its side |
/// | Left stick ←→, d-pad ←→ | turn the body |
/// | Left stick ↑↓, d-pad ↑↓ | raise or lower the head |
/// | Shoulder buttons | roll the head |
/// | Triggers | the antennas, as far as each is pulled |
/// | Right face button | reset to neutral |
///
/// **The look stick is the pad, not a second mapping of it.** It produces a
/// `JoystickDeflection` and `TeleopDriver` runs it through the same `JoystickMapping`,
/// rotation zone included, so a stick pushed to its side turns the body exactly as a
/// thumb at the pad's rim does and the two can never disagree about where that begins.
/// It is the right stick because that is where a controller's camera lives — Pollen's
/// desktop app puts its look on the right stick too. Its left stick drives the head's
/// `x` and `y` there, which this client does not: those are world-frame and would need
/// the body's yaw composed in (`TeleopDriver.target`).
///
/// **Only a change is reported, and that is what lets a controller sit beside the
/// screen.** A stick resting at centre would otherwise send `.zero` every tick and
/// snap the touch pad back under a finger, and triggers at rest would zero antennas a
/// slider had set. What is *held* — the turn, the lift, the roll — is reported every
/// tick, as an amount for the time that tick covered.
struct GamepadMapping: Equatable, Sendable {
    var joystick = JoystickMapping()
    /// Below this a stick reads as centred, and the travel above it is rescaled so the
    /// rim still reads as 1. Every stick drifts, and a drifting look stick would hold
    /// the head a few degrees off and keep writing targets about it.
    var stickDeadzone = 0.12
    /// Triggers rest a little off zero on some controllers, so the same idea applies.
    var triggerDeadzone = 0.05
    /// Metres per second at full travel: the height slider's half range in a second.
    var heightRate = TeleopDriver.heightLimit
    /// Radians per second while a shoulder button is held: the roll slider's half
    /// range in a second.
    var rollRate = JoystickMapping().headAngle
    /// How far a fully pulled trigger moves its antenna: the antenna slider's end.
    var antennaReach = TeleopDriver.antennaLimit

    /// The look stick as the pad would report it. A stick's `y` is up and a drag's is
    /// down, so it is flipped: pushing up looks up, as dragging up does.
    func look(_ reading: GamepadReading) -> JoystickDeflection {
        let stick = filtered(reading.rightStick)
        return JoystickDeflection(x: stick.x.clamped(to: -1 ... 1), y: (-stick.y).clamped(to: -1 ... 1))
    }

    /// What changed between two readings, plus what was held across the `seconds`
    /// between them. `nil` when there is nothing to send.
    func step(from previous: GamepadReading, to reading: GamepadReading, seconds: Double) -> TeleopStep? {
        if reading.reset, !previous.reset {
            return TeleopStep(reset: true)
        }
        var step = TeleopStep()

        let look = look(reading)
        if look != self.look(previous) {
            step.look = look
        }

        let move = filtered(reading.leftStick)
        // Pushing right turns the robot to its right, which is a negative yaw — the
        // same sign the pad's rotation zone gives the same push.
        step.bodyYaw = -Self.stronger(move.x, reading.dpad.x) * joystick.maxBodyYawRate * seconds
        step.height = Self.stronger(move.y, reading.dpad.y) * heightRate * seconds
        // A positive roll lifts the head's left side, tilting it to the robot's right.
        let tilt = (reading.rightShoulder ? 1.0 : 0) - (reading.leftShoulder ? 1.0 : 0)
        step.roll = tilt * rollRate * seconds

        // Mirrored, so the two move as a pair: the daemon's own poses carry
        // opposite signs on the two sides — `SLEEP_ANTENNAS_JOINT_POSITIONS` is
        // `[-3.05, 3.05]`, right then left, as `target_antennas` is ordered.
        let left = trigger(reading.leftTrigger)
        if left != trigger(previous.leftTrigger) {
            step.antennaLeft = left * antennaReach
        }
        let right = trigger(reading.rightTrigger)
        if right != trigger(previous.rightTrigger) {
            step.antennaRight = -right * antennaReach
        }

        return step == TeleopStep() ? nil : step
    }

    private func filtered(_ stick: GamepadReading.Stick) -> GamepadReading.Stick {
        let magnitude = (stick.x * stick.x + stick.y * stick.y).squareRoot()
        guard magnitude > stickDeadzone else { return .init() }
        let scale = min((magnitude - stickDeadzone) / (1 - stickDeadzone), 1) / magnitude
        return .init(x: stick.x * scale, y: stick.y * scale)
    }

    private func trigger(_ value: Double) -> Double {
        value > triggerDeadzone ? value.clamped(to: 0 ... 1) : 0
    }

    /// The left stick and the d-pad drive the same two axes; whichever is pushed
    /// further wins, so neither adds to the other past full speed.
    private static func stronger(_ analog: Double, _ digital: Double) -> Double {
        (abs(digital) > abs(analog) ? digital : analog).clamped(to: -1 ... 1)
    }
}
