import Foundation
import Observation
import OSLog
import ReachyKit
@preconcurrency import WebRTC

// iOS only: the audio *session* is an iOS concept, and asking to record moved to
// `MicrophonePermission`, which carries the cross-platform fork now.
#if os(iOS)
    import AVFAudio
#endif

/// Owns one WebRTC session to the robot: consumes `CameraSignalingClient`
/// events, answers the robot's offer, and exposes the remote video track plus
/// a mic toggle (client mic → robot speaker; the robot's offer is sendrecv).
///
/// Self-healing: any failure (ICE, watchdog, socket) drops the peer connection
/// and forces the signaling client to reconnect, which re-negotiates a session.
@MainActor
@Observable
public final class CameraSession {
    public enum Phase: Equatable, Sendable {
        case connecting
        /// Signaling is up but the daemon has no media producer (sim before acquire).
        case waitingForProducer
        case streaming
        case failed(String)
    }

    public private(set) var phase: Phase = .connecting
    public private(set) var videoTrack: RTCVideoTrack?
    public private(set) var isMicEnabled = false

    /// What the OS says about recording. Published because a refusal used to be
    /// swallowed here: `setMicEnabled(true)` returned early and wrote nothing, so the
    /// button redrew itself unchanged and unmuting did nothing, forever, unexplained.
    /// The viewport reads this to say why instead.
    public private(set) var micPermission: PermissionState = .undetermined

    /// The session's control surface. Exists from construction and stays the same
    /// object across re-negotiations, so a `RemoteControlChannel` built on it
    /// survives the self-healing restart that replaces the peer connection.
    ///
    /// Only worth driving over the relay: on the LAN the daemon's HTTP API is
    /// right there and says more.
    public let dataChannel = WebRTCDataChannel()

    /// Not `.streaming` for this long after an offer → drop and re-negotiate (upstream value).
    private static let streamTimeout: Duration = .seconds(10)

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private let signaling: any RobotSignaling
    private let connection: RobotConnection?
    private var peerConnection: RTCPeerConnection?
    private var delegateAdapter: PeerConnectionDelegateAdapter?
    private var micTrack: RTCAudioTrack?
    /// `@ObservationIgnored` because `deinit` reads it: the macro would turn a
    /// tracked property into a MainActor-isolated accessor, which a nonisolated
    /// `deinit` may not call — a stored property it may.
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// The deactivation still in flight, if any — see `deactivateAudioSession()`.
    private var audioDeactivationTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.alexey1312.ReachyMini", category: "CameraSession")
    private struct LocalCandidate {
        var sdp: String
        var sdpMLineIndex: Int32
        var sdpMid: String?
    }

    /// Local candidates gathered before the answer went out (gst requires answer first).
    private var pendingLocalCandidates: [LocalCandidate] = []
    private var answerSent = false

    /// On the LAN: the robot's own signaling socket, and its HTTP API alongside
    /// for the media-acquire nudge the simulator needs.
    public init(address: RobotAddress) throws {
        signaling = try CameraSignalingClient(address: address)
        connection = try? RobotConnection(address: address)
    }

    /// Anywhere else: whatever is carrying signaling — over the Hugging Face relay
    /// there is no HTTP API to reach, and nothing to acquire.
    public init(signaling: any RobotSignaling) {
        self.signaling = signaling
        connection = nil
    }

    /// The backstop for an owner that drops the session without `stop()`. The
    /// `weak self` in `start()` is what lets this run at all — but on its own it
    /// only half-closes the leak: `eventsTask` keeps consuming, and against an
    /// unreachable robot the captured signaling client redials the socket every
    /// half-second for as long as the app lives, with the `guard let self` never
    /// reached because a dead host yields no events. A stopped (or never
    /// started) session has `eventsTask == nil` and nothing to undo — previews
    /// construct sessions constantly and must not touch the shared audio session.
    ///
    /// `signaling` is bound before the `Task` so the closure never captures
    /// `self`, which a `deinit` may not escape (`RobotFilesModel` sets the idiom).
    deinit {
        guard let eventsTask else { return }
        eventsTask.cancel()
        dataChannel.close()
        let signaling = signaling
        Task { await signaling.disconnect() }
        #if os(iOS)
            Task { await Self.releaseAudioSession() }
        #endif
    }

    public func start() {
        guard eventsTask == nil else { return }
        // Read before anyone can tap, so a mic already refused in Settings shows as
        // refused rather than as an ordinary muted button waiting to be pressed.
        refreshMicPermission()
        configureAudioSession()
        // `weak self`: `handle` captures the session, so a strong capture keeps
        // `self → eventsTask → self` alive for as long as the signaling stream
        // runs — an owner that drops the session without `stop()` would leak it
        // and its socket (`RobotSceneModel.startStreaming` makes the same trade).
        eventsTask = Task { [weak self, signaling, connection] in
            // Sim registers no producer until media is acquired; harmless elsewhere.
            try? await connection?.acquireMedia()
            for await event in await signaling.events() {
                guard let self else { return }
                await handle(event)
            }
        }
    }

