@testable import ReachyUI
import Testing

/// A controller reading means something only through `TeleopDriver`, so most of these
/// assert on the step the driver would be handed — and the ones that matter most are
/// about what is *not* in it: a stick at rest that wrote `.zero` every tick would snap
/// the touch pad back under a finger.
@Suite("Gamepad mapping")
struct GamepadMappingTests {
    private let mapping = GamepadMapping()

    private func reading(_ edit: (inout GamepadReading) -> Void) -> GamepadReading {
        var reading = GamepadReading.neutral
        edit(&reading)
        return reading
    }

    @Test("a controller at rest asks for nothing")
    func restIsSilent() {
        #expect(mapping.step(from: .neutral, to: .neutral, seconds: 0.016) == nil)
    }

    /// Every stick drifts. A look stick reporting a few hundredths at rest would hold
    /// the head a few degrees off and write a target about it every tick.
    @Test("drift inside the deadzone reads as centred")
    func driftIsFiltered() {
        let drifting = reading {
            $0.rightStick = .init(x: 0.05, y: -0.04)
            $0.leftStick = .init(x: -0.06, y: 0.03)
        }
        #expect(mapping.step(from: .neutral, to: drifting, seconds: 0.016) == nil)
    }

    @Test("the rim still reads as full deflection past the deadzone")
    func deadzoneRescales() {
        let look = mapping.look(reading { $0.rightStick = .init(x: 1, y: 0) })
        #expect(look == JoystickDeflection(x: 1, y: 0))
    }

    /// The pad's `y` is a drag's, down; a stick's is up. Pushing up has to look up,
    /// as dragging up does — which is a negative pitch on the robot.
    @Test("pushing the look stick up looks up, as dragging the pad up does")
    func lookIsNotInverted() throws {
        let up = reading { $0.rightStick = .init(x: 0, y: 1) }
        let step = try #require(mapping.step(from: .neutral, to: up, seconds: 0))
        let look = try #require(step.look)
        #expect(look.y < 0)
        #expect(mapping.joystick.headPitch(look) < 0)
    }

    /// A held stick is a change once; after that it is the pad's own rotation ticker
    /// that keeps the body turning, and re-sending the same deflection would only
    /// restart it.
    @Test("a look held still is sent once")
    func lookIsSentOnChange() {
        let held = reading { $0.rightStick = .init(x: 0.4, y: 0.2) }
        #expect(mapping.step(from: .neutral, to: held, seconds: 0.016)?.look != nil)
        #expect(mapping.step(from: held, to: held, seconds: 0.016) == nil)
    }

    @Test("letting go of the look stick recentres the head, once")
    func releaseRecentres() {
        let held = reading { $0.rightStick = .init(x: 0.4, y: 0.2) }
        #expect(mapping.step(from: held, to: .neutral, seconds: 0.016)?.look == .zero)
    }

    /// Same sign as the pad's rotation zone for the same push, so the two ways of
    /// turning the body can never turn it opposite ways.
    @Test("the left stick turns the body the way the pad's zone does")
    func turnMatchesThePad() throws {
        let right = reading { $0.leftStick = .init(x: 1, y: 0) }
        let step = try #require(mapping.step(from: .neutral, to: right, seconds: 0.5))
        let padRate = mapping.joystick.bodyYawRate(JoystickDeflection(x: 1))
        #expect(step.bodyYaw < 0)
        #expect(padRate < 0)
        #expect(abs(step.bodyYaw - padRate * 0.5) < 1e-12)
    }

    /// What is held is an amount per tick, so a held turn keeps turning even though
    /// the reading never changes.
    @Test("a held turn keeps turning")
    func heldTurnIntegrates() {
        let held = reading { $0.dpad = .init(x: -1, y: 0) }
        let step = mapping.step(from: held, to: held, seconds: 0.1)
        #expect((step?.bodyYaw ?? 0) > 0)
    }

    @Test("the d-pad and the left stick do not add up past full speed")
    func strongerWins() throws {
        let both = reading {
            $0.dpad = .init(x: 1, y: 0)
            $0.leftStick = .init(x: 1, y: 0)
        }
        let step = try #require(mapping.step(from: .neutral, to: both, seconds: 1))
        #expect(abs(step.bodyYaw) == mapping.joystick.maxBodyYawRate)
    }

    @Test("up on the left stick raises the head")
    func liftRaises() throws {
        let step = try #require(mapping.step(from: .neutral, to: reading { $0.dpad = .init(x: 0, y: 1) }, seconds: 0.5))
        #expect(step.height == mapping.heightRate * 0.5)
    }

    @Test("the shoulder buttons roll the head in opposite directions")
    func shouldersRoll() throws {
        let right = try #require(mapping.step(from: .neutral, to: reading { $0.rightShoulder = true }, seconds: 0.1))
        let left = try #require(mapping.step(from: .neutral, to: reading { $0.leftShoulder = true }, seconds: 0.1))
        #expect(right.roll > 0)
        #expect(left.roll == -right.roll)
        let both = reading {
            $0.leftShoulder = true
            $0.rightShoulder = true
        }
        #expect(mapping.step(from: both, to: both, seconds: 0.1) == nil)
    }

    /// Mirrored: the daemon's own poses put opposite signs on the two sides, so a pair
    /// of triggers pulled alike moves the antennas as a pair.
    @Test("pulling both triggers alike moves the antennas as a mirrored pair")
    func triggersMirror() throws {
        let pulled = reading {
            $0.leftTrigger = 0.5
            $0.rightTrigger = 0.5
        }
        let step = try #require(mapping.step(from: .neutral, to: pulled, seconds: 0))
        let left = try #require(step.antennaLeft)
        #expect(left == 0.5 * mapping.antennaReach)
        #expect(step.antennaRight == -left)
    }

    /// Triggers at rest must not zero antennas a slider set; a trigger let go must
    /// bring its antenna back, which is the change from pulled to rest.
    @Test("triggers write the antennas only when they move")
    func triggersOnlyOnChange() {
        let pulled = reading { $0.leftTrigger = 0.8 }
        #expect(mapping.step(from: pulled, to: pulled, seconds: 0.016) == nil)
        #expect(mapping.step(from: pulled, to: .neutral, seconds: 0.016) == TeleopStep(antennaLeft: 0))
    }

    /// Each trigger owns one antenna. Writing both on any change would snap the
    /// other antenna, set by its slider, to wherever its own trigger rests.
    @Test("one trigger moves only its own antenna")
    func triggerMovesOneSide() {
        let step = mapping.step(from: .neutral, to: reading { $0.leftTrigger = 0.8 }, seconds: 0.016)
        #expect(step == TeleopStep(antennaLeft: 0.8 * mapping.antennaReach))
    }

    @Test("reset fires on the press, not for as long as it is held")
    func resetIsAnEdge() {
        let pressed = reading { $0.reset = true }
        #expect(mapping.step(from: .neutral, to: pressed, seconds: 0.016) == TeleopStep(reset: true))
        #expect(mapping.step(from: pressed, to: pressed, seconds: 0.016) == nil)
    }
}
