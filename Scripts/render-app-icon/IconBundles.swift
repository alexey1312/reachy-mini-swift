// The six Icon Composer bundles, one per theme: iPhone, iPad and Mac.

import CoreGraphics
import Foundation

// MARK: - Themes

/// A duplicate of `ReachyTheme.palette`'s gradient stops, for the reason
/// `render-theme-colors.swift` carries one of the accents: a standalone program
/// cannot link `ReachyDesign`. `ThemeIconNameTests.iconGradientMatchesPalette` reads
/// the generated documents back and is what catches the two copies drifting apart —
/// it does not keep them together, so edit both by hand.
struct IconTheme {
    let bundleName: String
    let gradientTop: UInt32
    let gradientBottom: UInt32
}

let iconThemes = [
    IconTheme(bundleName: "AppIcon", gradientTop: 0x9AA6B8, gradientBottom: 0x3E4757),
    IconTheme(bundleName: "AppIcon-Bronze", gradientTop: 0xFFC96B, gradientBottom: 0xB26708),
    IconTheme(bundleName: "AppIcon-Teal", gradientTop: 0x5FE0CE, gradientBottom: 0x00A0A8),
    IconTheme(bundleName: "AppIcon-Indigo", gradientTop: 0x9B9BF5, gradientBottom: 0x4B47D6),
    IconTheme(bundleName: "AppIcon-Orchid", gradientTop: 0xE8AEFF, gradientBottom: 0x9038D9),
    IconTheme(bundleName: "AppIcon-Rose", gradientTop: 0xFFA8CE, gradientBottom: 0xD6248A),
]

// MARK: - Output

/// Icon Composer writes a fill stop as a colour-space prefix and four fractions.
/// `srgb:` rather than `display-p3:` because the palette constants are sRGB and a
/// conversion here would be a second place for a colour to be defined.
func fillStop(_ hex: UInt32) -> String {
    String(
        format: "srgb:%.5f,%.5f,%.5f,1.00000",
        Double((hex >> 16) & 0xFF) / 255,
        Double((hex >> 8) & 0xFF) / 255,
        Double(hex & 0xFF) / 255
    )
}

func writeIconBundle(_ theme: IconTheme, glyph: CGImage, in resources: URL) throws {
    let bundle = resources.appendingPathComponent("\(theme.bundleName).icon")
    try? FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(
        at: bundle.appendingPathComponent("Assets"),
        withIntermediateDirectories: true
    )
    writePNG(glyph, to: bundle.appendingPathComponent("Assets/robot.png"))

    let document: [String: Any] = [
        "fill": ["linear-gradient": [fillStop(theme.gradientTop), fillStop(theme.gradientBottom)]],
        "groups": [[
            "layers": [["image-name": "robot.png", "name": "Robot"]],
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": false, "value": 0.5],
        ]],
        "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
    ]
    // `.sortedKeys` is what makes a re-run byte-identical; without it the dictionary's
    // order is the hash order and every run dirties the diff.
    let data = try JSONSerialization.data(
        withJSONObject: document,
        options: [.prettyPrinted, .sortedKeys]
    )
    let json = String(data: data, encoding: .utf8)! + "\n"
    try json.write(to: bundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote \(bundle.path)")
}
