import ReachyKit
@testable import ReachyUI
import Testing

/// The rotation ticker is a real `Task`, but every test body below is synchronous:
/// with no suspension point the main actor never yields, so the ticker cannot
/// interleave with an assertion. `stop()` at the end keeps it from outliving the test.
@MainActor
@Suite("Teleop driver")
struct TeleopDriverTests {
    @Test("inside the head zone the joystick moves the head and nothing else")
    func headOnly() {
        let driver = TeleopDriver()
        // Half of the head zone, taken from the mapping rather than spelled out: a
        // literal that happened to equal the boundary would test nothing.
        driver.apply(.init(x: driver.mapping.rotationThreshold / 2, y: -0.25))
        #expect(driver.target.yaw < 0)
        #expect(driver.target.pitch < 0)
        #expect(driver.bodyYawRate == 0)
        #expect(driver.target.bodyYaw == 0)
    }

    @Test("past the zone the head comes onto the body's axis and the body turns")
    func rotationStarts() {
        let driver = TeleopDriver()
        driver.apply(.init(x: 1.0))
        #expect(driver.bodyYawRate != 0)
        // Integrated first on purpose: with the body still at zero the world-frame yaw
        // and the joystick's own angle are the same number, so an uncomposed head
        // would pass too.
        driver.integrateRotation(seconds: 0.02)
        #expect(driver.target.bodyYaw != 0)
        #expect(driver.target.yaw == driver.target.bodyYaw)
        driver.stop()
    }

    /// The one invariant this type exists to hold. The daemon measures the head from
    /// the base, so what goes on the wire is the body's angle plus the joystick's.
    @Test("the head yaw sent is the body's plus the joystick's")
    func headYawIsComposed() {
        let driver = TeleopDriver()
        let deflection = JoystickDeflection(x: 0.8, y: -0.3)
        driver.apply(deflection)
        for _ in 0 ..< 10 {
            driver.integrateRotation(seconds: 0.02)
        }
        #expect(driver.target.bodyYaw != 0)
        #expect(abs(driver.target.yaw - driver.target.bodyYaw - driver.mapping.headYaw(deflection)) < 1e-12)
        driver.stop()
    }

    /// The request itself, as an equality of increments: whatever the body turns by,
    /// the head turns by too. This is the assertion that was false before the head was
    /// composed with the body — the difference used to be the body's whole step.
    @Test("turning the body carries the head with it")
    func turningCarriesTheHead() {
        let driver = TeleopDriver()
        driver.apply(.init(x: 0.75))
        let yaw = driver.target.yaw
        let bodyYaw = driver.target.bodyYaw
        driver.integrateRotation(seconds: 0.02)
        #expect(driver.target.bodyYaw != bodyYaw)
        #expect(abs((driver.target.yaw - yaw) - (driver.target.bodyYaw - bodyYaw)) < 1e-12)
        driver.stop()
    }

    /// `ControllerScreen` binds its slider to `bodyYaw` rather than into the target,
    /// so that a body moved by hand carries the head exactly as the ticker's does.
    @Test("the body-yaw slider carries the head too")
    func sliderCarriesTheHead() {
        let driver = TeleopDriver()
        let deflection = JoystickDeflection(x: driver.mapping.rotationThreshold / 2)
        driver.apply(deflection)
        driver.bodyYaw = 1.0
        #expect(driver.target.bodyYaw == 1.0)
        #expect(abs(driver.target.yaw - (1.0 + driver.mapping.headYaw(deflection))) < 1e-12)
    }

    /// A driver handed a world-frame pose keeps it: the head's own angle is the
    /// difference between the two fields, so the first write does not snap the head by
    /// the body's whole angle.
    @Test("a seeded pose keeps the head where it was put")
    func seedsTheRelativeAngle() {
        let driver = TeleopDriver(target: .init(yaw: 0.3, bodyYaw: 1.2))
        driver.bodyYaw = 1.4
        #expect(abs(driver.target.yaw - 0.5) < 1e-12)
    }

