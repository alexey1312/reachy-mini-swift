import CoreBluetooth
import Foundation

/// Talks to the robot's GATT service through CoreBluetooth.
///
/// Everything CoreBluetooth touches lives on one serial queue — the queue the central
/// manager was built with, which is also where every delegate callback arrives — so
/// `CBPeripheral` and `CBCharacteristic`, neither of them `Sendable`, never leave it.
/// Only the three values other threads read are copied out under a lock.
///
/// Constructing this is what prompts for Bluetooth permission on iOS, so build it only
/// once the screen explaining why is already up.
public final class CoreBluetoothTransport: NSObject, BLETransport, @unchecked Sendable {
    /// ATT's floor: a 23-byte MTU minus the 3-byte write header. Stands in until a
    /// peripheral connects and reports the real figure, and is never optimistic.
    static let minimumWriteLength = 20

    struct Snapshot {
        var availability: BLEAvailability = .unknown
        var discovered: [BLEPeripheralSnapshot] = []
        var maximumWriteLength = CoreBluetoothTransport.minimumWriteLength
        var attributeWriteLength = CoreBluetoothTransport.minimumWriteLength
    }

    private let queue = DispatchQueue(label: "com.alexey1312.reachy.bluetooth")
    private let lock = NSLock()
    private var snapshot = Snapshot()

    // Everything below is reached from `queue` alone, which is the whole safety
    // argument for the class. What the delegate callbacks need is internal rather than
    // private only because they live in the neighbouring file; nothing outside this
    // type may touch it.
    private var central: CBCentralManager?
    private var wantsScan = false
    private var pendingConnect: CheckedContinuation<Void, any Error>?
    private var eventListeners: [UUID: AsyncStream<BLETransportEvent>.Continuation] = [:]
    var peripherals: [UUID: CBPeripheral] = [:]
    var connected: CBPeripheral?
    var characteristics: [CBUUID: CBCharacteristic] = [:]
    var undiscoveredServices = 0
    var pendingWrites: [CBUUID: CheckedContinuation<Void, any Error>] = [:]
    var pendingReads: [CBUUID: CheckedContinuation<Data, any Error>] = [:]
    var pendingNotifies: [CBUUID: CheckedContinuation<Void, any Error>] = [:]
    var notificationListeners: [UUID: AsyncStream<Data>.Continuation] = [:]

