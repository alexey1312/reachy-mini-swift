# Icon Composer themed app icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The chosen `ReachyTheme` changes the app icon on the Home Screen, not only the accent colour.

**Architecture:** One pipeline, not two. `Scripts/render-app-icon.swift` stops writing an asset catalogue and instead
writes six Icon Composer bundles — `AppIcon.icon` plus five `AppIcon-<Theme>.icon` — each holding the same robot glyph
PNG and differing only in the background gradient in `icon.json`. `actool` compiles those into the modern icon, the
light/dark/tinted appearances, the iOS 18–25 back-deployment rasters and the macOS ladder, all of which it generates
itself. `ReachyTheme` gains `alternateIconName`, and the picker calls `UIApplication.setAlternateIconName` behind a
thin iOS-only wrapper.

**Tech Stack:** Swift 6, CoreGraphics + ImageIO (glyph render), `JSONSerialization` (icon.json), Tuist build settings,
UIKit `setAlternateIconName`, swift-testing.

## Global Constraints

- **Upstream is a spec, not a source** — never port Pollen's code.
- **Deployment floor stays iOS 18.0 / macOS 15.0.** Nothing in this plan raises it.
- **Every user-facing string goes through `.reachy(_:)`** (project rule 9). New keys must not differ from an existing
  key only in punctuation — that is a hard `xcstringstool` build error.
- **A visual change names a token or a role, never a literal** (project rule 10): `Space`, `Typography`, `Tone`.
- **A new screen state ships with its previews and recorded references** (project rule 8), and PNGs need an explicit
  `git add` — no hook stages them.
- **Never run tools bare.** `./bin/mise run <task>` or `./bin/mise x -- <tool>`.
- **`ReachyDesign` depends on SwiftUI and nothing else.** No UIKit import may be added there; the switcher lives in
  `ReachyUI`.
- **Determinism: same code, same bytes.** Every generated artefact must be byte-identical across runs or each run
  dirties the diff.
- Conventional commits; the pre-commit hook stages _every_ modified `*.swift` and `*.md`, so separate unrelated edits
  with `git stash push <paths>` first.

## Task 0: the risk this plan was gated on — RETIRED

Delivery step 1 of `docs/superpowers/specs/2026-08-10-runtime-theming-design.md` required a hardware prototype before
anything else was built, because sources disagreed on whether `.icon` bundles work as alternate icons under
Xcode 26.4.1. **That prototype has been run and the risk is retired.** Do not repeat it; the findings below are load
bearing for every task that follows.

Measured on Xcode 26.4.1 (build 17E202), Icon Composer 1.4, with a hand-written `icon.json` and two `.icon` bundles:

| question                                              | answer                 | how it was measured                                                                                                                                                                  |
| ----------------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Does a hand-written `icon.json` compile?              | **Yes**                | `Assets.car` gained `IconGroup`, `Named Gradient` ×2, `_Assets/robot` — the Icon Composer form, not a raster passthrough                                                             |
| `supportsAlternateIcons` under 26.4.1?                | **`true`**             | probe printed `[icon-probe] supports=true current=primary` on an iOS 26.4 simulator                                                                                                  |
| Does `setAlternateIconName` work with `.icon`?        | **Yes**                | Home Screen icon changed to the rose bundle, with the Liquid Glass specular highlight, plus the system "You have changed the icon" alert                                             |
| Can a layer be a PNG rather than SVG?                 | **Yes**                | the glyph shipped as `Assets/robot.png`; Ghostty's shipping `.icon` does the same                                                                                                    |
| Are dark/tinted appearances free?                     | **Yes**                | three `IconImageStack` entries per icon (`UIAppearanceLight`, `UIAppearanceDark`, `ISAppearanceTintable`), generated from one source                                                 |
| Does `.icon` coexist with a same-named `.appiconset`? | **No — it shadows it** | with both present, renditions under `AppIcon*` were 36 = 18 + 18, i.e. the catalogue contributed **zero**; renamed to `AppIconLegacy` it reappeared as an ordinary 2-rendition asset |
| Does iOS 18 get a usable fallback?                    | **Yes**                | the `.icon`-only build installed on a fresh iOS 18.5 simulator renders "Hey Reachy" correctly under the classic squircle mask                                                        |
| Does macOS get its ladder?                            | **Yes**                | the macOS build produced `AppIcon.icns` with 32/64/128/256/512/1024 and correct margins and shadow — better geometry than the hand-written Big Sur maths it replaces                 |

