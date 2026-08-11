import Foundation
@testable import ReachyDesign
import Testing

/// The build setting and the enum are two hand-kept lists of the same names, in two
/// languages, and nothing else compares them: a theme whose icon is missing from
/// `Apps/Project.swift` compiles, ships, and fails inside `setAlternateIconName` on a
/// device. That is what this suite exists to prevent.
@Suite("Theme icon names")
struct ThemeIconNameTests {
    @Test("the fallback theme uses the primary icon")
    func fallbackUsesPrimaryIcon() {
        #expect(ReachyTheme.fallback.alternateIconName == nil)
    }

    @Test("every other theme names an alternate icon")
    func everyOtherThemeNamesAnAlternate() {
        let others = ReachyTheme.allCases.filter { $0 != .fallback }
        #expect(others.count == 5)
        #expect(others.map { $0.alternateIconName == nil }.contains(true) == false)
    }

    @Test("alternate names are unique")
    func alternateNamesAreUnique() {
        let names = ReachyTheme.allCases.compactMap(\.alternateIconName)
        #expect(Set(names).count == names.count)
    }

    @Test("every alternate name is declared in the build settings")
    func everyAlternateNameIsDeclared() throws {
        let declared = try declaredAlternateIconNames()
        let wanted = Set(ReachyTheme.allCases.compactMap(\.alternateIconName))
        #expect(declared == wanted)
    }
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ReachyDesignTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // repo root

/// Reads the space-separated value of `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`
/// out of the Tuist manifest. Parsing Swift with string search is crude, and it is what
/// `ReachyThemeTests.accentColorMatchesFallback` already does to the asset catalogue —
/// the alternative is no check at all.
private func declaredAlternateIconNames() throws -> Set<String> {
    let manifest = try String(
        contentsOf: repoRoot.appendingPathComponent("Apps/Project.swift"),
        encoding: .utf8
    )
    let key = "\"ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES[sdk=iphone*]\":"
    guard let keyRange = manifest.range(of: key) else {
        Issue.record("\(key) is absent from Apps/Project.swift")
        return []
    }
    let tail = manifest[keyRange.upperBound...]
    guard let open = tail.firstIndex(of: "\"") else {
        Issue.record("no string literal follows \(key)")
        return []
    }
    let afterOpen = tail.index(after: open)
    guard let close = tail[afterOpen...].firstIndex(of: "\"") else {
        Issue.record("unterminated string literal after \(key)")
        return []
    }
    return Set(tail[afterOpen ..< close].split(separator: " ").map(String.init))
}
