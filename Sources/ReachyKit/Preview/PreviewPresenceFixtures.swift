#if DEBUG
    import Foundation

    /// Same reason as the conformance above: `canControlPresence` asks the client
    /// whether it speaks this protocol, so without it every presence control is
    /// missing from every reference and the gate is covered by nothing.
    ///
    /// Both succeed rather than throwing, unlike maintenance: nothing is deleted,
    /// and a preview of the controls is a preview of them working.
    extension PreviewRobotClient: PresenceClient {
        public func setWobbling(_: Bool) async throws {}

        public func setFaceTracking(_ enabled: Bool, weight _: Double) async throws -> Bool {
            enabled
        }

        /// Nobody in front of a preview's camera. The states worth drawing are seeded
        /// on `PresenceModel` itself, which is where the poll's answer lands.
        public func trackedFace() async throws -> RobotFaceTarget? {
            nil
        }
    }
#endif