**Two consequences that overrule the spec, and both simplify it:**

1. **The spec's "two pipelines" (strategy A) is not implementable and is not needed.** A same-named asset catalogue is
   shadowed, and two catalogues cannot both be the primary icon — `CFBundleIconName` names one. The back-deployment
   rasters `actool` generates from the `.icon` _are_ the iOS 18–25 pipeline, and they were verified to render. So
   `AppIcon.appiconset` is **deleted**, not kept in step.
2. **The spec's "no dark/tinted variants, they cost 3× " is obsolete.** They are generated from the single source at
   no authoring cost.

One measured behaviour the switcher must respect: calling `setAlternateIconName` before the scene is active fails with
`NSCocoaErrorDomain` code 3072 (`NSUserCancelledError`). From a button tap this cannot happen; do not call it from a
`.task` at launch.

## File Structure

| file                                                            | responsibility                                                                                                     |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `Sources/ReachyDesign/ReachyTheme.swift`                        | **modify** — gains `alternateIconName`                                                                             |
| `Apps/Project.swift`                                            | **modify** — `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` / `_INCLUDE_ALL_APPICON_ASSETS`, both `[sdk=iphone*]` |
| `Tests/ReachyDesignTests/ThemeIconNameTests.swift`              | **create** — names ↔ build setting ↔ committed bundles ↔ palette                                                   |
| `Scripts/render-app-icon.swift`                                 | **modify** — writes six `.icon` bundles instead of one asset catalogue                                             |
| `mise.toml`                                                     | **modify** — a `theme:icons` task; the script currently has none and its header tells a reader to run it bare      |
| `Apps/ReachyMini/Resources/AppIcon*.icon/`                      | **generated** — six bundles, committed                                                                             |
| `Apps/ReachyMini/Resources/Assets.xcassets/AppIcon.appiconset/` | **delete** — shadowed, and its 539 KB of rasters are dead weight                                                   |
| `Sources/ReachyUI/Settings/AppIconSwitcher.swift`               | **create** — the one `setAlternateIconName` call site                                                              |
| `Sources/ReachyUI/Settings/AppearanceSection.swift`             | **modify** — calls the switcher, reports a refusal                                                                 |
| `Sources/ReachyUI/Previews/SettingsPreviews.swift`              | **modify** — a preview of the refusal caption                                                                      |
| `Sources/ReachyDesign/AGENTS.md`, `CLAUDE.md`                   | **modify** — the pipeline and its traps                                                                            |

---

### Task 1: `alternateIconName` and the build settings that must agree with it

A theme whose icon is not declared in the build settings fails at runtime, on a device, silently — the worst place to
find it. This task makes that a compile-time-adjacent test instead. No icons exist yet; the test checks the _names_.

**Files:**

- Modify: `Sources/ReachyDesign/ReachyTheme.swift`
- Modify: `Apps/Project.swift` (the `settings: .settings(base:)` block on the `ReachyMini` target)
- Test: `Tests/ReachyDesignTests/ThemeIconNameTests.swift`

**Interfaces:**

- Consumes: `ReachyTheme` (six cases, `fallback == .graphite`) from the merged theming work.
- Produces: `ReachyTheme.alternateIconName: String?` — `nil` for `.graphite`, `"AppIcon-<Title>"` for the rest.
  Task 2 derives each bundle's directory name from it; Task 3 passes it straight to UIKit.

- [ ] **Step 1: Write the failing test**

Create `Tests/ReachyDesignTests/ThemeIconNameTests.swift`:

```swift
import Foundation
import Testing

@testable import ReachyDesign

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
```

- [ ] **Step 2: Run it and watch it fail**

```bash
./bin/mise run test:filter ThemeIconNameTests
```

Expected: compile error — `value of type 'ReachyTheme' has no member 'alternateIconName'`.

- [ ] **Step 3: Add `alternateIconName`**

Append to `Sources/ReachyDesign/ReachyTheme.swift`, after the `colorSetName` / `accent` extension:

