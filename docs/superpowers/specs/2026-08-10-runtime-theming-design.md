# Runtime theming: accent colour and app icon

## Problem

The app's accent is coral, and nothing verifies it.

**It arrived as a side effect.** `076bbd3` ("draw the Hey Reachy icon and accent colour", 2026-08-09) created the
project's first asset catalogue for `AppIcon` and, in the same commit, an `AccentColor.colorset` holding `#FF5A3C`
light / `#FF7A5C` dark. The only code change was one line — `resources: ["ReachyMini/Resources/**"]` in
`Apps/Project.swift:116`. Because `Tone.brand` resolves to `.tint`, that single JSON file repainted every `Button`,
`Link`, `Toggle`, `Picker` and every `.foregroundStyle(.tint)` in the app, without appearing in any Swift diff.

**It collides with `Tone.danger`.** Coral sits at hue 9.2°, the system red at 3.2°, at the same saturation and
lightness. Six degrees separate "this is the action" from "this is broken". Both already appear on one screen:
`Connection-permission-denied` measures 66% accent-hued pixels and 34% red, `Connection-connect-failed` 70/30. The
codebase already knows this failure mode — `CameraViewport.swift:173` picks `.warning` over `.danger` because "two
reds on one control would say recording and broken in the same colour" — but the accent escaped the same reasoning.

**No reference image has ever seen it.** `resources:` is declared on the `ReachyMini` target only.
`ReachyUISnapshotTests`, `ReachyStorybook` and `ReachyWidget` have no asset catalogue, so they render the system
blue. Measured across the reference set: `Joystick-screen` is 100% blue among saturated pixels,
`Connection-known-robot-not-responding` — the screen in the bug report — is 100% blue, `App-detail-private-space`
99.8%. All ~1100 references were recorded in a colour the app does not use.

**The design system does not know.** `Tone.swift:5` still claims "There is no palette and no asset catalogue behind
this, on purpose"; `ReachyDesign/AGENTS.md:130` still describes "a tintless label beside a blue one". Neither
mentions coral, and the value itself lives in the app target, outside the module documented as the design system's
rulebook.

## Goals

- A user-selectable theme — accent colour plus app icon as one decision — persisted across launches and shared with
  the widget.
- A default that does not collide with any semantic tone, applied to everyone who never opens Settings.
- Theme values that live in `ReachyDesign`, are visible to the snapshot target, and are verified by a test rather
  than by inspection.
- Migration of the app icon to Icon Composer, keeping the asset-catalogue pipeline for iOS 18–25.

## Non-goals

- **Arbitrary colours.** A picker cannot guarantee separation from `danger`, and alternate icons must exist in the
  bundle at build time, so a free colour could never carry a matching icon.
- **Alternate icons on macOS.** `setAlternateIconName` is UIKit. `NSApplication.applicationIconImage` would cover
  the Dock and Cmd-Tab while Finder, Launchpad and Spotlight kept the bundled icon — two icons for one app, which
  reads as a bug. macOS gets the accent colour only.
- **Per-robot themes.** A theme could live in `KnownRobot` beside `name`, but the feature is personalisation, not
  robot identity.
- **Dark and tinted icon variants.** iOS 18 supports them per icon; the current icon has none either. Six themes ×
  three variants is eighteen icons for a gain the user sees on the Home Screen only.
- **Re-recording every reference in every theme.** ~1100 references × 6 is not a viable LFS payload.

## Design

### The palette

Six themes. Each carries an accent for both appearances and a two-stop gradient for its icon.

| theme     | accent light | accent dark | hue  | contrast on white / on `#1C1C1E` | icon gradient         |
| --------- | ------------ | ----------- | ---- | -------------------------------- | --------------------- |
| graphite¹ | `#3E4757`    | `#A9B6CC`   | 218° | 9.36 / 8.30                      | `#9AA6B8` → `#3E4757` |
| bronze    | `#B26708`    | `#A86D16`   | 34°  | 4.34 / 3.94                      | `#FFC96B` → `#B26708` |
| teal      | `#00A0A8`    | `#4FD6DE`   | 183° | 3.18 / 9.73                      | `#5FE0CE` → `#00A0A8` |
| indigo    | `#4B47D6`    | `#8E8CF0`   | 242° | 6.62 / 5.80                      | `#9B9BF5` → `#4B47D6` |
| orchid    | `#9038D9`    | `#C58AF0`   | 273° | 5.59 / 6.70                      | `#E8AEFF` → `#9038D9` |
| rose      | `#D6248A`    | `#FF7ABA`   | 326° | 4.69 / 7.09                      | `#FFA8CE` → `#D6248A` |

