import Foundation
import ReachyJSON

/// Provisioning over HTTP, for a phone standing on the robot's own access point.
///
/// The same sealing and the same screen as the Bluetooth path, with two differences
/// that matter: the scan is not capped at 180 bytes, and neither is the sealed payload,
/// which is the reason this exists at all — `WIFI_CONNECT_ENC` is around 260 bytes
/// against an ATT MTU that may not carry it.
extension RobotConnection: WiFiConfigClient {
    public func provisioningKey() async throws -> WiFiProvisioningKey {
        try await wirelessJSON(path: "/wifi/prov_key")
    }

    /// A POST, unlike every other read here: the route rescans the air before answering.
    public func scanNetworks() async throws -> [String] {
        try await wirelessJSON(method: "POST", path: "/wifi/scan_and_list")
    }

    public func connectSealed(_ payload: SealedWiFiCredentials) async throws {
        do {
            try await wirelessData(
                method: "POST",
                path: "/wifi/connect_sealed",
                body: JSONCodec.daemon.encode(payload)
            )
        } catch ReachyKitError.daemonRejected(statusCode: 400) {
            // `decrypt_failed` — a wrong PIN or a `kid` older than the robot's 600 s
            // rotation. Reported as the same case the Bluetooth path uses so that the
            // one retry with a fresh key is transport-independent.
            throw BLECommandError.badCredentials
        } catch ReachyKitError.daemonBusy {
            throw BLECommandError.busy
        }
    }

    public func wifiStatus() async throws -> WiFiStatus {
        try await wirelessJSON(path: "/wifi/status")
    }

    public func forget(ssid: String) async throws {
        try await wirelessData(
            method: "POST",
            path: "/wifi/forget",
            queryItems: [URLQueryItem(name: "ssid", value: ssid)],
            // 404 here means the robot has no such saved network, which is a real answer.
            canReport404: true
        )
    }

    public func forgetAll() async throws {
        try await wirelessData(method: "POST", path: "/wifi/forget_all")
    }

    public func lastWiFiError() async throws -> String? {
        struct Reported: Decodable {
            let error: String?
        }
        let reported: Reported = try await wirelessJSON(path: "/wifi/error")
        return reported.error
    }

    public func resetWiFiError() async throws {
        try await wirelessData(method: "POST", path: "/wifi/reset_error")
    }
}
