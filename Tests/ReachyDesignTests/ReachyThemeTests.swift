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

/// The system colours `Tone` resolves to, in light appearance.
private enum SemanticTone {
    static let danger: UInt32 = 0xFF3B30
    static let warning: UInt32 = 0xFF9500
    static let success: UInt32 = 0x34C759
    static let all: [(name: String, hex: UInt32)] = [
        ("danger", danger), ("warning", warning), ("success", success),
    ]
}

private let white: UInt32 = 0xFFFFFF
private let darkBackground: UInt32 = 0x1C1C1E

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
    /// bronze sits 1.5 degrees from `warning` and separates by lightness instead —
    /// a hue-only rule would reject a colour that reads perfectly well.
    @Test("every accent is distinguishable from the semantic tones", arguments: ReachyTheme.allCases)
    func accentSeparation(theme: ReachyTheme) {
        for semantic in SemanticTone.all {
            let hueApart = Colorimetry.hueDistance(theme.palette.light, semantic.hex) >= 30
            let lightnessApart = Colorimetry.contrastRatio(theme.palette.light, semantic.hex) >= 1.8
            #expect(
                hueApart || lightnessApart,
                "\(theme.rawValue) is indistinguishable from \(semantic.name)"
            )
        }
    }

    /// Coral is not a case; this proves the rule is what excludes it rather than
    /// taste, and fails loudly if the thresholds are ever loosened enough to let
    /// it back in.
    @Test("the rejected coral would fail the separation rule")
    func coralIsRejected() {
        let coral: UInt32 = 0xFF5A3C
        let hueApart = Colorimetry.hueDistance(coral, SemanticTone.danger) >= 30
        let lightnessApart = Colorimetry.contrastRatio(coral, SemanticTone.danger) >= 1.8
        #expect(hueApart == false)
        #expect(lightnessApart == false)
    }

    /// The catalogue is generated, so this asserts the generator was actually run:
    /// a palette edit without a regeneration would otherwise ship a colour nothing
    /// verified. Read from source rather than from `Bundle.module` — a built
    /// catalogue is a compiled `Assets.car`, not JSON.
    @Test("the generated catalogue matches the constants", arguments: ReachyTheme.allCases)
    func catalogueMatchesConstants(theme: ReachyTheme) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ReachyDesignTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let contents = root
            .appendingPathComponent("Sources/ReachyDesign/Resources/Assets.xcassets")
            .appendingPathComponent("\(theme.colorSetName).colorset/Contents.json")

        let data = try Data(contentsOf: contents)
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
        let light = try hex(at: 0)
        let dark = try hex(at: 1)
        #expect(light == theme.palette.light)
        #expect(dark == theme.palette.dark)
    }
}
