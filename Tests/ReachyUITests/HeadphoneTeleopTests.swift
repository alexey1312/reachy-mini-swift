import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The hub with no headphones behind it: `receive` takes a reading already relative to
/// the reference, and `checkForSilence` is the watchdog's step with the clock handed in.
/// Synchronous throughout, as `TeleopDriverTests` is, so no timer can interleave.
@MainActor
@Suite("Headphone teleop")
struct HeadphoneTeleopTests {
    private let degree = Double.pi / 180
    private let start = ContinuousClock.now

    private func hub(driving driver: TeleopDriver) -> HeadphoneTeleop {
        let hub = HeadphoneTeleop(status: .off)
        hub.setOn(true)
        hub.attach(driver)
        return hub
    }

    /// The head of `driver` is level with its body: what every release must leave.
    private func isNeutral(_ driver: TeleopDriver) -> Bool {
        driver.target.yaw == driver.target.bodyYaw && driver.target.pitch == 0 && driver.target.roll == 0
    }

    @Test("switching on waits, and the first reading starts following")
    func waitsThenFollows() {
        let hub = HeadphoneTeleop(status: .off)
        hub.setOn(true)
        #expect(hub.status == .waiting)

        hub.receive(.level, at: start)

        #expect(hub.status == .following)
    }

    /// The invariant `TeleopDriver` exists to hold, reached from a head: what goes on the
    /// wire is the body's yaw plus the head's own.
    @Test("a turned head turns the robot's, composed onto the body's turn")
    func turnReachesTheDriver() {
        let driver = TeleopDriver(target: .init(yaw: 0.5, bodyYaw: 0.5))
        let hub = hub(driving: driver)

        hub.receive(HeadAttitude(yaw: 20 * degree), at: start)

        let lead = hub.mapping.aim(HeadAttitude(yaw: 20 * degree)).yaw
        #expect(lead != 0)
        #expect(abs(driver.target.yaw - (0.5 + lead)) < 1e-12)
        #expect(driver.target.bodyYaw == 0.5)
    }

    @Test("with no driver attached a reading moves nothing")
    func unattachedDrivesNothing() {
        let driver = TeleopDriver()
        let hub = HeadphoneTeleop(status: .off)
        hub.setOn(true)

        hub.receive(HeadAttitude(yaw: 20 * degree, pitch: 10 * degree), at: start)

        #expect(hub.status == .following)
        #expect(driver.target == TeleopTarget())
    }

    @Test("detaching puts the head back and leaves the body where it was")
    func detachReleases() {
        let driver = TeleopDriver(target: .init(yaw: 0.3, bodyYaw: 0.3))
        let hub = hub(driving: driver)
        hub.receive(HeadAttitude(yaw: 20 * degree, pitch: 10 * degree, roll: 5 * degree), at: start)
        #expect(!isNeutral(driver))

        hub.detach()

        #expect(isNeutral(driver))
        #expect(driver.target.bodyYaw == 0.3)
    }

    @Test("switching off puts the head back")
    func switchOffReleases() {
        let driver = TeleopDriver()
        let hub = hub(driving: driver)
        hub.receive(HeadAttitude(yaw: -15 * degree, pitch: 12 * degree), at: start)

        hub.setOn(false)

        #expect(hub.status == .off)
        #expect(isNeutral(driver))
    }

    /// An AirPod out of an ear stops the readings with no event at all, so silence is
    /// the signal. Inside the limit nothing changes; past it the head goes back and the
    /// next reading is a fresh reference.
    @Test("silence past the limit puts the head back and asks for a new reference")
    func silenceReleases() {
        let driver = TeleopDriver()
        let hub = hub(driving: driver)
        hub.receive(HeadAttitude(yaw: 20 * degree, pitch: 10 * degree), at: start)

        hub.checkForSilence(at: start + .milliseconds(500))
        #expect(hub.status == .following)
        #expect(!isNeutral(driver))

        hub.checkForSilence(at: start + HeadphoneTeleop.staleAfter + .milliseconds(1))
        #expect(hub.status == .waiting)
        #expect(hub.needsReference)
        #expect(isNeutral(driver))
    }

    @Test("recentring puts the head back and makes the next reading the reference")
    func recentreReleases() {
        let driver = TeleopDriver()
        let hub = hub(driving: driver)
        hub.receive(HeadAttitude(yaw: 25 * degree), at: start)

        hub.recentre()

        #expect(hub.needsReference)
        #expect(isNeutral(driver))
        #expect(hub.status == .following)
    }

    /// While the headphones only wait, the pad is live and may have a thumb on it. A
    /// release then would snap the robot out from under that thumb.
    @Test("a head that was never followed is not put back")
    func waitingDoesNotRelease() {
        let driver = TeleopDriver()
        driver.apply(JoystickDeflection(x: driver.mapping.rotationThreshold / 2, y: 0.3))
        let before = driver.target
        let hub = hub(driving: driver)

        hub.detach()
        hub.setOn(false)

        #expect(driver.target == before)
    }

    @Test("a device that cannot track a head cannot be switched on")
    func unsupportedStaysOff() {
        let hub = HeadphoneTeleop()
        hub.setOn(true)
        #expect(hub.status == .unsupported)
        #expect(!hub.isOn)
    }

    // MARK: TeleopDriver.aim

    @Test("aim keeps every axis inside the pad's reach")
    func aimClamps() {
        let driver = TeleopDriver()
        driver.aim(HeadAim(yaw: 2, pitch: -2, roll: 2))

        #expect(driver.target.yaw == driver.mapping.headAngle)
        #expect(driver.target.pitch == -driver.mapping.headAngle)
        #expect(driver.target.roll == driver.mapping.headAngle)
    }

    @Test("aim leaves the height, the antennas and the body alone")
    func aimTouchesTheHeadOnly() {
        let target = TeleopTarget(z: 0.01, bodyYaw: 0.4, antennaLeft: 0.2, antennaRight: -0.2)
        let driver = TeleopDriver(target: target)

        driver.aim(HeadAim(yaw: 0.1, pitch: 0.1, roll: 0.1))

        #expect(driver.target.z == target.z)
        #expect(driver.target.bodyYaw == target.bodyYaw)
        #expect(driver.target.antennaLeft == target.antennaLeft)
        #expect(driver.target.antennaRight == target.antennaRight)
        #expect(driver.bodyYawRate == 0)
    }
}
