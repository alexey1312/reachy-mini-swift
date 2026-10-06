import ReachyKit
@testable import ReachyUI
import Testing

/// The hub with no controller behind it: `tick` takes the reading the poll would have
/// copied out, so everything about who drives and what they are sent is reachable.
/// Synchronous throughout, as `TeleopDriverTests` is, and every driver that may have
/// started its rotation ticker is stopped before the test ends.
@MainActor
@Suite("Gamepad teleop")
struct GamepadTeleopTests {
    private func reading(_ edit: (inout GamepadReading) -> Void) -> GamepadReading {
        var reading = GamepadReading.neutral
        edit(&reading)
        return reading
    }

    @Test("a held turn integrates into the body, with the head carried along")
    func turnReachesTheDriver() {
        let hub = GamepadTeleop()
        let driver = TeleopDriver()
        _ = hub.claim(driver, priority: .screen, standDown: nil)

        let held = reading { $0.leftStick = .init(x: -1, y: 0) }
        for _ in 0 ..< 10 {
            hub.tick(held, seconds: 0.1)
        }

        #expect(driver.target.bodyYaw > 0)
        // The invariant `TeleopDriver` exists to hold: the head's world yaw is the
        // body's plus its own, and the controller has no way around it.
        #expect(driver.target.yaw == driver.target.bodyYaw)
    }

    /// Two drivers listening would be two targets on one robot. The Controller screen
    /// outranks a pad drawn over the picture, whichever claimed first.
    @Test("one controller drives one driver, and the Controller screen outranks a pad")
    func oneOwner() {
        let hub = GamepadTeleop()
        let screen = TeleopDriver()
        let overlay = TeleopDriver()
        _ = hub.claim(screen, priority: .screen, standDown: nil)
        _ = hub.claim(overlay, priority: .overlay, standDown: nil)

        hub.tick(reading { $0.dpad = .init(x: 0, y: 1) }, seconds: 0.5)

        #expect(hub.owner === screen)
        #expect(screen.target.z > 0)
        #expect(overlay.target.z == 0)
    }

    @Test("releasing the owner hands the controller back")
    func releaseHandsBack() {
        let hub = GamepadTeleop()
        let overlay = TeleopDriver()
        let screen = TeleopDriver()
        _ = hub.claim(overlay, priority: .overlay, standDown: nil)
        let claim = hub.claim(screen, priority: .screen, standDown: nil)

        hub.release(claim)
        hub.tick(reading { $0.dpad = .init(x: 0, y: 1) }, seconds: 0.5)

        #expect(hub.owner === overlay)
        #expect(overlay.target.z > 0)
    }

    /// The old owner's look is let go on the way out, or a stick held into a rotation
    /// zone would leave it turning the body under nobody's thumb.
    @Test("a hand-over releases the old owner's look and gives the new one what is held")
    func handOver() {
        let hub = GamepadTeleop()
        let first = TeleopDriver()
        _ = hub.claim(first, priority: .overlay, standDown: nil)
        let held = reading { $0.rightStick = .init(x: 1, y: 0) }
        hub.tick(held, seconds: 0.016)
        #expect(first.bodyYawRate != 0)

        let second = TeleopDriver()
        _ = hub.claim(second, priority: .overlay, standDown: nil)
        hub.tick(held, seconds: 0.016)

        #expect(first.bodyYawRate == 0)
        #expect(second.bodyYawRate != 0)
        first.stop()
        second.stop()
    }

    /// The robot's own head behaviours let go before a controller drives it, as they
    /// do for the pad — and a controller doing nothing must not keep asking.
    @Test("the owner's stand-down runs when the controller moves, and not at rest")
    func standsDownOnInput() {
        let hub = GamepadTeleop()
        var calls = 0
        _ = hub.claim(TeleopDriver(), priority: .screen, standDown: { calls += 1 })

        hub.tick(.neutral, seconds: 0.016)
        #expect(calls == 0)
        hub.tick(reading { $0.rightShoulder = true }, seconds: 0.016)
        #expect(calls == 1)
    }

