import Foundation
import ReachyJSON

/// Provisioning over Bluetooth, which is the only channel that works before the robot
/// is on any network at all.
public struct BLEProvisioningTransport: WiFiProvisioningTransport {
    private let pump: BLECommandPump
    private let transport: any BLETransport

    public init(pump: BLECommandPump, transport: any BLETransport) {
        self.pump = pump
        self.transport = transport
    }

    public func provisioningKey() async throws -> WiFiProvisioningKey {
        let json = try await pump.send(.wifiKeyExchange).value()
        return try JSONCodec.daemon.decode(WiFiProvisioningKey.self, from: Data(json.utf8))
    }

    public func scanNetworks() async throws -> [String] {
        let reply = try await pump.send(.wifiScan).value()
        return WiFiScanResult.networks(in: reply)
    }

    public func connectSealed(_ payload: SealedWiFiCredentials) async throws {
        _ = try await pump.send(.wifiConnectSealed(json: payload.jsonString())).value()
    }

    /// Read straight off the status characteristic rather than sent as `WIFI_STATUS`:
    /// it needs no PIN session, costs one ATT read instead of a proxied round trip that
    /// answers twice, and carries exactly the live address a two-second poll is after.
    public func wifiStatus() async throws -> WiFiStatus {
        try await networkStatus().status
    }

    /// The characteristic's own reading, which carries the live address that
    /// `WiFiStatus` cannot promise for both channels.
    public func networkStatus() async throws -> WiFiNetworkStatus {
        let raw = try await transport.read(.networkStatus)
        guard let text = String(bytes: raw, encoding: .utf8),
              let status = WiFiNetworkStatus(parsing: text)
        else {
            throw BLECommandError.other("The robot reported a network status this app could not read.")
        }
        return status
    }
}
