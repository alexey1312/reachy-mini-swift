// stasel/WebRTC ships no tvOS or visionOS slice, so those two platforms link LiveKit's
// build of the same library instead (`Package.swift`). LiveKit builds it with
// `RTC_OBJC_TYPE_PREFIX` set to `LK`, so every class, protocol, enum and the SSL
// functions carry the prefix. These names let the rest of this target spell each type
// one way on all four platforms.
//
// Public because the public API names some of them (`CameraSession.videoTrack`,
// `CameraVideoView.init(track:)`, the `RTCDataChannelDelegate` conformance). An enum
// that is only ever inferred (`RTCSdpType`, `RTCDataChannelState`) needs no name here:
// Swift strips the prefix from the cases, so `.answer` and `.open` read the same.
#if os(tvOS) || os(visionOS)
    @preconcurrency import LiveKitWebRTC

    public typealias RTCAudioSession = LKRTCAudioSession
    public typealias RTCAudioSource = LKRTCAudioSource
    public typealias RTCAudioTrack = LKRTCAudioTrack
    public typealias RTCConfiguration = LKRTCConfiguration
    public typealias RTCDataBuffer = LKRTCDataBuffer
    public typealias RTCDataChannel = LKRTCDataChannel
    public typealias RTCDataChannelConfiguration = LKRTCDataChannelConfiguration
    public typealias RTCDataChannelDelegate = LKRTCDataChannelDelegate
    public typealias RTCDefaultVideoDecoderFactory = LKRTCDefaultVideoDecoderFactory
    public typealias RTCDefaultVideoEncoderFactory = LKRTCDefaultVideoEncoderFactory
    public typealias RTCIceCandidate = LKRTCIceCandidate
    public typealias RTCIceConnectionState = LKRTCIceConnectionState
    public typealias RTCIceGatheringState = LKRTCIceGatheringState
    public typealias RTCIceServer = LKRTCIceServer
    public typealias RTCMediaConstraints = LKRTCMediaConstraints
    public typealias RTCMediaStream = LKRTCMediaStream
    public typealias RTCPeerConnection = LKRTCPeerConnection
    public typealias RTCPeerConnectionDelegate = LKRTCPeerConnectionDelegate
    public typealias RTCPeerConnectionFactory = LKRTCPeerConnectionFactory
    public typealias RTCPeerConnectionState = LKRTCPeerConnectionState
    public typealias RTCRtpReceiver = LKRTCRtpReceiver
    public typealias RTCSessionDescription = LKRTCSessionDescription
    public typealias RTCSignalingState = LKRTCSignalingState
    public typealias RTCVideoRenderer = LKRTCVideoRenderer
    public typealias RTCVideoTrack = LKRTCVideoTrack

    #if os(tvOS)
        /// visionOS has no Metal view in its slice; `SampleBufferVideoView` draws there.
        public typealias RTCMTLVideoView = LKRTCMTLVideoView
    #endif

    @discardableResult
    func RTCInitializeSSL() -> Bool {
        LKRTCInitializeSSL()
    }
#endif
