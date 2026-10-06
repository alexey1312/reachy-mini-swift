import Foundation
import Observation
import ReachyKit
@preconcurrency import WebRTC

/// Owns one WebRTC session to the robot: consumes `CameraSignalingClient`
/// events, answers the robot's offer, and exposes the remote video track plus
/// a mic toggle (client mic → robot speaker; the robot's offer is sendrecv).
///
/// Self-healing, within a budget: a negotiation that does not reach a connected
/// peer in time is started over once, and a second stall in a row is reported as
/// `.stalled` rather than retried at full speed — `CameraSession+Negotiation.swift`.
@MainActor
@Observable
public final class CameraSession {
    public enum Phase: Equatable, Sendable {
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
        /// somebody else took it is the opposite — so only this one offers it.
        case stalled
        case failed(String)
    }

    /// `internal(set)`, like `isMicEnabled` and `micPermission`, only so the extensions
    /// in their own files can move it — the negotiation, and the previews. This file is
    /// at SwiftLint's length limit. Outside the module all three read as they always did.
    public internal(set) var phase: Phase = .connecting
    public private(set) var videoTrack: RTCVideoTrack?
    public internal(set) var isMicEnabled = false

    /// Gain applied to this device's microphone before the robot hears it, where 1 is
    /// unchanged. libwebrtc takes 0…10 and clamps outside that.
    ///
    /// **It exists because the robot has no headroom left.** The daemon applies no
    /// software gain to anything it plays, and its mixer is already at 100, so a call
    /// cannot be made quieter or an app's speech louder from that end. What a person
    /// hears as "the call is much louder than the apps" is the level of the two
    /// sources: this device's voice arrives compressed and near full scale from the
    /// system's voice-processing unit, while a sound asset plays at whatever level it
    /// was recorded — `wake_up.wav` sits 14 dB below `go_sleep.wav`. Lowering this is
    /// the only control over that difference.
    public var micVolume: Double = 1 {
        didSet { micSource?.volume = min(max(micVolume, 0), 10) }
    }

    /// Whether `start()` has run and `stop()` has not — what "the camera is
    /// still up" means to the audio handover when a call ends over it. True through
    /// `.stalled` too: the session holds the audio session until it is stopped.
    var isRunning: Bool {
        isStarted
    }

    /// What the OS says about recording. Published because a refusal used to be
    /// swallowed here: `setMicEnabled(true)` returned early and wrote nothing, so the
    /// button redrew itself unchanged and unmuting did nothing, forever, unexplained.
    /// The viewport reads this to say why instead.
    public internal(set) var micPermission: PermissionState = .undetermined

    /// The session's control surface. Exists from construction and stays the same
    /// object across re-negotiations, so a `RemoteControlChannel` built on it
    /// survives the self-healing restart that replaces the peer connection.
    ///
    /// Only worth driving over the relay: on the LAN the daemon's HTTP API is
    /// right there and says more.
    public let dataChannel = WebRTCDataChannel()

