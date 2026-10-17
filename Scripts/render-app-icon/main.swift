// Renders the Hey Reachy app icons — one Icon Composer bundle per ReachyTheme —
// deterministically: same code, same bytes. Run from the repo root after changing
// the design:
//
//   ./bin/mise run theme:icons
//
// Each bundle holds the identical robot glyph on transparency; only icon.json's
// background gradient differs. `actool` generates everything else from that: the
// light, dark and tinted appearances, the iOS 18–25 back-deployment rasters and the
// macOS ladder. There is deliberately no asset catalogue — a same-named
// `.appiconset` is shadowed by the `.icon` and contributes nothing.
//
// visionOS and tvOS are the exceptions: they take no `.icon` bundle, so the same
// drawing also writes the visionOS app's solid image stack (`VisionIcon.swift`) and
// the TV app's brand assets (`TVIcon.swift`).
//
// Several files rather than one script, so each stays under SwiftLint's length limit:
// the task compiles them with `swiftc`, since `swift` runs a single file. The drawing
// is in `Drawing.swift`, once, for every platform.

import Foundation

let resources = URL(fileURLWithPath: "Apps/ReachyMini/Resources")
let glyph = renderGlyph(pixels: 1024)
for theme in iconThemes {
    try writeIconBundle(theme, glyph: glyph, in: resources)
}

try writeVisionIcon(iconThemes[0], to: URL(fileURLWithPath: "Apps/ReachyVision/Resources/Assets.xcassets"))
try writeTVIcon(iconThemes[0], to: URL(fileURLWithPath: "Apps/ReachyTV/Resources/Assets.xcassets"))
