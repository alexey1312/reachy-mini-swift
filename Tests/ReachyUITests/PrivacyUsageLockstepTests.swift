import Foundation
import Testing

/// Every privacy prompt this app can raise, declared where the system reads it.
///
/// A missing usage string is not a failed call: TCC kills the process on the first
/// request, with no Swift trace and nothing on stderr (the root `AGENTS.md` says how to
/// find it afterwards). Talking to Reachy from this device asks for two permissions on
/// one press, so both keys, and their translations, are held here.
@Suite("Privacy usage lockstep")
struct PrivacyUsageLockstepTests {
    private static let languages = ["de", "en", "es", "fr", "ru"]

    @Test("the manifest declares the microphone and speech recognition", arguments: [
        "NSMicrophoneUsageDescription",
        "NSSpeechRecognitionUsageDescription",
    ])
    func declares(_ key: String) throws {
        let manifest = try read("Apps/Project.swift")
        #expect(manifest.contains("\"\(key)\":"))
    }

    /// The manifest's English is the source string, and the catalogue is what a device
    /// in another language shows. A key the catalogue never heard of is not caught by
    /// `check-catalogue.py`, which only checks the keys it has.
    @Test("every usage string in the manifest is translated, and its English matches")
    func everyUsageStringIsTranslated() throws {
        let manifest = try read("Apps/Project.swift")
        let catalogue = try JSONSerialization.jsonObject(
            with: Data(read("Apps/ReachyMini/Resources/InfoPlist.xcstrings").utf8)
        ) as? [String: Any]
        let strings = catalogue?["strings"] as? [String: Any] ?? [:]

        let keys = usageKeys(in: manifest)
        #expect(keys.contains("NSSpeechRecognitionUsageDescription"))
        for key in keys {
            let entry = strings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any] ?? [:]
            let missing = Self.languages.filter { localizations[$0] == nil }
            #expect(missing.isEmpty, "\(key) is missing \(missing)")
            let unit = (localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let english = unit?["value"] as? String
            let matches = english.map { manifest.contains("\"\($0)\"") } == true
            #expect(matches, "\(key)'s English differs from the manifest")
        }
    }

    /// The Mac's sandbox has its own gate in front of the microphone, separate from TCC.
    @Test("the macOS app may still open the microphone")
    func macOSEntitlementAllowsAudioInput() throws {
        let entitlements = try read("Apps/ReachyMini/Entitlements/ReachyMini-macOS.entitlements")
        #expect(entitlements.contains("com.apple.security.device.audio-input"))
    }

    private func usageKeys(in manifest: String) -> [String] {
        let pattern = /"(NS[A-Za-z]+UsageDescription)":/
        return manifest.matches(of: pattern).map { String($0.output.1) }
    }
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ReachyUITests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // repo root

private func read(_ path: String) throws -> String {
    try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
}
