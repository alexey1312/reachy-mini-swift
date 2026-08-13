import CoreBluetooth
import Foundation

/// Every method here runs on the transport's own serial queue — CoreBluetooth delivers
/// both the central's and the peripheral's callbacks on the queue the manager was built
/// with — which is what lets them touch the queue-confined state directly.
extension CoreBluetoothTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let availability = Self.availability(for: central.state)
        publish { $0.availability = availability }
        emit(.availabilityChanged(availability))

        guard availability == .ready else {
            // Switching the radio off drops the link without any disconnect callback,
            // and clears what was found, since none of it is reachable any more.
            publish { $0.discovered = [] }
            emit(.discoveredChanged([]))
            teardown(reason: BLETransportError.unavailable(availability).errorDescription)
            return
        }
        scanIfPossible()
    }

    public func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        // 127 is CoreBluetooth's "no reading", not a very strong signal.
        let reading = rssi.intValue
        guard reading != 127 else { return }
        peripherals[peripheral.identifier] = peripheral

        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let found = BLEPeripheralSnapshot(
            id: peripheral.identifier,
            name: advertised ?? peripheral.name ?? BLEGATT.advertisedName,
            rssi: reading,
            // Carried rather than read here: the local name is identical on every
            // unit, so this is the only thing in an advertisement that could tell
            // two robots apart — and whether this firmware sends any is a hardware
            // question the recovery console exists to answer.
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        )
        let merged = Self.merging(found, into: discovered)
        publish { $0.discovered = merged }
        emit(.discoveredChanged(merged))
    }

    public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([
            CBUUID(string: BLEGATT.commandService),
            CBUUID(string: BLEGATT.statusService),
        ])
    }

    public func centralManager(
        _: CBCentralManager,
        didFailToConnect _: CBPeripheral,
        error: (any Error)?
    ) {
        teardown(reason: error?.localizedDescription ?? "The robot refused the connection.")
    }

    public func centralManager(
        _: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        guard peripheral.identifier == connected?.identifier else { return }
        teardown(reason: error?.localizedDescription)
    }
}

extension CoreBluetoothTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let services = peripheral.services, error == nil else {
            teardown(reason: error?.localizedDescription ?? "The robot offered no Bluetooth services.")
            return
        }
        undiscoveredServices = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard error == nil else {
            teardown(reason: error?.localizedDescription)
            return
        }
        absorb(service.characteristics ?? [])
    }

    public func peripheral(
        _: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard let pending = pendingWrites.removeValue(forKey: characteristic.uuid) else { return }
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }

    /// **A read and a notification are the same callback.** CoreBluetooth gives no way
    /// to tell them apart, so a pending read claims the value and anything else is
    /// treated as pushed. That is not a compromise here: the robot sets the response
    /// characteristic's value either way, so whichever of the two the value came from,
    /// it is the reply the caller is waiting for.
    public func peripheral(
        _: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let pending = pendingReads.removeValue(forKey: characteristic.uuid) {
            if let error {
                pending.resume(throwing: error)
            } else {
                pending.resume(returning: characteristic.value ?? Data())
            }
            return
        }
        guard error == nil, let value = characteristic.value else { return }
        for listener in notificationListeners.values {
            listener.yield(value)
        }
    }

    public func peripheral(
        _: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard let pending = pendingNotifies.removeValue(forKey: characteristic.uuid) else { return }
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }
}
