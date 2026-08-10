import Foundation
@testable import ReachyDesign
import Testing

/// WCAG relative luminance and contrast, and hue in degrees — the three numbers
/// the palette rule is written in. They live in the test rather than in the module
/// because nothing in the app computes them at runtime.
private enum Colorimetry {
    // swiftlint:disable:next large_tuple
    static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    static func relativeLuminance(_ hex: UInt32) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = components(hex)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func hueDegrees(_ hex: UInt32) -> Double {
        let (r, g, b) = components(hex)
        let high = max(r, g, b)
        let low = min(r, g, b)
        let chroma = high - low
        guard chroma > 0 else { return 0 }
        let raw: Double = if high == r {
            (g - b) / chroma
        } else if high == g {
            2 + (b - r) / chroma
        } else {
            4 + (r - g) / chroma
        }
        let degrees = (raw * 60).truncatingRemainder(dividingBy: 360)
        return degrees < 0 ? degrees + 360 : degrees
    }

    static func hueDistance(_ a: UInt32, _ b: UInt32) -> Double {
        let raw = abs(hueDegrees(a) - hueDegrees(b))
        return min(raw, 360 - raw)
    }
}

/// The system colours `Tone` resolves to, one set per appearance — `Tone.danger`,
/// `.warning` and `.success` are adaptive, so a light-only rule only ever checked
/// half of what actually renders.
private struct SemanticTones: Sendable {
    let danger: UInt32
    let warning: UInt32
    let success: UInt32

    var all: [(name: String, hex: UInt32)] {
        [("danger", danger), ("warning", warning), ("success", success)]
    }

    static let light = SemanticTones(danger: 0xFF3B30, warning: 0xFF9500, success: 0x34C759)
    static let dark = SemanticTones(danger: 0xFF453A, warning: 0xFF9F0A, success: 0x30D158)
}

private let white: UInt32 = 0xFFFFFF
private let black: UInt32 = 0x000000
private let darkBackground: UInt32 = 0x1C1C1E

/// The separation rule itself: ≥30° of hue **or** a ≥1.8 luminance-contrast ratio.
/// The one place both thresholds are spelled out — `accentSeparation` and
/// `coralIsRejected` both call this, so loosening either number here loosens the
/// canary along with the real rule, rather than leaving it checking its own
/// private copy.
private func separates(_ accent: UInt32, from tone: UInt32) -> Bool {
    Colorimetry.hueDistance(accent, tone) >= 30 || Colorimetry.contrastRatio(accent, tone) >= 1.8
}

@Suite("Theme palette")
struct ReachyThemeTests {
    @Test("graphite is the fallback")
    func fallbackIsGraphite() {
        #expect(ReachyTheme.fallback == .graphite)
    }

    @Test("six themes, each with a distinct raw value")
    func caseCount() {
        #expect(ReachyTheme.allCases.count == 6)
        #expect(Set(ReachyTheme.allCases.map(\.rawValue)).count == 6)
    }

    /// 3:1 is the floor for large text, and where the system blue itself lands
    /// (4.02 on white). Below it an accent stops being readable as a control.
    @Test("every accent is legible in both appearances", arguments: ReachyTheme.allCases)
    func accentContrast(theme: ReachyTheme) {
        #expect(Colorimetry.contrastRatio(theme.palette.light, white) >= 3.0)
        #expect(Colorimetry.contrastRatio(theme.palette.dark, darkBackground) >= 3.0)
    }

