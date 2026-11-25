public extension CameraSession {
    /// Where the session stands. In a file of its own because `CameraSession.swift`
    /// reached SwiftLint's length limit.
    enum Phase: Equatable, Sendable {
        case connecting
        /// Signaling is up but the daemon has no media producer (sim before acquire).
        case waitingForProducer
        /// The peer connection is connected — ICE found a path and DTLS finished on it,
        /// so media can flow. Not merely a video track named in the offer: libwebrtc
        /// announces that track while it applies the offer, before the robot has even
        /// seen an answer, and taking that for a stream is what once left a dead
        /// negotiation on screen as a black picture with no spinner.
        case streaming
        /// Negotiation stalled on the first attempt and again on the one retry after it,
        /// so nothing more is tried until `retry()` — on the LAN, a slow probe aside.
        /// Apart from `failed` because trying again is the remedy here, where for a robot
        /// somebody else took it is the opposite — so it offers a retry, and `failed` does not.
        case stalled
        /// The robot said that its media pipeline did not start: `POST /api/media/acquire`
        /// answered 500, which daemon 1.15.0 does when the camera is held by another
        /// process, for example (pollen-robotics/reachy_mini#1567). The robot has said so
        /// at once, so this skips both attempts' deadlines. No probe follows, because
        /// only an acquire starts that pipeline again, and an acquire is a takeover.
        /// `retry()` asks again.
        case mediaDidNotStart
        case failed(String)
    }
}
