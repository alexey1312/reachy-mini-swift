import Foundation
@testable import ReachyKit
import Testing

/// Protocol v1 of Pollen's embed SDK, as a page posts it and as a host answers.
@Suite("JS app host protocol")
struct JSAppHostProtocolTests {
    private static func message(_ json: String) -> JSAppHostProtocol.PageMessage? {
        JSAppHostProtocol.pageMessage(from: Data(json.utf8))
    }

    @Test("every page message type is read")
    func readsEachType() {
        #expect(Self.message(#"{"source":"reachy-mini","version":1,"type":"embed:ready"}"#) == .ready)
        #expect(Self.message(#"{"source":"reachy-mini","version":1,"type":"embed:request-leave"}"#) == .requestLeave)
        #expect(Self.message(#"{"source":"reachy-mini","version":1,"type":"embed:left"}"#) == .left)
        #expect(Self
            .message(#"{"source":"reachy-mini","version":1,"type":"embed:error","message":"no robot","fatal":true}"#)
            == .error(message: "no robot", fatal: true))
    }

    @Test("an app state carries its phase, its step and the daemon's version")
    func readsAppState() {
        let connecting = Self.message(
            // swiftlint:disable:next line_length
            #"{"source":"reachy-mini","version":1,"type":"embed:app-state","phase":"connecting","connectingStep":"wake","rttMs":null}"#
        )
        #expect(connecting == .appState(.init(phase: .connecting, step: .wake)))

        let live = Self.message(
            // swiftlint:disable:next line_length
            #"{"source":"reachy-mini","version":1,"type":"embed:app-state","phase":"live","daemonVersion":"1.11.0","sdkVersion":"0.9.0"}"#
        )
        #expect(live == .appState(.init(phase: .live, daemonVersion: "1.11.0")))
    }

    /// The SDK ignores a version it does not know, as a forward-compatible
    /// receiver should; so does this.
    @Test("anything outside protocol v1 is ignored")
    func ignoresOtherProtocols() {
        #expect(Self.message(#"{"source":"reachy-mini","version":2,"type":"embed:ready"}"#) == nil)
        #expect(Self.message(#"{"source":"reachy-mini-shell","version":1,"type":"embed:ready"}"#) == nil)
        #expect(Self.message(#"{"type":"save-file","name":"a.png"}"#) == nil)
        #expect(Self.message("not json") == nil)
    }

    @Test("an unknown type or phase is kept by name rather than dropped")
    func keepsTheUnknownByName() {
        #expect(Self.message(#"{"source":"reachy-mini","version":1,"type":"embed:debug","tag":"boot:link:start"}"#)
            == .other(type: "embed:debug"))
        #expect(Self.message(#"{"source":"reachy-mini","version":1,"type":"embed:app-state","phase":"dancing"}"#)
            == .other(type: "embed:app-state"))
    }

    @Test("host:leaving says why and how long the host will wait")
    func encodesLeaving() throws {
        let json = try JSAppHostProtocol.leaving(reason: .userAction, timeout: .milliseconds(9500))

        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["source"] as? String == "reachy-mini")
        #expect(object["version"] as? Int == 1)
        #expect(object["type"] as? String == "host:leaving")
        #expect(object["reason"] as? String == "user-action")
        #expect(object["timeoutMs"] as? Int == 9500)
    }

    @Test("host:theme-changed names the theme")
    func encodesTheme() throws {
        let json = try JSAppHostProtocol.themeChanged(.light)

        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "host:theme-changed")
        #expect(object["theme"] as? String == "light")
    }
}