```swift
public extension ReachyTheme {
    /// The alternate app icon this theme selects, or `nil` for the primary one.
    ///
    /// iOS only — macOS has no alternate icons, which is why this is a name rather
    /// than an image and why `AppIconSwitcher` is the only caller. Each name must
    /// also appear in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in
    /// `Apps/Project.swift` and name a committed `<name>.icon` bundle;
    /// `ThemeIconNameTests` is what keeps the three in step, because a mismatch
    /// surfaces only as a failed `setAlternateIconName` on a device.
    var alternateIconName: String? {
        switch self {
        case .graphite: nil
        case .bronze: "AppIcon-Bronze"
        case .teal: "AppIcon-Teal"
        case .indigo: "AppIcon-Indigo"
        case .orchid: "AppIcon-Orchid"
        case .rose: "AppIcon-Rose"
        }
    }
}
```

- [ ] **Step 4: Run again — four pass, one fails**

```bash
./bin/mise run test:filter ThemeIconNameTests
```

Expected: `everyAlternateNameIsDeclared` fails with "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES[sdk=iphone*]: is
absent from Apps/Project.swift". The other four pass.

- [ ] **Step 5: Declare the names in the manifest**

In `Apps/Project.swift`, inside the `ReachyMini` target's `settings: .settings(base: [...])`, after
`"ENABLE_HARDENED_RUNTIME[sdk=macosx*]": "YES",`:

```swift
// SDK-scoped because macOS has no alternate icons: an unscoped
// setting names five bundles the macOS build has no use for.
// Every name here must equal a `ReachyTheme.alternateIconName`
// and a committed `.icon` directory — `ThemeIconNameTests` reads
// this literal back and fails when the three drift.
"ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES[sdk=iphone*]":
    "AppIcon-Bronze AppIcon-Teal AppIcon-Indigo AppIcon-Orchid AppIcon-Rose",
"ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS[sdk=iphone*]": "YES",
```

- [ ] **Step 6: Run again — all five pass**

```bash
./bin/mise run test:filter ThemeIconNameTests
```

Expected: 5 tests, 0 failures.

- [ ] **Step 7: Lint and commit**

```bash
./bin/mise run format
./bin/mise run lint
git add Sources/ReachyDesign/ReachyTheme.swift Apps/Project.swift Tests/ReachyDesignTests/ThemeIconNameTests.swift
git commit -m "feat(theme): name each theme's alternate app icon"
```

---

### Task 2: one generator, six `.icon` bundles, no asset catalogue

**Files:**

- Modify: `Scripts/render-app-icon.swift`
- Modify: `mise.toml` (new `theme:icons` task)
- Delete: `Apps/ReachyMini/Resources/Assets.xcassets/AppIcon.appiconset/` (8 PNGs + `Contents.json`)
- Create (generated, committed): `Apps/ReachyMini/Resources/AppIcon.icon/`, `AppIcon-Bronze.icon/`,
  `AppIcon-Teal.icon/`, `AppIcon-Indigo.icon/`, `AppIcon-Orchid.icon/`, `AppIcon-Rose.icon/`
- Test: `Tests/ReachyDesignTests/ThemeIconNameTests.swift` (extend the suite from Task 1)

**Interfaces:**

- Consumes: `ReachyTheme.alternateIconName` (Task 1) for the directory names; `ReachyTheme.palette.gradientTop` /
  `.gradientBottom` for the colours.
- Produces: `Apps/ReachyMini/Resources/<name>.icon/{icon.json,Assets/robot.png}` for all six themes. Task 4's
  device verification depends on them existing and being committed.

**Two things to know before writing code:**

1. **The script cannot link `ReachyDesign`,** exactly as `Scripts/render-theme-colors.swift` cannot. It therefore
   carries its own copy of the six gradient pairs, and Step 5's test is what catches the two copies drifting.
2. **`Assets/robot.png` is byte-identical in all six bundles.** The glyph does not depend on the theme; only
   `icon.json`'s `fill` does.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ReachyDesignTests/ThemeIconNameTests.swift`, inside the `ThemeIconNameTests` suite:

```swift
    @Test("every theme has a committed icon bundle", arguments: ReachyTheme.allCases)
    func everyThemeHasAnIconBundle(_ theme: ReachyTheme) throws {
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
```

and beside the file's other helpers:

```swift
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
```

- [ ] **Step 2: Run it and watch it fail**

```bash
./bin/mise run test:filter ThemeIconNameTests
```

Expected: `everyThemeHasAnIconBundle` fails for all six — no bundle exists yet.

- [ ] **Step 3: Reduce the renderer to the glyph**

