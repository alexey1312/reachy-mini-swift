import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

@Suite("Joystick mapping")
struct JoystickMappingTests {
    private let mapping = JoystickMapping()

    /// The head leads out to its full angle by the boundary and gives that lead back
    /// across the zone, so a held turn leaves the camera looking straight down the
    /// torso rather than 40° off it.
    @Test("head yaw leads to the boundary and returns to the body's axis past it")
    func headYaw() {
        let boundary = mapping.rotationThreshold
        #expect(mapping.headYaw(.zero) == 0)
        #expect(abs(mapping.headYaw(.init(x: boundary / 2)) + mapping.headAngle / 2) < 1e-9)
        #expect(abs(mapping.headYaw(.init(x: boundary)) + mapping.headAngle) < 1e-9)
        #expect(abs(mapping.headYaw(.init(x: 1.0))) < 1e-9)
    }

    /// The two halves of the handover are driven by one ramp, so the head cannot still
    /// be giving its lead back after the body has reached full speed, or arrive on the
    /// torso's axis before the body has started at all.
    @Test("the head gives its lead back on the same ramp the body accelerates on")
    func recentringTracksTheRamp() {
        let halfway = mapping.rotationThreshold + (1 - mapping.rotationThreshold) / 2
        #expect(mapping.rotationRamp(.init(x: mapping.rotationThreshold)) == 0)
        #expect(abs(mapping.rotationRamp(.init(x: halfway)) - 0.5) < 1e-9)
        #expect(mapping.rotationRamp(.init(x: 1.0)) == 1)
        #expect(abs(mapping.headYaw(.init(x: halfway)) + mapping.headAngle / 2) < 1e-9)
    }

    /// Zero at the boundary is the point: entering the rotation zone cannot itself
    /// produce a jolt, because the speed it starts at is nothing.
    @Test("the body starts turning from a standstill at the zone boundary")
    func rotationRamp() {
        let boundary = mapping.rotationThreshold
        let halfway = boundary + (1 - boundary) / 2
        #expect(mapping.bodyYawRate(.init(x: boundary)) == 0)
        #expect(mapping.bodyYawRate(.init(x: boundary / 2)) == 0)
        #expect(abs(mapping.bodyYawRate(.init(x: halfway)) + mapping.maxBodyYawRate / 2) < 1e-9)
        #expect(abs(mapping.bodyYawRate(.init(x: 1.0)) + mapping.maxBodyYawRate) < 1e-9)
    }

    @Test("left and right are mirror images")
    func symmetry() {
        #expect(mapping.headYaw(.init(x: -0.5)) == -mapping.headYaw(.init(x: 0.5)))
        #expect(mapping.bodyYawRate(.init(x: -0.9)) == -mapping.bodyYawRate(.init(x: 0.9)))
    }

    /// The zone is a vertical slice of the pad, not a mark at the rim: a thumb pushed
    /// into a corner turns the body exactly as a level one does. The boundary sits
    /// inside the diagonal, which is what makes that true of the whole left and right
    /// of the pad — at 0.7 the rim only reached the boundary within 45.6° of level, so
    /// the corners were head-only and the zone read as "strictly left and right".
    @Test("a push into the corner of the pad turns the body")
    func cornersTurn() {
        let diagonal = cos(Double.pi / 4)
        #expect(mapping.rotationThreshold < diagonal)

        let corner = JoystickDeflection(x: -diagonal, y: -diagonal)
        #expect(mapping.bodyYawRate(corner) > 0)
        #expect(mapping.rotationSide(corner) == .left)
        // Part way through the handover, and by exactly as much as the body has taken
        // over: the corner is a fraction `rotationRamp` into the zone, so the head has
        // given back that fraction of its lead and kept the rest.
        let handedOver = mapping.rotationRamp(corner)
        #expect(handedOver > 0 && handedOver < 1)
        #expect(abs(mapping.headYaw(corner) - mapping.headAngle * (1 - handedOver)) < 1e-9)
    }

    /// The pad shades the side this names, so a lit slice that did not correspond to a
    /// turn — or a turn under an unlit one — would be the two disagreeing.
    @Test("the zone the pad lights is exactly the one that turns")
    func zoneMatchesTheTurn() {
        #expect(mapping.rotationSide(.zero) == nil)
        #expect(mapping.rotationSide(.init(x: mapping.rotationThreshold)) == nil)
        #expect(mapping.rotationSide(.init(x: 1.0)) == .right)
        #expect(mapping.rotationSide(.init(x: -1.0)) == .left)
        #expect(mapping.rotationSide(.init(y: 1.0)) == nil)
    }

    /// If the joystick could outrun the limiter, the emitted pose would fall
    /// permanently behind the goal and the body would turn at the limiter's speed
    /// rather than the one the finger asked for.
    @Test("the joystick cannot outrun the slew limiter")
    func staysUnderTheCeiling() {
        #expect(mapping.maxBodyYawRate < TargetSlewLimiter().bodyYawRate)
    }

    @Test("pitch keeps its existing meaning")
    func pitch() {
        #expect(abs(mapping.headPitch(.init(y: 1.0)) - mapping.headAngle) < 1e-9)
        #expect(abs(mapping.headPitch(.init(y: -0.5)) + mapping.headAngle / 2) < 1e-9)
    }
}
