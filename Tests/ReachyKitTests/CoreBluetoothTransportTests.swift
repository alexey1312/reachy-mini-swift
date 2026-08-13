import CoreBluetooth
import Foundation
@testable import ReachyKit
import Testing

/// The adapter needs a radio and a Linux robot, so what is checked here are the two
/// rules that carry a decision rather than a CoreBluetooth call: what the user is told
/// when Bluetooth cannot be used, and the order robots are offered in.
@Suite("CoreBluetoothTransport")
struct CoreBluetoothTransportTests {
    private static func robot(
        _ id: String,
        name: String = "ReachyMini",
        rssi: Int,
        manufacturerData: Data? = nil
    ) -> BLEPeripheralSnapshot {
        BLEPeripheralSnapshot(
            id: UUID(uuidString: id)!,
            name: name,
            rssi: rssi,
            manufacturerData: manufacturerData
        )
    }

    private static let near = "00000000-0000-0000-0000-0000000000AA"
    private static let far = "00000000-0000-0000-0000-0000000000BB"

    @Test("every manager state maps to something the screen can explain")
    func mapsManagerStates() {
        #expect(CoreBluetoothTransport.availability(for: .poweredOn) == .ready)
        #expect(CoreBluetoothTransport.availability(for: .poweredOff) == .poweredOff)
        #expect(CoreBluetoothTransport.availability(for: .unauthorized) == .unauthorized)
        // What every iOS Simulator run reports, so it needs a screen of its own.
        #expect(CoreBluetoothTransport.availability(for: .unsupported) == .unsupported)
        // Resetting is temporary, so it must not look like a permanent refusal.
        #expect(CoreBluetoothTransport.availability(for: .resetting) == .unknown)
        #expect(CoreBluetoothTransport.availability(for: .unknown) == .unknown)
    }

    @Test("a fresh sighting replaces the earlier reading rather than duplicating it")
    func replacesRepeatSightings() throws {
        let list = CoreBluetoothTransport.merging(Self.robot(Self.near, rssi: -80), into: [])
        let updated = CoreBluetoothTransport.merging(Self.robot(Self.near, rssi: -45), into: list)

        #expect(try updated.map(\.id) == [#require(UUID(uuidString: Self.near))])
        #expect(updated.first?.rssi == -45)
    }

    /// **A later sighting carrying no manufacturer data must not erase an earlier one
    /// that did.** CoreBluetooth calls back on every packet it accepts, and the
    /// manufacturer block often travels in the scan response rather than in the
    /// advertisement — so the field is absent from most callbacks by design. Replacing
    /// the snapshot wholesale left it nil for ever, which reads exactly like a robot
    /// whose firmware never sends one.
    @Test("a sighting without manufacturer data keeps the last one that had it")
    func keepsManufacturerDataAcrossSightings() {
        let advert = Data([0xFF, 0xFF, 0x01, 192, 168, 1, 42, 0xB6, 0x8F, 0xF6, 0xBB, 0xE4, 0x7F, 0x06])
        var list = CoreBluetoothTransport.merging(
            Self.robot(Self.near, rssi: -50, manufacturerData: advert),
            into: []
        )
        list = CoreBluetoothTransport.merging(Self.robot(Self.near, rssi: -48), into: list)

        #expect(list.first?.manufacturerData == advert)
        #expect(list.first?.advertisement?.address == "192.168.1.42")
        // The reading itself is still the newest one — only the absent field is carried.
        #expect(list.first?.rssi == -48)
    }

    /// A robot that starts sending a different block replaces it: this is a robot
    /// changing networks, not a packet that happened to omit the field.
    @Test("fresh manufacturer data replaces the stored one")
    func newerManufacturerDataWins() {
        let first = Data([0xFF, 0xFF, 0x01, 192, 168, 1, 42, 1, 2, 3, 4, 5, 6, 7])
        let second = Data([0xFF, 0xFF, 0x00, 10, 42, 0, 1, 1, 2, 3, 4, 5, 6, 7])
        var list = CoreBluetoothTransport.merging(
            Self.robot(Self.near, rssi: -50, manufacturerData: first),
            into: []
        )
        list = CoreBluetoothTransport.merging(
            Self.robot(Self.near, rssi: -50, manufacturerData: second),
            into: list
        )

        #expect(list.first?.advertisement?.address == "10.42.0.1")
        #expect(list.first?.advertisement?.isOnLAN == false)
    }

    @Test("the strongest signal is offered first")
    func ordersByStrength() {
        var list = CoreBluetoothTransport.merging(Self.robot(Self.far, rssi: -88), into: [])
        list = CoreBluetoothTransport.merging(Self.robot(Self.near, rssi: -40), into: list)

        #expect(list.map(\.rssi) == [-40, -88])
    }

    /// Robots advertise one shared name, so ties are common and an order that depends on
    /// arrival would reshuffle the list under the user's finger on every sighting.
    @Test("two indistinguishable robots keep the same order whichever arrives first")
    func ordersTiesDeterministically() {
        let first = CoreBluetoothTransport.merging(
            Self.robot(Self.far, rssi: -60),
            into: [Self.robot(Self.near, rssi: -60)]
        )
        let second = CoreBluetoothTransport.merging(
            Self.robot(Self.near, rssi: -60),
            into: [Self.robot(Self.far, rssi: -60)]
        )

        #expect(first.map(\.id) == second.map(\.id))
    }
}