`actool` now generates the iOS square and the macOS ladder from the `.icon`, so both shapes the script used to draw
are gone — and with them the reason `IconShape` existed. In `Scripts/render-app-icon.swift`:

- **delete** `enum IconShape` entirely (a one-case enum is a parameter that can only take one value),
- **delete** `drawGradient(_:in:)` — the gradient lives in `icon.json` now,
- **delete** the two colour constants that describe it, `backgroundTop` and `backgroundBottom` (they are the coral
  this whole feature exists to retire). **Keep** `shell`, `shellShade`, `ink` and `sparkle` — they colour the robot,
  which is unchanged and shared by all six icons.

Replace `render(pixels:shape:)` with:

```swift
/// The robot on transparency. Every `.icon` bundle carries this same image; only the
/// background gradient in `icon.json` tells the six themes apart.
func renderGlyph(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Flip to top-left origin so the drawing reads like the design.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: 1, y: -1)
    drawRobot(ctx, content: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return ctx.makeImage()!
}
```

- [ ] **Step 4: Replace the output section**

Replace the file's whole `// MARK: - Output` section (the `appIconSet` URL and the two `writePNG` calls under it):

```swift
// MARK: - Themes

/// A duplicate of `ReachyTheme.palette`'s gradient stops, for the reason
/// `render-theme-colors.swift` carries one of the accents: a script run by `swift`
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

let resources = URL(fileURLWithPath: "Apps/ReachyMini/Resources")
let glyph = renderGlyph(pixels: 1024)
for theme in iconThemes {
    try writeIconBundle(theme, glyph: glyph, in: resources)
}
```

Update the file's header comment, which still describes the asset catalogue:

```swift
// Renders the Hey Reachy app icons — one Icon Composer bundle per ReachyTheme —
// deterministically: same code, same bytes. Run after changing the design:
//
//   ./bin/mise run theme:icons
//
// Each bundle holds the identical robot glyph on transparency; only icon.json's
// background gradient differs. `actool` generates everything else from that: the
// light, dark and tinted appearances, the iOS 18–25 back-deployment rasters and the
// macOS ladder. There is deliberately no asset catalogue — a same-named
// `.appiconset` is shadowed by the `.icon` and contributes nothing.
```

- [ ] **Step 5: Add the mise task**

In `mise.toml`, beside `[tasks."theme:colors"]`:

```toml
[tasks."theme:icons"]
description = "Regenerate the six AppIcon*.icon bundles from the palette"
run = """
set -o pipefail
swift Scripts/render-app-icon.swift
git status --porcelain Apps/ReachyMini/Resources
"""
```

- [ ] **Step 6: Generate, and delete the catalogue the `.icon` shadows**

```bash
./bin/mise run theme:icons
git rm -r Apps/ReachyMini/Resources/Assets.xcassets/AppIcon.appiconset
```

- [ ] **Step 7: Prove determinism**

```bash
./bin/mise run theme:icons
git status --porcelain Apps/ReachyMini/Resources | grep -v '^??' || echo "byte-identical"
```

Expected: `byte-identical` — a second run must modify nothing already committed.

- [ ] **Step 8: Run the tests**

```bash
./bin/mise run test:filter ThemeIconNameTests
```

Expected: 8 tests, 0 failures.

- [ ] **Step 9: Prove the drift test actually catches drift**

Temporarily change `AppIcon-Teal`'s `gradientTop` in the script to `0x000000`, re-run `theme:icons`, re-run the
suite, and confirm `iconGradientMatchesPalette` fails for `.teal`. Then restore the constant and regenerate.

- [ ] **Step 10: Build both platforms**

```bash
./bin/mise run build:app:ios
./bin/mise run build:app
```

Expected: both succeed. `build:app:ios` is the one that compiles the widget; `build:app` proves the macOS icon still
resolves with no asset catalogue behind it.

- [ ] **Step 11: Commit**

```bash
./bin/mise run format
./bin/mise run lint
git add Scripts/render-app-icon.swift mise.toml Tests/ReachyDesignTests/ThemeIconNameTests.swift
git add Apps/ReachyMini/Resources/AppIcon*.icon
git commit -m "feat(theme): generate an Icon Composer bundle per theme"
```

---

### Task 3: the one `setAlternateIconName` call site

**Files:**

