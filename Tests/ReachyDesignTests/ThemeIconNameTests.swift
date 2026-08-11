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

    @Test("every theme has a committed icon bundle", arguments: ReachyTheme.allCases)
    func everyThemeHasAnIconBundle(_ theme: ReachyTheme) {
        let bundle = iconBundle(for: theme)
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("icon.json").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Assets/robot.png").path))
    }

    @Test("every icon's gradient matches its theme's palette", arguments: ReachyTheme.allCases)
    func iconGradientMatchesPalette(_ theme: ReachyTheme) throws {
        let (top, bottom) = try iconGradient(of: theme)
        #expect(top == theme.palette.gradientTop)
        #expect(bottom == theme.palette.gradientBottom)
    }

    @Test("the glyph is shared byte for byte across the six bundles")
    func glyphIsShared() throws {
        let glyphs = try ReachyTheme.allCases.map {
            try Data(contentsOf: iconBundle(for: $0).appendingPathComponent("Assets/robot.png"))
        }
        #expect(glyphs.map { $0 == glyphs[0] }.contains(false) == false)
    }
}

private func iconBundle(for theme: ReachyTheme) -> URL {
    repoRoot
        .appendingPathComponent("Apps/ReachyMini/Resources")
        .appendingPathComponent("\(theme.alternateIconName ?? "AppIcon").icon")
}

/// `icon.json` stores a fill stop as `"srgb:0.60392,0.65098,0.72157,1.00000"`.
/// Reading it back and rounding to 8 bits is what makes the generated document
/// comparable with the `UInt32` constants it was written from.
private func iconGradient(of theme: ReachyTheme) throws -> (top: UInt32, bottom: UInt32) {
    let data = try Data(contentsOf: iconBundle(for: theme).appendingPathComponent("icon.json"))
    let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let fill = document?["fill"] as? [String: Any]
    guard let stops = fill?["linear-gradient"] as? [String], stops.count == 2 else {
        Issue.record("\(theme) has no two-stop linear gradient")
        return (0, 0)
    }
    return (hex(fromFillStop: stops[0]), hex(fromFillStop: stops[1]))
}

private func hex(fromFillStop stop: String) -> UInt32 {
    let components = stop.replacingOccurrences(of: "srgb:", with: "").split(separator: ",")
    guard components.count == 4 else {
        Issue.record("malformed fill stop \(stop)")
        return 0
    }
    let channels = components.prefix(3).map { UInt32((Double($0) ?? 0) * 255 + 0.5) }
    return channels[0] << 16 | channels[1] << 8 | channels[2]
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
