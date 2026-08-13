@testable import ReachyMedia
import Testing

/// The one thing standing between the robot's ordinary end-of-candidates marker
/// and a dead app.
///
/// Nothing here can be asserted through `handle(_:)`: `peerConnection?.add` is an
/// optional chain, so with no peer the argument is never evaluated and the broken
/// version survives the very call that killed it in production. The decision is
/// therefore its own function, and this is what holds it.
@MainActor
@Suite("Camera session ICE candidates")
struct CameraSessionCandidateTests {
    /// An empty candidate is ICE saying gathering is over. `RTCIceCandidate.init`
    /// answers it with `NSParameterAssert(sdp.length)` — an `NSException`, which no
    /// `try?` catches — so passing it on terminated the process.
    @Test("the end-of-candidates marker is dropped")
    func dropsTheEndOfCandidatesMarker() {
        #expect(CameraSession.iceCandidate(sdp: "", sdpMLineIndex: 0, sdpMid: "0") == nil)
    }

    /// And the guard may not swallow the candidates the connection is actually
    /// made of — dropping every one of them would read as the same silent failure.
    @Test("a real candidate still gets through")
    func keepsARealCandidate() {
        let candidate = CameraSession.iceCandidate(
            sdp: "candidate:1 1 UDP 2130706431 192.168.8.188 54321 typ host",
            sdpMLineIndex: 0,
            sdpMid: "0"
        )
        #expect(candidate != nil)
    }
}
