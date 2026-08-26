import Foundation
@testable import ReachyUI
import Testing

/// The call framing leans on three hand-kept declarations outside the Swift the
/// compiler checks: the background mode that keeps call audio alive, the
/// activity type a Recents redial relaunches under, and the metadata guard's
/// action list. Each can drift silently — the symptom is a call that dies on
/// lock, a redial that opens the app onto nothing, or a release shipping with
/// the intent extracted away — so this suite reads the files the way
/// `ThemeIconNameTests` reads the icon names.
@Suite("Call project lockstep")
struct CallProjectLockstepTests {
    /// Without `audio` the OS suspends the process mid-call the moment the app
    /// leaves the foreground; nothing else in the repository declares the key.
    @Test("the app declares the audio background mode")
    func declaresTheAudioBackgroundMode() throws {
        let manifest = try projectManifest()
        let key = "\"UIBackgroundModes\":"
        guard let keyRange = manifest.range(of: key) else {
            Issue.record("\(key) is absent from Apps/Project.swift")
            return
        }
        let declaration = manifest[keyRange.upperBound...].prefix(120)
        #expect(declaration.contains("\"audio\""))
    }

    /// `CallActivity.activityType` is declared a second time in
    /// `NSUserActivityTypes`; a drifted pair delivers the redial to nobody.
    @Test("the redial activity type is declared")
    func declaresTheRedialActivityType() throws {
        let manifest = try projectManifest()
        let key = "\"NSUserActivityTypes\":"
        guard let keyRange = manifest.range(of: key) else {
            Issue.record("\(key) is absent from Apps/Project.swift")
            return
        }
        guard let close = manifest[keyRange.upperBound...].range(of: "])") else {
            Issue.record("no array literal follows \(key)")
            return
        }
        let declaration = manifest[keyRange.upperBound ..< close.lowerBound]
        #expect(declaration.contains("\"\(CallActivity.activityType)\""))
    }

    /// The metadata check is what notices extraction failing in a Release
    /// build; an intent absent from its list ships green with no Siri phrase.
    @Test("the metadata guard counts the call intent")
    func metadataGuardCountsTheCallIntent() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/check-appintents-metadata.sh"),
            encoding: .utf8
        )
        #expect(script.contains("\"CallRobotIntent\""))
    }
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ReachyUITests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // repo root

private func projectManifest() throws -> String {
    try String(
        contentsOf: repoRoot.appendingPathComponent("Apps/Project.swift"),
        encoding: .utf8
    )
}
