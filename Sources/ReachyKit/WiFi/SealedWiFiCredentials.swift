import Foundation
import ReachyJSON

/// The robot's ephemeral key for sealing a Wi-Fi password, from `WIFI_KEYEX` over BLE
/// or `GET /wifi/prov_key` over HTTP.
public struct WiFiProvisioningKey: Equatable, Sendable, Decodable {
    /// The robot rotates its keypair roughly every 10 minutes and refuses a stale id,
    /// which it reports as bad credentials — so that error deserves one retry with a
    /// fresh key before the PIN is blamed.
    public let kid: String
    /// Base64 of the raw 32-byte X25519 public key.
    public let pk: String
    public let alg: String

    public static let supportedAlgorithm = "x25519-hkdf-sha256-aesgcm"

    public init(kid: String, pk: String, alg: String = WiFiProvisioningKey.supportedAlgorithm) {
        self.kid = kid
        self.pk = pk
        self.alg = alg
    }
}

/// The `WIFI_CONNECT_ENC` / `POST /wifi/connect_sealed` payload. Field names are fixed
/// by the daemon's Pydantic model, so the JSON is emitted with no key strategy.
public struct SealedWiFiCredentials: Equatable, Sendable, Encodable {
    public let ssid: String
    public let kid: String
    /// Base64 of this client's raw 32-byte ephemeral X25519 public key.
    public let epk: String
    /// Base64 of the 12-byte AES-GCM nonce.
    public let nonce: String
    /// Base64 of `ciphertext ‖ 16-byte tag`. CryptoKit exposes the two separately;
    /// Python's `AESGCM.decrypt` expects them joined.
    public let ct: String

    public func jsonString() throws -> String {
        let data = try JSONCodec.daemon.encode(self)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw ReachyKitError.daemonRejected(statusCode: -1)
        }
        return json
    }
}
