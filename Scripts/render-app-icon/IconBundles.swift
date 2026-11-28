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

/// `hex` blended toward black by `amount`, 0 to 1.
func darkened(_ hex: UInt32, by amount: Double) -> UInt32 {
    func channel(_ shift: UInt32) -> UInt32 {
        UInt32((Double((hex >> shift) & 0xFF) * (1 - amount)).rounded()) << shift
    }
    return channel(16) | channel(8) | channel(0)
}

extension IconTheme {
    /// The dark appearance's background: the theme's own hue, deep. Without it the
    /// system puts the same near-black behind every theme, and in Dark Mode the six
    /// icons cannot be told apart.
    var darkFill: [UInt32] {
        [darkened(gradientBottom, by: 0.45), darkened(gradientBottom, by: 0.78)]
    }

    /// A layer's colour in the dark and tinted appearances, where it differs from the
    /// light one the SVG carries.
    ///
    /// - Dark: ink antennas vanish into a dark background, so they take the theme's
    ///   light stop and become its accent.
    /// - Tinted (and Clear, which the system derives from it): the system keeps only
    ///   each layer's luminance, so the antennas turn white to stay visible against the
    ///   dark background, and the goggles turn black: their grey rims and ink lenses
    ///   otherwise come out as a dim tint barely apart from the shell's.
    func specializations(of layer: RobotLayer) -> [(appearance: String, color: UInt32)] {
        switch layer.name {
        case "Antennas": [("dark", gradientTop), ("tinted", white)]
        case "Lenses": [("tinted", black)]
        case "Rims": [("tinted", 0x2C2C2E)]
        default: []
        }
    }
}

func writeIconBundle(_ theme: IconTheme, in resources: URL) throws {
    let bundle = resources.appendingPathComponent("\(theme.bundleName).icon")
    try? FileManager.default.removeItem(at: bundle)
    let assets = bundle.appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    for layer in robotLayers {
        try svgDocument(layer).write(
            to: assets.appendingPathComponent(layer.fileName),
            atomically: true,
            encoding: .utf8
        )
    }

    let groups: [[String: Any]] = robotGroups.map { group in
        [
            "layers": group.layers.map { layer in
                var document: [String: Any] = ["glass": layer.glass, "image-name": layer.fileName, "name": layer.name]
                let specializations = theme.specializations(of: layer)
                if !specializations.isEmpty {
                    document["fill-specializations"] = specializations.map {
                        ["appearance": $0.appearance, "value": ["solid": fillStop($0.color)]]
                    }
                }
                return document
            },
            "name": group.name,
            "shadow": ["kind": "neutral", "opacity": group.shadow],
            "specular": true,
            "translucency": ["enabled": false, "value": 0.5],
        ]
    }
    // Both fills go in `fill-specializations`. A top-level `fill` beside a dark entry
    // wins over it (measured with ictool 27.1): the system then puts its own near-black
    // behind the robot and paints the theme's gradient onto the white shell instead.
    let document: [String: Any] = [
        "fill-specializations": [
            ["value": ["linear-gradient": [fillStop(theme.gradientTop), fillStop(theme.gradientBottom)]]],
            ["appearance": "dark", "value": ["linear-gradient": theme.darkFill.map(fillStop)]],
        ],
        "groups": groups,
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