- Create: `Sources/ReachyUI/Settings/AppIconSwitcher.swift`
- Test: `Tests/ReachyUITests/AppIconSwitcherTests.swift`

**Interfaces:**

- Consumes: `ReachyTheme.alternateIconName` (Task 1).
- Produces: `AppIconSwitcher.apply(_ theme: ReachyTheme) async -> Bool` — `@MainActor`, `true` when the icon now
  matches the theme (including "nothing to do" and "this platform has no icons"), `false` when it refused. Task 4
  renders the `false` case as a caption.

- [ ] **Step 1: Write the failing test**

Create `Tests/ReachyUITests/AppIconSwitcherTests.swift`:

```swift
import Testing

@testable import ReachyDesign
@testable import ReachyUI

/// UIKit refuses to change an icon outside a foreground-active app, so the switch
/// itself is device-only. What is testable here is the decision *around* it: which
/// name a theme resolves to, and that the no-op cases are treated as success rather
/// than as a refusal the picker would report to the reader.
@Suite("App icon switcher")
@MainActor
struct AppIconSwitcherTests {
    @Test("the fallback theme resolves to the primary icon")
    func fallbackResolvesToPrimary() {
        #expect(AppIconSwitcher.iconName(for: .graphite) == nil)
    }

    @Test("a themed icon resolves to its bundle name")
    func themedResolvesToBundleName() {
        #expect(AppIconSwitcher.iconName(for: .rose) == "AppIcon-Rose")
    }

    @Test("applying the icon already in use is a no-op success")
    func alreadyInUseIsSuccess() {
        #expect(AppIconSwitcher.isAlreadyApplied(.rose, current: "AppIcon-Rose"))
        #expect(AppIconSwitcher.isAlreadyApplied(.graphite, current: nil))
    }

    @Test("applying a different icon is not a no-op")
    func differentIconIsNotANoOp() {
        #expect(AppIconSwitcher.isAlreadyApplied(.rose, current: nil) == false)
        #expect(AppIconSwitcher.isAlreadyApplied(.graphite, current: "AppIcon-Rose") == false)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
./bin/mise run test:filter AppIconSwitcherTests
```

Expected: compile error — `cannot find 'AppIconSwitcher' in scope`.

- [ ] **Step 3: Write the switcher**

Create `Sources/ReachyUI/Settings/AppIconSwitcher.swift`:

