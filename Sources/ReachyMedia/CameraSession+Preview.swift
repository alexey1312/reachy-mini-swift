import ReachyKit

#if DEBUG
    public extension CameraSession {
        /// A session parked in one phase. Constructing one is inert — `start()` is what opens the
        /// signaling socket and builds the peer connection, and it is never called here.
        ///
        /// A file of its own because `CameraSession.swift` reached SwiftLint's length limit;
        /// the three setters it needs are `internal(set)` for exactly this.
        ///
        /// `micPermission` is a parameter because a refused microphone is a state the
        /// viewport renders differently and no preview could otherwise reach: the real
        /// value is only ever written by `start()`, which a preview must not call.
        static func preview(
            _ phase: Phase,
            micPermission: PermissionState = .undetermined,
            isMicEnabled: Bool = false
        ) -> CameraSession {
            // A well-formed host cannot fail to produce a signaling client, and nothing dials it.
            // swiftlint:disable:next force_try
            let session = try! CameraSession(address: RobotAddress(host: "192.168.1.42"))
            session.phase = phase
            session.micPermission = micPermission
            // No track exists without a peer connection, so this is the flag alone —
            // which is all the button and the chrome row read.
            session.isMicEnabled = isMicEnabled
            return session
        }
    }
#endif