    public func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        teardownPeer()
        dataChannel.close()
        deactivateAudioSession()
        phase = .connecting
        let signaling = signaling
        Task { await signaling.disconnect() } // best-effort endSession; ws close also suffices
    }

    public func setMicEnabled(_ enabled: Bool) {
        guard enabled else {
            isMicEnabled = false
            micTrack?.isEnabled = false
            return
        }
        Task {
            micPermission = await MicrophonePermission.request()
            guard micPermission == .granted else { return }
            isMicEnabled = true
            micTrack?.isEnabled = true
        }
    }

    /// Re-reads the non-prompting authorization status after the app returns from
    /// Settings. A session survives that round trip, so the value captured by
    /// `start()` would otherwise leave a newly granted microphone looking blocked
    /// until the whole camera session was rebuilt.
    public func refreshMicPermission() {
        micPermission = MicrophonePermission.current
        guard micPermission != .granted else { return }
        isMicEnabled = false
        micTrack?.isEnabled = false
    }

    // MARK: - Signaling events

    private func handle(_ event: SignalingEvent) async {
        switch event {
        case .waitingForProducer:
            if phase != .streaming {
                phase = .waitingForProducer
            }
        case let .offer(_, sdp):
            await accept(offerSDP: sdp)
        case let .remoteCandidate(_, candidate, sdpMLineIndex, sdpMid):
            // Late-candidate errors are expected once ICE is connected — ignore (upstream does too).
            try? await peerConnection?.add(
                RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            )
        case let .sessionEnded(reason):
            teardownPeer()
            // On the LAN the client re-negotiates on its own, so this is a lull
            // rather than an ending. Over the relay central says why, and there is
            // nothing further coming — which is also the line the control channel
            // is drawn on: a lull leaves its commands waiting, an ending fails them.
            guard let reason else {
                phase = .connecting
                return
            }
            dataChannel.close()
            phase = .failed(RemoteSessionEnd(reason: reason).message)
        case let .failed(message):
            teardownPeer()
            dataChannel.close()
            phase = .failed(message)
        }
    }

    private func accept(offerSDP: String) async {
        teardownPeer()
        phase = .connecting

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = [RTCIceServer(urlStrings: [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
        ])]
        let adapter = PeerConnectionDelegateAdapter(owner: self)
        guard let peer = Self.factory.peerConnection(
            with: configuration, constraints: Self.noConstraints, delegate: adapter
        ) else {
            phase = .failed("Could not create peer connection")
            return
        }
        delegateAdapter = adapter
        peerConnection = peer

        do {
            try await peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offerSDP))
            attachMicTrack(to: peer)
            let answer = try await peer.answer(for: Self.noConstraints)
            try await peer.setLocalDescription(answer)
            await signaling.send(answerSDP: answer.sdp)
            answerSent = true
            for candidate in pendingLocalCandidates {
                await signaling.send(
                    candidate: candidate.sdp,
                    sdpMLineIndex: candidate.sdpMLineIndex,
                    sdpMid: candidate.sdpMid
                )
            }
            pendingLocalCandidates = []
        } catch {
            phase = .failed(error.localizedDescription)
            teardownPeer()
            return
        }
        startWatchdog()
    }

    // MARK: - Peer connection callbacks (from the delegate adapter)

    func handleLocalCandidate(sdp: String, sdpMLineIndex: Int32, sdpMid: String?) {
        guard answerSent else {
            pendingLocalCandidates.append(LocalCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid))
            return
        }
        let signaling = signaling
        Task { await signaling.send(candidate: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid) }
    }

    func handleRemote(videoTrack: RTCVideoTrack) {
        self.videoTrack = videoTrack
        phase = .streaming
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// ICE failed or the stream never arrived: drop everything and force the
    /// signaling socket closed — its reconnect loop negotiates a fresh session.
    func restartSession() {
        teardownPeer()
        phase = .connecting
        let signaling = signaling
        Task { await signaling.disconnect() }
    }

    // MARK: - Internals

    private func attachMicTrack(to peer: RTCPeerConnection) {
        // ponytail: the mic track is attached even while muted — gst webrtcsink
        // doesn't renegotiate consumer sessions, so audio must be in the answer
        // from the start. Verified: the OS permission prompt still fires only on
        // the first unmute (WebRTC doesn't start capture for a disabled track).
        let source = Self.factory.audioSource(with: Self.noConstraints)
        let track = Self.factory.audioTrack(with: source, trackId: "reachy-mic")
        track.isEnabled = isMicEnabled
        if let transceiver = peer.transceivers.first(where: { $0.mediaType == .audio }) {
            transceiver.sender.track = track
            transceiver.setDirection(.sendRecv, error: nil)
        }
        micTrack = track
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task {
            guard await (try? Task.sleep(for: Self.streamTimeout)) != nil else { return }
            if phase != .streaming {
                restartSession()
            }
        }
    }

    /// The robot opens exactly one channel and labels it `"data"`; anything else
    /// is not the daemon's control surface and is left alone.
    func adopt(_ channel: RTCDataChannel) {
        guard channel.label == "data" else { return }
        dataChannel.attach(channel)
    }

    private func teardownPeer() {
        watchdogTask?.cancel()
        watchdogTask = nil
        dataChannel.detachPeer()
        peerConnection?.close()
        peerConnection = nil
        delegateAdapter = nil
        micTrack = nil
        videoTrack = nil
        answerSent = false
        pendingLocalCandidates = []
    }

    private static var noConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    private func configureAudioSession() {
        #if os(iOS)
            // A stop() a moment ago may still be retrying deactivation; left
            // running, it would deactivate the session this start just opened.
            audioDeactivationTask?.cancel()
            audioDeactivationTask = nil
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker])
            try? session.setActive(true)
        #endif
    }

    /// The mirror `stop()` owes `configureAudioSession()`: leaving the camera
    /// used to keep the app holding a record-category session — other apps'
    /// audio stayed ducked and the OS went on treating this one as a recorder.
    /// `.notifyOthersOnDeactivation` is what lets them resume.
    private func deactivateAudioSession() {
        #if os(iOS)
            audioDeactivationTask?.cancel()
            audioDeactivationTask = Task { await Self.releaseAudioSession() }
        #endif
    }

    #if os(iOS)
        /// `setActive(false)` races WebRTC's own audio unit, which
        /// `peerConnection.close()` winds down on its background thread after
        /// `stop()` has already returned — deactivating immediately commonly
        /// fails "session is busy", and a `try?` there made the release silently
        /// not happen. So: retry briefly, and log when the OS still refuses,
        /// because a swallowed failure looks exactly like the ducked-audio bug
        /// this method exists to end.
        private static func releaseAudioSession() async {
            for _ in 0 ..< 5 {
                do {
                    try AVAudioSession.sharedInstance().setActive(
                        false,
                        options: [.notifyOthersOnDeactivation]
                    )
                    return
                } catch {
                    guard (try? await Task.sleep(for: .milliseconds(200))) != nil else { return }
                }
            }
            log.warning("Audio session would not deactivate; other apps' audio may stay ducked")
        }
    #endif
}