```swift
import ReachyDesign

#if os(iOS)
    import UIKit
#endif

/// Applies a theme's app icon, best effort.
///
/// iOS only. macOS has no alternate icons — `NSApplication.applicationIconImage`
/// reaches the Dock and Cmd-Tab but leaves Finder, Launchpad and Spotlight on the
/// bundle's own icon, which reads as a bug rather than as a feature — so there the
/// theme is colour only and `AppearanceSection` promises nothing else.
///
/// The theme is saved unconditionally by the picker; this is what may fail. On a
/// refusal the picker shows a caption and no alert: iOS already presents its own
/// unsuppressable "You have changed the icon" on *success*, and stacking a second
/// dialog on the failure path would be worse than the failure.
enum AppIconSwitcher {
    /// The bundle name a theme selects, or `nil` for the primary icon.
    static func iconName(for theme: ReachyTheme) -> String? {
        theme.alternateIconName
    }

    /// Whether the icon already in use is the one this theme wants.
    ///
    /// Guarding on this is not an optimisation: `setAlternateIconName` raises the
    /// system alert every time it is called with a *different* name, so without the
    /// guard, re-selecting the theme already applied would show "You have changed
    /// the icon" over an icon that did not change.
    static func isAlreadyApplied(_ theme: ReachyTheme, current: String?) -> Bool {
        iconName(for: theme) == current
    }

    /// `true` when the icon now matches the theme — including the two cases where
    /// there was nothing to do and the case where this platform has no icons to
    /// switch. `false` only when iOS refused.
    @MainActor
    static func apply(_ theme: ReachyTheme) async -> Bool {
        #if os(iOS)
            let application = UIApplication.shared
            guard application.supportsAlternateIcons else { return false }
            guard !isAlreadyApplied(theme, current: application.alternateIconName) else { return true }
            do {
                // Measured: called before the scene is active this throws
                // NSCocoaErrorDomain 3072 (NSUserCancelledError). Every caller is a
                // button tap, so the app is foreground-active by construction — do
                // not move this onto a launch `.task`.
                try await application.setAlternateIconName(iconName(for: theme))
                return true
            } catch {
                return false
            }
        #else
            return true
        #endif
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
./bin/mise run test:filter AppIconSwitcherTests
```

Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
./bin/mise run format
./bin/mise run lint
git add Sources/ReachyUI/Settings/AppIconSwitcher.swift Tests/ReachyUITests/AppIconSwitcherTests.swift
git commit -m "feat(theme): switch the app icon with the theme"
```

---

### Task 4: the picker applies the icon, and says so when it cannot

**Files:**

- Modify: `Sources/ReachyUI/Settings/AppearanceSection.swift`
- Modify: `Sources/ReachyUI/Previews/SettingsPreviews.swift`
- Modify: `Sources/ReachyDesign/Resources/Localizable.xcstrings` (one new key)
- References: `Apps/ReachyUISnapshotTests/__Snapshots__/…`

**Interfaces:**

- Consumes: `AppIconSwitcher.apply(_:)` (Task 3).
- Produces: nothing other tasks read.

**Copy check before writing:** the new key is `"The app icon didn't change."` It must not differ from an existing key
only in punctuation — `xcstringstool` fails the build on that, so grep the catalogue for `app icon` first.

- [ ] **Step 1: Grep for a colliding key**

```bash
grep -in "app icon" Sources/ReachyDesign/Resources/Localizable.xcstrings
```

Expected: no hit. If there is one, pick wording that differs by more than punctuation.

- [ ] **Step 2: Add the failure state and the call**

In `AppearanceSection`, add the state and the injection seam beside the existing `init(defaults:)`:

```swift
    /// Set when `setAlternateIconName` refuses. Injectable for the same reason the
    /// defaults suite is: a preview cannot reach a refusal, and an uncovered failure
    /// caption is one nobody looks at until a reader reports it.
    @State private var iconChangeFailed: Bool

    init(defaults: UserDefaults = KnownRobots.defaults, iconChangeFailed: Bool = false) {
        _rawTheme = AppStorage(
            wrappedValue: ReachyTheme.fallback.rawValue,
            ThemeStore.key,
            store: defaults
        )
        _iconChangeFailed = State(initialValue: iconChangeFailed)
    }
```

In `tile(_:)`, replace the `Button` action body:

```swift
Button {
    rawTheme = theme.rawValue
    #if !os(macOS)
        WidgetCenter.shared.reloadAllTimelines()
    #endif
    // The theme is already saved; the icon is best effort. Awaiting it here
    // would block the tile's highlight behind iOS's own alert.
    Task { iconChangeFailed = await AppIconSwitcher.apply(theme) == false }
} label: {
```

Give the `Section` a footer — note the full `header:`/`footer:` form, because `Section("X") { } footer: { }` does not
compile:

```swift
} header: {
    Text(.reachy("Appearance"))
} footer: {
    if iconChangeFailed {
        Text(.reachy("The app icon didn't change."))
            .foregroundStyle(Tone.danger.style)
    }
}
```

- [ ] **Step 3: Add the preview**

In `Sources/ReachyUI/Previews/SettingsPreviews.swift`, beside the existing appearance preview:

```swift
#Preview("Appearance — icon refused") {
    Form {
        AppearanceSection.preview(.rose, iconChangeFailed: true)
    }
    .formStyle(.grouped)
    .reachyTheme(.rose)
}
```

and extend the `#if DEBUG` factory in `AppearanceSection.swift` to carry the flag:

```swift
static func preview(_ theme: ReachyTheme, iconChangeFailed: Bool = false) -> AppearanceSection {
    let defaults = UserDefaults(suiteName: "ReachyUI.previews") ?? .standard
    ThemeStore(defaults: defaults).theme = theme
    return AppearanceSection(defaults: defaults, iconChangeFailed: iconChangeFailed)
}
```

- [ ] **Step 4: Seed the localization key**

Add to `Sources/ReachyDesign/Resources/Localizable.xcstrings`, in key order, with `extractionState: "manual"` like
its neighbours:

```json
"The app icon didn't change." : {
  "extractionState" : "manual"
},
```

- [ ] **Step 5: Regenerate and see what moved before recording**

```bash
./bin/mise run project
./bin/mise run test:snapshots
```

