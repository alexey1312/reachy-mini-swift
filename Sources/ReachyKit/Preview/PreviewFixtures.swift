#if DEBUG
    import Foundation
    import ReachyJSON

    /// Daemon double for previews and snapshots. Answers the reads a frozen screen performs and
    /// leaves everything that would move a robot on the protocol's throwing defaults.
    public struct PreviewRobotClient: RobotAPIClient {
        public var identity: RobotIdentity
        public var status: Components.Schemas.DaemonStatus
        public var moves: [String]
        public var speaker: AudioLevel
        public var microphone: AudioLevel
        public var wifi: WiFiStatus
        public var wifiError: String?

        public init(
            identity: RobotIdentity = .preview,
            status: Components.Schemas.DaemonStatus = .preview(),
            moves: [String] = [],
            speaker: AudioLevel = .previewSpeaker,
            microphone: AudioLevel = .previewMicrophone,
            wifi: WiFiStatus = .preview,
            wifiError: String? = nil
        ) {
            self.identity = identity
            self.status = status
            self.moves = moves
            self.speaker = speaker
            self.microphone = microphone
            self.wifi = wifi
            self.wifiError = wifiError
        }

        public func handshake() async throws -> RobotConnection.Handshake {
            .init(identity: identity, status: status)
        }

        public func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
            status
        }

        public func wakeUp() async throws -> String {
            "preview-wake"
        }

        public func gotoSleep() async throws -> String {
            "preview-sleep"
        }

        public func listMoves(dataset _: String) async throws -> [String] {
            moves
        }

        public func runningMoveUUIDs() async throws -> Set<String> {
            []
        }

        public func volume() async throws -> AudioLevel {
            speaker
        }

        public func microphoneVolume() async throws -> AudioLevel {
            microphone
        }
    }

    /// `RobotScreen` decides whether to offer the joystick and the log console by testing the
    /// client for these, exactly as it decides everything else — so a preview of a LAN robot
    /// needs a client that speaks them. Both are inert: a preview must never open a socket.
    extension PreviewRobotClient: TeleopClient, DaemonLogClient {
        public func makeTeleop() throws -> any TeleopChannel {
            PreviewTeleopChannel()
        }

        public func daemonLogLines() throws -> AsyncStream<String> {
            AsyncStream { $0.finish() }
        }
    }

    /// `SettingsScreen` tests the client for this before drawing the Maintenance
    /// section, so without the conformance `canPerformMaintenance` is false in
    /// every preview and the section is missing from `Settings — wireless robot`
    /// while `Settings — Lite robot` proves nothing about the gate. Both actions
    /// throw: a preview must never ask a robot to delete anything, and nothing in
    /// a captured frame taps a button behind a confirmation dialog.
    extension PreviewRobotClient: CacheMaintenanceClient {
        public func clearHuggingFaceCache() async throws {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }

        public func resetApps() async throws {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
    }

    /// Accepts targets and does nothing with them.
    public struct PreviewTeleopChannel: TeleopChannel {
        public init() {}

        public func connect() async {}

        public func send(_: TeleopTarget) async {}

        public func disconnect() async {}
    }

    /// What a relay session actually is, as a preview fixture: the commands and the camera, and
    /// none of the HTTP surface. Its conformances are `RemoteRobotConnection`'s — no apps, no
    /// Wi-Fi, no update, no robot Hugging Face account — so a preview of a remote robot closes
    /// the same screens the real one does.
    public struct PreviewRemoteRobotClient: RobotAPIClient, TeleopClient, DaemonLogClient {
        public var identity: RobotIdentity
        public var status: Components.Schemas.DaemonStatus
        public var logLines: [String]

        public init(
            identity: RobotIdentity = .preview,
            status: Components.Schemas.DaemonStatus = .preview(wirelessVersion: false),
            logLines: [String] = []
        ) {
            self.identity = identity
            self.status = status
            self.logLines = logLines
        }

        public func handshake() async throws -> RobotConnection.Handshake {
            .init(identity: identity, status: status, supportsRename: false)
        }

        public func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
            status
        }

        public func wakeUp() async throws -> String {
            ""
        }

        public func gotoSleep() async throws -> String {
            ""
        }

        public func makeTeleop() throws -> any TeleopChannel {
            PreviewTeleopChannel()
        }

        public func daemonLogLines() throws -> AsyncStream<String> {
            let lines = logLines
            return AsyncStream { continuation in
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }
    }

    /// `SettingsScreen` decides whether to draw its network section by testing the client for
    /// this protocol, so a preview of that section needs a client that conforms — the read
    /// side answers from the fixture, and everything that would change the robot throws.
    extension PreviewRobotClient: WiFiConfigClient {
        public func wifiStatus() async throws -> WiFiStatus {
            wifi
        }

        public func lastWiFiError() async throws -> String? {
            wifiError
        }

        public func provisioningKey() async throws -> WiFiProvisioningKey {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }

        public func scanNetworks() async throws -> [String] {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }

        public func connectSealed(_: SealedWiFiCredentials) async throws {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }

        public func forget(ssid _: String) async throws {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }

        public func forgetAll() async throws {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }

        public func resetWiFiError() async throws {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
    }

    public extension CentralRobot {
        /// Decoded rather than constructed: `CentralRobot` is `Decodable` only, so
        /// central's own wire shape is the thing to pin a fixture to.
        static func preview(
            peerID: String = "peer-preview",
            name: String = "Reachy Mini",
            hardwareID: String = "a1b2c3d4e5f60718",
            transport: String = "wifi",
            isBusy: Bool = false,
            activeApp: String? = nil
        ) -> CentralRobot {
            let app = activeApp.map { #""activeApp":"\#($0)","# } ?? ""
            let json = """
            {"peerId":"\(peerID)","robotName":"\(name)","busy":\(isBusy),\(app)
             "meta":{"name":"\(name)","transport":"\(transport)","hardware_id":"\(hardwareID)"}}
            """
            // A fixture that cannot decode is a broken fixture, not a runtime path.
            // swiftlint:disable:next force_try
            return try! JSONCodec.daemon.decode(CentralRobot.self, from: Data(json.utf8))
        }
    }

    public extension RobotIdentity {
        static let preview = RobotIdentity(hardwareID: "hw-preview", name: "Reachy Mini", daemonVersion: "1.9.0")
    }

    public extension AudioLevel {
        static let previewSpeaker = AudioLevel(percent: 65, platform: "pulseaudio", device: "Built-in Speaker")
        static let previewMicrophone = AudioLevel(percent: 40, platform: "pulseaudio", device: "Built-in Microphone")
    }

    public extension WiFiStatus {
        static let preview = WiFiStatus(mode: .wlan, connected: "Home", known: ["Home", "Cafe", "Hotspot"])
    }

    public extension RobotSession.MovePlayback {
        static func preview(
            move: String,
            dataset: String = "pollen-robotics/reachy-mini-dances-library",
            uuid: String = "preview-playback"
        ) -> RobotSession.MovePlayback {
            .init(uuid: uuid, identity: .init(dataset: dataset, move: move))
        }

        /// Playback adopted from `/api/move/running`, which names nothing.
        static func preview(uuid: String) -> RobotSession.MovePlayback {
            .init(uuid: uuid, identity: nil)
        }
    }

    public extension RobotSession {
        /// A session parked in one state, with no polling task and no path monitor.
        ///
        /// Previews must be final on their first frame — Prefire captures synchronously, and the
        /// delay it offers comes from a module ReachyUI cannot import without breaking the macOS
        /// build. So nothing here connects; the phase is simply assigned.
        static func preview(
            phase: ConnectionPhase = .connected(.preview),
            status: Components.Schemas.DaemonStatus? = .preview(),
            address: RobotAddress? = RobotAddress(host: "192.168.1.42"),
            // Overrides `address` where the transport is the point. Defaulted from
            // `address` so every preview written before the relay existed still
            // parks the session exactly where it did.
            link: Link? = nil,
            error: String? = nil,
            powerTransition: PowerTransition? = nil,
            compatibilityWarning: String? = nil,
            moveActivity: MoveActivity? = nil,
            // The dock is mounted on the root, so every root preview needs a way to
            // reach a state that otherwise requires an app running on a real robot.
            runningApp: RobotAppStatus? = nil,
            automaticConnectionAllowed: Bool = true,
            supportsRename: Bool = true,
            // Defaulted: nil is the Link row before the first poll ever answered.
            roundTrip: Duration? = .milliseconds(12),
            client: any RobotAPIClient = PreviewRobotClient()
        ) -> RobotSession {
            let session = RobotSession { _ in client }
            session.supportsRename = supportsRename
            // Claimed without connecting: the capability flags a screen asks about
            // (`canConfigureWiFi`, `canManageApps`, `canLinkHuggingFace`) are all
            // "does this client speak that protocol", and a nil client answers no
            // to every one of them.
            session.client = client
            session.phase = phase
            session.lastStatus = status
            session.link = link ?? address.map(RobotSession.Link.lan) ?? .none
            session.robotError = error
            session.powerTransition = powerTransition
            session.compatibilityWarning = compatibilityWarning
            session.moveActivity = moveActivity
            session.runningApp = runningApp
            session.automaticConnectionAllowed = automaticConnectionAllowed
            session.lastRoundTrip = roundTrip
            return session
        }
    }

    /// A radio that is switched on and never hears anything. `FakeBLETransport` replays the
    /// GATT exchange to drive a protocol test; this one exists so a `BLELink` can be built
    /// at all, and every state a screen renders is set on the link directly.
    ///
    /// The two write lengths are the pair `OnboardingJoinStep` prints, at the values a
    /// current iPhone reports.
    public final class PreviewBLETransport: BLETransport {
        public let availability: BLEAvailability
        public let discovered: [BLEPeripheralSnapshot]
        public let maximumWriteLength: Int
        public let attributeWriteLength: Int

        public init(
            availability: BLEAvailability = .ready,
            discovered: [BLEPeripheralSnapshot] = [],
            maximumWriteLength: Int = 182,
            attributeWriteLength: Int = 512
        ) {
            self.availability = availability
            self.discovered = discovered
            self.maximumWriteLength = maximumWriteLength
            self.attributeWriteLength = attributeWriteLength
        }

        public func startScan() throws {}

        public func stopScan() {}

        public func connect(_: UUID) async throws {}

        public func disconnect() {}

        public func setNotify(_: Bool, for _: BLECharacteristicID) async throws {}

        public func write(_: Data, to _: BLECharacteristicID) async throws {
            throw BLETransportError.notConnected
        }

        public func read(_ characteristic: BLECharacteristicID) async throws -> Data {
            throw BLETransportError.characteristicMissing(characteristic)
        }

        /// Finished rather than open: `BLELink.observe()` iterates this on `init`, and a
        /// stream that never ends would leave a task alive behind every preview card.
        public func notifications() -> AsyncStream<Data> {
            AsyncStream { $0.finish() }
        }

        public func events() -> AsyncStream<BLETransportEvent> {
            AsyncStream { $0.finish() }
        }
    }
#endif
