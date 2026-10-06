import Foundation
@testable import ReachyKit
import Testing

/// The address a JS app is opened at, checked against what the page's SDK reads:
/// `decodeURIComponent`, then `atob`, then `JSON.parse` of the fragment's `creds`.
@Suite("JS app embed URL")
struct JSAppEmbedTests {
    private static let hello = JSApp(id: "tfrere/reachy-mini-sdkjs-demo-static", title: "Reachy Mini Hello World")
    private static let telepresence = JSApp(
        id: "pollen-robotics/telepresence",
        title: "Telepresence",
        sdk: .server("docker")
    )

    private static func credentials(
        token: String = "hf_narrow",
        hardwareID: String? = "0123456789abcdef",
        theme: JSAppEmbed.Theme = .dark
    ) -> JSAppEmbed.Credentials {
        JSAppEmbed.Credentials(
            hfToken: token,
            userName: "ak",
            robotPeerID: "peer-42",
            robotHardwareID: hardwareID,
            signalingURL: URL(string: "https://pollen-robotics-reachy-mini-central.hf.space")!,
            theme: theme,
            appName: "Reachy Mini Hello World"
        )
    }

    /// The fragment read back the way the SDK reads it.
    private static func decodedCredentials(in url: URL) throws -> [String: Any] {
        let fragment = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment)
        #expect(fragment.hasPrefix("creds="))
        let encoded = String(fragment.dropFirst("creds=".count))
        let base64 = try #require(encoded.removingPercentEncoding)
        let json = try #require(Data(base64Encoded: base64))
        return try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    @Test(
        "a Space id becomes its subdomain",
        arguments: [
            ("tfrere/reachy-mini-sdkjs-demo-static", "tfrere-reachy-mini-sdkjs-demo-static"),
            ("Pollen-Robotics/Marionette_JS", "pollen-robotics-marionette-js"),
            ("someone/a_b_c", "someone-a-b-c"),
            // A dot left in would start a DNS label of its own.
            ("someone/reachy.mini_app.v2", "someone-reachy-mini-app-v2"),
        ]
    )
    func slug(id: String, expected: String) {
        #expect(JSAppEmbed.slug(for: id) == expected)
    }

    @Test("only a static Space is served from a host of its own")
    func origin() {
        #expect(JSAppEmbed.origin(of: Self.hello)?.absoluteString
            == "https://tfrere-reachy-mini-sdkjs-demo-static.static.hf.space")
        #expect(JSAppEmbed.origin(of: Self.telepresence)?.absoluteString
            == "https://pollen-robotics-telepresence.hf.space")
    }

    @Test("the query asks for the embedded mode in the host's theme")
    func query() throws {
        let url = try JSAppEmbed.url(for: Self.hello, credentials: Self.credentials(theme: .light))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/")
        #expect(components.queryItems == [
            URLQueryItem(name: "embedded", value: "1"),
            URLQueryItem(name: "theme", value: "light"),
        ])
    }

    /// The SDK's keys, spelled exactly, with `config` and an unknown hardware id
    /// written as `null` the way upstream writes them.
    @Test("the fragment carries the credentials under the SDK's own keys")
    func credentialKeys() throws {
        let url = try JSAppEmbed.url(for: Self.hello, credentials: Self.credentials())

        let creds = try Self.decodedCredentials(in: url)
        #expect(Set(creds.keys) == [
            "hfToken", "userName", "robotPeerId", "robotHardwareId", "signalingUrl",
            "theme", "config", "hostName", "appName",
        ])
        #expect(creds["hfToken"] as? String == "hf_narrow")
        #expect(creds["userName"] as? String == "ak")
        #expect(creds["robotPeerId"] as? String == "peer-42")
        #expect(creds["robotHardwareId"] as? String == "0123456789abcdef")
        #expect(creds["signalingUrl"] as? String == "https://pollen-robotics-reachy-mini-central.hf.space")
        #expect(creds["theme"] as? String == "dark")
        #expect(creds["config"] is NSNull)
        #expect(creds["hostName"] as? String == "Hey Reachy")
        #expect(creds["appName"] as? String == "Reachy Mini Hello World")
    }

    @Test("an unknown hardware id is written as null, not left out")
    func nullHardwareID() throws {
        let url = try JSAppEmbed.url(for: Self.hello, credentials: Self.credentials(hardwareID: nil))

        let creds = try Self.decodedCredentials(in: url)
        #expect(creds.keys.contains("robotHardwareId"))
        #expect(creds["robotHardwareId"] is NSNull)
    }

    /// Standard base64 carries `+`, `/` and `=`, none of which may stand bare in
    /// a fragment the SDK runs `decodeURIComponent` over.
    @Test("the base64 alphabet's three specials are percent-encoded")
    func percentEncodesTheSpecials() {
        #expect(JSAppEmbed.percentEncoded("a+b/c==") == "a%2Bb%2Fc%3D%3D")
    }

    /// A token that base64-encodes to all three specials still round-trips.
    @Test("the fragment survives a token whose encoding needs escaping")
    func roundTripsAwkwardToken() throws {
        let awkward = "hf_?>?>~~~ünïcode"
        let url = try JSAppEmbed.url(for: Self.hello, credentials: Self.credentials(token: awkward))

        #expect(try Self.decodedCredentials(in: url)["hfToken"] as? String == awkward)
    }
}
