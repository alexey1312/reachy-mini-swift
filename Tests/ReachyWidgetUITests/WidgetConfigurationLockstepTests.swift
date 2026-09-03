import AppIntents
import Foundation
@testable import ReachyWidgetUI
import Testing

/// The `@Parameter(size:)` guard is three hand-kept spellings living outside the
/// Swift the compiler checks: the metadata tag `check-appintents-metadata.sh`
/// keys on, the intent's name, and the parameter's. It is also a guard that
/// nothing on a push to `main` runs — every caller of that script is a Release
/// build or a release script, and both Release app-build jobs are
/// `pull_request`-only — so drift there ships green and surfaces at a release.
///
/// This reads the script the way `CallProjectLockstepTests` reads it for the call
/// intent, and for the same reason.
@Suite("Widget configuration lockstep")
struct WidgetConfigurationLockstepTests {
    /// The tag is the metadata processor's, not ours, so it can only be pinned by
    /// spelling. Losing it does not fail the guard loudly: `collection_sizes`
    /// would return `None` for every parameter and the whole rule would pass
    /// vacuously — which is what the required-list arm is there to turn back into
    /// a failure, and what this asserts is still wired up.
    @Test("the metadata guard asserts the widget's collection sizes")
    func metadataGuardAssertsCollectionSizes() throws {
        let script = try metadataGuard()
        #expect(script.contains("LNValueTypeMetadataKeyCollectionSizes"))
        #expect(script.contains("(\"RobotAppsConfigurationIntent\", \"apps\")"))
    }

    /// `name` in `extract.actionsdata` is the Swift property's, so the string in
    /// the script is that property spelled a second time. `Mirror` reports the
    /// `@Parameter` wrapper's storage — `_apps` — hence the strip; asserting on
    /// the wrapped name is what makes a rename fail here rather than at an upload.
    @Test("the guarded parameter is the one the intent declares")
    func guardedParameterMatchesTheIntent() {
        let declared = Mirror(reflecting: RobotAppsConfigurationIntent())
            .children
            .compactMap(\.label)
            .map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }

        #expect(declared.contains("apps"))
    }
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ReachyWidgetUITests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // repo root

private func metadataGuard() throws -> String {
    try String(
        contentsOf: repoRoot.appendingPathComponent("Scripts/check-appintents-metadata.sh"),
        encoding: .utf8
    )
}
