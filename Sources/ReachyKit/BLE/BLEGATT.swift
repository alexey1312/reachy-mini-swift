import Foundation

/// The GATT profile `bluetooth_service.py` exposes, present since daemon 1.9.0.
///
/// Two traps live here. The robot advertises the **status** service, not the command
/// service, so scanning for `commandService` finds nothing. And it registers its
/// characteristics in reverse order — the response characteristic becomes `char1` and
/// the command characteristic `char0` — so they must be matched by UUID, never by
/// discovery order.
public enum BLEGATT {
    /// The local name of a robot nobody renamed, with no per-unit suffix. From daemon
    /// 1.15.0 a renamed robot advertises its own name instead, cut to 29 bytes, in the
    /// scan response (pollen-robotics/reachy_mini#1558). Two robots that were never
    /// renamed are still told apart only after connecting, by `hardwareID`.
    public static let advertisedName = "ReachyMini"

    public static let commandService = "12345678-1234-5678-1234-56789abcdef0"
    public static let statusService = "12345678-1234-5678-1234-56789abcdef3"
    public static let deviceInformationService = "0000180a-0000-1000-8000-00805f9b34fb"

    /// The only service in the advertisement, so the only usable scan filter.
    public static let advertisedService = statusService
}

/// A characteristic this client reads, writes or subscribes to.
public enum BLECharacteristicID: String, CaseIterable, Sendable, Hashable {
    /// Write-with-response only. UTF-8 command strings.
    case command = "12345678-1234-5678-1234-56789abcdef1"
    /// Read and notify. Carries every reply.
    case response = "12345678-1234-5678-1234-56789abcdef2"
    /// Plain text, not JSON: `"{MODE} [iface] ip ; [iface] ip"`, or a bare `"OFFLINE"`.
    case networkStatus = "12345678-1234-5678-1234-56789abcdef4"
    case systemStatus = "12345678-1234-5678-1234-56789abcdef5"
    /// Comma-joined recovery script names, read from the robot's `commands/` directory
    /// at startup. Read it rather than hardcoding — the directory can grow.
    case availableCommands = "12345678-1234-5678-1234-56789abcdef6"
    /// `sha256(usb serial)[:16]`. The same value the daemon reports as `hardware_id`
    /// and advertises as the mDNS `unit_id`, which is how a robot provisioned over
    /// Bluetooth is recognised once it appears on the LAN.
    case hardwareID = "12345678-1234-5678-1234-56789abcdef7"

    public var service: String {
        switch self {
        case .command, .response: BLEGATT.commandService
        case .networkStatus, .systemStatus, .availableCommands, .hardwareID: BLEGATT.statusService
        }
    }
}

/// Why the central cannot be used, so the UI can say something better than a spinner.
public enum BLEAvailability: Equatable, Sendable {
    case unknown
    /// No Bluetooth hardware. This is what every iOS Simulator run reports.
    case unsupported
    case unauthorized
    case poweredOff
    case ready
}
