import Foundation

/// The robot's own network settings, reached through the session so the UI never builds a
/// URL of its own.
///
/// Provisioning over Bluetooth is not here — that is `BLELink`, for a robot this app
/// cannot reach yet. What *is* here is the same handover over the connection a session
/// already has, which is how a robot moves from one network to another without anybody
/// standing next to it with a phone on its hotspot.
public extension RobotSession {
    /// False on a Lite robot, which never mounts `/wifi/*`.
    var canConfigureWiFi: Bool {
        client is any WiFiConfigClient && supportsWirelessFeatures
    }

    func wifiStatus() async throws -> WiFiStatus {
        try await withWiFiClient { try await $0.wifiStatus() }
    }

    /// What the robot can hear right now. A POST on the wire: the route rescans the
    /// air before it answers, so it is slow and worth a spinner.
    func scanWiFiNetworks() async throws -> [String] {
        try await withWiFiClient { try await $0.scanNetworks() }
    }

    /// Hands the robot a network, and expects to lose it.
    ///
    /// The reply means "accepted", never "joined": the robot answers first and
    /// reconfigures its interface afterwards, which takes this connection down. So
    /// there is nothing here to wait on and nothing to poll — the robot is found
    /// again by discovery, on whatever address the new network gives it.
    ///
    /// Recoverable by design: a password the robot cannot use puts it back on the
    /// network it was on, so a mistake here costs a wait rather than a trip to the
    /// robot. `WiFiProvisioning.join` does the sealing and the one retry with a fresh
    /// key, the same as over Bluetooth.
    func joinWiFi(ssid: String, password: String, pin: String) async throws {
        try await withWiFiClient {
            try await WiFiProvisioning.join(ssid: ssid, password: password, pin: pin, using: $0)
        }
    }

    /// Answers 404 for a network the robot never saved, and refuses its own hotspot.
    func forgetWiFi(ssid: String) async throws {
        try await withWiFiClient { try await $0.forget(ssid: ssid) }
    }

    /// Forgets every saved network at once, the robot's own hotspot aside — the
    /// route the settings card's "Forget all" calls.
    ///
    /// `/wifi/forget_all` rather than a loop over `forget(ssid:)`: the robot does
    /// this in one `nmcli` operation, and the per-network route answers 409 while
    /// another one runs, so a loop would race itself.
    func forgetAllWiFi() async throws {
        try await withWiFiClient { try await $0.forgetAll() }
    }

    /// Why the last join failed. `connect_sealed` returns before it joins, so this is
    /// where the reason ends up rather than in the reply.
    func lastWiFiError() async throws -> String? {
        try await withWiFiClient { try await $0.lastWiFiError() }
    }

    func resetWiFiError() async throws {
        try await withWiFiClient { try await $0.resetWiFiError() }
    }
}

extension RobotSession {
    func withWiFiClient<T>(_ call: (any WiFiConfigClient) async throws -> T) async throws -> T {
        guard let client else { throw ReachyKitError.notConnected }
        guard let wifiClient = client as? any WiFiConfigClient else {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
        return try await call(wifiClient)
    }
}
