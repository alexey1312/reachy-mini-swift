@preconcurrency import WebRTC

/// A file of its own because `CameraSession.swift` is at SwiftLint's 400-line
/// limit, and `--strict` turns that into a build failure — the same split
/// `RobotSession+Moves.swift` made for the same reason.
extension CameraSession {
    /// `nil` for the end-of-candidates marker, which is an empty candidate string
    /// and which the robot's gstreamer webrtcsink sends on every negotiation.
    ///
    /// **`RTCIceCandidate.init` asserts on it and throws an `NSException`, which
    /// `try?` does not catch** — and the constructor is an argument, so it runs
    /// before `peerConnection?.add` is ever reached. The app therefore died the
    /// moment the robot *finished* gathering, on the ordinary path rather than on
    /// a failure: `Invalid parameter not satisfying: sdp.length`,
    /// `RTCIceCandidate.mm:28`. libwebrtc's ObjC surface has no way to signal
    /// end-of-candidates, so dropping it is the whole of the handling.
    static func iceCandidate(sdp: String, sdpMLineIndex: Int32, sdpMid: String?) -> RTCIceCandidate? {
        guard !sdp.isEmpty else { return nil }
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
}
