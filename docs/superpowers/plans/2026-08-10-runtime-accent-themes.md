# Runtime accent themes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user pick one of six accent themes in Settings and have it apply to the app, the widget and every
snapshot, with graphite as a default that no longer collides with `Tone.danger`.

**Architecture:** `ReachyTheme` is a token in `ReachyDesign` carrying sRGB constants; those constants generate the
asset catalogue that SwiftUI reads and feed the test that guards them. A theme reaches the UI through
`EnvironmentValues.reachyTheme` and one `.tint(_:)` applied at the scene entry point — never at `ReachyRootView`,
so the app and the storybook can each apply their own choice without `ReachyRootView` overwriting it. Persistence
is one string in the shared App Group suite, which is also how the widget process sees it.

**Correction, added after Task 5's implementation.** The entry-point application above does not reach the
snapshot suite — `#Preview` bodies are instantiated directly by Prefire and never pass through `ReachyMiniApp` or
`ReachyStorybookApp`. What themes every capture is a second mechanism, added as a Task 5 follow-up once review
caught the gap: the forked `Apps/ReachyUISnapshotTests/PreviewTests.stencil` wraps every preview body it inlines
in `Group { … }.reachyTheme(.fallback)` (commit `85cf545`). `ReachyTheme.accent` resolves against `ReachyDesign`'s
own bundled colour catalogue, which is why that theme reaches a test bundle with no dependency on either app
target. See Task 5 below.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, swift-testing, SwiftPM + Tuist, Prefire snapshots.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-10-runtime-theming-design.md`. This plan covers its colour half only;
  app icons are a second plan.
- **Every user-facing string goes through `.reachy(_:)`** (project rule 9). A bare `Text("Graphite")` in a library
  target resolves against `Bundle.main` and can never be translated.
- **A visual change names a token, never a literal** (project rule 10): `Space.lg`, `Radius.rect(Radius.lg)`,
  `Typography.detail`. Note the argument is a `CGFloat` — `Radius.rect(.lg)` does not compile.
- **`@Entry` is unavailable.** The macro ships with Xcode, not with the pinned swift.org toolchain, so environment
  keys are written out by hand — see `Sources/ReachyUI/PreviewMode.swift` for the shape to copy.
- **Never run tools bare.** `./bin/mise run <task>` or `./bin/mise x -- <tool>`.
- **Conventional commits.** The pre-commit hook stages _every_ modified `*.swift` and `*.md`, not only what you
  `git add` — stash unrelated edits first. PNGs need an explicit `git add`.
- **Two spellings of a localized string**, decided by the type: `.reachy("…")` where SwiftUI takes a
  `LocalizedStringResource`; `String(localized: .reachy("…"))` only where the value must stay a `String`.
- **The palette is fixed** and must not be re-derived: graphite `#3E4757`/`#A9B6CC`, bronze `#B26708`/`#E3A24A`,
  teal `#00A0A8`/`#4FD6DE`, indigo `#4B47D6`/`#8E8CF0`, orchid `#9038D9`/`#C58AF0`, rose `#D6248A`/`#FF7ABA`.

---

## File Structure

**Created:**

| path                                                              | responsibility                                                    |
| ----------------------------------------------------------------- | ----------------------------------------------------------------- |
| `Sources/ReachyDesign/ReachyTheme.swift`                          | The enum, its palette constants, derived names, `accent`, `title` |
| `Sources/ReachyDesign/ThemeStore.swift`                           | Read/write one raw value against an injected `UserDefaults`       |
| `Sources/ReachyDesign/ThemeEnvironment.swift`                     | `EnvironmentValues.reachyTheme` + `.reachyTheme(_:)`              |
| `Sources/ReachyDesign/Resources/Assets.xcassets/Theme*.colorset/` | Six generated adaptive colours                                    |
| `Sources/ReachyUI/ThemeSettings.swift`                            | `.reachyThemeFromSettings(_:)` — binds the store to the app group |
| `Sources/ReachyUI/Settings/AppearanceSection.swift`               | The picker section                                                |
| `Sources/ReachyUI/Previews/AppearancePreviews.swift`              | Picker preview + the six-theme gallery                            |
| `Scripts/render-theme-colors.swift`                               | Generates the colorsets from the constants                        |
| `Tests/ReachyDesignTests/ReachyThemeTests.swift`                  | Contrast, separation, catalogue-matches-constants                 |
| `Tests/ReachyDesignTests/ThemeStoreTests.swift`                   | Persistence round trip and fallbacks                              |

**Modified:**

