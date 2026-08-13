import Foundation
@testable import ReachyKit
import Testing

/// What an advertisement carries besides its name.
///
/// Every Reachy Mini advertises the same `ReachyMini`, so until a client connects
/// and reads `…cdef7` it cannot tell two of them apart. Upstream's PR #1086 puts a
/// flag, an IPv4 address and the first seven bytes of the hardware id into
/// `ManufacturerData` under `0xFFFF` — **and no robot here has been seen doing it**.
/// So this decodes what that PR describes and reports nil for everything else,
/// which is what a robot on older firmware looks like.
@Suite("BLE advertisement")
struct BLEAdvertisementTests {
    /// `0xFFFF` little-endian, the LAN flag, 192.168.1.42, seven id bytes.
    private let pollenAdvert = Data([
        0xFF, 0xFF,
        0x01,
        192, 168, 1, 42,
        0xB6, 0x8F, 0xF6, 0xBB, 0xE4, 0x7F, 0x06,
    ])

    @Test("the Pollen block decodes to an address and an id prefix")
    func decodesPollenBlock() throws {
        let advert = try #require(BLEAdvertisement(manufacturerData: pollenAdvert))

        #expect(advert.address == "192.168.1.42")
        #expect(advert.hardwareIDPrefix == "b68ff6bbe47f06")
        #expect(advert.isOnLAN)
    }

    /// The flag is what says whether that address is reachable from this phone or is
    /// the robot's own hotspot — an address on a network nobody is on is worse than
    /// no address, because it reads as a robot that can be dialled.
    @Test("the hotspot flag is carried rather than assumed")
    func readsTheFlag() throws {
        var hotspot = pollenAdvert
        hotspot[2] = 0x00

        #expect(try #require(BLEAdvertisement(manufacturerData: hotspot)).isOnLAN == false)
    }

    /// Every other manufacturer's block, and every robot whose firmware predates the
    /// advert, land here. Nil rather than a partly filled value: a client that acted
    /// on half of somebody else's payload would dial an address at random.
    @Test("anything that is not the Pollen block is refused", arguments: [
        Data(),
        Data([0x4C, 0x00, 0x01, 0x02]),
        Data([0xFF, 0xFF]),
        Data([0xFF, 0xFF, 0x01, 192, 168]),
    ])
    func refusesEverythingElse(data: Data) {
        #expect(BLEAdvertisement(manufacturerData: data) == nil)
    }

    /// The prefix is seven of the sixteen hex characters' worth of bytes, so it is not
    /// a `deduplicationKey` and must never be compared against one whole. Matching is
    /// `hasPrefix`, which is why it is exposed as its own name.
    @Test("the prefix is a prefix of the full hardware id")
    func prefixesTheHardwareID() throws {
        let advert = try #require(BLEAdvertisement(manufacturerData: pollenAdvert))

        #expect("b68ff6bbe47f0608".hasPrefix(advert.hardwareIDPrefix))
    }
}
