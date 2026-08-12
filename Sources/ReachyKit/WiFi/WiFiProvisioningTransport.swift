import Foundation
import ReachyJSON

/// Handing the robot a Wi-Fi password, over whichever channel can currently reach it.
///
/// Two implementations answer this: Bluetooth, which works with no network at all, and
/// HTTP to `10.42.0.1` once the phone has joined the robot's own access point. They
/// share one sealing scheme and one screen, and the HTTP one is also the way out if the
/// sealed payload turns out not to fit a single ATT write on real hardware.
public protocol WiFiProvisioningTransport: Sendable {
    /// The robot's current provisioning key. Rotated roughly every 10 minutes.
    func provisioningKey() async throws -> WiFiProvisioningKey
    func scanNetworks() async throws -> [String]
    func connectSealed(_ payload: SealedWiFiCredentials) async throws
    func wifiStatus() async throws -> WiFiStatus
}

/// How a join attempt ended.
public enum WiFiJoinOutcome: Equatable, Sendable {
    case joined(WiFiStatus)
    /// The budget ran out before the robot reported itself connected. `last` is what it
    /// reported at the end — back on its own access point means `nmcli` used up its
    /// three attempts, which is a wrong password far more often than anything else.
    case gaveUp(last: WiFiStatus?)
}

public enum WiFiProvisioning {
    /// Seals the password under a key fetched from the robot and hands it over.
    ///
    /// The one retry is not defensive padding. The robot rotates its provisioning
    /// keypair every 600 s and rejects a `kid` older than that as bad credentials —
    /// the same error it gives for a wrong PIN — so a single fresh exchange is what
    /// tells the two apart. A second retry would only ask the same question again.
    public static func join(
        ssid: String,
        password: String,
        pin: String,
        using transport: any WiFiProvisioningTransport
    ) async throws {
        do {
            try await attempt(ssid: ssid, password: password, pin: pin, using: transport)
        } catch {
            guard deservesFreshKey(error) else { throw error }
            try await attempt(ssid: ssid, password: password, pin: pin, using: transport)
        }
    }

    /// Polls until the robot reports itself on the network, or the budget runs out.
    ///
    /// The default budget covers the robot's own: `nmcli` makes three attempts, each
    /// settling for 2 s and pausing 3 s afterwards.
    public static func awaitJoin(
        using transport: any WiFiProvisioningTransport,
        timeout: Duration = .seconds(60),
        pollInterval: Duration = .seconds(2)
    ) async throws -> WiFiJoinOutcome {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var last: WiFiStatus?
        while true {
            // A read can fail while the interface is being reconfigured, which is the
            // normal middle of a join rather than a reason to stop. So is `.busy`, and
            // so is a mode this build has never heard of.
            if let status = try? await transport.wifiStatus() {
                last = status
                // Not `hasJoined(ssid:)`: over Bluetooth the robot reports only that it
                // is on a network, never which one, so the SSID cannot be part of the
                // shared condition.
                if status.mode == .wlan {
                    return .joined(status)
                }
            }
            guard ContinuousClock.now < deadline else {
                return .gaveUp(last: last)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private static func attempt(
        ssid: String,
        password: String,
        pin: String,
        using transport: any WiFiProvisioningTransport
    ) async throws {
        let key = try await transport.provisioningKey()
        let sealed = try WiFiPasswordSeal.seal(ssid: ssid, password: password, pin: pin, key: key)
        try await transport.connectSealed(sealed)
    }

    /// The single failure a fresh key exchange can plausibly fix.
    static func deservesFreshKey(_ error: any Error) -> Bool {
        (error as? BLECommandError) == .badCredentials
    }
}

/// Reads the SSID list out of a `WIFI_SCAN` reply.
public enum WiFiScanResult {
    /// The reply is capped at 180 bytes with no pagination and no flag saying anything
    /// was dropped, so a JSON array cut mid-name is ordinary rather than exceptional.
    /// Every name that closed its quotes is still good; the partial one at the end is
    /// not, and the missing ones are why manual SSID entry is a required part of the
    /// flow rather than a fallback.
    public static func networks(in raw: String) -> [String] {
        let decoded = try? JSONCodec.daemon.decode([String].self, from: Data(raw.utf8))
        var seen = Set<String>()
        // A hidden network scans as an empty name, which is not something to offer.
        return (decoded ?? salvage(raw)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func salvage(_ raw: String) -> [String] {
        var names: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", inQuotes {
                escaped = true
            } else if character == "\"" {
                if inQuotes {
                    names.append(current)
                    current = ""
                }
                inQuotes.toggle()
            } else if inQuotes {
                current.append(character)
            }
        }
        return names
    }
}