Expected: `Appearance — icon refused` is missing and gets written; the existing `Appearance` references may move if
an empty footer changes the section's spacing. **Read the list before recording** — `record` overwrites blind. If
anything outside `Settings —` / `Appearance —` moved, stop and explain it rather than recording over it.

- [ ] **Step 6: Record and stage**

```bash
./bin/mise run test:snapshots:record
./bin/mise run test:snapshots
git add Apps/ReachyUISnapshotTests/__Snapshots__
```

Expected: the second run is clean.

- [ ] **Step 7: Commit**

```bash
./bin/mise run format
./bin/mise run lint
git add Sources/ReachyUI Sources/ReachyDesign/Resources/Localizable.xcstrings
git commit -m "feat(theme): apply the theme's icon from the picker"
```

---

### Task 5: verify on hardware and on the deployment floor

Nothing above proves the feature works where it is used: no reference image renders a Home Screen, and the snapshot
suite runs on one iOS version. This task is measurement, not code.

**Files:** none — findings go into Task 6's documentation.

- [ ] **Step 1: Install on the phone**

```bash
./bin/mise run device
```

If the phone is locked the install succeeds and the launch is refused with exit 3 — unlock and re-run. Check for
`App installed:`, not for a clean stderr; `devicectl` prints a provisioning warning on every invocation.

- [ ] **Step 2: Walk the picker on the device**

Settings → Appearance. For each of the six themes: tap it, dismiss iOS's alert, background the app, and confirm the
Home Screen icon matches. Confirm that re-tapping the theme already selected raises **no** alert.

- [ ] **Step 3: Verify the iOS 18 fallback**

```bash
RT=com.apple.CoreSimulator.SimRuntime.iOS-18-5
SIM=$(xcrun simctl create "iOS18-icon-check" com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$RT")
xcrun simctl boot "$SIM" && xcrun simctl bootstatus "$SIM" -b
xcodebuild build -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyMini \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath Apps/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO 2>&1 | ./bin/mise x -- xcsift
xcrun simctl install "$SIM" Apps/DerivedData/Build/Products/Debug-iphonesimulator/ReachyMini.app
sleep 12 && xcrun simctl io "$SIM" screenshot /tmp/ios18-icon.png
```

Expected: the Home Screen shows a graphite "Hey Reachy" under the classic squircle mask. Delete the simulator when
done: `xcrun simctl delete "$SIM"`.

- [ ] **Step 4: Measure the bundle, do not estimate it**

```bash
./bin/mise run inspect:bundle
```

Numbers only mean something off a Release archive — a Debug bundle carries `__preview.dylib` and the provisioning
profile. Record the `Assets.car` figure for Task 6. For scale, the **source** tree shrinks: the deleted
`AppIcon.appiconset` was 539 KB across 8 PNGs, and the six glyphs are 57.5 KB each (345 KB total).

- [ ] **Step 5: Record what was found**

Write the four results into the branch's notes for Task 6 — device pass/fail per theme, the iOS 18 screenshot, the
`Assets.car` delta, and anything that surprised you.

---

### Task 6: documentation, and the traps this pipeline sets

**Files:**

- Modify: `Sources/ReachyDesign/AGENTS.md`
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-08-10-runtime-theming-design.md` (a correction paragraph)

- [ ] **Step 1: Correct the spec rather than silently diverging from it**

The spec's "App icons: two pipelines" section is wrong in three specific ways and the branch must say so, in the same
voice the theming spec already uses for its own corrections. Add under that section:

```markdown
**Correction, measured on Xcode 26.4.1.** Three claims above did not survive the prototype:

1. **"The asset catalogue stays for iOS 18–25" is not implementable.** A `.icon` shadows a same-named `.appiconset`
   entirely — with both present, `Assets.car` carried 18 renditions per `.icon` and **zero** from the catalogue.
   Two catalogues cannot both be primary either; `CFBundleIconName` names one. What actually serves iOS 18–25 is the
   back-deployment rasters `actool` generates from the `.icon`, verified rendering correctly on an iOS 18.5
   simulator. `AppIcon.appiconset` is therefore deleted, and there is one pipeline, not two.
2. **"Writing `icon.json` from scratch is explicitly not the plan" is reversed.** A hand-written document compiles
   into the full Icon Composer form (`IconGroup`, `Named Gradient`, three `IconImageStack`s). The schema was read off
   four shipping `.icon` bundles rather than guessed. Generation is what keeps six themes cheap.
