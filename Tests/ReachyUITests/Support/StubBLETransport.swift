import CryptoKit
import Foundation
@testable import ReachyKit

/// A robot answering just enough of the GATT protocol to drive the onboarding flow. The
/// real service is Linux/BlueZ, so nothing simulates it — this replays the exchange.
///
/// Proxied commands answer on the read rather than acking and notifying: the pump's
/// two-phase path is covered in `ReachyKitTests`, and repeating it here would only make
/// these tests about the pump.
final class StubBLETransport: BLETransport, @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [String] = []
    private var response = ""
    private var values: [BLECharacteristicID: String] = [:]
    private var notificationContinuation: AsyncStream<Data>.Continuation?
    private var eventContinuation: AsyncStream<BLETransportEvent>.Continuation?
    private var connects: [UUID] = []
    private var disconnects = 0
    private var journalStarts = 0

    var availability: BLEAvailability = .ready
    var discovered: [BLEPeripheralSnapshot] = []
    var maximumWriteLength = 512
    var attributeWriteLength = 512
    /// The code this robot accepts. Case-sensitive, like the real comparison.
    var pin = "4A7f9"
    var scanReply = #"["Home","Cafe"]"#
    /// What the network-status characteristic reads back once a sealed password has been
    /// accepted. Left nil, the robot never comes up — which is what a wrong Wi-Fi
    /// password looks like from here.
    var networkStatusAfterJoin: String?
    /// Handed out one per `JOURNAL_READ`, then empty — which is what a quiet robot reads
    /// back, not an error.
    var journalChunks: [String] = []
    /// Makes this many reads fail the way a robot whose `journalctl` has exited does.
    /// It answers again once `JOURNAL_START` has respawned it.
    var journalStopsAfter: Int?
    /// A daemon 1.10.0 robot, which answers `SET_NAME`. Left false, it echoes the
    /// command back the way a 1.9.x robot does.
    var namesItself = false

    init(
        hardwareID: String = "a1b2c3d4e5f60718",
        networkStatus: String = "HOTSPOT [wlan0] 10.42.0.1",
        availableCommands: String = "RESTART_DAEMON, HOTSPOT, WIFI_RESET, SOFTWARE_RESET"
    ) {
        values[.hardwareID] = hardwareID
        values[.networkStatus] = networkStatus
        values[.availableCommands] = availableCommands
    }

    var writtenCommands: [String] {
        lock.withLock { writes }
    }

    var connectedIDs: [UUID] {
        lock.withLock { connects }
    }

    var disconnectCount: Int {
        lock.withLock { disconnects }
    }

    var journalStartCount: Int {
        lock.withLock { journalStarts }
    }

    func advertise(_ peripherals: [BLEPeripheralSnapshot]) {
        discovered = peripherals
        lock.withLock { eventContinuation }?.yield(.discoveredChanged(peripherals))
    }

    func startScan() throws {}

    func stopScan() {}

    func connect(_ id: UUID) async throws {
        lock.withLock { connects.append(id) }
    }

    func disconnect() {
        lock.withLock { disconnects += 1 }
    }

    func setNotify(_: Bool, for _: BLECharacteristicID) async throws {}

    func write(_ payload: Data, to _: BLECharacteristicID) async throws {
        let command = String(bytes: payload, encoding: .utf8) ?? ""
        lock.withLock {
            writes.append(command)
            response = reply(to: command)
        }
    }

    func read(_ characteristic: BLECharacteristicID) async throws -> Data {
        try lock.withLock {
            let text = characteristic == .response ? response : values[characteristic]
            guard let text else { throw BLETransportError.characteristicMissing(characteristic) }
            return Data(text.utf8)
        }
    }

    func notifications() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        lock.withLock { notificationContinuation = continuation }
        return stream
    }

    func events() -> AsyncStream<BLETransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BLETransportEvent.self)
        lock.withLock { eventContinuation = continuation }
        return stream
    }

    /// Called under `lock`. Nil for anything that is not a journal command.
    private func journalReply(to command: String) -> String? {
        switch command {
        case "JOURNAL_START":
            journalStarts += 1
            // Respawns a journal that had died; a healthy one is unaffected, so the
            // countdown a test armed survives the console's own opening START.
            if journalStopsAfter == 0 {
                journalStopsAfter = nil
            }
            return "OK: Journal streaming started"
        case "JOURNAL_READ":
            if let remaining = journalStopsAfter {
                guard remaining > 0 else { return "ERROR: Journal not running" }
                journalStopsAfter = remaining - 1
            }
            return journalChunks.isEmpty ? "" : journalChunks.removeFirst()
        case "JOURNAL_STOP":
            return "OK: Journal streaming stopped"
        default:
            return nil
        }
    }

    /// Called under `lock`.
    private func reply(to command: String) -> String {
        if command == "PING" {
            return "PONG"
        }
        if let code = command.dropPrefixIfPresent("PIN_") {
            return code == pin ? "OK: Authenticated" : "ERROR: Incorrect PIN"
        }
        if command == "WIFI_KEYEX" {
            let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            return #"{"kid":"k1","pk":"\#(key)","alg":"\#(WiFiProvisioningKey.supportedAlgorithm)"}"#
        }
        if command == "WIFI_SCAN" {
            return scanReply
        }
        if namesItself, let name = command.dropPrefixIfPresent("SET_NAME ") {
            return "OK: Named \(name)"
        }
        if let journal = journalReply(to: command) {
            return journal
        }
        if command.hasPrefix("WIFI_CONNECT_ENC ") {
            if let joined = networkStatusAfterJoin {
                values[.networkStatus] = joined
            }
            return "OK: Connecting"
        }
        return "ECHO: \(command)"
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