/// Bridges nonisolated WebRTC delegate callbacks onto the MainActor session.
private final class PeerConnectionDelegateAdapter: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private weak var owner: CameraSession?

    init(owner: CameraSession) {
        self.owner = owner
    }

    func peerConnection(_: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let sdp = candidate.sdp
        let index = candidate.sdpMLineIndex
        let mid = candidate.sdpMid
        Task { @MainActor [owner] in
            owner?.handleLocalCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
        }
    }

    func peerConnection(_: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams _: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [owner] in
            owner?.handleRemote(videoTrack: track)
        }
    }

    func peerConnection(_: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        guard newState == .failed else { return }
        Task { @MainActor [owner] in
            owner?.restartSession()
        }
    }

    /// The robot is the one that opens the channel, and only once negotiation is
    /// far enough along — so this, not construction, is when the control surface
    /// becomes usable.
    func peerConnection(_: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [owner] in
            owner?.adopt(dataChannel)
        }
    }

    // Required by the protocol; nothing to do.
    func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
}

#if DEBUG
    public extension CameraSession {
        /// A session parked in one phase. Constructing one is inert — `start()` is what opens the
        /// signaling socket and builds the peer connection, and it is never called here.
        ///
        /// `phase` is `private(set)`, so this has to live in the same file.
        ///
        /// `micPermission` is a parameter because a refused microphone is a state the
        /// viewport renders differently and no preview could otherwise reach: the real
        /// value is only ever written by `start()`, which a preview must not call.
        static func preview(_ phase: Phase, micPermission: PermissionState = .undetermined) -> CameraSession {
            // A well-formed host cannot fail to produce a signaling client, and nothing dials it.
            // swiftlint:disable:next force_try
            let session = try! CameraSession(address: RobotAddress(host: "192.168.1.42"))
            session.phase = phase
            session.micPermission = micPermission
            return session
        }
    }
#endif
