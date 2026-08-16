import simd

/// Rigid-body maths shared by the URDF model, the state stream and the Stewart
/// solver.
///
/// Euler conventions are the single largest source of silent errors here, so
/// there is exactly one implementation of each direction and everything routes
/// through it.
public enum RigidTransform {
    /// URDF `rpy`: intrinsic x-y-z, which composes as `Rz(yaw) * Ry(pitch) * Rx(roll)`.
    public static func rotation(rpy: SIMD3<Double>) -> simd_double3x3 {
        let (sr, cr) = (sin(rpy.x), cos(rpy.x))
        let (sp, cp) = (sin(rpy.y), cos(rpy.y))
        let (sy, cy) = (sin(rpy.z), cos(rpy.z))
        return simd_double3x3(rows: [
            SIMD3(cy * cp, cy * sp * sr - sy * cr, cy * sp * cr + sy * sr),
            SIMD3(sy * cp, sy * sp * sr + cy * cr, sy * sp * cr - cy * sr),
            SIMD3(-sp, cp * sr, cp * cr),
        ])
    }

    /// Inverse of ``rotation(rpy:)``. Extrinsic X-Y-Z extraction, matching
    /// `scipy`'s `as_euler("xyz")`.
    ///
    /// - Important: this is the convention of a URDF `origin rpy`, **not** of a
    ///   joint chain. Three stacked revolute joints compose the other way round —
    ///   see ``wristAngles(from:)``.
    public static func euler(from rotation: simd_double3x3) -> SIMD3<Double> {
        // Column-major storage: `rotation[column][row]`.
        let sy = -rotation[0][2]
        guard abs(sy) < Self.gimbalLockThreshold else {
            // Pitch at ±90°: roll and yaw fold into one axis, so pin roll to 0.
            return SIMD3(0, sy > 0 ? .pi / 2 : -.pi / 2, atan2(-rotation[1][0], rotation[1][1]))
        }
        return SIMD3(
            atan2(rotation[1][2], rotation[2][2]),
            asin(sy),
            atan2(rotation[0][1], rotation[0][0])
        )
    }

    /// A spherical wrist spelled as three stacked revolute joints — `passive_i_x`,
    /// then `_y`, then `_z`, each turning about its own axis in its own frame — so
    /// the chain composes as `Rx(x) * Ry(y) * Rz(z)`.
    ///
    /// This is the **reverse** of ``rotation(rpy:)``, and the two are not
    /// interchangeable: a triplet extracted with one and rebuilt with the other
    /// names a different rotation as soon as the angles leave the small-angle
    /// regime, which is why the wrists get a pair of their own.
    public static func wristRotation(angles: SIMD3<Double>) -> simd_double3x3 {
        let (sx, cx) = (sin(angles.x), cos(angles.x))
        let (sy, cy) = (sin(angles.y), cos(angles.y))
        let (sz, cz) = (sin(angles.z), cos(angles.z))
        return simd_double3x3(rows: [
            SIMD3(cy * cz, -cy * sz, sy),
            SIMD3(sx * sy * cz + cx * sz, cx * cz - sx * sy * sz, -sx * cy),
            SIMD3(sx * sz - cx * sy * cz, cx * sy * sz + sx * cz, cx * cy),
        ])
    }

    /// Inverse of ``wristRotation(angles:)``. Intrinsic X-Y-Z extraction, matching
    /// `scipy`'s `as_euler("XYZ")`.
    public static func wristAngles(from rotation: simd_double3x3) -> SIMD3<Double> {
        // Column-major storage: `rotation[column][row]`.
        let sine = rotation[2][0]
        guard abs(sine) < Self.gimbalLockThreshold else {
            // The middle joint at ±90° folds the outer and inner ones onto one
            // axis, so pin the inner one to 0 and give their sum to the outer.
            let sign: Double = sine > 0 ? 1 : -1
            return SIMD3(atan2(sign * rotation[0][1], rotation[1][1]), sign * .pi / 2, 0)
        }
        return SIMD3(
            atan2(-rotation[2][1], rotation[2][2]),
            asin(sine),
            atan2(-rotation[1][0], rotation[0][0])
        )
    }

    public static func transform(translation: SIMD3<Double>, rpy: SIMD3<Double>) -> simd_double4x4 {
        transform(rotation: rotation(rpy: rpy), translation: translation)
    }

    public static func transform(
        rotation: simd_double3x3,
        translation: SIMD3<Double>
    ) -> simd_double4x4 {
        simd_double4x4(
            SIMD4(rotation.columns.0, 0),
            SIMD4(rotation.columns.1, 0),
            SIMD4(rotation.columns.2, 0),
            SIMD4(translation, 1)
        )
    }

    /// The daemon sends 4x4 poses flattened row by row; simd stores columns.
    public static func matrix(rowMajor values: [Double]) -> simd_double4x4? {
        guard values.count == 16 else { return nil }
        return simd_double4x4(rows: [
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15]),
        ])
    }

    /// Inverse of ``matrix(rowMajor:)``: back to the flat row-by-row array the
    /// daemon reads, which is what `set_full_target` takes for the head pose.
    public static func rowMajorValues(_ matrix: simd_double4x4) -> [Double] {
        (0 ..< 4).flatMap { row in
            (0 ..< 4).map { column in matrix[column][row] }
        }
    }

    /// Rotation about `axis` by `angle`, for URDF revolute joints.
    public static func rotation(axis: SIMD3<Double>, angle: Double) -> simd_double3x3 {
        simd_double3x3(simd_quatd(angle: angle, axis: simd_normalize(axis)))
    }

    /// Shortest rotation carrying `from` onto `to`, both assumed unit length.
    ///
    /// Rodrigues' formula degenerates when the vectors are parallel or opposed —
    /// the cross product vanishes and the axis is undefined — so those are handled
    /// before it is applied.
    public static func alignment(from: SIMD3<Double>, to: SIMD3<Double>) -> simd_double3x3 {
        let dot = simd_dot(from, to)
        if dot > Self.alignmentThreshold {
            return matrix_identity_double3x3
        }
        if dot < -Self.alignmentThreshold {
            // Opposed: any perpendicular axis works, so pick one that is not
            // itself parallel to the input.
            let seed = abs(from.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            let axis = simd_normalize(simd_cross(from, seed))
            return rotation(axis: axis, angle: .pi)
        }
        let axis = simd_cross(from, to)
        let sine = simd_length(axis)
        let skew = simd_double3x3(rows: [
            SIMD3(0, -axis.z, axis.y),
            SIMD3(axis.z, 0, -axis.x),
            SIMD3(-axis.y, axis.x, 0),
        ])
        let scale = (1 - dot) / (sine * sine)
        return matrix_identity_double3x3 + skew + skew * skew * scale
    }

    private static let alignmentThreshold = 0.99999

    private static let gimbalLockThreshold = 0.99999
}

public extension simd_double4x4 {
    var rotation: simd_double3x3 {
        simd_double3x3(columns.0.xyz, columns.1.xyz, columns.2.xyz)
    }

    var translation: SIMD3<Double> {
        columns.3.xyz
    }
}

extension SIMD4<Double> {
    var xyz: SIMD3<Double> {
        SIMD3(x, y, z)
    }
}