    override public init() {
        super.init()
        // The manager reports its state on `queue`, possibly before this assignment
        // lands — which is why every delegate method uses the manager it is handed
        // rather than this property.
        central = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    public var availability: BLEAvailability {
        lock.withLock { snapshot.availability }
    }

    public var discovered: [BLEPeripheralSnapshot] {
        lock.withLock { snapshot.discovered }
    }

    public var maximumWriteLength: Int {
        lock.withLock { snapshot.maximumWriteLength }
    }

    public var attributeWriteLength: Int {
        lock.withLock { snapshot.attributeWriteLength }
    }

    public func startScan() throws {
        let availability = availability
        switch availability {
        case .unsupported, .unauthorized, .poweredOff:
            throw BLETransportError.unavailable(availability)
        case .unknown, .ready:
            // `.unknown` is what a freshly built manager reports for the moment it
            // takes to answer, so scanning is remembered and started on `.poweredOn`
            // rather than refused.
            break
        }
        queue.async { [self] in
            wantsScan = true
            scanIfPossible()
        }
    }

    public func stopScan() {
        queue.async { [self] in
            wantsScan = false
            central?.stopScan()
        }
    }

    public func connect(_ id: UUID) async throws {
        try await awaitingReply(timeout: .seconds(20)) { [self] (continuation: CheckedContinuation<Void, any Error>) in
            // `retrievePeripherals` covers a robot known to the system but not seen by
            // this scan — a reconnect right after provisioning, typically.
            guard let central,
                  let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
            else {
                continuation.resume(throwing: BLETransportError.connectionFailed("That robot is no longer in range."))
                return
            }
            peripherals[id] = peripheral
            peripheral.delegate = self
            connected = peripheral
            characteristics = [:]
            pendingConnect = continuation
            central.stopScan()
            central.connect(peripheral)
        } expire: { [self] in
            guard let pending = pendingConnect else { return }
            pendingConnect = nil
            if let connected {
                central?.cancelPeripheralConnection(connected)
            }
            pending.resume(throwing: BLETransportError.timedOut)
        }
    }

    public func disconnect() {
        queue.async { [self] in
            guard let connected else { return }
            central?.cancelPeripheralConnection(connected)
        }
    }

    public func write(_ payload: Data, to characteristic: BLECharacteristicID) async throws {
        let limit = maximumWriteLength
        guard payload.count <= limit else {
            throw BLETransportError.payloadTooLong(bytes: payload.count, limit: limit)
        }
        // `CBUUID` is not `Sendable`, so the key is derived inside the closures from the
        // enum case, which is.
        try await awaitingReply(timeout: .seconds(10)) { [self] (continuation: CheckedContinuation<Void, any Error>) in
            do {
                let (peripheral, target) = try resolve(characteristic)
                pendingWrites[Self.key(characteristic)] = continuation
                peripheral.writeValue(payload, for: target, type: .withResponse)
            } catch {
                continuation.resume(throwing: error)
            }
        } expire: { [self] in
            pendingWrites.removeValue(forKey: Self.key(characteristic))?
                .resume(throwing: BLETransportError.timedOut)
        }
    }

    public func read(_ characteristic: BLECharacteristicID) async throws -> Data {
        try await awaitingReply(timeout: .seconds(10)) { [self] continuation in
            do {
                let (peripheral, target) = try resolve(characteristic)
                pendingReads[Self.key(characteristic)] = continuation
                peripheral.readValue(for: target)
            } catch {
                continuation.resume(throwing: error)
            }
        } expire: { [self] in
            pendingReads.removeValue(forKey: Self.key(characteristic))?
                .resume(throwing: BLETransportError.timedOut)
        }
    }

    public func setNotify(_ enabled: Bool, for characteristic: BLECharacteristicID) async throws {
        try await awaitingReply(timeout: .seconds(10)) { [self] (continuation: CheckedContinuation<Void, any Error>) in
            do {
                let (peripheral, target) = try resolve(characteristic)
                pendingNotifies[Self.key(characteristic)] = continuation
                peripheral.setNotifyValue(enabled, for: target)
            } catch {
                continuation.resume(throwing: error)
            }
        } expire: { [self] in
            pendingNotifies.removeValue(forKey: Self.key(characteristic))?
                .resume(throwing: BLETransportError.timedOut)
        }
    }

    public func notifications() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let token = UUID()
        // Registration is enqueued before the caller's write, and the queue is serial,
        // so a reply can never slip into the gap between the two.
        queue.async { [self] in notificationListeners[token] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            queue.async { self.notificationListeners[token] = nil }
        }
        return stream
    }

    public func events() -> AsyncStream<BLETransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BLETransportEvent.self)
        let token = UUID()
        queue.async { [self] in
            eventListeners[token] = continuation
            continuation.yield(.availabilityChanged(availability))
            continuation.yield(.discoveredChanged(discovered))
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            queue.async { self.eventListeners[token] = nil }
        }
        return stream
    }
}

// MARK: - Queue-confined helpers

extension CoreBluetoothTransport {
    func publish(_ mutate: (inout Snapshot) -> Void) {
        lock.withLock { mutate(&snapshot) }
    }

    func emit(_ event: BLETransportEvent) {
        for listener in eventListeners.values {
            listener.yield(event)
        }
    }

    func scanIfPossible() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [CBUUID(string: BLEGATT.advertisedService)],
            // **Duplicates are what deliver the scan response.** Without this iOS
            // coalesces a peripheral into one callback, and a manufacturer block that
            // travels in the scan response rather than in the advertisement can miss
            // it entirely — indistinguishable from firmware that sends none. It costs
            // a callback per packet, which is bounded by the two screens that scan:
            // both are open only while somebody is looking at them, and both stop on
            // disappear. `merging` is what keeps the extra callbacks cheap.
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    static func key(_ id: BLECharacteristicID) -> CBUUID {
        CBUUID(string: id.rawValue)
    }

    private func resolve(_ id: BLECharacteristicID) throws -> (CBPeripheral, CBCharacteristic) {
        guard let peripheral = connected, peripheral.state == .connected else {
            throw BLETransportError.notConnected
        }
        guard let characteristic = characteristics[Self.key(id)] else {
            throw BLETransportError.characteristicMissing(id)
        }
        return (peripheral, characteristic)
    }

    /// Records a discovered characteristic and, once every requested service has
    /// reported, finishes the connection.
    func absorb(_ discovered: [CBCharacteristic]) {
        // Matched by UUID because the robot registers its characteristics in reverse
        // order, so discovery order says nothing about which is which.
        for characteristic in discovered
            where BLECharacteristicID(rawValue: characteristic.uuid.uuidString.lowercased()) != nil
        {
            characteristics[characteristic.uuid] = characteristic
        }
        undiscoveredServices -= 1
        guard undiscoveredServices <= 0, let pending = pendingConnect else { return }
        pendingConnect = nil
        let missing = [BLECharacteristicID.command, .response]
            .first { characteristics[Self.key($0)] == nil }
        if let missing {
            pending.resume(throwing: BLETransportError.characteristicMissing(missing))
            return
        }
        if let peripheral = connected {
            publish {
                $0.maximumWriteLength = Self.singlePacketWriteLength(of: peripheral)
                $0.attributeWriteLength = peripheral.maximumWriteValueLength(for: .withResponse)
            }
        }
        pending.resume()
    }

