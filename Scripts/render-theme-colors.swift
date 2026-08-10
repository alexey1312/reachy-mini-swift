// Generates the theme colour sets from ReachyTheme's constants, deterministically:
// same constants, same bytes. Run from the repo root after changing a palette:
//
//   swift Scripts/render-theme-colors.swift
//
// The constants are duplicated here rather than imported because this is a script,
// not a target — it cannot link ReachyDesign. `ReachyThemeTests` is what keeps the
// two copies honest: it fails the moment they disagree.

import Foundation

struct Theme {
    let name: String
    let light: UInt32
    let dark: UInt32
}

let themes = [
    Theme(name: "ThemeGraphite", light: 0x3E4757, dark: 0xA9B6CC),
    Theme(name: "ThemeBronze", light: 0xB26708, dark: 0xE3A24A),
    Theme(name: "ThemeTeal", light: 0x00A0A8, dark: 0x4FD6DE),
    Theme(name: "ThemeIndigo", light: 0x4B47D6, dark: 0x8E8CF0),
    Theme(name: "ThemeOrchid", light: 0x9038D9, dark: 0xC58AF0),
    Theme(name: "ThemeRose", light: 0xD6248A, dark: 0xFF7ABA),
]

// swiftlint:disable:next large_tuple
func channels(_ hex: UInt32) -> (String, String, String) {
    (
        String(format: "0x%02X", (hex >> 16) & 0xFF),
        String(format: "0x%02X", (hex >> 8) & 0xFF),
        String(format: "0x%02X", hex & 0xFF)
    )
}

func entry(_ hex: UInt32, dark: Bool) -> String {
    let (r, g, b) = channels(hex)
    let appearances = dark
        ? """
              "appearances" : [
                {
                  "appearance" : "luminosity",
                  "value" : "dark"
                }
              ],

        """
        : ""
    return """
        {
    \(appearances)      "color" : {
            "color-space" : "srgb",
            "components" : {
              "alpha" : "1.000",
              "blue" : "\(b)",
              "green" : "\(g)",
              "red" : "\(r)"
            }
          },
          "idiom" : "universal"
        }
    """
}

let catalogue = URL(fileURLWithPath: "Sources/ReachyDesign/Resources/Assets.xcassets")
try FileManager.default.createDirectory(at: catalogue, withIntermediateDirectories: true)
try """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""".write(
    to: catalogue.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
print("wrote Assets.xcassets/Contents.json")

for theme in themes {
    let directory = catalogue.appendingPathComponent("\(theme.name).colorset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let json = """
    {
      "colors" : [
    \(entry(theme.light, dark: false)),
    \(entry(theme.dark, dark: true))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try json.write(
        to: directory.appendingPathComponent("Contents.json"),
        atomically: true,
        encoding: .utf8
    )
    print("wrote \(theme.name).colorset")
}
