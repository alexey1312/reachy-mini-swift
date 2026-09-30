import Foundation

/// `/api/hf-auth/*`.
///
/// The two token routes go through the generated client, which is what puts the
/// token in a JSON body rather than anywhere it could be logged. The other four
/// are declared `additionalProperties: true` in the spec, so the generated client
/// hands back an untyped container — decoding the raw payload directly costs less
/// than re-encoding that container, and lets every enum stay tolerant of a value
/// a later daemon invents (project rule 3).
extension RobotConnection: HFAuthClient {
    public func hfAuthStatus() async throws -> HFAuthStatus {
        try await hubJSON(path: "/api/hf-auth/status")
    }

    /// 400 when the Hub refuses the token — the daemon runs `whoami` before it
    /// stores anything.
    @discardableResult
    public func saveHFToken(_ token: String) async throws -> String? {
        switch try await hubClient.saveTokenApiHfAuthSaveTokenPost(body: .json(.init(token: token))) {
        case let .ok(response):
            return try response.body.json.username
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    public func deleteHFToken() async throws {
        switch try await hubClient.deleteTokenApiHfAuthTokenDelete() {
        case .ok:
            return
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    public func relayStatus() async throws -> RelayStatus {
        try await hubJSON(path: "/api/hf-auth/relay-status")
    }

    @discardableResult
    public func refreshRelay() async throws -> RelayRefresh {
        try await hubJSON(method: "POST", path: "/api/hf-auth/refresh-relay")
    }

    public func centralRobotStatus() async throws -> CentralRobotStatusProxy {
        try await hubJSON(path: "/api/hf-auth/central-robot-status")
    }

    public func startDeviceLogin() async throws -> RobotDeviceLogin {
        try await hubJSON(method: "POST", path: "/api/hf-auth/oauth/device/start")
    }

    public func deviceLoginStatus(sessionID: String) async throws -> RobotDeviceLoginStatus {
        try await hubJSON(path: "/api/hf-auth/oauth/device/status/\(Self.pathComponent(sessionID))")
    }

    /// 404 for a session the daemon has already dropped, which is the outcome a
    /// cancel wanted anyway.
    public func cancelDeviceLogin(sessionID: String) async throws {
        do {
            _ = try await hubData(
                method: "DELETE",
                path: "/api/hf-auth/oauth/device/session/\(Self.pathComponent(sessionID))"
            )
        } catch let error as ReachyKitError where error.statusCode == 404 {
            return
        }
    }

    /// The daemon's ids are hex, but an id is still the robot's text and ends up in
    /// a path.
    private static func pathComponent(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id
    }
}
