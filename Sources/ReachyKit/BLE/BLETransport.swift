import Foundation

/// One robot seen while scanning.
///
/// `id` is CoreBluetooth's per-host identifier, not the Bluetooth address, so it is
/// meaningful only on this device. Every robot advertises the same local name, so two
/// in range are told apart by signal strength until one is connected and its
/// `hardwareID` can be read.
public struct BLEPeripheralSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    /// `kCBAdvDataManufacturerData`, verbatim and undecoded.
    ///
    /// Kept raw as well as parsed because **no robot here has been seen sending
    /// anything at all**: `BLEAdvertisement` decodes the shape upstream's PR #1086
    /// describes, and the recovery console prints these bytes so a robot on other
    /// firmware can be read rather than guessed at. Nil is the ordinary answer.
    public let manufacturerData: Data?

    /// The robot's own claim about its address and identity, when it makes one.
    public var advertisement: BLEAdvertisement? {
        manufacturerData.flatMap(BLEAdvertisement.init(manufacturerData:))
    }

    public init(id: UUID, name: String, rssi: Int, manufacturerData: Data? = nil) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.manufacturerData = manufacturerData
    }
}

/// The CoreBluetooth surface this client needs, kept behind a protocol so the command
/// protocol above it is testable without hardware — the robot's BLE service is
/// Linux/BlueZ, so no simulator can ever stand in for it.
///
/// Only `String`, `Data` and `UUID` cross this boundary: `CBPeripheral` and
/// `CBCharacteristic` are not `Sendable` and never leave the adapter.
public protocol BLETransport: Sendable, AnyObject {
    var availability: BLEAvailability { get }
    /// Peripherals seen so far, newest reading per robot.
    var discovered: [BLEPeripheralSnapshot] { get }
    /// Largest payload one write can carry. `WIFI_CONNECT_ENC` is around 260 bytes
    /// against a default ATT MTU of 185, so this decides whether BLE provisioning
    /// works at all on a given phone.
    var maximumWriteLength: Int { get }
    /// What a with-response write is allowed to be — 512 on every iPhone, since
    /// CoreBluetooth reaches that by splitting the value into ATT prepare/execute writes.
    /// The robot's handler ignores write offsets and would see those fragments as
    /// separate commands, so this is a number to report, never a budget to spend.
    var attributeWriteLength: Int { get }

    func startScan() throws
    func stopScan()
    func connect(_ id: UUID) async throws
    func disconnect()

    func write(_ payload: Data, to characteristic: BLECharacteristicID) async throws
    func read(_ characteristic: BLECharacteristicID) async throws -> Data
    func setNotify(_ enabled: Bool, for characteristic: BLECharacteristicID) async throws
    /// Values pushed on the response characteristic. Only proxied commands notify.
    func notifications() -> AsyncStream<Data>
    /// Everything that changes without being asked for.
    func events() -> AsyncStream<BLETransportEvent>
}

/// A change the caller did not ask for: the radio was switched off, a robot came into
/// range, or the link dropped. The synchronous properties above are the same facts as a
/// snapshot; this is how a screen learns they moved.
public enum BLETransportEvent: Equatable, Sendable {
    case availabilityChanged(BLEAvailability)
    case discoveredChanged([BLEPeripheralSnapshot])
    /// Also delivered when the radio is switched off, which drops the link without any
    /// disconnect being requested.
    case disconnected(reason: String?)
}

public enum BLETransportError: Error, Equatable, Sendable {
    case unavailable(BLEAvailability)
    case notConnected
    case characteristicMissing(BLECharacteristicID)
    case connectionFailed(String)
    /// The payload exceeds what one ATT write can carry. The robot's command handler
    /// ignores write offsets, so a fragmented write would be dispatched as two
    /// separate commands rather than reassembled.
    case payloadTooLong(bytes: Int, limit: Int)
    case timedOut
}

extension BLETransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unavailable(availability):
            switch availability {
            case .unsupported: "This device has no Bluetooth."
            case .unauthorized: "Bluetooth access is turned off for this app."
            case .poweredOff: "Bluetooth is switched off."
            case .unknown, .ready: "Bluetooth is not ready."
            }
        case .notConnected: "Not connected to a robot over Bluetooth."
        case let .characteristicMissing(characteristic):
            "The robot did not offer the \(characteristic) characteristic."
        case let .connectionFailed(message): message
        case let .payloadTooLong(bytes, limit):
            "The robot accepts \(limit) bytes per message and this one is \(bytes)."
        case .timedOut: "The robot did not answer in time."
        }
    }
}