| path                                                                           | change                                                |
| ------------------------------------------------------------------------------ | ----------------------------------------------------- |
| `Package.swift:112`                                                            | New `ReachyDesignTests` test target                   |
| `Apps/ReachyMini/Sources/ReachyMiniApp.swift:15`                               | Apply the theme at the scene root                     |
| `Apps/ReachyStorybook/Sources/`                                                | Same, so the catalogue renders themed                 |
| `Apps/ReachyMini/Resources/Assets.xcassets/AccentColor.colorset/Contents.json` | Repaint to graphite                                   |
| `Sources/ReachyUI/Settings/SettingsScreen.swift:31-42`                         | One line adding the section                           |
| `Apps/ReachyWidget/Sources/ReachyAppsWidget.swift:91`                          | Theme the widget body                                 |
| `Sources/ReachyDesign/Tone.swift:5`                                            | The stale "no palette and no asset catalogue" comment |
| `Sources/ReachyDesign/AGENTS.md`                                               | A theming section                                     |
| `CLAUDE.md`                                                                    | Where theme values live and what regenerates them     |

---

### Task 1: `ReachyTheme` and the palette test

The enum and its numbers, with the rule that rejected coral encoded as a test. No SwiftUI, no catalogue — this task
is pure arithmetic and must pass before any pixel depends on it.

**Files:**

- Create: `Sources/ReachyDesign/ReachyTheme.swift`
- Create: `Tests/ReachyDesignTests/ReachyThemeTests.swift`
- Modify: `Package.swift:112`

**Interfaces:**

- Consumes: nothing.
- Produces: `ReachyTheme` (`.graphite`, `.bronze`, `.teal`, `.indigo`, `.orchid`, `.rose`; `static let fallback`),
  `ReachyTheme.Palette` with `light: UInt32`, `dark: UInt32`, `gradientTop: UInt32`, `gradientBottom: UInt32`, and
  `var palette: Palette`. Later tasks add `accent`, `title`, `colorSetName` to the same type.

- [ ] **Step 1: Add the test target so the suite can exist**

In `Package.swift`, immediately before the `HuggingFaceAuthTests` target at line 112:

```swift
.testTarget(
    name: "ReachyDesignTests",
    dependencies: ["ReachyDesign"]
),
```

- [ ] **Step 2: Write the failing test**

Create `Tests/ReachyDesignTests/ReachyThemeTests.swift`:

```swift
import Foundation
import Testing
@testable import ReachyDesign

/// WCAG relative luminance and contrast, and hue in degrees — the three numbers
/// the palette rule is written in. They live in the test rather than in the module
/// because nothing in the app computes them at runtime.
private enum Colorimetry {
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
    static let danger: UInt32 = 0xFF_3B30
    static let warning: UInt32 = 0xFF_9500
    static let success: UInt32 = 0x34_C759
    static let all: [(name: String, hex: UInt32)] = [
        ("danger", danger), ("warning", warning), ("success", success),
    ]
}

private let white: UInt32 = 0xFF_FFFF
private let darkBackground: UInt32 = 0x1C_1C1E

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
        let coral: UInt32 = 0xFF_5A3C
        let hueApart = Colorimetry.hueDistance(coral, SemanticTone.danger) >= 30
        let lightnessApart = Colorimetry.contrastRatio(coral, SemanticTone.danger) >= 1.8
        #expect(hueApart == false)
        #expect(lightnessApart == false)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `./bin/mise run test:filter ReachyThemeTests`
Expected: compile failure — `cannot find 'ReachyTheme' in scope`.

- [ ] **Step 4: Write the minimal implementation**

Create `Sources/ReachyDesign/ReachyTheme.swift`:

```swift
import SwiftUI

/// A theme the user can pick: one accent colour and, on iOS, one app icon.
///
/// The values live here as constants rather than only in the asset catalogue
/// because three consumers need the same numbers — SwiftUI reads the generated
/// catalogue, the icon script reads the gradient, and `ReachyThemeTests` reads the
/// accents to check them. One source, so a rendered colour cannot differ from a
/// verified one.
public enum ReachyTheme: String, CaseIterable, Sendable, Identifiable {
    case graphite
    case bronze
    case teal
    case indigo
    case orchid
    case rose

    /// What an absent or unrecognised stored value resolves to — the latter happens
    /// to anyone who downgrades to a build that predates a theme.
    public static let fallback = ReachyTheme.graphite

    public var id: String { rawValue }
}

public extension ReachyTheme {
    /// sRGB, one accent per appearance plus the two gradient stops the icon uses.
    struct Palette: Sendable, Equatable {
        public let light: UInt32
        public let dark: UInt32
        public let gradientTop: UInt32
        public let gradientBottom: UInt32
    }