¹ default.

Teal (3.18) and graphite's neighbours sit near the system blue's own 4.02 on white — that is the iOS norm, not a
defect. Every dark accent clears the 3 : 1 background floor; bronze's 3.94 is the tightest of the six.

**Coral is deliberately absent.** It fails the separation rule below against both `danger` (6.0° apart, luminance
ratio 1.15) and `warning` (25.8°, 1.41) — every theme above passes. Moving it far enough to pass would
either land it on `warning` or darken it into a brick. A theme the project's own rule calls unreadable is a trap,
not a choice.

**Amber was rejected and replaced by bronze.** `#E8890C` measured 2.62 : 1 on white — below the 3 : 1 floor — and
sat 1° from `Tone.warning`, which is drawn on the same screen the accent dominates
(`Connect/ConnectRail.swift:156` fills the Daemon → Version → Backend rail marker with it;
`Connect/ManualAddressSection.swift:37` uses it for the manual-address caveat). Bronze keeps the tone and separates
by lightness instead.

**Bronze's dark value was corrected in the final-fix pass before merge.** It shipped as `#E3A24A`, chosen against
the light-appearance system tones only — the separation rule below checked `palette.light` in both appearances,
never `palette.dark`. Measured against the dark system orange (`#FF9F0A`) once the rule covered both appearances,
`#E3A24A` sits 2.0° of hue and a 1.07 contrast ratio away — failing both limbs, and less distinguishable from
`warning` than the coral this feature exists to remove. `#A86D16` keeps the same hue (36°, the tone this theme is
built on) and separates by lightness instead, the same trade the light accent already makes: 2.10 against dark
`warning`, comfortably clear of the 1.8 floor, and 3.94 against the `#1C1C1E` background. Escaping the system
orange's hue upward runs into near-white before it clears 30°, so the escape is downward in lightness — bronze's
dark accent is deliberately darker than a dark-appearance accent usually is.

### `ReachyTheme` (ReachyDesign)

```swift
public enum ReachyTheme: String, CaseIterable, Sendable, Identifiable {
    case graphite, bronze, teal, indigo, orchid, rose

    public static let fallback = ReachyTheme.graphite

    public var accent: Color                // Color("ThemeGraphite", bundle: .module)
    public var alternateIconName: String?   // nil for graphite — that one is the primary AppIcon
    public var title: LocalizedStringResource
}
```

`Tone.brand` does not change. It stays `AnyShapeStyle(.tint)`, and a theme is applied with a single
`.tint(theme.accent)` at the scene root. Consequence: none of the 26 sites reading `.tint` / `Tone.brand` /
`.accentColor` are touched, and the system controls that carry no colour in source at all follow the theme for free.

### Colour values are Swift constants; the catalogue is generated

The accents are declared once as sRGB constants in `ReachyDesign` and the six `.colorset` directories under
`Sources/ReachyDesign/Resources/Assets.xcassets` are **generated from them** by the icon script.

Two reasons, both load-bearing:

1. **SwiftUI cannot build an adaptive `Color` from two literals.** Either an asset catalogue or a
   `#if canImport(UIKit)` fork of `UIColor`/`NSColor`, and `ReachyDesign` builds for both platforms. The catalogue
   is the only cross-platform answer.
2. **A test cannot read a `.colorset`.** With the constants as the source, one set of numbers feeds SwiftUI (via the
   generated catalogue), the icons (via the script) and the contrast test (directly). A rendered value that differs
   from a verified value becomes impossible.

`Package.swift:49` already declares `resources: [.process("Resources")]` for `ReachyDesign`, so the catalogue needs
no manifest change.

`Apps/ReachyMini/Resources/Assets.xcassets/AccentColor.colorset` stays, repainted to graphite. It is not dead
weight: the system applies it to everything drawn outside our hierarchy — system alerts, the share sheet, context
menus — and to the first frame before SwiftUI mounts the root. It must equal the default or launch shows a flash of
another colour.

### `ThemeStore` and propagation

```swift
public struct ThemeStore: Sendable {
    static let key = "ReachyDesign.theme"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults)
    public var theme: ReachyTheme { get nonmutating set }   // unknown raw value → .fallback
}
```

