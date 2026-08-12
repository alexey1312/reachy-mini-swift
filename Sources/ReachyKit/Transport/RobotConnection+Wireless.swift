import Foundation
import ReachyJSON

/// Routes that exist only on a Reachy Mini Wireless.
///
/// `/update/*` and `/wifi/*` are mounted only when the daemon runs with
/// `--wireless-version`, and they sit at the app root rather than under `/api`.
/// The committed `openapi.json` is generated without that flag, so the generated
/// client has no idea they exist — these are hand-written, like the WebSocket
/// clients next door. A Lite robot answers 404, which surfaces as
/// `wirelessFeaturesUnavailable` rather than a bare status code.
extension RobotConnection: DaemonUpdateClient {
    public func availableUpdate(preRelease: Bool) async throws -> DaemonUpdateAvailability {
        let response: DaemonUpdateAvailability.Response = try await wirelessJSON(
            path: "/update/available",
            queryItems: [preReleaseItem(preRelease)]
        )
        guard let availability = response.availability else {
            throw ReachyKitError.daemonRejected(statusCode: 200)
        }
        return availability
    }

    public func startUpdate(preRelease: Bool) async throws -> String {
        struct StartedJob: Decodable {
            let jobId: String

            enum CodingKeys: String, CodingKey {
                case jobId = "job_id"
            }
        }
        let started: StartedJob = try await wirelessJSON(
            method: "POST",
            path: "/update/start",
            queryItems: [preReleaseItem(preRelease)]
        )
        return started.jobId
    }

    public func updateInfo(jobID: String) async throws -> DaemonUpdateJob {
        try await wirelessJSON(
            path: "/update/info",
            queryItems: [URLQueryItem(name: "job_id", value: jobID)],
            canReport404: true
        )
    }

    private func preReleaseItem(_ preRelease: Bool) -> URLQueryItem {
        // FastAPI parses the lowercase spelling; "True"/"1" are not accepted for bools.
        URLQueryItem(name: "pre_release", value: preRelease ? "true" : "false")
    }
}

extension RobotConnection {
    func wirelessJSON<T: Decodable>(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        canReport404: Bool = false
    ) async throws -> T {
        let data = try await wirelessData(
            method: method,
            path: path,
            queryItems: queryItems,
            body: body,
            canReport404: canReport404
        )
        return try JSONCodec.daemon.decode(T.self, from: data)
    }

    /// - Parameter canReport404: whether this route can legitimately answer 404 for a
    ///   resource that is simply absent. Everywhere else a 404 means the route was never
    ///   mounted, which is what a Lite robot looks like.
    @discardableResult
    func wirelessData(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        canReport404: Bool = false
    ) async throws -> Data {
        guard let url = address.httpURL(path: path, queryItems: queryItems) else {
            throw ReachyKitError.invalidAddress(address)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await wirelessSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReachyKitError.daemonRejected(statusCode: -1)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 404, !canReport404 {
                throw ReachyKitError.wirelessFeaturesUnavailable
            }
            throw ReachyKitError.fromStatusCode(http.statusCode)
        }
        return data
    }
}