    var palette: Palette {
        switch self {
        case .graphite:
            Palette(light: 0x3E_4757, dark: 0xA9_B6CC, gradientTop: 0x9A_A6B8, gradientBottom: 0x3E_4757)
        case .bronze:
            Palette(light: 0xB2_6708, dark: 0xE3_A24A, gradientTop: 0xFF_C96B, gradientBottom: 0xB2_6708)
        case .teal:
            Palette(light: 0x00_A0A8, dark: 0x4F_D6DE, gradientTop: 0x5F_E0CE, gradientBottom: 0x00_A0A8)
        case .indigo:
            Palette(light: 0x4B_47D6, dark: 0x8E_8CF0, gradientTop: 0x9B_9BF5, gradientBottom: 0x4B_47D6)
        case .orchid:
            Palette(light: 0x90_38D9, dark: 0xC5_8AF0, gradientTop: 0xE8_AEFF, gradientBottom: 0x90_38D9)
        case .rose:
            Palette(light: 0xD6_248A, dark: 0xFF_7ABA, gradientTop: 0xFF_A8CE, gradientBottom: 0xD6_248A)
        }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./bin/mise run test:filter ReachyThemeTests`
Expected: PASS, 5 tests (two of them parameterised over six themes).

- [ ] **Step 6: Lint and format**

Run: `./bin/mise run format && ./bin/mise run lint`
Expected: clean. `Package.resolved` may show as modified — that is the documented oscillation, leave it.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/ReachyDesign/ReachyTheme.swift Tests/ReachyDesignTests/ReachyThemeTests.swift
git commit -m "feat(theme): add the six-theme palette and the rule that guards it"
```

---

### Task 2: Generated colorsets and `accent`

The catalogue SwiftUI reads, generated from Task 1's constants, plus a test that the two cannot drift apart.

**Files:**

- Create: `Scripts/render-theme-colors.swift`
- Create: `Sources/ReachyDesign/Resources/Assets.xcassets/Theme{Graphite,Bronze,Teal,Indigo,Orchid,Rose}.colorset/Contents.json`
- Modify: `Sources/ReachyDesign/ReachyTheme.swift`
- Modify: `Tests/ReachyDesignTests/ReachyThemeTests.swift`

**Interfaces:**

- Consumes: `ReachyTheme.palette` from Task 1.
- Produces: `ReachyTheme.colorSetName -> String` (e.g. `"ThemeGraphite"`) and `ReachyTheme.accent -> Color`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ReachyDesignTests/ReachyThemeTests.swift`, inside the `ReachyThemeTests` suite:

```swift
    /// The catalogue is generated, so this asserts the generator was actually run:
    /// a palette edit without a regeneration would otherwise ship a colour nothing
    /// verified. Read from source rather than from `Bundle.module` — a built
    /// catalogue is a compiled `Assets.car`, not JSON.
    @Test("the generated catalogue matches the constants", arguments: ReachyTheme.allCases)
    func catalogueMatchesConstants(theme: ReachyTheme) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReachyDesignTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./bin/mise run test:filter ReachyThemeTests`
Expected: compile failure — `value of type 'ReachyTheme' has no member 'colorSetName'`.

- [ ] **Step 3: Add the derived names and `accent`**

Append to `Sources/ReachyDesign/ReachyTheme.swift` (the file already imports SwiftUI):

```swift
public extension ReachyTheme {
    /// The colour set this theme resolves to. Generated by
    /// `Scripts/render-theme-colors.swift` — never hand-edited.
    var colorSetName: String {
        "Theme" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Adaptive by construction: the asset catalogue carries both appearances, which
    /// is the only cross-platform way to build one — SwiftUI cannot make an adaptive
    /// `Color` from two literals, and a `UIColor`/`NSColor` fork would not compile
    /// for both platforms this module targets.
    var accent: Color {
        Color(colorSetName, bundle: .module)
    }
}
```

- [ ] **Step 4: Write the generator**

Create `Scripts/render-theme-colors.swift`:

```swift
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
    Theme(name: "ThemeGraphite", light: 0x3E_4757, dark: 0xA9_B6CC),
    Theme(name: "ThemeBronze", light: 0xB2_6708, dark: 0xE3_A24A),
    Theme(name: "ThemeTeal", light: 0x00_A0A8, dark: 0x4F_D6DE),
    Theme(name: "ThemeIndigo", light: 0x4B_47D6, dark: 0x8E_8CF0),
    Theme(name: "ThemeOrchid", light: 0x90_38D9, dark: 0xC5_8AF0),
    Theme(name: "ThemeRose", light: 0xD6_248A, dark: 0xFF_7ABA),
]

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
        \n
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
```

- [ ] **Step 5: Run the generator**

Run: `swift Scripts/render-theme-colors.swift`
Expected: six `wrote Theme*.colorset` lines.

- [ ] **Step 6: Run the test to verify it passes**

Run: `./bin/mise run test:filter ReachyThemeTests`
Expected: PASS. If the JSON shape assertion fails, fix the **generator**, not the test — the test encodes what
Xcode's own `AccentColor.colorset` looks like.

- [ ] **Step 7: Verify the generator is deterministic**

Run: `swift Scripts/render-theme-colors.swift && git diff --stat Sources/ReachyDesign/Resources`
Expected: no output from `git diff` — a second run must produce identical bytes.

- [ ] **Step 8: Commit**

```bash
./bin/mise run format
git add Scripts/render-theme-colors.swift Sources/ReachyDesign/Resources Sources/ReachyDesign/ReachyTheme.swift Tests/ReachyDesignTests/ReachyThemeTests.swift
git commit -m "feat(theme): generate the theme colour sets from the palette constants"
```

---

### Task 3: `ThemeStore`

Persistence, with the injected-defaults seam the parallel test runner requires.

**Files:**

- Create: `Sources/ReachyDesign/ThemeStore.swift`
- Create: `Tests/ReachyDesignTests/ThemeStoreTests.swift`

**Interfaces:**

- Consumes: `ReachyTheme`, `ReachyTheme.fallback`.
- Produces: `ThemeStore(defaults:)` with `var theme: ReachyTheme { get nonmutating set }` and
  `static let key = "ReachyDesign.theme"`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ReachyDesignTests/ThemeStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import ReachyDesign

/// One suite name per test, because `--parallel` runs suites concurrently and a
/// shared `UserDefaults` table is exactly the global state that makes two green
/// suites turn red together. `KnownRobotStore` takes its defaults for the same
/// reason.
private func makeDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "ThemeStoreTests.\(name)")!
    defaults.removePersistentDomain(forName: "ThemeStoreTests.\(name)")
    return defaults
}

@Suite("Theme store")
struct ThemeStoreTests {
    @Test("an untouched store reports the fallback")
    func emptyStore() {
        let store = ThemeStore(defaults: makeDefaults(#function))
        #expect(store.theme == .graphite)
    }

    @Test("a written theme reads back")
    func roundTrip() {
        let store = ThemeStore(defaults: makeDefaults(#function))
        store.theme = .orchid
        #expect(store.theme == .orchid)
    }

    @Test("a second store over the same defaults sees the write")
    func sharedAcrossInstances() {
        let defaults = makeDefaults(#function)
        ThemeStore(defaults: defaults).theme = .teal
        #expect(ThemeStore(defaults: defaults).theme == .teal)
    }

    /// The downgrade case: a build that predates a theme reads its name and must not
    /// crash or render an empty tint.
    @Test("an unknown raw value falls back")
    func unknownValue() {
        let defaults = makeDefaults(#function)
        defaults.set("chartreuse", forKey: ThemeStore.key)
        #expect(ThemeStore(defaults: defaults).theme == .graphite)
    }

    @Test("a value of the wrong type falls back")
    func wrongType() {
        let defaults = makeDefaults(#function)
        defaults.set(42, forKey: ThemeStore.key)
        #expect(ThemeStore(defaults: defaults).theme == .graphite)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./bin/mise run test:filter ThemeStoreTests`
Expected: compile failure — `cannot find 'ThemeStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ReachyDesign/ThemeStore.swift`:

```swift
import Foundation

/// Where the chosen theme lives, bound to one `UserDefaults`.
///
/// The defaults are injected rather than reached for: `--parallel` runs suites
/// concurrently over a single `.standard` table, and production passes the shared
/// app-group suite so the widget process reads the same value. This type knows
/// about neither — it takes what it is given, exactly as `KnownRobotStore` does.
public struct ThemeStore {
    public static let key = "ReachyDesign.theme"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var theme: ReachyTheme {
        get {
            guard let raw = defaults.string(forKey: Self.key),
                  let theme = ReachyTheme(rawValue: raw)
            else { return .fallback }
            return theme
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./bin/mise run test:filter ThemeStoreTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
./bin/mise run format
git add Sources/ReachyDesign/ThemeStore.swift Tests/ReachyDesignTests/ThemeStoreTests.swift
git commit -m "feat(theme): persist the chosen theme in an injected defaults suite"
```

---

### Task 4: Environment plumbing

The two modifiers: one in `ReachyDesign` that applies a theme, one in `ReachyUI` that knows where the value lives.

**Files:**

- Create: `Sources/ReachyDesign/ThemeEnvironment.swift`
- Create: `Sources/ReachyUI/ThemeSettings.swift`

**Interfaces:**

- Consumes: `ReachyTheme`, `ThemeStore`, `KnownRobots.defaults` (ReachyKit).
- Produces: `EnvironmentValues.reachyTheme`, `View.reachyTheme(_ theme: ReachyTheme) -> some View`,
  `View.reachyThemeFromSettings(_ defaults: UserDefaults = KnownRobots.defaults) -> some View`.

- [ ] **Step 1: Write the environment key**

Create `Sources/ReachyDesign/ThemeEnvironment.swift`:

```swift
import SwiftUI

private struct ReachyThemeKey: EnvironmentKey {
    static let defaultValue = ReachyTheme.fallback
}

public extension EnvironmentValues {
    /// The theme in force. Defaults to `.fallback`, which is what makes an
    /// un-themed preview or snapshot render exactly what a fresh install shows.
    ///
    /// Spelled out rather than written with `@Entry`: that macro ships in Xcode's
    /// SDKs and not in the pinned swift.org toolchain, so it would break
    /// `swift build` — the same reason `reachyPreviewMode` is hand-written.
    var reachyTheme: ReachyTheme {
        get { self[ReachyThemeKey.self] }
        set { self[ReachyThemeKey.self] = newValue }
    }
}

public extension View {
    /// Applies a theme: the value for anything that reads it, and the tint every
    /// system control follows.
    ///
    /// Belongs at a scene's entry point, never at `ReachyRootView`. Environment
    /// resolves nearest-to-leaf, so a root that read the store itself would
    /// overwrite whatever a preview injected — and the snapshot suite could then
    /// only ever capture the default.
    func reachyTheme(_ theme: ReachyTheme) -> some View {
        environment(\.reachyTheme, theme)
            .tint(theme.accent)
    }
}
```

- [ ] **Step 2: Write the settings-bound modifier**

Create `Sources/ReachyUI/ThemeSettings.swift`:

```swift
import ReachyDesign
import ReachyKit
import SwiftUI

/// Reads the stored theme and applies it, redrawing when it changes.
///
/// `@AppStorage` rather than a `ThemeStore` read: the store is a value type with no
/// change notification, and a scene root has to re-render the moment the picker
/// writes. Both sit on the same key and the same suite, so the widget — which has
/// no SwiftUI to observe with — keeps using `ThemeStore`.
private struct ThemeFromSettings: ViewModifier {
    @AppStorage(ThemeStore.key) private var rawTheme: String = ReachyTheme.fallback.rawValue

    init(defaults: UserDefaults) {
        _rawTheme = AppStorage(
            wrappedValue: ReachyTheme.fallback.rawValue,
            ThemeStore.key,
            store: defaults
        )
    }

    func body(content: Content) -> some View {
        content.reachyTheme(ReachyTheme(rawValue: rawTheme) ?? .fallback)
    }
}

public extension View {
    /// The app's own themed root. The default suite is the shared app group, so the
    /// app and the widget read one value.
    func reachyThemeFromSettings(_ defaults: UserDefaults = KnownRobots.defaults) -> some View {
        modifier(ThemeFromSettings(defaults: defaults))
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `./bin/mise run build`
Expected: success. `KnownRobots.defaults` is `public` and `ReachyUI` already depends on `ReachyKit`.

- [ ] **Step 4: Commit**

```bash
./bin/mise run format && ./bin/mise run lint
git add Sources/ReachyDesign/ThemeEnvironment.swift Sources/ReachyUI/ThemeSettings.swift
git commit -m "feat(theme): carry the theme through the environment and the tint"
```

---

### Task 5: Apply at the entry points and re-record the references

The commit that turns the app graphite. Every reference image moves here, once.

**Correction, added after implementation.** It took two commits, not one, and the first did not touch the
snapshot suite at all. `.reachyThemeFromSettings()` at `ReachyMiniApp` and `ReachyStorybookApp` cannot reach a
single `#Preview` — Prefire instantiates preview bodies directly, never through `ReachyRootView` or either
`WindowGroup`/`NavigationStack`. Step 4 below measured 44 references moving from the entry-point commit alone, not
"a large number" of the ~1100, and that delta was never explained — it is not evidence the entry point reached the
suite. A follow-up commit, `85cf545`, wrapped every preview body inlined by
`Apps/ReachyUISnapshotTests/PreviewTests.stencil` in `Group { … }.reachyTheme(.fallback)`; that is what actually
re-recorded 978 of the 1272 references. The steps below are left as originally written — read their
"moves"/"re-record" language as describing the state after both commits, not the entry-point commit alone.

**Files:**

- Modify: `Apps/ReachyMini/Sources/ReachyMiniApp.swift`
- Modify: the storybook's app entry under `Apps/ReachyStorybook/Sources/`
- Modify: `Apps/ReachyMini/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`
- Modify: `Apps/ReachyUISnapshotTests/__Snapshots__/**` (regenerated)

**Interfaces:**

- Consumes: `.reachyThemeFromSettings()` from Task 4.
- Produces: nothing new — this is wiring.

- [ ] **Step 1: Apply the theme in the app**

In `Apps/ReachyMini/Sources/ReachyMiniApp.swift`, chain the modifier onto `ReachyRootView` after
`.reachyPreviewMode(…)`:

```swift
.reachyPreviewMode(ProcessInfo.processInfo.arguments.contains("--reachy-smoke"))
.reachyThemeFromSettings()
```

- [ ] **Step 2: Apply the theme in the storybook**

In `Apps/ReachyStorybook/Sources/ReachyStorybookApp.swift`, add `import ReachyUI` and chain the modifier onto the
`NavigationStack` inside the `WindowGroup`, after `.toolbar(.hidden, …)`:

```swift
        .toolbar(.hidden, for: .navigationBar, .bottomBar)
}
.reachyThemeFromSettings()
```

The storybook has no app-group entitlement, so `KnownRobots.defaults` resolves to `.standard` there — deliberate,
and the reason that function guards rather than force-unwraps.

- [ ] **Step 3: Repaint `AccentColor` to graphite**

Replace the two `components` blocks in
`Apps/ReachyMini/Resources/Assets.xcassets/AccentColor.colorset/Contents.json` — light `red 0x3E`, `green 0x47`,
`blue 0x57`; dark `red 0xA9`, `green 0xB6`, `blue 0xCC`. Leave the structure untouched.

This is what the system uses for the first frame and for surfaces outside our hierarchy; it must equal the default
theme or launch flashes another colour.

- [ ] **Step 4: See what moves before overwriting it**

Run: `./bin/mise run test:snapshots`
Expected: FAIL, naming a large number of references. That is correct — they were all recorded in system blue.
Note the count. If a reference that renders no tint at all (`JoystickPad` draws `.fill(.tint)`, so pick something
else, e.g. a log console capture) also moved, stop: something other than the accent changed.

- [ ] **Step 5: Re-record**

Run: `./bin/mise run test:snapshots:record`
Expected: every reference rewritten. `record` deletes all ~1100 PNGs first, so if the snapshot target fails to
_build_ you are left with none — confirm `./bin/mise run snapshots:_run` compiles before running this.

- [ ] **Step 6: Verify the re-recording settles**

Run: `./bin/mise run test:snapshots`
Expected: PASS with nothing rewritten.

- [ ] **Step 7: Commit**

```bash
./bin/mise run format
git add Apps/ReachyMini Apps/ReachyStorybook Apps/ReachyUISnapshotTests/__Snapshots__
git commit -m "feat(theme): apply the stored theme at every scene entry point"
```

The PNGs need that explicit `git add` — no hook stages them.

---

### Task 6: The picker

**Files:**

- Create: `Sources/ReachyUI/Settings/AppearanceSection.swift`
- Create: `Sources/ReachyUI/Previews/AppearancePreviews.swift`
- Modify: `Sources/ReachyUI/Settings/SettingsScreen.swift:31-42`

**Interfaces:**

- Consumes: `ReachyTheme`, `ThemeStore`, `EnvironmentValues.reachyTheme`.
- Produces: `AppearanceSection()` — a `View` with no parameters, and `ReachyTheme.title`.

- [ ] **Step 1: Add the localized titles**

Append to `Sources/ReachyDesign/ReachyTheme.swift`:

```swift
public extension ReachyTheme {
    /// Colour names, not robot vocabulary — a translator gets the same six words a
    /// paint chart would use.
    var title: LocalizedStringResource {
        switch self {
        case .graphite: .reachy("Graphite")
        case .bronze: .reachy("Bronze")
        case .teal: .reachy("Teal")
        case .indigo: .reachy("Indigo")
        case .orchid: .reachy("Orchid")
        case .rose: .reachy("Rose")
        }
    }
}
```

- [ ] **Step 2: Add the `Color(hex:)` helper the tile will need**

Append to `Sources/ReachyDesign/ReachyTheme.swift`:

```swift
public extension Color {
    /// A fixed sRGB colour from a palette constant. Not adaptive on purpose — the
    /// gradient stops describe an icon, which has one appearance.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
```

- [ ] **Step 3: Write the section**

Create `Sources/ReachyUI/Settings/AppearanceSection.swift`:

```swift
import ReachyDesign
import ReachyKit
import SwiftUI

/// The theme picker.
///
/// A tile is the theme's own icon gradient rather than a rendered app icon: the
/// gradient *is* the icon's background, it costs no asset, and it does not promise
/// an icon change on macOS, where there is none.
struct AppearanceSection: View {
    @AppStorage(ThemeStore.key, store: KnownRobots.defaults)
    private var rawTheme: String = ReachyTheme.fallback.rawValue

    private var selection: ReachyTheme {
        ReachyTheme(rawValue: rawTheme) ?? .fallback
    }

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.md) {
                    ForEach(ReachyTheme.allCases) { theme in
                        tile(theme)
                    }
                }
                .padding(.vertical, Space.sm)
            }
        } header: {
            Text(.reachy("Appearance"))
        }
    }

    private func tile(_ theme: ReachyTheme) -> some View {
        Button {
            rawTheme = theme.rawValue
        } label: {
            VStack(spacing: Space.sm) {
                Radius.rect(Radius.lg)
                    .fill(gradient(theme))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Radius.rect(Radius.lg)
                            .strokeBorder(theme.accent, lineWidth: theme == selection ? 3 : 0)
                            .padding(-Space.xs)
                    }
                Text(theme.title)
                    .font(Typography.status)
                    .foregroundStyle(theme == selection ? Tone.brand.style : Tone.quiet.style)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(theme.title))
        .accessibilityAddTraits(theme == selection ? [.isSelected] : [])
    }

    private func gradient(_ theme: ReachyTheme) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(hex: theme.palette.gradientTop),
                Color(hex: theme.palette.gradientBottom),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
```

- [ ] **Step 4: Mount it in Settings**

In `Sources/ReachyUI/Settings/SettingsScreen.swift`, add `AppearanceSection()` to the `Form` immediately before
`privacySection`:

```swift
AppearanceSection()
privacySection
```

- [ ] **Step 5: Write the previews**

Create `Sources/ReachyUI/Previews/AppearancePreviews.swift`:

```swift
import ReachyDesign
import SwiftUI

#Preview("Appearance — picker") {
    Form {
        AppearanceSection()
    }
    .formStyle(.grouped)
}

#Preview("Appearance — graphite") { themedSample(.graphite) }
#Preview("Appearance — bronze") { themedSample(.bronze) }
#Preview("Appearance — teal") { themedSample(.teal) }
#Preview("Appearance — indigo") { themedSample(.indigo) }
#Preview("Appearance — orchid") { themedSample(.orchid) }
#Preview("Appearance — rose") { themedSample(.rose) }

/// One screen per theme, so a reference exists for each accent rather than for the
/// default alone. A `Form` with the controls that actually carry the tint — a
/// button, a link-styled row, a toggle, a segmented picker.
@MainActor
private func themedSample(_ theme: ReachyTheme) -> some View {
    ThemeSample()
        .reachyTheme(theme)
}

private struct ThemeSample: View {
    @State private var isOn = true
    @State private var segment = 0

    var body: some View {
        Form {
            Section {
                Button(.reachy("Set up a new robot over Bluetooth")) {}
                Toggle(.reachy("Automatic reconnect"), isOn: $isOn)
                Picker(.reachy("Source"), selection: $segment) {
                    Text(.reachy("This network")).tag(0)
                    Text(.reachy("Manual")).tag(1)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(.reachy("Appearance"))
            }
            AppearanceSection()
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 6: Regenerate the project and check the previews compile**

Run: `./bin/mise run project && ./bin/mise run snapshots:build`
Expected: success. A preview that does not compile is invisible to `swift build` — `Previews/` is excluded from the
SwiftPM target — so this step is the only thing that catches it before `record` deletes every reference.

- [ ] **Step 7: Record the new references**

Run: `./bin/mise run test:snapshots` then `./bin/mise run test:snapshots:record`
Expected: the seven new previews appear as new references; nothing else moves. If unrelated references move, check
whether any of them holds an indeterminate `ProgressView` — those capture at whatever phase the run reached, and a
timing shift is the usual explanation.

- [ ] **Step 8: Commit**

```bash
./bin/mise run format && ./bin/mise run lint
git add Sources/ReachyUI Sources/ReachyDesign Apps/ReachyUISnapshotTests/__Snapshots__
git commit -m "feat(theme): add the appearance picker to Settings"
```

---

### Task 7: The widget follows the theme

**Files:**

- Modify: `Apps/ReachyWidget/Sources/ReachyAppsWidget.swift:91`
- Modify: `Sources/ReachyUI/Settings/AppearanceSection.swift`

**Interfaces:**

- Consumes: `ThemeStore`, `KnownRobots.defaults`, `.reachyTheme(_:)`.
- Produces: nothing new.

- [ ] **Step 1: Theme the widget bodies**

In `Apps/ReachyWidget/Sources/ReachyAppsWidget.swift`, apply the stored theme to the view the configuration
returns:

```swift
RobotAppsWidgetView(content: entry.content)
    .reachyTheme(ThemeStore(defaults: KnownRobots.defaults).theme)
```

Do the same at `Apps/ReachyWidget/Sources/RobotStatusWidget.swift:76`:

```swift
RobotWidgetView(content: entry.content)
    .reachyTheme(ThemeStore(defaults: KnownRobots.defaults).theme)
```

`ReachyWidgetUI` already depends on `ReachyDesign` and `ReachyKit`, so no manifest change is needed.

- [ ] **Step 2: Reload timelines when the theme changes**

In `AppearanceSection.tile(_:)`, after writing `rawTheme`:

```swift
Button {
    rawTheme = theme.rawValue
    #if !os(macOS)
        WidgetCenter.shared.reloadAllTimelines()
    #endif
} label: {
```

and `import WidgetKit` at the top. Without this the widget keeps its old accent until the system next rebuilds a
timeline, which can be hours. `ReachyRootViewSupport.swift:64` does the same after a robot change.

- [ ] **Step 3: Build both platforms**

Run: `./bin/mise run build:app && ./bin/mise run build:app:ios`
Expected: both succeed. `build:app` targets macOS, where `ReachyWidget` does not exist at all — only `build:app:ios`
compiles the extension, which is why both are run.

- [ ] **Step 4: Commit**

```bash
./bin/mise run format && ./bin/mise run lint
git add Apps/ReachyWidget Sources/ReachyUI/Settings/AppearanceSection.swift
git commit -m "feat(theme): follow the chosen theme in the widget"
```

---

### Task 8: Documentation

The three places that describe a world without themes.

**Files:**

- Modify: `Sources/ReachyDesign/Tone.swift:5`
- Modify: `Sources/ReachyDesign/AGENTS.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Fix the stale claim in `Tone.swift`**

Replace the paragraph beginning "There is no palette and no asset catalogue behind this, on purpose" with:

```swift
/// The palette behind `.brand` is `ReachyTheme` — six generated colour sets, one of
/// which the scene root applies as its tint. The other four roles stay system
/// colours on purpose: a role that pinned its own literal could not adapt under
/// chrome, which is the trap `ReachyUI/AGENTS.md` records the app falling into
/// twice.
```

- [ ] **Step 2: Add a theming section to `ReachyDesign/AGENTS.md`**

Under `## Rules`, add:

```markdown
- **A theme is applied at a scene's entry point, never inside a root view.** Environment resolves nearest-to-leaf,
  so a root reading `ThemeStore` itself would overwrite the theme a preview injected — and the snapshot suite could
  then capture nothing but the default. `ReachyMiniApp` and `ReachyStorybook` apply it; `ReachyRootView` does not.
- **Theme colours are Swift constants; `Theme*.colorset` is generated.** `Scripts/render-theme-colors.swift` writes
  the catalogue from `ReachyTheme.palette`, and `ReachyThemeTests` fails if the two disagree. Edit the constants,
  re-run the script, never hand-edit the JSON.
- **A new theme must pass the separation rule** — 3:1 against its background in both appearances, and either 30° of
  hue or a 1.8 luminance ratio away from `danger`, `warning` and `success`. Coral failed both limbs against
  `danger`, which is why the app's first accent is not among the themes.
- **`AccentColor.colorset` in the app target still matters.** It paints the first frame and every surface drawn
  outside our hierarchy — system alerts, the share sheet. It must equal `ReachyTheme.fallback` or launch flashes
  another colour.
```

Also fix line 130: "a tintless label beside a blue one reads as disabled" now reads "beside a tinted one".

- [ ] **Step 3: Record where theme values live in `CLAUDE.md`**

In the Quick Reference block, after the `update-spec` line:

```
swift Scripts/render-theme-colors.swift  # Regenerate Theme*.colorset from ReachyTheme.palette
```

- [ ] **Step 4: Verify formatting**

Run: `./bin/mise run format-check`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReachyDesign CLAUDE.md
git commit -m "docs(theme): record where theme values live and what applies them"
```

---

## Deviations from the spec

Two, both found while writing this plan:

1. **`ThemeStore` is not declared `Sendable`.** It holds a `UserDefaults`, which is thread-safe but unmarked;
   `KnownRobotStore` has the same shape and the same omission. Adding `@unchecked Sendable` would state more than
   is known.
2. **Picker tiles are drawn, not rendered.** The spec had the icon script emitting PNG thumbnails; a
   `LinearGradient` over the theme's two gradient stops is the same image with no asset, and it does not imply an
   icon change on macOS. This also removes thumbnail generation from the icon plan.