    /// A surface going away, the robot falling asleep, the app leaving the foreground:
    /// each releases the claim mid-gesture, and a look held into the rotation zone
    /// would otherwise leave the driver's own ticker turning the body for good.
    @Test("losing the controller mid-turn stops the turn")
    func releaseStopsAHeldTurn() {
        let hub = GamepadTeleop()
        let driver = TeleopDriver()
        let claim = hub.claim(driver, priority: .screen, standDown: nil)
        hub.tick(reading { $0.rightStick = .init(x: 1, y: 0) }, seconds: 0.016)
        #expect(driver.bodyYawRate != 0)

        hub.release(claim)

        #expect(driver.bodyYawRate == 0)
        driver.stop()
    }

    /// A Mac window left visible behind another app keeps the scene `.active`, and the
    /// system stops sending the controller's input to it: the reading the poll copied
    /// last stays held. The poll can also take one more turn with that reading.
    @Test("the app losing the front stops a held turn until it is back in front")
    func losingTheFrontStopsAHeldTurn() {
        let hub = GamepadTeleop()
        let driver = TeleopDriver()
        _ = hub.claim(driver, priority: .screen, standDown: nil)
        let held = reading { $0.rightStick = .init(x: 1, y: 0) }
        hub.tick(held, seconds: 0.016)
        #expect(driver.bodyYawRate != 0)

        hub.setAppActive(false)
        #expect(driver.bodyYawRate == 0)
        hub.tick(held, seconds: 0.016)
        #expect(driver.bodyYawRate == 0)

        hub.setAppActive(true)
        hub.tick(held, seconds: 0.016)
        #expect(driver.bodyYawRate != 0)
        driver.stop()
    }

    /// The pad and the controller share a driver; letting go of the controller must
    /// not recentre a head a finger is holding.
    @Test("letting go leaves a look the controller was not holding")
    func releaseLeavesAFingersLook() {
        let hub = GamepadTeleop()
        let driver = TeleopDriver()
        let claim = hub.claim(driver, priority: .screen, standDown: nil)
        hub.tick(reading { $0.rightShoulder = true }, seconds: 0.016)
        driver.apply(JoystickDeflection(x: 0.2, y: -0.3))
        let held = driver.target

        hub.release(claim)

        #expect(driver.target == held)
    }

    @Test("with nobody claiming it the controller drives nothing")
    func unclaimedIsInert() {
        let hub = GamepadTeleop()
        let driver = TeleopDriver()
        let claim = hub.claim(driver, priority: .screen, standDown: nil)
        hub.release(claim)

        hub.tick(reading { $0.dpad = .init(x: 0, y: 1) }, seconds: 0.5)

        #expect(hub.owner == nil)
        #expect(driver.target.z == 0)
    }

    // MARK: - What `steer` keeps inside

    /// A held button integrates, so an unbounded one would wind up: ten seconds of
    /// "up" would need ten seconds of "down" to come back from a height the daemon
    /// never went to. The bounds are the sliders' own.
    @Test("held buttons stay inside the sliders' ranges")
    func heldAxesStayInRange() {
        let driver = TeleopDriver()
        for _ in 0 ..< 100 {
            driver.steer(TeleopStep(roll: 0.1, height: 0.01))
        }
        #expect(driver.target.z == TeleopDriver.heightLimit)
        #expect(driver.target.roll == driver.mapping.headAngle)
    }

    /// The clamp is for what the controller adds, not a second opinion on what some
    /// other writer set.
    @Test("an axis the controller did not move is not clamped")
    func untouchedAxesStay() {
        let driver = TeleopDriver(target: TeleopTarget(z: 0.05))
        driver.steer(TeleopStep(roll: 0.1))
        #expect(driver.target.z == 0.05)
    }

    @Test("reset from the controller is the same reset the button does")
    func resetIsTheButton() {
        let driver = TeleopDriver(target: TeleopTarget(z: 0.02, roll: 0.3, yaw: 0.5, bodyYaw: 0.5))
        driver.steer(TeleopStep(reset: true))
        #expect(driver.target == TeleopTarget())
    }
}
