import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

@Suite("RobotAddress")
struct RobotAddressTests {
    @Test("root URL for a hostname")
    func rootURLHostname() {
        let address = RobotAddress(host: "reachy-mini.local")
        #expect(address.rootURL?.absoluteString == "http://reachy-mini.local:8000")
    }

    @Test("IPv6 literal is bracketed (upstream issue #269 regression)")
    func ipv6Bracketing() {
        let address = RobotAddress(host: "fd00::1234", port: 8000)
        #expect(address.rootURL?.absoluteString == "http://[fd00::1234]:8000")
        #expect(address.webSocketURL(path: "/api/state/ws/full")?.absoluteString
            == "ws://[fd00::1234]:8000/api/state/ws/full")
    }

    /// The daemon's local-network guard (reachy_mini#1423) accepts a name only when it
    /// ends in `.local`, so a fully qualified `reachy-mini.local.` would be a 400.
    @Test(
        "a trailing dot never reaches the Host header",
        arguments: ["reachy-mini.local.", "reachy-mini.local.:8000", "  reachy-mini.local.  "]
    )
    func dropsTheTrailingDot(input: String) throws {
        let address = try #require(RobotAddress(parsing: input))
        #expect(address.host == "reachy-mini.local")
        #expect(address.rootURL?.absoluteString == "http://reachy-mini.local:8000")
    }

    /// A record written before the normalisation decodes straight into the stored
    /// property, so the URL builder has to apply it as well.
    @Test("a stored address with a trailing dot still builds a URL without it")
    func dropsTheTrailingDotFromAStoredAddress() throws {
        let stored = Data(#"{"host": "reachy-mini.local.", "port": 8000}"#.utf8)
        let address = try JSONCodec.stored.decode(RobotAddress.self, from: stored)
        #expect(address.webSocketURL(path: "/api/state/ws/full")?.absoluteString
            == "ws://reachy-mini.local:8000/api/state/ws/full")
    }

    @Test("custom port is preserved")
    func customPort() {
        let address = RobotAddress(host: "10.0.0.5", port: 9000)
        #expect(address.rootURL?.absoluteString == "http://10.0.0.5:9000")
    }

    @Test(
        "parses user input with optional port (phone-testing regression: ip:port was bracketed as IPv6)",
        arguments: [
            ("192.168.50.75", "192.168.50.75", 8000),
            ("192.168.50.75:8000", "192.168.50.75", 8000),
            ("192.168.50.75:9001", "192.168.50.75", 9001),
            ("reachy-mini.local", "reachy-mini.local", 8000),
            ("reachy-mini.local:8000", "reachy-mini.local", 8000),
            ("fd00::1234", "fd00::1234", 8000),
            ("[fd00::1234]", "fd00::1234", 8000),
            ("[fd00::1234]:9001", "fd00::1234", 9001),
            (" 10.0.0.5 ", "10.0.0.5", 8000),
        ]
    )
    func parsing(input: String, host: String, port: Int) {
        let address = RobotAddress(parsing: input)
        #expect(address?.host == host)
        #expect(address?.port == port)
    }

    @Test("rejects garbage input", arguments: ["", "  ", "host:notaport", "[fd00::1234", "[fd00::1]x"])
    func parsingRejects(input: String) {
        #expect(RobotAddress(parsing: input) == nil)
    }
}
