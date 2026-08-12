import Foundation
import ReachyJSON

/// `/api/apps/*`, plus the one lock route that lives under `/api/daemon/`.
///
/// Two paths, on purpose. Most routes go through the generated client, which is
/// also what guarantees `install` posts the catalogue entry back unchanged. Five
/// do not, and each for a reason the spec cannot express:
///
/// - `current-app-status` answers **200 with a literal `null`** when the robot is
///   idle. FastAPI types it `AppStatus | None`; `Scripts/normalize-openapi.py`
///   strips the null branch (the generator cannot handle it), so the generated
///   model is non-optional and throws on the one answer that matters most.
/// - `start-app`, `restart-current-app` and `robot-app-lock-status` return closed
///   enums. A state a later daemon adds would throw where it should simply be
///   carried through (project rule 3) — `RobotAppStatus` and `RobotAppLockStatus`
///   decode those defensively.
/// - `job-status` likewise, via `DaemonJob`.
/// - `stop-current-app` answers 400 with two opposite meanings in its `detail`,
///   and the generated client discards the body. Its 200 body is an untyped `{}`
///   nothing here reads, so there was nothing on the other side of the trade.
extension RobotConnection: RobotAppsClient {
    public func availableApps() async throws -> [RobotApp] {
        switch try await hubClient.listAllAvailableAppsApiAppsListAvailableGet() {
        case let .ok(response):
            return try response.body.json.map(RobotApp.init)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    public func installedApps() async throws -> [RobotApp] {
        switch try await hubClient.listAvailableAppsApiAppsListAvailableSourceKindGet(
            path: .init(sourceKind: .installed)
        ) {
        case let .ok(response):
            return try response.body.json.map(RobotApp.init)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    public func currentAppStatus() async throws -> RobotAppStatus? {
        let data = try await hubData(path: "/api/apps/current-app-status")
        // The idle answer. Decoding it as a status would throw, and "nothing is
        // running" is not an error.
        guard !Self.isJSONNull(data) else { return nil }
        return try JSONCodec.daemon.decode(RobotAppStatus.self, from: data)
    }

    /// 400 when an app already holds the robot — the caller has to stop that one
    /// first, and the screen should say which.
    public func startApp(named name: String) async throws -> RobotAppStatus {
        try await hubJSON(method: "POST", path: "/api/apps/start-app/\(name)")
    }

    public func restartCurrentApp() async throws -> RobotAppStatus {
        try await hubJSON(method: "POST", path: "/api/apps/restart-current-app")
    }

    /// 400 when nothing is running, which is what a second Stop looks like — and
    /// what an app wedged in `stopping` looks like for as long as it stays wedged.
    ///
    /// Hand-rolled like its two siblings rather than generated, and that is a
    /// change: the 200 body is an untyped `{}` this client never reads, so the
    /// generated path bought nothing, while `hubData` carries the daemon's `detail`
    /// up to the screen. Telling those two 400s apart is the whole value here.
    public func stopCurrentApp() async throws {
        _ = try await hubData(method: "POST", path: "/api/apps/stop-current-app")
    }

    /// The daemon stores this exact `AppInfo` as the app's metadata, so it goes
    /// back the way it came. Anything but a Hugging Face Space is refused with a
    /// 400 the spec never mentions.
    public func installApp(_ app: RobotApp) async throws -> String {
        switch try await hubClient.installAppApiAppsInstallPost(body: .json(app.info)) {
        case let .ok(response):
            return try Self.jobID(in: response.body.json.additionalProperties)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// A private Space is fetched with the token the robot has stored, so this
    /// answers 401 until the robot is linked to a Hugging Face account.
    public func installPrivateSpace(id spaceID: String) async throws -> String {
        switch try await hubClient.installPrivateSpaceApiAppsInstallPrivateSpacePost(
            body: .json(.init(spaceId: spaceID))
        ) {
        case let .ok(response):
            return try Self.jobID(in: response.body.json.additionalProperties)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// Removing also clears the startup app if it was this one — the daemon does
    /// that itself, so a client must not race it.
    public func removeApp(named name: String) async throws -> String {
        switch try await hubClient.removeAppApiAppsRemoveAppNamePost(path: .init(appName: name)) {
        case let .ok(response):
            return try Self.jobID(in: response.body.json.additionalProperties)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    public func updateApp(named name: String) async throws -> String {
        switch try await hubClient.updateAppApiAppsUpdateAppNamePost(path: .init(appName: name)) {
        case let .ok(response):
            return try Self.jobID(in: response.body.json.additionalProperties)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// 404 once the daemon has restarted: the job register lives in memory and
    /// does not survive it.
    public func appJob(id jobID: String) async throws -> DaemonJob {
        try await hubJSON(path: "/api/apps/job-status/\(jobID)")
    }

    public func appUpdates(force: Bool) async throws -> AppUpdatesSummary {
        switch try await hubClient.checkAppUpdatesApiAppsCheckUpdatesGet(query: .init(force: force)) {
        case let .ok(response):
            return try AppUpdatesSummary(response.body.json)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    public func startupApp() async throws -> String? {
        switch try await hubClient.getStartupAppApiAppsStartupAppGet() {
        case let .ok(response):
            return try response.body.json.startupApp
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// `nil` clears it. Refused with a 400 for an app that is not installed.
    @discardableResult
    public func setStartupApp(_ name: String?) async throws -> String? {
        switch try await hubClient.setStartupAppApiAppsStartupAppPut(body: .json(.init(startupApp: name))) {
        case let .ok(response):
            return try response.body.json.startupApp
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    public func appLockStatus() async throws -> RobotAppLockStatus {
        try await hubJSON(path: "/api/daemon/robot-app-lock-status")
    }

    private static func jobID(in payload: [String: String]) throws -> String {
        guard let jobID = payload["job_id"], !jobID.isEmpty else {
            throw ReachyKitError.daemonRejected(statusCode: 200)
        }
        return jobID
    }

    private static func isJSONNull(_ data: Data) -> Bool {
        guard let text = String(bytes: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "null"
    }
}

extension RobotConnection {
    func hubJSON<T: Decodable>(method: String = "GET", path: String) async throws -> T {
        try await JSONCodec.daemon.decode(T.self, from: hubData(method: method, path: path))
    }

    /// Unlike `wirelessData`, a 404 here is the resource's absence — a forgotten
    /// job — not a route that was never mounted, so it is reported as itself.
    func hubData(method: String = "GET", path: String) async throws -> Data {
        guard let url = address.httpURL(path: path) else {
            throw ReachyKitError.invalidAddress(address)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method

        let (data, response) = try await hubSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReachyKitError.daemonRejected(statusCode: -1)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            // The refusals on this surface are the ones a person has to act on, and
            // the daemon words them itself: "No app is currently running" against
            // "An app is already running" are the same 400 and mean opposite things.
            // Reporting only the status left both reading `HTTP 400`.
            throw ReachyKitError.fromStatusCode(http.statusCode, detail: ReachyKitError.detail(in: data))
        }
        return data
    }
}
