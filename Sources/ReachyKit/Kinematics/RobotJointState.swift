import Foundation

/// Every joint angle the viewer needs, addressed by its URDF name.
public struct RobotJointState: Sendable, Equatable {
    /// Drives `yaw_body`.
    public var bodyYaw: Double = 0
    /// Six values for `stewart_1` ... `stewart_6`.
    public var stewart: [Double] = Array(repeating: 0, count: 6)
    public var antennaLeft: Double = 0
    public var antennaRight: Double = 0
    /// Twenty-one values: `passive_1_x` ... `passive_7_z`.
    public var passive: [Double] = Array(repeating: 0, count: 21)

    public static let neutral = RobotJointState()

    public init() {}

    public subscript(jointName: String) -> Double? {
        switch jointName {
        case "yaw_body": bodyYaw
        case "left_antenna": antennaLeft
        case "right_antenna": antennaRight
        default: indexed(jointName)
        }
    }

    private func indexed(_ jointName: String) -> Double? {
        if let index = Self.stewartIndex(jointName) {
            return stewart.indices.contains(index) ? stewart[index] : nil
        }
        if let index = Self.passiveIndex(jointName) {
            return passive.indices.contains(index) ? passive[index] : nil
        }
        return nil
    }

    /// `stewart_1` ... `stewart_6`, one-based in the URDF.
    private static func stewartIndex(_ name: String) -> Int? {
        guard name.hasPrefix("stewart_"), let number = Int(name.dropFirst(8)) else { return nil }
        return number - 1
    }

    /// `passive_<1...7>_<x|y|z>` flattens to `(chain - 1) * 3 + axis`.
    private static func passiveIndex(_ name: String) -> Int? {
        guard name.hasPrefix("passive_") else { return nil }
        let parts = name.dropFirst(8).split(separator: "_")
        guard parts.count == 2, let chain = Int(parts[0]) else { return nil }
        let axis: Int
        switch parts[1] {
        case "x": axis = 0
        case "y": axis = 1
        case "z": axis = 2
        default: return nil
        }
        return (chain - 1) * 3 + axis
    }

    /// Builds a pose from one state-stream frame.
    ///
    /// `head_joints` carries `[body_yaw, stewart_1 ... stewart_6]` and is the
    /// preferred source; `body_yaw` alone is the fallback for streams that did not
    /// ask for the motor angles.
    ///
    /// - Parameter platform: solves the six cranks when the frame carries none.
    ///   **Leaving them at zero is what draws a head with no robot under it**: the
    ///   daemon defaults `with_head_joints` to *false*, and a viewer that places the
    ///   head from `head_pose` then has the linkage standing at its zero
    ///   configuration — 27 mm lower than the pose's own origin, and further still
    ///   under any rotation. The angles are recoverable from the pose alone, so
    ///   recover them rather than draw a robot in two places at once.
    public static func resolve(
        _ frame: RobotStateFrame,
        solver: PassiveJointSolver? = nil,
        platform: StewartIK? = nil
    ) -> RobotJointState {
        var state = RobotJointState()
        if let joints = frame.headJoints, joints.count >= 7 {
            state.bodyYaw = joints[0]
            state.stewart = Array(joints[1 ... 6])
        } else {
            if let bodyYaw = frame.bodyYaw {
                state.bodyYaw = bodyYaw
            }
            // After body yaw, which the solve subtracts out of the pose.
            if let platform, let pose = frame.headPose?.transform,
               let stewart = platform.solve(headPose: pose, bodyYaw: state.bodyYaw)
            {
                state.stewart = stewart
            }
        }
        if let antennas = frame.antennas, antennas.count >= 2 {
            // The stream reports (right, left), but the URDF's antenna joints are
            // mirrored and wound the other way, so the pair is crossed and negated.
            // Matches the official viewer; worth re-checking against real hardware
            // if the antennas ever look swapped.
            state.antennaLeft = -antennas[1]
            state.antennaRight = -antennas[0]
        }
        // A Placo-backed daemon sends these; every other one leaves them out, which
        // is why the client can work them out itself.
        if let passive = frame.passiveJoints, passive.count == 21 {
            state.passive = passive
        } else if let solver, let pose = frame.headPose?.transform {
            state.passive = solver.solve(
                headPose: pose,
                bodyYaw: state.bodyYaw,
                stewart: state.stewart
            )
        }
        return state
    }
}