    /// The robot's pose, pushed rather than asked for.
    ///
    /// Daemon 1.10.0 opens a second channel labelled `pose` and, once subscribed,
    /// writes the state snapshot to it at about 30 Hz. It is deliberately
    /// unreliable and unordered — a dropped frame is replaced a thirtieth of a
    /// second later, and waiting for it would be worse than missing it — which is
    /// exactly why it is not carried on the control channel.
    ///
    /// Separate from ``dataChannel`` and not a replacement: commands still go over
    /// `data`, where a lost frame would matter.
    public let poseChannel = WebRTCDataChannel()

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    let signaling: any RobotSignaling
    let connection: RobotConnection?
    /// How long an attempt has to connect. A `var` for the tests, which shorten the
    /// stalls they cause and lengthen the attempts they expect to go through.
    @ObservationIgnored var negotiationDeadline: Duration
    /// The wait from `.stalled` to a probe; nil, and no probe, off the LAN. A `var` for the tests.
    @ObservationIgnored var probeDelay: Duration?
    private(set) var peerConnection: RTCPeerConnection?
    private var delegateAdapter: PeerConnectionDelegateAdapter?
    private var micTrack: RTCAudioTrack?
    /// Held so ``micVolume`` can move after the track is attached. The peer owns the
    /// track; nothing else keeps the source alive.
    private var micSource: RTCAudioSource?
    /// `@ObservationIgnored` because `deinit` reads it: the macro would turn a
    /// tracked property into a MainActor-isolated accessor, which a nonisolated
    /// `deinit` may not call — a stored property it may.
    @ObservationIgnored private(set) var isStarted = false
    /// The current signaling subscription. Nil before `start()`, after `stop()`, and
    /// while `.stalled` — a session that gave up asks only in a LAN probe. Ignored by
    /// observation for the reason `isStarted` is.
    @ObservationIgnored var eventsTask: Task<Void, Never>?
    /// The carrier's half of the last subscription, still being ended. A new
    /// subscription waits for it, or an `endSession` meant for the stalled session
    /// could land on its replacement.
    var ending: Task<Void, Never>?
    var deadlineTask: Task<Void, Never>?
    /// Attempts that stalled since the peer last connected, or since `start()`.
    var stalledAttempts = 0

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
        negotiationDeadline = Self.defaultNegotiationDeadline
        probeDelay = Self.defaultProbeDelay
    }

    /// Anywhere else: whatever is carrying signaling — over the Hugging Face relay
    /// there is no HTTP API to reach, and nothing to acquire.
    public convenience init(signaling: any RobotSignaling) {
        self.init(signaling: signaling, negotiationDeadline: Self.defaultNegotiationDeadline)
    }

    /// The deadline is a parameter for the tests alone: they stall on purpose, twice,
    /// and cannot wait the real one out each time.
    init(signaling: any RobotSignaling, negotiationDeadline: Duration) {
        self.signaling = signaling
        connection = nil
        self.negotiationDeadline = negotiationDeadline
    }

    /// The backstop for an owner that drops the session without `stop()`. The
    /// `weak self` in `subscribe()` is what lets this run at all — but on its own it
    /// only half-closes the leak: `eventsTask` keeps consuming, and against an
    /// unreachable robot the captured signaling client redials the socket every
    /// half-second for as long as the app lives, with the `guard let self` never
    /// reached because a dead host yields no events. A stopped (or never
    /// started) session has `isStarted == false` and nothing to undo — previews
    /// construct sessions constantly and must not touch the shared audio session.
    ///
    /// `signaling` is bound before the `Task` so the closure never captures
    /// `self`, which a `deinit` may not escape (`RobotFilesModel` sets the idiom).
    deinit {
        guard isStarted else { return }
        eventsTask?.cancel()
        dataChannel.close()
        poseChannel.close()
        let signaling = signaling
        Task { await signaling.disconnect() }
        Task { @MainActor in MediaAudioSession.shared.cameraSessionStopped() }
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        // Read before anyone can tap, so a mic already refused in Settings shows as
        // refused rather than as an ordinary muted button waiting to be pressed.
        refreshMicPermission()
        MediaAudioSession.shared.cameraSessionStarted()
        stalledAttempts = 0
        subscribe()
    }

    public func stop() {
        isStarted = false
        unsubscribe()
        disarmDeadline()
        stalledAttempts = 0
        teardownPeer()
        dataChannel.close()
        poseChannel.close()
        MediaAudioSession.shared.cameraSessionStopped()
        phase = .connecting
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

    func handle(_ event: SignalingEvent) async {
        switch event {
        case .waitingForProducer:
            if phase != .streaming {
                phase = .waitingForProducer
                // Nothing to negotiate with is not a stall — the robot says so itself.
                disarmDeadline()
            }
        case .sessionRequested: sessionRequested()
        case let .offer(_, sdp):
            await accept(offerSDP: sdp)
        case let .remoteCandidate(_, candidate, sdpMLineIndex, sdpMid):
            guard let candidate = Self.iceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            else { return }
            // Late-candidate errors are expected once ICE is connected — ignore (upstream does too).
            try? await peerConnection?.add(candidate)
        case let .sessionEnded(reason):
            teardownPeer()
            // On the LAN the client re-negotiates on its own, so this is a lull
            // rather than an ending. Over the relay central says why, and there is
            // nothing further coming — which is also the line the control channel
            // is drawn on: a lull leaves its commands waiting, an ending fails them.
            guard let reason else {
                phase = .connecting
                // Still one attempt, on the clock it already had, if any.
                armDeadlineIfIdle()
                return
            }
            let end = RemoteSessionEnd(reason: reason)
            // The robot's own watchdog gave up on this attempt — the same stall,
            // seen from the other end, and as worth one more try.
            guard !end.isNegotiationStall else {
                negotiationStalled()
                return
            }
            disarmDeadline()
            dataChannel.close()
            poseChannel.close()
            phase = .failed(end.message)
        case let .failed(message):
            disarmDeadline()
            teardownPeer()
            dataChannel.close()
            poseChannel.close()
            phase = .failed(message)
        }
    }

    private func accept(offerSDP: String) async {
        teardownPeer()
        phase = .connecting
        armDeadlineIfIdle()

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
            disarmDeadline()
            phase = .failed("Could not create peer connection")
            return
        }
        delegateAdapter = adapter
        peerConnection = peer

        // Each `guard peer === peerConnection` is a restart that landed during the
        // await before it: this peer is closed and its attempt over, and nothing it
        // goes on to do may touch the one that replaced it.
        do {
            try await peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offerSDP))
            guard peer === peerConnection else { return }
            attachMicTrack(to: peer)
            let answer = try await peer.answer(for: Self.noConstraints)
            try await peer.setLocalDescription(answer)
            guard peer === peerConnection else { return }
            await signaling.send(answerSDP: answer.sdp)
            guard peer === peerConnection else { return }
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
            guard peer === peerConnection else { return }
            disarmDeadline()
            phase = .failed(error.localizedDescription)
            teardownPeer()
        }
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

    /// Held from the moment the offer names it, so the view is attached before the
    /// first frame — but it is no evidence of a stream; `peer(_:changedTo:)` decides that.
    func handleRemote(videoTrack: RTCVideoTrack) {
        self.videoTrack = videoTrack
    }

    // MARK: - Internals

    private func attachMicTrack(to peer: RTCPeerConnection) {
        // ponytail: the mic track is attached even while muted — gst webrtcsink
        // doesn't renegotiate consumer sessions, so audio must be in the answer
        // from the start. Verified: the OS permission prompt still fires only on
        // the first unmute (WebRTC doesn't start capture for a disabled track).
        let source = Self.factory.audioSource(with: Self.noConstraints)
        // Re-applied here rather than only in the setter: a renegotiation builds a new
        // source, and the old one's gain goes with it.
        source.volume = min(max(micVolume, 0), 10)
        let track = Self.factory.audioTrack(with: source, trackId: "reachy-mic")
        track.isEnabled = isMicEnabled
        micSource = source
        if let transceiver = peer.transceivers.first(where: { $0.mediaType == .audio }) {
            transceiver.sender.track = track
            transceiver.setDirection(.sendRecv, error: nil)
        }
        micTrack = track
    }

    /// The robot opens two: `data` for commands and `pose` for the live state it
    /// pushes. Anything else belongs to neither and is left alone.
    ///
    /// A daemon before 1.10.0 opens only the first, which is why the pose channel
    /// is allowed to stay unattached rather than being waited for. `isOpen` is what
    /// a caller reads to choose between the pushed pose and the polled one — see
    /// `ViewportModel.remotePose`.
    func adopt(_ channel: RTCDataChannel) {
        switch channel.label {
        case "data": dataChannel.attach(channel)
        case "pose": poseChannel.attach(channel)
        default: return
        }
    }

    /// The peer and everything hung on it. Not the deadline: that belongs to the
    /// attempt, which can outlive one peer — a LAN lull drops the peer and keeps going.
    func teardownPeer() {
        dataChannel.detachPeer()
        poseChannel.detachPeer()
        peerConnection?.close()
        peerConnection = nil
        delegateAdapter = nil
        micTrack = nil
        micSource = nil
        videoTrack = nil
        answerSent = false
        pendingLocalCandidates = []
    }

    private static var noConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }
}
