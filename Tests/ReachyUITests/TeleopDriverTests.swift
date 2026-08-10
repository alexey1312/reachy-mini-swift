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

    @Test("past the zone the head holds and the body starts turning")
    func rotationStarts() {
        let driver = TeleopDriver()
        driver.apply(.init(x: 1.0))
        #expect(abs(driver.target.yaw + driver.mapping.headAngle) < 1e-9)
        #expect(driver.bodyYawRate != 0)
        driver.stop()
    }

    @Test("integration accumulates and clamps at half a turn")
    func integrationClamps() {
        let driver = TeleopDriver()
        driver.apply(.init(x: -1.0))
        for _ in 0 ..< 400 {
            driver.integrateRotation(seconds: 0.02)
        }
        #expect(abs(driver.target.bodyYaw - .pi) < 1e-9)
        driver.stop()
    }

    /// The whole point of turning: letting go must not undo it.
    @Test("releasing returns the head and leaves the body where it turned to")
    func releaseKeepsBodyYaw() {
        let driver = TeleopDriver()
        driver.apply(.init(x: -1.0))
        for _ in 0 ..< 25 {
            driver.integrateRotation(seconds: 0.02)
        }
        let turned = driver.target.bodyYaw
        #expect(turned > 0)

        driver.apply(.zero)
        #expect(driver.target.yaw == 0)
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