`UserDefaults` is injected, as `KnownRobotStore(defaults:)` and `FloatingViewportPreferences(defaults:)` already do:
`--parallel` runs suites concurrently over one `.standard` table, and the seam is what keeps them from fighting.
An unknown raw value resolves to `.fallback` — the case of a user who downgraded to a build that predates a theme.

```swift
// ReachyDesign — knows themes, knows nothing about app groups
extension View {
    func reachyTheme(_ theme: ReachyTheme) -> some View {
        environment(\.reachyTheme, theme).tint(theme.accent)
    }
}

// ReachyUI — knows where the value lives; @AppStorage supplies reactivity
extension View {
    func reachyThemeFromSettings(_ defaults: UserDefaults = KnownRobots.defaults) -> some View
}
```

`EnvironmentValues.reachyTheme` defaults to `.graphite`.

**Applied at the entry point — `ReachyMiniApp` and `ReachyStorybook` — not inside `ReachyRootView`.** A root that
read the store itself would overwrite whatever a preview injected from outside, and the snapshot suite could then
only ever capture the default: green results over unverified code, which is the original defect wearing a new
disguise. With the modifier at the entry point, a preview writes `.reachyTheme(.orchid)` and gets orchid.

**Correction, added after Task 5's implementation found this wrong.** The snapshot suite does not inherit the
entry point's application, in either direction. `#Preview` bodies are instantiated directly by Prefire's
generated test methods, which never construct `ReachyRootView` and never pass through either app's
`WindowGroup`/`NavigationStack` content view — so `.reachyThemeFromSettings()` at `ReachyMiniApp` and
`ReachyStorybookApp` cannot reach a single capture. The paragraph above is still the right reason to keep
`ThemeStore` out of `ReachyRootView`'s own body — for the app and the storybook themselves — but it is not why any
reference image ends up themed. What themes those is a second mechanism, added once Task 5's review caught the
gap: the forked `Apps/ReachyUISnapshotTests/PreviewTests.stencil` wraps every preview body it inlines in
`Group { … }.reachyTheme(.fallback)` (commit `85cf545`). `ReachyTheme.accent` resolves against `ReachyDesign`'s
own bundled colour catalogue, which is why that theme reaches a test bundle depending on neither app target.

### The widget

`ReachyWidgetUI` already depends on `ReachyDesign` and `ReachyKit` (`Package.swift:106`), so it reads the same
store and applies `.reachyTheme(_:)` in `ReachyAppsWidget.body` and the status widget beside it. No new edge in the
module graph, and `ReachyMedia` stays out of the widget process as required.

A widget does not redraw on a defaults change: selecting a theme must call
`WidgetCenter.shared.reloadAllTimelines()`. The app already does this in `ReachyRootViewSupport.swift:64`.

In accented render mode the system supplies its own tint and ours is ignored — expected, not a bug.

### App icons: two pipelines

The icon migrates to Icon Composer, and the asset catalogue stays for iOS 18–25. Apple is explicit: "If you want
your existing icon to appear in previous releases, continue to use asset catalogs to represent your app icon."

**Source of truth.** One reference `AppIcon.icon` is composed by hand in Icon Composer.app and committed. A `.icon`
is a directory holding `icon.json` and an `Assets/` folder of scalable SVG, so the five alternates are produced by
the script from the reference through colour substitution. Writing `icon.json` from scratch is explicitly not the
plan: the schema is undocumented and will not survive every Xcode.

**What the script produces**, from the same palette constants:

| output                                        | for                                                 |
| --------------------------------------------- | --------------------------------------------------- |
| `Sources/ReachyDesign/Resources/…/*.colorset` | SwiftUI accents (6)                                 |
| `AppIcon.icon` alternates (5)                 | iOS 26+, Icon Composer pipeline                     |
| `AppIcon*.appiconset` (6)                     | iOS 18–25 fallback, current CoreGraphics renderer   |
| picker tiles (PNG)                            | `AppearanceSection` — `.icon` exposes no thumbnails |

The existing CoreGraphics renderer is not discarded; it keeps producing the fallback catalogue and gains the tile
and `.colorset` outputs. Determinism ("same code, same bytes") must hold for every output, or each run dirties the
diff.

