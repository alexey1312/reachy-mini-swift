// Renders the Hey Reachy app icons — one Icon Composer bundle per ReachyTheme —
// deterministically: same code, same bytes. Run from the repo root after changing
// the design:
//
//   ./bin/mise run theme:icons
//
// Each bundle holds the identical robot as five SVG layers in three groups
// (`Geometry.swift`), which actool keeps as vectors: the icon stays sharp at any
// size the system draws it, where the old 1024 px bitmap layer showed its pixels on
// an iPad. Only icon.json differs between themes: the background gradient, the dark
// background in the theme's own hue, and the antennas' dark and tinted colours.
// `actool` generates everything else from that: the light, dark, tinted and clear
// appearances, the iOS 18–25 back-deployment rasters and the macOS ladder. There is
// deliberately no asset catalogue — a same-named `.appiconset` is shadowed by the
// `.icon` and contributes nothing.
//
// visionOS and tvOS are the exceptions: they take no `.icon` bundle, so the same
// drawing also writes the visionOS app's solid image stack (`VisionIcon.swift`) and
// the TV app's brand assets (`TVIcon.swift`), as bitmaps of the same paths.
//
// Several files rather than one script, so each stays under SwiftLint's length limit:
// the task compiles them with `swiftc`, since `swift` runs a single file. The drawing
// is in `Geometry.swift`, once, for every platform.

import Foundation

let resources = URL(fileURLWithPath: "Apps/ReachyMini/Resources")
for theme in iconThemes {
    try writeIconBundle(theme, in: resources)
}

try writeVisionIcon(iconThemes[0], to: URL(fileURLWithPath: "Apps/ReachyVision/Resources/Assets.xcassets"))
try writeTVIcon(iconThemes[0], to: URL(fileURLWithPath: "Apps/ReachyTV/Resources/Assets.xcassets"))
