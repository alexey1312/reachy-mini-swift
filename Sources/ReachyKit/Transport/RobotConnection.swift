import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import ReachyJSON

/// Owns the HTTP client for one robot daemon and performs the connection handshake.
///
/// The handshake establishes robot identity (hardware id, display name) and daemon
/// version before anything else — the version drives graceful degradation, and the
/// hardware id is the only safe way to deduplicate robots seen at several addresses.
public actor RobotConnection {
    public let address: RobotAddress
    /// Not `private`: the wake, sleep and daemon-lifecycle routes live in
    /// `RobotConnection+Power`, a sibling file, the same way `/wifi/*` lives in
    /// `RobotConnection+Wireless`.
    let client: Client
    /// The readiness probe reads a status code, never a body, so it deliberately
    /// bypasses the generated client. It also gets upstream's 10 s budget rather
    /// than the 3.5 s tuned for the 3 s status poll.
    private let readinessSession: URLSession
    /// Mesh downloads run to tens of megabytes; the 3.5 s health-poll budget would
    /// abort them, so they get their own session.
    private let assetSession: URLSession
    /// `/update/*` and `/wifi/*` are answered by the robot only after it has talked to
    /// PyPI or driven `nmcli`, so they need a far longer budget than the health poll.
    /// Not `private`: the routes live in `RobotConnection+Wireless`, a sibling file.
    let wirelessSession: URLSession
    /// Everything the robot answers only after talking to Hugging Face: the app
    /// catalogue, which the daemon budgets at 30 s
    /// (`apps/sources/hf_space.REQUEST_TIMEOUT`), and `/api/hf-auth/*`, whose
    /// status route runs a `whoami` on every call. Under the 3.5 s health-poll
    /// budget neither would ever load.
    let hubSession: URLSession
    /// The generated client again, on that longer budget — the transport carries
    /// the timeout, so one `Client` cannot serve both.
    let hubClient: Client

    public init(address: RobotAddress, session: URLSession? = nil) throws {
        guard let serverURL = address.rootURL else {
            throw ReachyKitError.invalidAddress(address)
        }
        self.address = address

        func makeSession(timeout: TimeInterval, resourceTimeout: TimeInterval? = nil) -> URLSession {
            // An injected session belongs to a test harness — reuse it so stubbed
            // protocols still intercept every request. It is also how an App Intent
            // caps every budget at once (`RobotIntentTarget.connection(timeout:)`):
            // the 35 s hub session is meant for a screen with a spinner, and an
            // intent that waited it out would be killed before writing anything.
            if let session {
                return session
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            if let resourceTimeout {
                configuration.timeoutIntervalForResource = resourceTimeout
            }
            return URLSession(configuration: configuration)
        }

        /// Generated routes exchange finite JSON. The actual streams use their own
        /// clients, so avoid URLSession's bidirectional upload path here: on macOS 15
        /// its response callbacks can race a custom URLProtocol used by tests.
        func makeTransport(_ session: URLSession) -> URLSessionTransport {
            URLSessionTransport(
                configuration: .init(session: session, httpBodyProcessingMode: .buffered)
            )
        }

        client = Client(
            serverURL: serverURL,
            transport: makeTransport(makeSession(timeout: 3.5))
        )
        readinessSession = makeSession(timeout: 10)
        assetSession = makeSession(timeout: 20, resourceTimeout: 120)
        wirelessSession = makeSession(timeout: 15)
        let hubSession = makeSession(timeout: 35)
        self.hubSession = hubSession
        hubClient = Client(
            serverURL: serverURL,
            transport: makeTransport(hubSession)
        )
    }

    /// Result of a successful handshake with the daemon.
    public struct Handshake: Sendable {
        public let identity: RobotIdentity
        public let status: Components.Schemas.DaemonStatus
        public let compatibility: DaemonCompatibility
        /// Whether `/api/daemon/robot-name` is mounted at all — the route postdates
        /// daemon 1.9.0, which is still the minimum this app supports.
        public let supportsRename: Bool

        public init(
            identity: RobotIdentity,
            status: Components.Schemas.DaemonStatus,
            compatibility: DaemonCompatibility? = nil,
            supportsRename: Bool = true
        ) {
            self.identity = identity
            self.status = status
            self.compatibility = compatibility ?? DaemonCompatibilityPolicy.evaluate(identity.daemonVersion)
            self.supportsRename = supportsRename
        }
    }

    /// An unsupported version is reported, not thrown. The daemon's own update route
    /// is the way out of that state, and throwing here left the user on a "Try again"
    /// button that could never work. `RobotSession` gates the command surface on the
    /// verdict instead — see ADR 0001.
    public func handshake() async throws -> Handshake {
        let status = try await daemonStatus()
        let compatibility = DaemonCompatibilityPolicy.evaluate(status.version)
        let hardwareID = await hardwareID(reportedIn: status)
        let displayName = await robotDisplayName()

        return Handshake(
            identity: RobotIdentity(
                hardwareID: hardwareID,
                name: displayName.name ?? status.robotName,
                daemonVersion: status.version
            ),
            status: status,
            compatibility: compatibility,
            supportsRename: displayName.routeExists
        )
    }

    /// Reads the display name, and doubles as the probe for whether this daemon can be
    /// renamed at all: 1.9.0 mounts neither verb of `/api/daemon/robot-name`, so the
    /// route's own 404 is the only signal — the version alone does not distinguish it
    /// from a newer daemon still reporting `1.9.0`.
    ///
    /// Only a 404 counts. Any other failure says nothing about the route, and treating
    /// it as absence would grey out the field for a robot that renames perfectly well.
    private func robotDisplayName() async -> (name: String?, routeExists: Bool) {
        do {
            switch try await client.getRobotDisplayNameApiDaemonRobotNameGet() {
            case let .ok(response):
                return try (response.body.json.name, true)
            case let .undocumented(statusCode, _):
                return (nil, statusCode != 404)
            }
        } catch {
            return (nil, true)
        }
    }

    /// The one value the daemon files under `hardware_id` — `sha256(usb serial)[:16]`.
    ///
    /// It must reach `RobotIdentity` unreshaped: the same string is what the robot
    /// hands out over BLE and advertises as the mDNS `unit_id`, so a robot provisioned
    /// over Bluetooth is recognised on the LAN by comparing it. The status payload
    /// already carries it; the dedicated route covers daemons that leave it out. A
    /// daemon with no robot attached answers `{"hardware_id": null}`, which the
    /// generated `[String: String]` map rejects — that is "no hardware id", not a
    /// failed handshake.
    private func hardwareID(reportedIn status: Components.Schemas.DaemonStatus) async -> String? {
        if let reported = status.hardwareId, !reported.isEmpty {
            return reported
        }
        let map = try? await client.getRobotHardwareIdApiDaemonHardwareIdGet()
            .ok.body.json.additionalProperties
        return map?["hardware_id"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One-shot full state via REST — fallback only; prefer `StateStreamClient`.
    public func fullState() async throws -> Components.Schemas.FullState {
        switch try await client.getFullStateApiStateFullGet() {
        case let .ok(response):
            return try response.body.json
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// The readiness gate. `daemonStatus().state == .running` flips before the
    /// backend finishes coming up; this route is guarded by the daemon's
    /// `get_backend`, which answers 503 until `backend.ready` is set — so a 200
    /// here is the first honest "the robot can be driven" signal.
    ///
    /// Only the status code carries that signal, so the body is never decoded:
    /// going through the generated client made readiness depend on whether our
    /// schema could parse the payload, and a live daemon serves `last_alive` in a
    /// format the generated ISO-8601 date decoder rejects — a ready robot then
    /// looked like a failed connection.
    public func probeBackendReady() async throws {
        guard let url = address.httpURL(path: "/api/state/full") else {
            throw ReachyKitError.invalidAddress(address)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (_, response) = try await readinessSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReachyKitError.daemonRejected(statusCode: -1)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ReachyKitError.fromStatusCode(http.statusCode)
        }
    }

    public func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        switch try await client.getDaemonStatusApiDaemonStatusGet() {
        case let .ok(response):
            return try response.body.json
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// Returns the name the daemon actually stored. It persists it and re-advertises
    /// mDNS without a restart, and rejects an empty or over-long name with a 422.
    public func setRobotName(_ name: String) async throws -> String {
        switch try await client.setRobotDisplayNameApiDaemonRobotNamePost(
            body: .json(.init(name: name))
        ) {
        case let .ok(response):
            return try response.body.json.name ?? name
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            if statusCode == 404 {
                throw ReachyKitError.renameUnavailable
            }
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    // MARK: Recorded moves (dances / emotions / music libraries)

    /// Move names available in a HF dataset, e.g. `pollen-robotics/reachy-mini-dances-library`.
    public func listMoves(dataset: String) async throws -> [String] {
        try await client.listRecordedMoveDatasetApiMoveRecordedMoveDatasetsListDatasetNameGet(
            path: .init(datasetName: dataset)
        ).ok.body.json
    }

    /// Starts a recorded move; returns its UUID for `stopMove`.
    public func playMove(dataset: String, move: String) async throws -> String {
        try await client.playRecordedMoveDatasetApiMovePlayRecordedMoveDatasetDatasetNameMoveNamePost(
            path: .init(datasetName: dataset, moveName: move)
        ).ok.body.json.uuid
    }

    /// Authoritative daemon view of tasks still running, used to detect natural completion.
    public func runningMoveUUIDs() async throws -> Set<String> {
        let moves = try await client.getRunningMovesApiMoveRunningGet().ok.body.json
        return Set(moves.map(\.uuid))
    }

    /// The daemon's own definition of the zero pose, in the units the `goto` route
    /// takes.
    ///
    /// **The antennas are not vertical, and that is deliberate upstream.**
    /// `reachy_mini.INIT_ANTENNAS_JOINT_POSITIONS` is `[-0.1745, 0.1745]` — ~±10°,
    /// carrying the comment "to reduce shaking at vertical" — and it is what the
    /// daemon sends itself when an app releases the robot. This used to be
    /// `[0.0, 0.0]`, which is a second definition of "base" that no reader could
    /// tell from the first except by watching the antennas twitch.
    static let zeroAntennas: [Double] = [-0.1745, 0.1745]

    /// The zero pose, sent as one `goto` rather than as a teleop target: the daemon
    /// ignores `set_target` while a move is running, and this is what runs right
    /// after one. Every axis is named explicitly — an omitted field means "leave
    /// this one where it is", and the whole point is that nothing is left behind.
    public func gotoNeutral(duration: TimeInterval) async throws -> String {
        // `head_pose` is an `anyOf` of two pose shapes, which the generator renders
        // as a struct with one optional per branch rather than as an enum — filling
        // `value1` is how the flat XYZRPY form is chosen. `antennas` is a
        // `prefixItems` tuple, and the generator has no type for that either.
        try await client.gotoApiMoveGotoPost(
            body: .json(.init(
                headPose: .init(value1: .init(x: 0, y: 0, z: 0, roll: 0, pitch: 0, yaw: 0)),
                antennas: OpenAPIRuntime.OpenAPIArrayContainer(unvalidatedValue: Self.zeroAntennas),
                bodyYaw: 0,
                duration: duration
            ))
        ).ok.body.json.uuid
    }

    public func stopMove(uuid: String) async throws {
        _ = try await client.stopMoveApiMoveStopPost(body: .json(.init(uuid: uuid))).ok
    }

    /// Recorded music is owned by the daemon's media player, separately from the move task.
    public func stopSound() async throws {
        _ = try await client.stopSoundApiMediaStopSoundPost().ok
    }

    // MARK: Audio levels

    public func volume() async throws -> AudioLevel {
        try await AudioLevel(client.getVolumeApiVolumeCurrentGet().ok.body.json)
    }

    /// Note that the daemon plays a test sound on every accepted call, so this
    /// belongs at the end of a slider gesture, never on each change.
    public func setVolume(_ percent: Int) async throws -> AudioLevel {
        switch try await client.setVolumeApiVolumeSetPost(body: .json(.init(volume: percent))) {
        case let .ok(response):
            return try AudioLevel(response.body.json)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    public func microphoneVolume() async throws -> AudioLevel {
        try await AudioLevel(client.getMicrophoneVolumeApiVolumeMicrophoneCurrentGet().ok.body.json)
    }

    public func setMicrophoneVolume(_ percent: Int) async throws -> AudioLevel {
        switch try await client.setMicrophoneVolumeApiVolumeMicrophoneSetPost(body: .json(.init(volume: percent))) {
        case let .ok(response):
            return try AudioLevel(response.body.json)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    public func playTestSound() async throws {
        _ = try await client.playTestSoundApiVolumeTestSoundPost().ok
    }

    /// The robot's own URDF, about 250 KB of XML wrapped in a one-key JSON object.
    /// Geometry comes from the robot rather than the app bundle, so the model
    /// always matches the machine in front of the user.
    public func urdf() async throws -> String {
        let payload = try await client.getUrdfApiKinematicsUrdfGet().ok.body.json.additionalProperties
        guard let xml = payload["urdf"], !xml.isEmpty else {
            throw ReachyKitError.daemonRejected(statusCode: 200)
        }
        return xml
    }

    /// A mesh referenced by the URDF, as raw bytes.
    ///
    /// The generated client cannot fetch this: it declares `application/json` for
    /// every response and sends a matching `Accept`, while the daemon answers
    /// `model/stl` — the runtime rejects the reply before reading a byte.
    public func stlAsset(named filename: String) async throws -> Data {
        guard let url = address.httpURL(path: "/api/kinematics/stl/\(filename)") else {
            throw ReachyKitError.invalidAddress(address)
        }
        let (data, response) = try await assetSession.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw ReachyKitError.fromStatusCode(http.statusCode)
        }
        guard !data.isEmpty else {
            throw URLError(.zeroByteResource)
        }
        return data
    }

    /// Which kinematics engine the daemon runs — the one thing that decides
    /// whether `passive_joints` ever arrives populated.
    public func kinematicsInfo() async throws -> KinematicsInfo {
        let container = try await client.getKinematicsInfoApiKinematicsInfoGet().ok.body.json
        let data = try JSONCodec.daemon.encode(container)
        return try JSONCodec.daemon.decode(KinematicsInfo.self, from: data)
    }

    /// Re-acquires camera/audio hardware for the daemon's WebRTC producer.
    /// The simulator registers no producer until this is called; on a real
    /// robot it's a harmless no-op when media is already held.
    public func acquireMedia() async throws {
        _ = try await client.acquireMediaApiMediaAcquirePost().ok
    }
}
