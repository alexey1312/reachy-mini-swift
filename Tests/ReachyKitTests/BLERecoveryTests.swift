import Foundation
@testable import ReachyKit
import Testing

@Suite("BLE journal reassembly")
struct BLEJournalReaderTests {
    @Test("a line cut between two reads comes back out whole")
    func joinsAcrossChunks() {
        var reader = BLEJournalReader()

        #expect(reader.ingest("abc\ndef") == ["abc"])
        #expect(reader.ingest("ghi\njkl") == ["defghi"])
        #expect(reader.flush() == ["jkl"])
    }

    @Test("a chunk that ends on a newline holds nothing back")
    func handsOverCompleteChunks() {
        var reader = BLEJournalReader()

        #expect(reader.ingest("one\ntwo\n") == ["one", "two"])
        #expect(reader.flush().isEmpty)
    }

    @Test("an empty poll is not an empty line — the robot answers those constantly")
    func ignoresEmptyChunks() {
        var reader = BLEJournalReader()
        _ = reader.ingest("partial")

        #expect(reader.ingest("").isEmpty)
        #expect(reader.flush() == ["partial"])
    }

    @Test("a chunk with no newline at all is held until one arrives")
    func withholdsUnterminatedText() {
        var reader = BLEJournalReader()

        #expect(reader.ingest("a").isEmpty)
        #expect(reader.ingest("b").isEmpty)
        #expect(reader.ingest("c\n") == ["abc"])
    }
}

@Suite("BLE recovery scripts")
struct BLERecoveryScriptTests {
    @Test("the characteristic is a directory listing, comma-and-space joined")
    func parsesTheListing() {
        let scripts = BLERecoveryScript.parse("RESTART_DAEMON, HOTSPOT, WIFI_RESET")

        #expect(scripts.map(\.name) == ["RESTART_DAEMON", "HOTSPOT", "WIFI_RESET"])
    }

    @Test("an empty commands directory reads as the literal None")
    func parsesTheEmptyListing() {
        #expect(BLERecoveryScript.parse("None").isEmpty)
        #expect(BLERecoveryScript.parse("  ").isEmpty)
    }

    @Test("a script this build has never heard of is never presented as harmless")
    func treatsUnknownScriptsAsDisruptive() {
        let unknown = BLERecoveryScript.describing("FACTORY_WIPE")

        #expect(unknown.severity == .disruptive)
        #expect(unknown.name == "FACTORY_WIPE")
    }

    @Test("each known script is titled in words, and an unknown one by its file name")
    func scriptsHaveTitles() {
        #expect(BLERecoveryScript.describing("RESTART_DAEMON").title == "Restart the robot's software")
        #expect(BLERecoveryScript.describing("SOFTWARE_RESET").title == "Software reset")
        #expect(BLERecoveryScript.describing("FACTORY_WIPE").title == "FACTORY_WIPE")
    }

    @Test("the destructive one is classified as such, and the restart as routine")
    func classifiesTheKnownScripts() {
        #expect(BLERecoveryScript.describing("SOFTWARE_RESET").severity == .destructive)
        #expect(BLERecoveryScript.describing("RESTART_DAEMON").severity == .routine)
        #expect(BLERecoveryScript.describing("HOTSPOT").severity == .disruptive)
        #expect(BLERecoveryScript.describing("WIFI_RESET").severity == .disruptive)
    }

    @Test("the order is fixed here, because os.listdir's is not")
    func ordersTheListStably() {
        let one = BLERecoveryScript.parse("SOFTWARE_RESET, WIFI_RESET, RESTART_DAEMON, HOTSPOT")
        let other = BLERecoveryScript.parse("HOTSPOT, SOFTWARE_RESET, RESTART_DAEMON, WIFI_RESET")

        #expect(one.map(\.name) == other.map(\.name))
        #expect(one.map(\.name) == ["RESTART_DAEMON", "HOTSPOT", "WIFI_RESET", "SOFTWARE_RESET"])
    }
}
