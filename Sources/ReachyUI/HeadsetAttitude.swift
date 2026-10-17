import simd

/// A headset's orientation as a head moves: a turn, then a nod, then a tilt.
///
/// ARKit reports the device pose (`DeviceAnchor.originFromAnchorTransform`) in a
/// right-handed, gravity-aligned frame: y is up, and the device looks along -z. The
/// rotation is decomposed as R = Ry(yaw) · Rx(pitch) · Rz(roll), which gives:
///
/// - yaw positive turning left, about the vertical;
/// - pitch positive looking up, about the head's own left–right axis;
/// - roll positive with the left ear down, about the line of sight.
///
/// `HeadphoneMotionMapping.headset` turns these into the robot's convention. Unlike
/// the headphones' frame, this one is documented, so the signs follow from it rather
/// than from a guess; a headset is still where they are confirmed.
///
/// Platform-neutral on purpose: it is simd and nothing else, so `swift test` holds
/// the geometry on a Mac though only visionOS has a pose to feed it.
enum HeadsetAttitude {
    /// The three angles of a pose, in radians. The translation is ignored.
    static func angles(of transform: simd_float4x4) -> HeadAttitude {
        // Column-major: `columns.j[i]` is row i, column j of R.
        let pitch = asin(min(max(-Double(transform.columns.2.y), -1), 1))
        let yaw = atan2(Double(transform.columns.2.x), Double(transform.columns.2.z))
        let roll = atan2(Double(transform.columns.0.y), Double(transform.columns.1.y))
        return HeadAttitude(yaw: yaw, pitch: pitch, roll: roll)
    }

    /// `current` against `reference`: the turn from the reference's heading, wrapped
    /// to ±180°, and the nod and the tilt as their change from the reference's own.
    ///
    /// Angle by angle rather than one rotation relative to the other, because ARKit's
    /// frame knows where gravity is and the headphones' does not. A reference taken
    /// while looking a little down then keeps a turn about the vertical a pure turn;
    /// as a relative rotation, that turn would also read as some tilt.
    static func attitude(of current: simd_float4x4, from reference: simd_float4x4) -> HeadAttitude {
        let now = angles(of: current)
        let then = angles(of: reference)
        return HeadAttitude(
            yaw: remainder(now.yaw - then.yaw, 2 * .pi),
            pitch: now.pitch - then.pitch,
            roll: now.roll - then.roll
        )
    }
}
