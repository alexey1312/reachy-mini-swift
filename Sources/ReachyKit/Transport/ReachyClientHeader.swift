import Foundation
import HTTPTypes
import OpenAPIRuntime

/// How this app names itself to the robot: the `X-Reachy-Client` header that daemon
/// 1.13.0 reads (pollen-robotics/reachy_mini#1472).
///
/// The daemon counts which kinds of client talk to it, for the anonymous usage events
/// it sends Pollen while the robot's owner leaves telemetry on
/// (`ClientTelemetryMiddleware`, read on every HTTP request and socket handshake).
/// It knows four kinds — `desktop`, `mobile`, `web` and `python_sdk` — and files
/// every other kind as `other`. So this app is counted as `other`, never as Pollen's
/// own mobile app. A value that does not match the daemon's pattern is dropped
/// without a word, which is why `ReachyClientHeaderTests` checks it against the
/// daemon's own regular expression.
///
/// Only the daemon's port receives it. Central, Hugging Face, the media server on
/// `:8443` and an app's own port do not read it, and a header nobody reads is a fact
/// about the user sent for nothing.
public enum ReachyClientHeader {
    public static let name = "X-Reachy-Client"

    /// `hey_reachy/<CFBundleShortVersionString> (<os>)`.
    public static let value = make(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        system: system
    )

    static func make(version: String?, system: String) -> String {
        "hey_reachy/\(versionToken(version)) (\(system))"
    }

    /// The daemon accepts `[0-9A-Za-z.+-]{1,32}`. A test process has no bundle
    /// version, and a hand-edited one could carry a space; either way the header
    /// still has to parse, or the whole value is dropped.
    static func versionToken(_ version: String?) -> String {
        let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+-")
        let token = String((version ?? "").filter(allowed.contains).prefix(32))
        return token.isEmpty ? "unknown" : token
    }

    /// The daemon knows `macos`, `windows`, `linux`, `ios` and `android`. visionOS and
    /// tvOS are named anyway: the daemon files them as `other`, and a false `ios`
    /// would be a wrong count rather than a missing one.
    static var system: String {
        #if os(visionOS)
            "visionos"
        #elseif os(tvOS)
            "tvos"
        #elseif os(iOS)
            "ios"
        #elseif os(macOS)
            "macos"
        #else
            "other"
        #endif
    }
}

public extension URLRequest {
    /// A request to the robot's daemon that names this app (``ReachyClientHeader``).
    static func toDaemon(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(ReachyClientHeader.value, forHTTPHeaderField: ReachyClientHeader.name)
        return request
    }
}

/// Puts ``ReachyClientHeader`` on every request the generated client sends.
struct ReachyClientMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let field = HTTPField.Name(ReachyClientHeader.name) {
            request.headerFields[field] = ReachyClientHeader.value
        }
        return try await next(request, body, baseURL)
    }
}