**Build settings** — added to the existing `settings: .settings(base:)` on `ReachyMini` (`Project.swift:132`),
SDK-scoped so the macOS build ignores them:

```swift
"ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES[sdk=iphone*]":
    "AppIcon-Bronze AppIcon-Teal AppIcon-Indigo AppIcon-Orchid AppIcon-Rose",
"ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS[sdk=iphone*]": "YES",
```

**Switching** is `UIApplication.shared.setAlternateIconName(_:)` behind `#if os(iOS)`, wrapped thinly in `ReachyUI`.
The theme is saved unconditionally; the icon is best effort. On failure — including
`supportsAlternateIcons == false` — a caption appears under the picker. No alert: iOS already shows its own
unsuppressable "You have changed the icon for Hey Reachy" on success, and stacking one on top would be worse than
the failure.

**This carries a risk that must be retired first.** Sources disagree on whether `.icon` files work as alternate
icons under Xcode 26: the developer forums report the `supportsAlternateIcons == false` regression fixed in
beta 3, while Use Your Loaf reports it working only in Xcode 27. The toolchain here is 26.4.1. Step 1 of delivery is
a two-icon prototype on hardware, before any of the rest is built.

**Correction, measured on Xcode 26.4.1 (build 17E202) with Icon Composer 1.4.** Four claims above did not survive the
prototype, and the risk the delivery order was built around is retired: `supportsAlternateIcons` is `true` and the
switch was observed changing a Home Screen icon.

1. **"The asset catalogue stays for iOS 18–25" is not implementable.** A `.icon` shadows a same-named `.appiconset`
   entirely — with both present, `Assets.car` carried 18 renditions from the `.icon` and **zero** from the catalogue;
   renamed to `AppIconLegacy` it reappeared as an ordinary 2-rendition asset. Two catalogues cannot both be primary
   either, since `CFBundleIconName` names one. What actually serves iOS 18–25 is the back-deployment rasters `actool`
   derives from the `.icon`, verified rendering correctly on a fresh iOS 18.5 simulator. So `AppIcon.appiconset` is
   deleted and there is **one** pipeline, not two.
2. **"Writing `icon.json` from scratch is explicitly not the plan" is reversed.** A hand-written document compiles
   into the full Icon Composer form — `IconGroup`, `Named Gradient` ×2, three `IconImageStack`s. The schema was read
   off four shipping `.icon` bundles rather than guessed, and generating it is what keeps six themes cheap to author.
3. **The macOS ladder is generated too**, with better geometry than the hand-written Big Sur rounded rectangle it
   replaces, so that maths leaves the script along with the asset catalogue.
4. **The dark and tinted appearances are free to _author_ and not free in _bytes_.** `actool` derives all three from
   the single source with no extra work — but each `.icon` compiles to 24 renditions where an `.appiconset` produced
   a handful. Measured by building the same tree twice: `Assets.car` is 1.66 MiB with one icon and 4.71 MiB with six,
   so the five alternates cost **3.05 MiB, or 624 KiB each** — against this document's estimate of ~1.25 MB for all
   five. The source tree moves the other way: the deleted catalogue was 539 KB of PNG and the six bundles are 349 KB.

### `AppearanceSection` (ReachyUI)

A new `Sources/ReachyUI/Settings/AppearanceSection.swift`, following `AudioSettingsSection`,
`AdvancedSettingsSection` and `HFAccountSection`; `SettingsScreen` (139 lines) gains one line in its `body` rather
than a fourth responsibility.

A horizontal strip of tiles: icon preview, title, the selected one outlined in its own accent. Each tile is a
`Button` carrying `accessibilityLabel` from `ReachyTheme.title` and `.isSelected`. Titles go through `.reachy(_:)`
(rule 9); spacing and corners through `Space` / `Radius.rect(.lg)` / `Typography` (rule 10).

On macOS the strip renders the colours but makes no promise about the Dock icon.

## Testing

**`ThemeStoreTests`** — round trip, empty key → `.fallback`, unknown raw value → `.fallback`, and that writing
through one store instance is visible to another over the same injected `UserDefaults`.

**`ReachyThemeTests`** — the rule that this whole feature exists to enforce, as a red test:

- every accent ≥ 3 : 1 against white (light) and against `#1C1C1E` (dark);
- every accent separated from `Tone.danger`, `Tone.warning` and `Tone.success` by **either** ≥ 30° of hue **or** a
  luminance-contrast ratio ≥ 1.8.