3. **The dark and tinted variants are not a 3× cost.** `actool` derives all three appearances from the single source.

The risk the delivery order was built around — whether `setAlternateIconName` works with `.icon` under 26.4.1 — is
retired: `supportsAlternateIcons` is `true` and the switch was observed on a Home Screen.
```

- [ ] **Step 2: Write the rule into the design system's rulebook**

Add to `Sources/ReachyDesign/AGENTS.md`, in the Rules list beside the existing theme entries:

```markdown
- **A theme's icon is generated, and the `.icon` is the only pipeline.** `Scripts/render-app-icon.swift` writes six
  `Apps/ReachyMini/Resources/AppIcon*.icon` bundles from its own copy of the gradient stops — the same hand-kept
  duplicate `render-theme-colors.swift` carries, and for the same reason (a `swift` script cannot link this module).
  All six share a byte-identical `Assets/robot.png`; only `icon.json`'s `fill` differs. Never hand-edit a generated
  bundle, and never open one in Icon Composer.app to "just tweak it" — it rewrites the document in its own shape and
  the next `./bin/mise run theme:icons` reverts it. Three names must agree — `ReachyTheme.alternateIconName`, the
  `.icon` directory, and `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in `Apps/Project.swift` — and
  `ThemeIconNameTests` is the only thing that checks, because a mismatch surfaces as a failed
  `setAlternateIconName` on a device and nowhere earlier.
- **There is no `AppIcon.appiconset`, and adding one back does nothing.** A `.icon` shadows a same-named catalogue:
  measured, the catalogue contributed zero renditions while the `.icon` contributed 18. iOS 18–25 is served by the
  back-deployment rasters `actool` derives, and macOS by the ladder it generates — including better geometry than the
  Big Sur rounded rectangle the script used to draw by hand.
- **No reference image can cover an app icon.** The snapshot suite renders views, never a Home Screen. Icons are a
  device check plus one iOS 18 simulator install, and that is the whole of their cover — say so rather than assuming
  a green suite means anything about them.
```

- [ ] **Step 3: Write the operational trap into the root instructions**

Add to `CLAUDE.md`, near the other icon/asset notes:

```markdown
**App icons are six Icon Composer bundles, generated — `./bin/mise run theme:icons`.** They live at
`Apps/ReachyMini/Resources/AppIcon*.icon` and are ordinary opaque resources: Tuist references each as one file, so
the existing `resources: ["ReachyMini/Resources/**"]` glob needs no change, and nothing decomposes them into
`icon.json` plus `Assets/`. A second run must leave the tree clean — `JSONSerialization` is called with
`.sortedKeys` precisely so it does. There is **no asset catalogue for the app icon**: a `.icon` shadows a same-named
`.appiconset` completely, so re-adding one is a silent no-op. Alternate icons are declared twice — in
`ReachyTheme.alternateIconName` and in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES[sdk=iphone*]` — and only
`ThemeIconNameTests` keeps them in step.
```

- [ ] **Step 4: Format, lint, commit**

```bash
./bin/mise run format
./bin/mise run lint
git add CLAUDE.md Sources/ReachyDesign/AGENTS.md docs/superpowers/specs/2026-08-10-runtime-theming-design.md
git commit -m "docs(theme): record the one-pipeline icon generation and its traps"
```

---

## Deviations from the spec

Four, all forced by measurement rather than by taste, and all recorded in Task 6's correction paragraph:

1. **One pipeline, not two.** The asset catalogue is deleted; `actool`'s back-deployment rasters serve iOS 18–25.
2. **`icon.json` is generated, not hand-composed.** The schema was read off four shipping bundles and a written
   document compiles.
3. **Dark and tinted appearances are included** because they cost nothing, where the spec deliberately skipped them.
4. **Picker tiles stay `LinearGradient`s**, as the colour plan already decided — `.icon` exposes no thumbnails, and
   the gradient _is_ the icon's background.

## What this plan does not do

- **macOS icons do not follow the theme.** Decided during brainstorming: `NSApplication.applicationIconImage` reaches
  the Dock and Cmd-Tab but leaves Finder, Launchpad and Spotlight on the bundle icon.
- **System surfaces keep the fallback accent.** Unrelated to icons and already recorded as a known limitation.
- **No `.icon` for the widget extension.** A widget has no app icon.