    /// What keeps the daemon's own `max_relative_yaw` (65°) inert — and with it the
    /// whole of `bodyYawLimit` reachable. Sending a head pinned 40° off a body the
    /// daemon then truncates to stay within 65° is the bug composition removed; a
    /// `headAngle` raised past 65° would silently bring it back.
    @Test("the head never asks for more than the daemon allows relative to the body")
    func staysInsideTheRelativeLimit() {
        for step in -10 ... 10 {
            let driver = TeleopDriver()
            driver.apply(.init(x: Double(step) / 10))
            for _ in 0 ..< 200 {
                driver.integrateRotation(seconds: 0.02)
            }
            #expect(abs(driver.target.yaw - driver.target.bodyYaw) <= driver.mapping.headAngle + 1e-12)
            driver.stop()
        }
    }

    /// The same number `URDFParserTests` reads out of `yaw_body`, which is what the
    /// daemon clamps to. Mirrored rather than trusted because the head's world yaw is
    /// computed from it: a body yaw truncated on the robot leaves the head cocked by
    /// exactly the truncation.
    @Test("the body stops at the URDF's own limit")
    func integrationClamps() {
        let driver = TeleopDriver()
        #expect(abs(TeleopDriver.bodyYawLimit - 2.79253) < 1e-5)

        driver.apply(.init(x: -1.0))
        for _ in 0 ..< 400 {
            driver.integrateRotation(seconds: 0.02)
        }
        #expect(abs(driver.target.bodyYaw - TeleopDriver.bodyYawLimit) < 1e-9)
        #expect(driver.target.yaw == driver.target.bodyYaw)
        driver.stop()
    }

    /// The whole point of turning: letting go must not undo it. And the head comes back
    /// into line with the **body**, not with the room — a released head at world zero
    /// would be a robot facing sideways and looking back over its shoulder.
    @Test("releasing lines the head up with the body and leaves the turn standing")
    func releaseKeepsBodyYaw() {
        let driver = TeleopDriver()
        driver.apply(.init(x: -1.0))
        for _ in 0 ..< 25 {
            driver.integrateRotation(seconds: 0.02)
        }
        let turned = driver.target.bodyYaw
        #expect(turned > 0)

        driver.apply(.zero)
        #expect(driver.target.yaw == turned)
        #expect(driver.bodyYawRate == 0)
        #expect(driver.target.bodyYaw == turned)

        driver.integrateRotation(seconds: 0.02)
        #expect(driver.target.bodyYaw == turned)
    }

    /// What the camera's return-to-neutral button keys off, and why it keys off the
    /// body alone: the pad puts the head back itself on release, so a button
    /// answering to head deflection would appear under the finger and leave with it.
    @Test("only an accumulated body turn reads as displaced")
    func bodyTurnedTracksTheBodyAlone() {
        let driver = TeleopDriver()
        #expect(driver.isBodyTurned == false)

        driver.apply(.init(x: driver.mapping.rotationThreshold / 2, y: -0.25))
        #expect(driver.target.yaw != 0)
        #expect(driver.isBodyTurned == false)

        // One 20 ms tick at full deflection is 1.2°, well past the 0.5° threshold:
        // the button is there as soon as the turn starts, not once it is large.
        driver.apply(.init(x: -1.0))
        driver.integrateRotation(seconds: 0.02)
        #expect(driver.isBodyTurned)

        driver.apply(.zero)
        #expect(driver.isBodyTurned)

        driver.reset()
        #expect(driver.isBodyTurned == false)
        driver.stop()
    }

    /// `ControllerScreen` binds a slider to this same property, and a gesture can
    /// leave float dust behind — which must not put a button on the camera.
    @Test("a turn too small to see is not a turn")
    func bodyTurnedIgnoresDust() {
        #expect(TeleopDriver(target: .init(bodyYaw: 1e-12)).isBodyTurned == false)
        #expect(TeleopDriver(target: .init(bodyYaw: -1.0 * .pi / 180)).isBodyTurned)
    }

    @Test("reset returns the body too")
    func reset() {
        let driver = TeleopDriver(target: .init(roll: 0.3, bodyYaw: 1.2))
        driver.reset()
        #expect(driver.target == SetTargetClient.Target())
        #expect(driver.bodyYawRate == 0)
    }
}