    /// The largest command that survives one ATT packet.
    ///
    /// Deliberately not `.withResponse`, which answers 512 on every iPhone: that is the
    /// maximum *attribute* length, reachable only because CoreBluetooth silently splits
    /// a longer value into ATT prepare/execute writes. The robot's `WriteValue` ignores
    /// `options["offset"]`, so those fragments arrive as separate commands instead of
    /// being reassembled. `.withoutResponse` reports `ATT_MTU - 3`, the only figure that
    /// describes what actually fits — even though the command characteristic accepts
    /// write-with-response only, and that is the write type used.
    static func singlePacketWriteLength(of peripheral: CBPeripheral) -> Int {
        max(peripheral.maximumWriteValueLength(for: .withoutResponse), minimumWriteLength)
    }

    /// Drops the link and fails everything waiting on it.
    func teardown(reason: String?) {
        characteristics = [:]
        connected = nil
        undiscoveredServices = 0
        publish {
            $0.maximumWriteLength = Self.minimumWriteLength
            $0.attributeWriteLength = Self.minimumWriteLength
        }

        pendingConnect?.resume(throwing: BLETransportError.connectionFailed(reason ?? "The robot disconnected."))
        pendingConnect = nil
        for continuation in pendingWrites.values {
            continuation.resume(throwing: BLETransportError.notConnected)
        }
        pendingWrites = [:]
        for continuation in pendingReads.values {
            continuation.resume(throwing: BLETransportError.notConnected)
        }
        pendingReads = [:]
        for continuation in pendingNotifies.values {
            continuation.resume(throwing: BLETransportError.notConnected)
        }
        pendingNotifies = [:]
        // Ends the pump's wait, which then falls back to a read and reports the drop
        // rather than sitting out its timeout.
        for listener in notificationListeners.values {
            listener.finish()
        }
        notificationListeners = [:]

        emit(.disconnected(reason: reason))
    }

    /// Runs `start` on the queue, waits for a delegate callback to resume it, and runs
    /// `expire` on the same queue if that never happens. Both sides mutate the pending
    /// slot from one serial queue, so the losing side finds it already gone and cannot
    /// resume a second time.
    private func awaitingReply<T: Sendable>(
        timeout: Duration,
        start: @escaping @Sendable (CheckedContinuation<T, any Error>) -> Void,
        expire: @escaping @Sendable () -> Void
    ) async throws -> T {
        let expiry = Task { [queue] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            queue.async(execute: expire)
        }
        defer { expiry.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { start(continuation) }
        }
    }
}

// MARK: - Pure rules

extension CoreBluetoothTransport {
    static func availability(for state: CBManagerState) -> BLEAvailability {
        switch state {
        case .poweredOn: .ready
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .unknown, .resetting: .unknown
        @unknown default: .unknown
        }
    }

    /// Strongest first. Every robot advertises the same name, so the order has to be
    /// fully determined or the list reshuffles under the user's finger on each sighting.
    static func merging(
        _ snapshot: BLEPeripheralSnapshot,
        into list: [BLEPeripheralSnapshot]
    ) -> [BLEPeripheralSnapshot] {
        // **The manufacturer block is carried across a sighting that lacks one.**
        // CoreBluetooth calls back on every packet it accepts, and that block usually
        // travels in the scan response rather than in the advertisement — so most
        // callbacks legitimately have no `manufacturerData`, and replacing the
        // snapshot wholesale erased the one that did. The field then read nil for
        // ever, which is indistinguishable from a robot whose firmware never sends
        // one. Fresh data still wins: a robot that changed networks is saying so.
        let previous = list.first { $0.id == snapshot.id }
        let merged = BLEPeripheralSnapshot(
            id: snapshot.id,
            name: snapshot.name,
            rssi: snapshot.rssi,
            manufacturerData: snapshot.manufacturerData ?? previous?.manufacturerData
        )
        return (list.filter { $0.id != snapshot.id } + [merged]).sorted {
            if $0.rssi != $1.rssi {
                return $0.rssi > $1.rssi
            }
            if $0.name != $1.name {
                return $0.name < $1.name
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
