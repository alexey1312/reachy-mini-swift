import Foundation

/// What a robot says about itself before anybody connects.
///
/// **Every Reachy Mini advertises the same local name**, so a scan can list three
/// robots and tell you nothing about which is which — telling them apart costs a
/// connection and a read of `…cdef7`. Upstream's PR #1086 puts the answer in the
/// advertisement itself, and this decodes that shape:
///
/// | bytes | meaning                                            |
/// | ----- | -------------------------------------------------- |
/// | 0…1   | company id `0xFFFF`, little-endian — the "no company assigned" value, so it is a convention rather than a
/// registration |
/// | 2     | 1 on a joined network, 0 on the robot's own hotspot |
/// | 3…6   | IPv4, one byte per octet                           |
/// | 7…13  | the first seven bytes of the hardware id           |
///
/// **The robot on hand sends no manufacturer data at all** — measured on 2026-08-13,
/// on a build that keeps the field across sightings and scans with `allowDuplicates`,
/// so the absence is the firmware's rather than the scanner's. This decodes the shape
/// anyway because the PR is merged upstream and the firmware will arrive; until it
/// does, `BLEPeripheralSnapshot` carries the raw bytes and the recovery console prints
/// them, so the next measurement is a glance rather than a build. Everything here
/// answers nil for a robot that sends none, which is
/// exactly what the app did before this existed.
public struct BLEAdvertisement: Sendable, Hashable {
    /// `0xFFFF` is "no company assigned", which is what makes this a convention two
    /// implementations agreed on rather than something the Bluetooth SIG blesses —
    /// so the length and prefix checks below are the whole of the validation.
    static let companyID: UInt16 = 0xFFFF
    private static let length = 14

    /// Whether the address below is on a network this phone could also be on. False
    /// is the robot's own hotspot, whose address is reachable only after joining it —
    /// dialling that from a phone on Wi-Fi reaches somebody else's 10.42.0.1.
    public let isOnLAN: Bool
    public let address: String
    /// **Seven bytes of the sixteen-hex-character id, so it is not a
    /// `deduplicationKey`.** Compare with `hasPrefix`, never for equality; the name
    /// says so because a `==` against a stored key would silently never match.
    public let hardwareIDPrefix: String

    /// - Parameter manufacturerData: `kCBAdvDataManufacturerData`, verbatim.
    /// - Returns: nil for any other manufacturer's block and for a robot whose
    ///   firmware predates the advert. Partly decoding somebody else's payload would
    ///   put a random address in front of a reader as a robot to dial.
    public init?(manufacturerData: Data) {
        let bytes = [UInt8](manufacturerData)
        guard bytes.count >= Self.length else { return nil }
        let company = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard company == Self.companyID else { return nil }

        isOnLAN = bytes[2] == 1
        address = bytes[3 ... 6].map(String.init).joined(separator: ".")
        hardwareIDPrefix = bytes[7 ... 13].map { String(format: "%02x", $0) }.joined()
    }
}
