import Foundation

/// A file of its own because `CoreBluetoothTransport.swift` reached SwiftLint's length limit.
extension CoreBluetoothTransport {
    /// Strongest first. Robots nobody renamed advertise the same name, so the order has to
    /// be fully determined or the list reshuffles under the user's finger on each sighting.
    ///
    /// `namedByAdvert` says whether this sighting carried a local name of its own, or
    /// whether `snapshot.name` is the fallback (the name iOS cached, or `ReachyMini`).
    static func merging(
        _ snapshot: BLEPeripheralSnapshot,
        namedByAdvert: Bool = true,
        into list: [BLEPeripheralSnapshot]
    ) -> [BLEPeripheralSnapshot] {
        // **The manufacturer block is carried across a sighting that lacks one.**
        // CoreBluetooth calls back on every packet it accepts, and that block usually
        // travels in the scan response rather than in the advertisement — so most
        // callbacks legitimately have no `manufacturerData`, and replacing the
        // snapshot wholesale erased the one that did. The field then read nil for
        // ever, which is indistinguishable from a robot whose firmware never sends
        // one. Fresh data still wins: a robot that changed networks is saying so.
        //
        // **The name is carried the same way, for the same reason.** From daemon 1.15.0
        // a renamed robot advertises its name (pollen-robotics/reachy_mini#1558), and
        // BlueZ puts it in the scan response, because the 128-bit service UUID fills the
        // advert. A sighting without it falls back to a name that may be the old one,
        // and taking that made a renamed robot change its name between two sightings.
        let previous = list.first { $0.id == snapshot.id }
        let merged = BLEPeripheralSnapshot(
            id: snapshot.id,
            name: namedByAdvert ? snapshot.name : previous?.name ?? snapshot.name,
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