Two-limb on purpose. Bronze sits 1.5° from `warning` and passes on lightness (1.97) — separation by brightness is a
legitimate answer, and a hue-only rule would reject a readable colour. Coral fails both limbs against `danger`
(6.0°, 1.15), which is exactly the case that must stay rejected.

**`ThemeIconNameTests`** — `graphite.alternateIconName == nil`, every other case non-nil, and each name present in
`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`. A theme whose icon is not in the build setting fails at runtime
only, on a device, which is the worst place to find it.

## Previews and snapshots

**A theme gallery** — six previews, one screen per theme, under `Sources/ReachyUI/Previews`, plus one preview of
`AppearanceSection` itself. This is where theme coverage lives; recording is `mise run test:snapshots:record`
followed by an explicit `git add` of the PNGs, which no hook stages.

**Every existing reference is re-recorded once, in graphite.** They are currently system blue; after this change
the whole set moves. **Correction:** not because "the entry point applies the default" — it does not reach a
`#Preview` at all, per the correction under "`ThemeStore` and propagation" above. What actually moves the set is
`Apps/ReachyUISnapshotTests/PreviewTests.stencil` wrapping every inlined preview body in `.reachyTheme(.fallback)`,
landed one commit after the entry-point wiring once review caught the gap. Run `mise run test:snapshots` first to
see the extent, per the standing rule that `record` overwrites blind.

Adding a preview directory is not one edit: `Apps/.prefire.yml` `sources`, the `sources` of both preview-hosting
targets in `Project.swift`, `testable_imports`, and the explicit directory list handed to `prefire playbook` in
**two** `mise.toml` tasks (`project` and `storybook`). The gallery lives inside `Sources/ReachyUI/Previews`, so no
new directory is introduced — but if that changes, all five edits apply.

## Delivery

Sequenced so the riskiest unknown is retired first and each step lands green.

1. **Icon Composer prototype.** One reference `.icon` plus one alternate, `setAlternateIconName` exercised on
   hardware via `mise run device`. Confirms `supportsAlternateIcons` under Xcode 26.4.1. If it fails, the icon half
   of the feature is re-planned before anything is built on it; the colour half is unaffected.
2. **`ReachyTheme` + generated colorsets + `ThemeStore`,** with `ThemeStoreTests` and `ReachyThemeTests`.
   No UI. The contrast test guards the palette from here on.
3. **Propagation:** environment key, `.reachyTheme(_:)`, entry-point application in `ReachyMiniApp` and
   `ReachyStorybook`; `AccentColor.colorset` repainted to graphite. The theme gallery previews land here too — each
   one calls `.reachyTheme(_:)` on itself directly, which is what proves the modifier paints all six accents (not
   the entry-point wiring, which no preview passes through). **Correction:** re-recording the reference set took a
   second commit within this step, not the entry-point commit alone — see the corrections above.
4. **Icons:** script extended to emit `.icon` alternates, fallback catalogues and picker tiles; build settings in
   `Project.swift`; `ThemeIconNameTests`.
5. **`AppearanceSection`** with its previews and references, plus the failure caption.
6. **Widget:** theme applied in `ReachyAppsWidget`, `reloadAllTimelines()` on selection.
7. **Documentation:** `Tone.swift`'s stale comment, a theming section in `ReachyDesign/AGENTS.md`, and the
   two-icon-pipeline trap in `CLAUDE.md`.

Bundle size is measured, not estimated: `mise run inspect:bundle` on a Release archive once step 4 lands. The
fallback catalogues alone add roughly 1.25 MB (five icons at the current 249 KB); the `.icon` contribution compiles
into `Assets.car` and has no reliable prior estimate.

## Known limitations

- **System surfaces keep the default accent.** With orchid selected, the share sheet stays graphite.
  `AccentColor` is a property of the bundle and cannot be overridden at runtime.
- **iOS shows its own alert on every icon change.** Not suppressible by legal means.
- **macOS never changes its icon.** Colour only.
- **Existing installs move to graphite on update.** Distinguishing "upgrade" from "fresh install" would need a
  marker and a permanent second branch in the store, to spare users a colour change they can undo in two taps. A
  release note covers it instead.
- **`.icon` back-deployment is imperfect,** which is why the asset catalogue stays. The two pipelines must be
  regenerated together; a palette change applied to one and not the other diverges silently.