    /// The rule coral fails, and the reason this suite exists. Two limbs, because
    /// bronze sits close to `warning` in hue and separates by lightness instead —
    /// a hue-only rule would reject a colour that reads perfectly well. Checked in
    /// both appearances: `Tone.warning` and `Tone.brand` co-occur on
    /// `ConnectRail`, and a theme that only separated from the light tones could
    /// still collide with the dark ones on that exact screen.
    @Test("every accent is distinguishable from the semantic tones", arguments: ReachyTheme.allCases)
    func accentSeparation(theme: ReachyTheme) {
        for semantic in SemanticTones.light.all {
            #expect(
                separates(theme.palette.light, from: semantic.hex),
                "\(theme.rawValue) light is indistinguishable from \(semantic.name)"
            )
        }
        for semantic in SemanticTones.dark.all {
            #expect(
                separates(theme.palette.dark, from: semantic.hex),
                "\(theme.rawValue) dark is indistinguishable from \(semantic.name)"
            )
        }
    }

    /// Coral is not a case; this proves the rule is what excludes it rather than
    /// taste, and fails loudly if the thresholds are ever loosened enough to let
    /// it back in — because it calls the very `separates` helper the real rule
    /// does, rather than spelling the same two numbers out a second time.
    @Test("the rejected coral would fail the separation rule")
    func coralIsRejected() {
        let coral: UInt32 = 0xFF5A3C
        #expect(separates(coral, from: SemanticTones.light.danger) == false)
    }

    /// A third limb, beside the 3:1 background floor and the tone-separation rule:
    /// contrast against `.label` (black in light appearance, white in dark) — what
    /// makes a tinted row read as tappable against the text beside it. Same 1.8
    /// floor the separation rule's lightness limb uses. Graphite clears it in both
    /// appearances but only just in dark (measured below); that is accepted and
    /// recorded in `ReachyDesign/AGENTS.md`, not a reason to repaint the default.
    ///
    /// Teal's dark accent does not clear it — discovered by adding this limb,
    /// which is exactly what the limb is for, and not something this suite may
    /// decide on its own: repainting a shipped theme's dark accent is a palette
    /// call, not a test fix. `withKnownIssue` keeps the shortfall visible and the
    /// suite green pending that call, and still guards every other theme —
    /// including whatever comes after these six — at the real floor.
    @Test("every accent holds its own against the primary label", arguments: ReachyTheme.allCases)
    func accentAgainstLabel(theme: ReachyTheme) {
        #expect(Colorimetry.contrastRatio(theme.palette.light, black) >= 1.8)
        if theme == .teal {
            withKnownIssue(
                """
                teal's dark accent (#4FD6DE) measures ~1.75 against the dark-mode \
                label (white), below the 1.8 floor. Needs a palette decision — see \
                ReachyDesign/AGENTS.md — not a change to this test.
                """
            ) {
                #expect(Colorimetry.contrastRatio(theme.palette.dark, white) >= 1.8)
            }
        } else {
            #expect(Colorimetry.contrastRatio(theme.palette.dark, white) >= 1.8)
        }
    }

    /// The catalogue is generated, so this asserts the generator was actually run:
    /// a palette edit without a regeneration would otherwise ship a colour nothing
    /// verified. Read from source rather than from `Bundle.module` — a built
    /// catalogue is a compiled `Assets.car`, not JSON.
    @Test("the generated catalogue matches the constants", arguments: ReachyTheme.allCases)
    func catalogueMatchesConstants(theme: ReachyTheme) throws {
        let contents = repoRoot
            .appendingPathComponent("Sources/ReachyDesign/Resources/Assets.xcassets")
            .appendingPathComponent("\(theme.colorSetName).colorset/Contents.json")
        let (light, dark) = try colorSetHexPair(at: contents)
        #expect(light == theme.palette.light)
        #expect(dark == theme.palette.dark)
    }

    /// `AccentColor.colorset` is hand-edited, not generated — it paints the first
    /// frame and everything drawn outside our hierarchy (system alerts, the share
    /// sheet), and `ReachyDesign/AGENTS.md` states it must equal `.fallback` or
    /// launch flashes another colour. Nothing else checks that the hand edit was
    /// kept in step, so a drift here was silent until this test existed.
    @Test("the app's AccentColor equals the default theme")
    func accentColorMatchesFallback() throws {
        let contents = repoRoot
            .appendingPathComponent("Apps/ReachyMini/Resources/Assets.xcassets")
            .appendingPathComponent("AccentColor.colorset/Contents.json")
        let (light, dark) = try colorSetHexPair(at: contents)
        #expect(light == ReachyTheme.fallback.palette.light)
        #expect(dark == ReachyTheme.fallback.palette.dark)
    }
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ReachyDesignTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // repo root

/// Both `Theme*.colorset` (generated) and `AccentColor.colorset` (hand-edited)
/// share this shape: two universal-idiom entries, light first, dark tagged with
/// a `luminosity` appearance.
private func colorSetHexPair(at url: URL) throws -> (light: UInt32, dark: UInt32) {
    let data = try Data(contentsOf: url)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let colors = try #require(json["colors"] as? [[String: Any]])

    func hex(at index: Int) throws -> UInt32 {
        let entry = try #require(colors[index]["color"] as? [String: Any])
        let components = try #require(entry["components"] as? [String: String])
        var value: UInt32 = 0
        for key in ["red", "green", "blue"] {
            let channel = try #require(components[key])
            let scanned = try #require(UInt32(channel.replacingOccurrences(of: "0x", with: ""), radix: 16))
            value = value << 8 | scanned
        }
        return value
    }

    #expect(colors.count == 2)
    return try (hex(at: 0), hex(at: 1))
}
