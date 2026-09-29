import Foundation
import ReachyDesign
import ReachyKit
@testable import ReachyUI
import Testing

/// The robot screen's version warning, which used to be an English sentence built
/// inside `ReachyKit` and so could never be translated.
@Suite("Daemon compatibility captions")
struct DaemonCompatibilityCaptionTests {
    @Test("nothing to warn about says nothing", arguments: [
        nil,
        DaemonCompatibility.supported,
        // Halted on and explained by the update screen, never shown here.
        .unsupported(reported: "1.8.0", minimum: "1.9.0"),
    ] as [DaemonCompatibility?])
    func silent(compatibility: DaemonCompatibility?) {
        #expect(DaemonCompatibilityCaption.warning(for: compatibility) == nil)
    }

    @Test("a newer daemon names the version this app was tested with")
    func newer() throws {
        let warning = try #require(DaemonCompatibilityCaption.warning(
            for: .untestedNewer(reported: "1.12.0", tested: "1.11.0")
        ))

        #expect(String(localized: warning.message) == String(localized: .reachy(
            "This robot's software is newer than this app was tested with. Some features may not work."
        )))
        #expect(warning.testedVersion == "1.11.0")
    }

    /// There is nothing to compare an unreadable version against, so no row either.
    @Test("an unreadable version is said so, with no comparison beside it")
    func unknown() throws {
        let warning = try #require(DaemonCompatibilityCaption.warning(for: .unknown(reported: "dev")))

        #expect(String(localized: warning.message) == String(localized: .reachy(
            "This robot didn't report a software version this app can read. Some features may not work."
        )))
        #expect(warning.testedVersion == nil)
    }

    /// The message is a plain catalogue key, so it is translated rather than falling
    /// back to English — the whole reason the sentence moved out of `ReachyKit`.
    @Test("the warning is translated")
    func translated() throws {
        let warning = try #require(DaemonCompatibilityCaption.warning(
            for: .untestedNewer(reported: "1.12.0", tested: "1.11.0")
        ))
        var russian = warning.message
        russian.locale = Locale(identifier: "ru")

        #expect(String(localized: russian).hasPrefix("ПО этого робота"))
    }
}
