#if DEBUG
    import Foundation

    public extension BLEPeripheralSnapshot {
        /// Fixed ids, not `UUID()`: they key the `ForEach` in the scan list, and a fresh one per
        /// render is a diff in the snapshot for no reason.
        static let previewNear = BLEPeripheralSnapshot(id: previewID(1), name: "Reachy Mini", rssi: -41)
        static let previewFar = BLEPeripheralSnapshot(id: previewID(2), name: "Reachy Mini", rssi: -78)

        /// Two robots with names of their own, which daemon 1.15.0 advertises
        /// (pollen-robotics/reachy_mini#1558). The second is as long as the advert takes,
        /// 29 bytes, so the scan row is seen at its widest.
        static let previewRenamed = BLEPeripheralSnapshot(id: previewID(5), name: "Kitchen", rssi: -44)
        static let previewRenamedLong = BLEPeripheralSnapshot(
            id: previewID(6),
            name: "Reachy in the workshop corner",
            rssi: -71
        )

        /// A robot advertising the block upstream's PR #1086 describes — which no
        /// unit here has been seen doing, so this fixture is the only place the
        /// decoded row can be looked at until one is.
        static let previewAdvertising = BLEPeripheralSnapshot(
            id: previewID(3),
            name: "Reachy Mini",
            rssi: -52,
            manufacturerData: Data([0xFF, 0xFF, 0x01, 192, 168, 1, 42, 0xB6, 0x8F, 0xF6, 0xBB, 0xE4, 0x7F, 0x06])
        )

        /// Somebody else's manufacturer block, which is what an unknown advertisement
        /// looks like: printed as hex rather than decoded, because acting on half of
        /// it would put a stranger's address in front of a reader.
        static let previewUnknownAdvert = BLEPeripheralSnapshot(
            id: previewID(4),
            name: "Reachy Mini",
            rssi: -63,
            manufacturerData: Data([0x4C, 0x00, 0x02, 0x15, 0xDE, 0xAD, 0xBE, 0xEF])
        )

        private static func previewID(_ n: Int) -> UUID {
            UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)") ?? UUID()
        }
    }
#endif
