# ReachyDesign

Design tokens and the `ReachySurface` facade. **Depends on SwiftUI and nothing else** — both `ReachyUI` and
`ReachyWidgetUI` link it, and a dependency is linked into a _target_, not into the place it is called from, so
anything heavier added here would be dragged into the widget extension too. In particular: never import `ReachyKit`.
A caller maps its own domain type onto a token (`RobotAppStatus.state` → `StatusTone`); the mapping is the caller's.

## What is here

| File                       | Holds                                                                                                                                |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `Space.swift`              | The 4-point layout rhythm, and the two rules for adopting it                                                                         |
| `Radius.swift`             | Corner radii, `Radius.rect(_:)` and `Radius.flush(to:_:)` — the only two handed out                                                  |
| `Tone.swift`               | Semantic colour roles over system styles; `.brand` is the one exception, resolving to `ReachyTheme`                                  |
| `ReachyTheme.swift`        | The six-theme palette, `accent`, `title`, `colorSetName`, `alternateIconName`, and the `Color(hex:)` the picker draws its tiles with |
| `ThemeStore.swift`         | The chosen theme, persisted against an injected `UserDefaults`                                                                       |
| `ThemeEnvironment.swift`   | `EnvironmentValues.reachyTheme` + `.reachyTheme(_:)`                                                                                 |
| `Typography.swift`         | Text roles from semantic `Font`s, and `IconRatio` for glyph-as-artwork                                                               |
| `Motion.swift`             | The animations the app runs, named — including the one that carries a gesture                                                        |
| `Metrics.swift`            | Sizes fixed by what they represent rather than by their text                                                                         |
| `StatusTone.swift`         | `StatusTone` + `ReachyStatusLabel`, the one shape a state caption renders in                                                         |
| `ReachySurface.swift`      | `SurfaceRole` + `reachySurface(_:in:)`, and its safe-area form                                                                       |
| `ReachyBadge.swift`        | A word in a capsule, on the `.badge` surface                                                                                         |
| `ReachySurfaceGroup.swift` | `GlassEffectContainer` — and why it cannot hold a `reachySurface`                                                                    |
| `ReachyButton.swift`       | `ButtonEmphasis` + `reachyButton(_:)` — and why it has no glass tier                                                                 |
| `ReachyChrome.swift`       | The iOS 26 bar behaviours, each a no-op below the floor                                                                              |
| `ReachySheet.swift`        | The one axis a sheet declares on macOS, the one it measures, and why iOS reads none                                                  |
| `ReachyTabAccessory.swift` | The tab-view bottom accessory, its placement vocabulary, and its fallback                                                            |

## Rules

- **A theme is applied at a scene's entry point, never inside a root view.** Environment resolves nearest-to-leaf,
  so a root reading `ThemeStore` itself would override whatever an ancestor injected — a preview, `ReachyMiniApp`,
  or `ReachyStorybook`. `ReachyMiniApp` and `ReachyStorybook` apply it; `ReachyRootView` does not. **Neither entry
  point reaches the snapshot suite, though** — `#Preview` bodies are instantiated directly by Prefire and never
  pass through either scene. What themes every capture is the forked
  `Apps/ReachyUISnapshotTests/PreviewTests.stencil`, which wraps each inlined preview body in
  `Group { … }.reachyTheme(.fallback)`; `ReachyTheme.accent` resolves against this module's own bundled colour
  catalogue (`Color(colorSetName, bundle: .module)`), which is why that theme reaches a test bundle depending on
  neither app target.
- **Theme colours are Swift constants; `Theme*.colorset` is generated — from a second, hand-kept copy of them.**
  `Scripts/render-theme-colors.swift` cannot link `ReachyDesign`, so it carries its own duplicate of
  `ReachyTheme.palette` and writes the catalogue — including the catalogue's own root `Contents.json` — from that
  copy. A new or changed theme means editing both files by hand before re-running `./bin/mise run theme:colors`;
  `ReachyThemeTests` only catches the two drifting apart, it does not keep them together. Never hand-edit the
  generated JSON, and never invoke the script bare — the mise task is what pins the toolchain.
- **A new theme must pass the separation rule**, enforced by `Tests/ReachyDesignTests/ReachyThemeTests.swift` and
  checked in **both** appearances — `palette.light` against the light-appearance system tones, `palette.dark`
  against the dark ones. `Tone.danger`/`.warning`/`.success` are adaptive, so a rule that only ever read
  `palette.light` was only ever checking half of what a dark-mode screen renders; `ConnectRail.swift` draws
  `Tone.warning` and `Tone.brand` on the same node stack, which is exactly where that gap would show. Three limbs,
  all defined once as `separates(_:from:)` in the test file so `accentSeparation` and the coral canary share the
  same numbers rather than the canary checking its own private copy:
  1. **3:1 against its background** — white in light, `#1C1C1E` in dark.
  2. **≥30° of hue or a ≥1.8 luminance-contrast ratio away from `danger`, `warning` and `success`.** Coral failed
     both limbs against `danger` in light appearance, which is why the app's first accent is not among the themes.
     Bronze is the rule's other limb in practice, in **both** appearances: ~1.5° from `warning` and separating by
     lightness instead — 1.97 at the light accent, 2.10 at the dark one.
  3. **≥1.8 against `.label`** (black in light, white in dark) — what makes a tinted row read as tappable next to
     the body text beside it. Graphite clears it in both appearances but only just in dark — 2.24 light / 2.05 dark,
     measured — which is accepted as this theme's floor rather than a reason to repaint the default fallback.
     **Teal's dark accent does not clear it** (≈1.75), found only once this limb existed to check for it, and left
     as a `withKnownIssue` in `accentAgainstLabel` rather than silently repainted: changing a shipped theme's dark
     accent to fix a test is a palette decision, not something a test file gets to decide on its own.
     This limb's 1.8 is the weakest-founded number in the rule, and worth knowing before leaning on it. Limb 1 cites
     WCAG's large-text floor; limb 2's 1.8 was chosen to separate two _saturated_ colours from each other. Limb 3
     reuses that same 1.8 for a different question — is a tint legible beside body text — with no standard behind
     it. It was not reverse-engineered to admit graphite and exclude teal (it predates both measurements), but a
     seventh theme landing near it deserves a look at the number rather than deference to it.
- **Bronze's dark accent is `#A86D16`, deliberately darker than a dark-appearance accent usually is.** It shipped as
  `#E3A24A`, chosen against the light-appearance system tones only, before the separation rule above checked
  `palette.dark` against the dark ones. Measured against dark `warning` (`#FF9F0A`), `#E3A24A` scored 2.0° of hue and
  a 1.07 contrast ratio — failing both limbs, and less distinguishable from `warning` than the coral this feature
  exists to remove. `#A86D16` keeps the same hue (36°, the tone bronze is built on) and separates by lightness
  instead — 2.10 against dark `warning`, comfortably past the 1.8 floor, and 3.94 against the `#1C1C1E` background,
  above the 3:1 floor. Escaping the system orange's hue upward runs into near-white before it clears 30°, so the
  only room to move is downward in lightness — hence a dark-appearance accent that is deliberately darker than the
  rest of this palette's dark accents tend to be.
- **A theme's icon is generated, and the `.icon` is the only pipeline.** `Scripts/render-app-icon.swift` writes six
  `Apps/ReachyMini/Resources/AppIcon*.icon` bundles from its own copy of the gradient stops — the same hand-kept
  duplicate `render-theme-colors.swift` carries, and for the same reason (a script run by `swift` cannot link this
  module). All six share a byte-identical `Assets/robot.png`; only `icon.json`'s `fill` differs, which is why adding
  a theme's icon is two constants rather than an artwork task. `JSONSerialization` is called with `.sortedKeys` so a
  re-run is byte-identical; without it the key order is the hash order and every run dirties the diff. Never
  hand-edit a generated bundle, and never open one in Icon Composer.app to "just tweak it" — it rewrites the document
  in its own shape and the next `./bin/mise run theme:icons` reverts it. Three names must agree —
  `ReachyTheme.alternateIconName`, the `.icon` directory, and `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in
  `Apps/Project.swift` — and `ThemeIconNameTests` is the only thing that checks, because a mismatch surfaces as a
  failed `setAlternateIconName` on a device and nowhere earlier.
- **There is no `AppIcon.appiconset`, and adding one back does nothing.** A `.icon` shadows a same-named catalogue:
  measured under Xcode 26.4.1, the catalogue contributed **zero** renditions while the `.icon` contributed 18, and
  renaming it to `AppIconLegacy` brought it back as an ordinary asset. iOS 18–25 is served by the back-deployment
  rasters `actool` derives — verified on a fresh iOS 18.5 simulator, which renders the icon correctly under the
  classic squircle mask — and macOS by the ladder it generates, with better geometry than the Big Sur rounded
  rectangle the script used to draw by hand.
- **The three appearances are free to author and cost 624 KiB each.** `actool` derives light, dark and tinted from
  the one source, so no artwork is authored for them — but a `.icon` compiles to 24 renditions where an
  `.appiconset` produced a handful. Measured by building the same tree twice: `Assets.car` is 1.66 MiB with one icon
  and 4.71 MiB with six. A seventh theme is 624 KiB of binary, not a rounding error; the _source_ tree is the half
  that got smaller (539 KB of deleted PNG against 349 KB of bundles).
- **A theme swatch is `ReachyTheme.iconSwatch`, and it deliberately does not copy the icon.** The picker cannot show
  the real thing — a `.icon` exposes no thumbnail — so it paints a swatch, and a swatch of the two declared stops
  reads flatter than the icon it stands for. Three things were measured off the shipping `AppIcon.icns` at 256 pt
  and are what the swatch reproduces: the gradient is **vertical** (leading and trailing edges within 5/255 of each
  other through the body of the icon, so it is not diagonal), `icon.json`'s stops land at roughly **17 % and 83 %**
  of the height rather than at the edges, and past them the material runs lighter at the top and darker at the
  bottom. **Fitting the material itself was tried and abandoned**: graphite's extremes move +20/+20/+20 and rose's
  +0/+24/+14, so neither an additive nor a multiplicative model holds across two themes, and a formula from two
  samples of an undocumented private render would be false precision that the next Xcode invalidates. The two
  magnitudes in `iconSwatch` are a judgement in the measured direction, and the blend is toward white/black rather
  than an addition so that orchid's blue and rose's red — already at full — lighten without dragging their hue.
- **A theme tile takes `Radius.tile(side:)`, not a layout radius.** It stands for the app icon, so it takes the
  icon's corner proportion (`side / 4.5` ≈ 22 %, the iOS squircle) and reads as the same object as the store and
  dock artwork, which use the same token. It shipped as `Radius.lg` — 16 pt on a 56 pt tile, 29 % — which is
  visibly rounder than an icon. **A selection ring around it is concentric or it is wrong**: a ring pushed out by
  `Space.xs` needs its radius grown by the same `Space.xs`, or the gap is narrower at the corners than along the
  sides and the corner reads pinched. Equal radii at different insets is the mistake to look for.
- **SwiftUI has an API for concentric corners and it does not fit this call site — measured, not assumed.**
  `ContainerRelativeShape` (iOS 14+) inside `containerShape(_:)`, and `ConcentricRectangle` /
  `.rect(corner: .containerConcentric)` (**iOS 26+**, above this app's floor), all derive the **inner** shape of a
  nested pair from its container. The theme tile is the inner one and its radius is the thing that must stay pinned
  — it carries the icon's squircle through `Radius.tile(side:)`, shared with `AppArtwork` — so deriving it would
  hang the token on the ring, which is decoration. The direction actually needed here, outer from inner, is not
  offered at any deployment target.
  What the framework would compute in the direction it does cover is exactly `radius ± inset`: rendered at 8× with
  `ImageRenderer`, a `ContainerRelativeShape` inset 4 pt inside a `RoundedRectangle(cornerRadius: 16.444, style:
  .continuous)` came back **byte-identical** to `RoundedRectangle(cornerRadius: 12.444, style: .continuous)` — 0
  differing pixels of 262 144. So the arithmetic at the call site is the framework's own rule and not an
  approximation of it. Reach for `ContainerRelativeShape` when the container's radius is one we do **not** own — a
  widget, a window, the screen — which is the case these APIs exist for.
- **No reference image can cover an app icon.** The snapshot suite renders views, never a Home Screen. Icons are a
  device check plus one iOS 18 simulator install, and that is the whole of their cover — a green suite says nothing
  about them. `AppIconSwitcher`'s unit tests cover the decision around the call (which name, and the no-op guard that
  keeps iOS's unsuppressable alert from firing when the chosen theme is already applied), never the call itself.
- **`setAlternateIconName` fails with `NSCocoaErrorDomain` 3072 before the scene is active.** Measured: called from a
  launch `.task` it throws `NSUserCancelledError` and the icon does not change. Every caller must be a button tap, so
  the app is foreground-active by construction.
- **`AccentColor.colorset` in the app target still matters, and a test now reads it.** It paints the first frame and
  every surface drawn outside our hierarchy — system alerts, the share sheet. It must equal `ReachyTheme.fallback`
  or launch flashes another colour; `ReachyThemeTests.accentColorMatchesFallback` parses the hand-edited JSON the
  same way `catalogueMatchesConstants` parses the generated one, so a drift between the two is now a test failure
  rather than a launch flash nobody notices until a device shows it.
- **A call site names a role, never a material, a glass or an OS version.** `.reachySurface(.chrome, in: .capsule)`,
  not `.background(.regularMaterial, in: Capsule())`. The availability fork lives in one file.
- **A backdrop under a bar is not automatically a `.scrim`, and the difference is whether anything passes under it.**
  A scrim carries glass, glass renders a light surface whatever is behind it, and a footer at the bottom of a sheet
  where the step fits on one screen is backing nothing at all — so it reads as a grey strip stuck to the bottom of the
  screen with a button in it, which is how `OnboardingStepScaffold`'s footer was reported. `.page` is that footer's
  role: the opaque page fill and no effect over it, which still hides what scrolls under on the steps that do scroll
  and says nothing on the ones that do not. The two consoles keep `reachyScrim` — over a log tail there _is_ content
  passing under, and the effect is the notice that there is. Glass-free but **not** `.window`: a window is raised off
  what is behind it and takes a `.bar` material, and a page is the thing behind it.
- **Every sheet's content carries `reachySheet()`, because on macOS nothing else gives it a width.** A sheet there is
  laid out at its content's _ideal_ size, and a `Form`, a `ScrollView` or a `NavigationStack` over one offers no ideal
  width — AppKit picks something cramped and clips what does not fit rather than laying it out again. So one axis is
  declared and the other measured: `Metrics.sheetWidth`, then `presentationSizing(.fitted)` to ask the content how
  tall it wants to be _at that width_. **No reference can catch a missing one**: the snapshot suite runs on an iOS
  simulator, where this modifier does nothing at all. It is a `#if os(macOS)`, not an `#available` — a platform
  difference, not a version one, and `presentationSizing` is available at this app's floor.
  It went through two other shapes first, each shipped, each reported as a bug of its own:
  1. **A minimum in both axes.** "A minimum, so content that wants more still grows" is false for everything in
     these sheets: a `Form` and a `ScrollView` are _flexible_ and never want more than the floor they are handed, so
     the minimum was the final height of every one of them. The sign-in sheet came up as a 680 pt slab with a single
     card adrift in the middle of it, taller than the window it hung off.
  2. **`.form` for the width.** `FormPresentationSizing` proposes ~435 pt on macOS — which is the ~440 pt the
     original bug was reported at, arrived at from the other direction. A form's width is the system's idea of a
     settings sheet, not of this one.
- **A sheet reading too narrow is worth one look at the `Form` inside it before it is worth a width.** The Hugging
  Face sheet's `LabeledContent` rows losing "Remote access" off the leading edge read exactly like a sheet 100 pt too
  narrow, and were not: macOS defaults a `Form` to `.columns`, which lays every label in a right-aligned leading
  column, and that column was placed past the sheet's own leading edge — outside the container, not clipped by it.
  `HFSignInScreen` was the one `Form` in the app without `.formStyle(.grouped)`, and a wider sheet had only been
  hiding it. A symptom at the edge of a container is not evidence about the container.
- **Every role lays an opaque `baseFill` first, then the effect on top.** Neither glass nor a material renders in a
  headless snapshot (`RunningAppDock`'s `windowEdge` records the same about `.bar`). Without a fill that _does_ render,
  every surface would be invisible to the reference images and the layout and text on each card would silently lose
  their regression cover. Do not "simplify" the fill away because it looks redundant on device.
- **Glass is invisible headless, but what it wraps is not.** `glassEffect` renders its content vibrantly, and that
  _does_ come out in a reference image: measured on the iOS 26 simulator, `.red`, `.orange`, `.green` and `.secondary`
  text inside one all render black, while `.tint` survives. Modifier order makes no difference — inside or outside the
  surface, the result is identical. So the effect goes **under** the content, never around it, and `.badge` takes
  neither glass nor material: a marker inside a card floats over nothing, and carrying a colour is the whole of its job.
- **Four more things glass does headless, each measured rather than assumed.** They are why this module looks more
  conservative than the plan:
  1. **`.buttonStyle(.glass)` blanks the whole capture.** Not "does not render" — a screen carrying one comes out
     empty apart from its toolbar, which is a separate pass. Recorded the onboarding suite twice to confirm: every
     reference blank with it, every reference complete without it, nothing else changed. `reachyButton` therefore has
     no glass tier, and roughly sixty references keep their cover.
  2. **An enabled `tabViewBottomAccessory` blanks the whole capture too**, and it is the same failure wearing a
     different hat — the system draws that slot as a glass container. Recorded once: `Root — dock on the robot tab`
     came back with no `Form` on it at all, only ghosts of the app's artwork tile and the tab-bar glyphs. So **no
     root capture may mount the system slot**, and `PreviewScene.root` forces
     `ReachyTabAccessoryStyle.legacy` on every root preview rather than leave each one to remember. What the
     resulting images still certify is everything both placements share: the tab bar survives, the strip is above
     it, the tab's content is inset to clear it. What is uncapturable is the **container**, not the placement:
     `Dock — expanded` mounts no container and photographs the row the system slot would hold, which is the only
     cover `.expanded` has. See `ReachyTabAccessory`.
  3. **Glass over an edge with nothing behind it renders as a black-red-green smear.** Measured when the dock's shape
     still crossed the safe area; it does not any more, and `.window` is the role that came out of it — `.scrim`
     minus the glass. Keep the role: glass-free is also what makes it the one surface that flips correctly in a dark
     reference, which is why `FloatingViewport` uses it.
  4. **Glass laid over a `Color.clear` does the same** — there is no backdrop to refract. It goes over the opaque
     `baseFill`, which is where `ReachySurfaceFill` puts it.
- **Wrapping something in `.opacity()` moves its reference, at opacity 1 and with nothing else changed.** SwiftUI
  composites that subtree offscreen and blends it back, and the round-trip lands within 1 bit. Measured when the
  floating viewport's edge glyphs became fadeable: 14 references moved, 3990 px each on an iPhone capture, **max
  channel delta 3/255**, and the bounding box sat inside the tab over the two glyphs rather than at its edges — so
  neither the shape, the shadow nor the position had moved. Invisible on a device, and not a reason to avoid the
  modifier; a reason to expect the re-record and to check _where_ the delta is before believing a story about it.
  **A byte-identical control is what makes that reading safe**: the same run left the floating-window capture at 0
  differing pixels, which is what ruled out the shared container as the cause. Quantify with a throwaway `swiftc`
  script over `CGImageSourceCreateWithURL` — eyeballing a 3/255 delta reports "identical".
- **`.shadow` over a subtree carrying a material muddies the material.** The shadow's offscreen pass renders the
  material without a backdrop to sample, so the `.bar` in a `.window` surface came out gray in the references — with
  the loading card inside standing out white on it, read for a while as the intended look. Measured on
  `FloatingViewport`: the same window with the shadow moved to a background twin (`shape.fill(.background)` +
  `.shadow`, behind the surface) renders uniformly white, the material sampling in place. The twin is also the cheap
  form — an opaque window's silhouette is its shape, and a shape whose contents never change is one Core Animation
  can cache instead of re-blurring a live video subtree every frame. The bare docked tab — no material in frame —
  moved by only 8/255 between the two forms, which sizes the pure path difference; the window captures moved up to
  70/255, all of it the material clearing and the chrome's corner-overhang losing the drop shadow it had been
  dragging along.
- **No reference image is evidence about the safe area.** `Apps/ReachyUISnapshotTests/PreviewTests.stencil` sets
  `snapshot.device.safeArea = .zero` before every capture, so the home indicator, the status bar and every inset
  derived from them are simply absent from all ~1100 of them. This is not a detail: it is the whole reason the
  running-app dock shipped for five releases mounted in a way that drew it straight over the tab bar, with three
  root references recording that and being read as confirming the opposite. Anything about safe-area geometry gets a
  booted simulator and `simctl io booted screenshot`, or a device — never a reference.
- **`GlassEffectContainer` and `reachySurface` are mutually exclusive, and only a device says so.** A container
  composites the `glassEffect`s it finds in its subtree into one merged sheet — but it only finds the ones applied to
  its own subviews. One nested inside a `.background`, which is where every role puts it, is hoisted into that sheet
  and drawn **over** the content rather than under it. The result is a crisp capsule with its own contents refracted
  into a smear: on the Live tab the switcher's "3D model" / "Camera" labels and the options glyph were unreadable,
  while the capsule's edge stayed sharp — which is the tell, since a low-contrast surface blurs nothing.
  **The references did carry it, as an absence nobody read.** The hoisted sheet is the opaque light glass this file
  already describes, so headless it covered the chrome instead of blurring it: 36 captures across `Viewport*` and
  `Root — live tab` showed bare white where the switcher and the options button should be. White on a white viewport
  reads as "nothing is drawn there yet", which is why it sat unnoticed. Removing the container re-recorded all 36 and
  put "3D model | Camera" and the glyph back into them, so the fix is also a restoration of cover, not a cost to it.
  The diagnosis came from a booted iOS 26.4 simulator instead — a four-cell isolate, `.background`-glass and
  content-wrapping glass, each inside a container and outside one, through `simctl io booted screenshot`. Only the
  `.background`-inside-a-container cell was broken. Reach for that harness when a reference shows an absence: it says
  _that_ something is wrong, never _what_.
- **Wrapping glass does _not_ eat colour on a device.** The same isolate put a `.red` glyph inside a content-wrapping
  `glassEffect` and it stayed red. The rule above — red, orange and green rendering black — is a property of the
  headless capture, not of glass, and the two claims are about different things. Do not cite it as a device-side
  argument.
- **A surface is a shape, not a `Color`.** A `Color` is flexible in both axes, so one carrying `ignoresSafeArea`
  expands to the entire safe-area container rather than to the thing it backs. Mounted under a `safeAreaInset` — which
  draws over the content — that painted whole screens in the window colour. Use `ReachySurfaceFill`, or `reachyScrim`,
  which asks for the inset by name because `reachySurface` uses the `ViewBuilder` form of `background` and stops at
  the safe area where `background(_:)` taking a `ShapeStyle` did not.
- **No `@ScaledMetric` on `Space`.** The app is 98 `Section`s over 18 `Form`s and SwiftUI already scales list metrics;
  what clips at AX5 is a fixed _size_. So each component that reads a `Metrics` constant gets its own `@ScaledMetric`
  — and at the default text size the multiplier is 1, so adopting one moves no reference image.
- **Optical adjustments stay literals.** `Space` governs the rhythm of a layout; a 1 pt gap inside the dock or a 3 pt
  inset on the joystick's arc is not rhythm. A grid that swallowed the optics would be worse than no grid.
- Nothing in this module renders a domain type. `ReachyStatusLabel` takes a `String`.
- **A `Tone` colours a foreground, not a fill.** `ReachyBadge` puts the tone on its text and takes the `.badge`
  surface underneath, which is what let the app's one pinned `.foregroundStyle(.white)` go: white read only against a
  capsule filled with `.tint`, and a light tint in a dark appearance left white on light. Filling a shape with a tone
  brings the pinned foreground back with it.
- **A `static func` returning one of these views needs `@MainActor`.** `View` carries that isolation in Swift 6, so a
  nonisolated factory building a `ReachyStatusLabel` compiles with an `ActorIsolatedCall` warning
  (`RunningAppCaption.label`). The value-only mappings beside it stay off the actor.

## Not here yet, and why

- **A glass tier on `reachyButton`.** Not deferred for taste — it blanks the capture (see the rules above). Revisit
  only with evidence that a screen carrying one snapshots whole. `ButtonEmphasis` did gain a third case,
  `quiet` (`.borderless`), and that one is not a glass question: it exists because three bordered capsules in a row
  broke their labels across two lines on an iPhone, and stacking them gave a ragged column of three different widths.
  Both were recorded as references before being read. `.borderless` rather than `.plain` — plain drops the tint, and a
  tintless label beside a tinted one reads as disabled.
- **`glassEffectID` morphing between screens.** Worth having only once a layout is built around it, and there is no
  equivalent below the floor.
- **A gesture-carrying spring beyond `absorb(velocity:)`.** It is the module's only `Animation` that is a function
  rather than a constant, and the only one seeded from a gesture: `.interpolatingSpring` is the sole form taking an
  initial velocity, and that velocity is **normalised** — a fraction of the journey per second, not points per second,
  so the caller divides its speed by the distance to cover. `FloatingViewport.release` is the worked example. Handing
  it raw points per second overshoots by whatever the distance happens to be. `absorbContent` beside it is a plain
  curve at roughly a third of the duration, scoped to an opacity with `animation(_:value:)` — that scoping is the whole
  mechanism by which the geometry keeps a spring while the content does not. Neither is a reduce-motion question, for
  the reason the constants are not: both are one-shot responses to something the reader did.
- **A blanket reduce-motion resolver.** Still absent, and `dock` / `stateChange` / `absorb` still resolve nothing:
  each is a one-shot response to something the reader did or something that changed, which is not what the setting is
  about. `Motion.waiting(reduceMotion:)` is the single exception and covers the app's only endlessly repeating
  animation — the connection rail's turning arc. It takes the flag as a **parameter**: this module reads no
  environment, so `\.accessibilityReduceMotion` stays the caller's to look up. Returning `nil` is the whole mechanism,
  because `withAnimation` and `animation(_:value:)` already take an optional. A caller that stops moving must still
  render a distinguishable resting state — `ConnectRailNode` draws a static arc, which is also what every reference
  image records, so the resting state is the one under regression cover.
- **The App Intents _metadata_ strings.** `RobotAppIntents`, `RobotPowerIntents`, `RobotAppShortcutIntents`,
  `RobotAppsConfigurationIntent`, `RobotAppEntity`, `ReachyShortcuts` and the two widget `configurationDisplayName`s
  stay bare `LocalizedStringResource` against the main bundle. `AppIntent.title` and `DisplayRepresentation` are baked
  into `Metadata.appintents` at build time, and `.reachy(_:)` records a _runtime_ bundle URL the metadata processor has
  no reason to be able to follow — Siri and Shortcuts would read an unresolvable reference. Localizing them means a
  catalogue in each executable's own bundle, which is a separate decision from this one.
  **The boundary is extraction, not the word "intent".** An `IntentDialog` returned from `perform()` is built and
  resolved in this process while it runs, so nothing extracts it and there is no unresolvable reference to be had:
  those take `.reachy(_:)` like any other sentence a person reads, through `IntentDialog.init(_:)`, which takes a
  `LocalizedStringResource`. `RobotAppShortcutIntents` is where they are — its metadata is exempt and its dialogs are
  not, in the same file.

## The localization catalogue

`Resources/Localizable.xcstrings` is the app's only catalogue, and `Localization.swift` is the only way in:
`.reachy("Wake up")` returns a `LocalizedStringResource` bound to `Bundle.module`.

It lives here because **both executables link this target**, so SwiftPM copies `ReachyMini_ReachyDesign.bundle` into
each — verified on a device build: `en.lproj/Localizable.strings` is present in `ReachyMini.app` _and_ in
`PlugIns/ReachyWidget.appex`. One catalogue, one hand-off to a translator, two processes served.

**Four languages ship: `de`, `es`, `fr`, `ru`** — 553 keys × 4, plus `Apps/ReachyMini/Resources/InfoPlist.xcstrings`
for the four `NS*UsageDescription` alerts, which are the first sentences a user reads and live in no catalogue
otherwise. That second file does a second job: it gives the **main** bundle real `<lang>.lproj` directories, which is
what makes the per-app Language picker appear and the App Store list four languages. The catalogue itself lives in the
nested `ReachyMini_ReachyDesign.bundle`, which negotiates independently, so without it the app would advertise
English while rendering Russian. If a built bundle ever shows no `InfoPlist.strings` at its root, the fallback is a
`CFBundleLocalizations` array in `Apps/Project.swift` — deliberately not added up front, because a second hand-kept
list of languages is exactly the drift this file keeps warning about.

**They are machine-translated and no native speaker has reviewed them.** `state` is `"translated"` rather than
`"needs_review"` because the latter reads as 0 % done in Xcode's progress column; the honest status is here instead.
`fr` is checkable against Pollen's own French copy. **Nothing in CI can catch truncation** — the references are
English-only by design (`-testLanguage en -testRegion US`), so a German or Russian label that clips does so
invisibly. The five-tab bar is the tightest spot; `Live` is deliberately `Directo` / `Direct` / `Эфир` rather than the
longer phrase for that reason, while `Einstellungen` and `Приложения` are as short as those languages get.

Three things measured rather than assumed:

- **`Section`, `LabeledContent`, `TextField` and `SecureField` only got their `LocalizedStringResource` initialiser in
  iOS 26 / macOS 26.** `Text`, `Button`, `Label`, `Toggle`, `Picker`, `navigationTitle`, `alert` and the rest have had
  one since iOS 16. `LocalizedControls.swift` backfills those four at this app's floor, forwarding to the
  `Text`-taking form. Both are visible against the iOS 26 SDK and the SDK's carries `@_disfavoredOverload`, so ours
  win with no ambiguity — 28 call sites that would otherwise each be a two-closure builder.
- **The catalogue derives a Swift symbol per key, and two keys that differ only in punctuation collide** — a hard
  build error from `xcstringstool`, not a warning. `"Bluetooth is switched off."` against `"Bluetooth is switched
  off"` was the app saying the same sentence two ways; `"Starting…"` against `"Starting"` was not, and the daemon's
  lifecycle took `"Starting up"` / `"Shutting down"` to clear it. Expect to be told when a new key rhymes with an old
  one, and fix the copy rather than the tooling. **Case counts too**: `"robot"` — the fallback noun in
  `ConnectHeader`'s header sentence — collides with the `"Robot"` section title, which is why that call site now reads
  `.reachy("the robot")`. `Scripts/check-catalogue.py` reproduces the rule in Python and so catches all three on
  Linux, before a Mac build can. It is an approximation of a tool we cannot run there, tuned to over-report rather
  than under-report: a false positive costs one copy edit, a false negative costs a red build.
- **`.xcstrings` compiles under the pinned swift.org toolchain**, unlike `#Preview`: SwiftPM shells out to `xcrun`
  for `xcstringstool`, so `mise run build` and `mise run test` are unaffected.

Seeding is manual. `SWIFT_EMIT_LOC_STRINGS` is not set for SwiftPM targets through Tuist, so Xcode never extracts,
and every entry carries `extractionState: "manual"`. **Because nothing extracted, nothing checked, and the catalogue
drifted 139 keys behind the code** — each one rendering its English key perfectly and so invisibly. That is what
`Scripts/check-catalogue.py` exists for, and it runs first in `mise run lint` because it is the only check in that
task that needs no toolchain at all. It asserts four things: the plain `.reachy("…")` literals in the sources are
_exactly_ the catalogue's keys, every shipped language covers every key in both catalogues, the file round-trips
byte-identically through its own emitter, and no two keys derive the same symbol. `--fix` writes the canonical form;
it deliberately will **not** add or remove keys, because a scanner bug would then delete shipping copy.

Two things the scanner has to get right, both of which gave a wrong answer first:

- **Comments are stripped before scanning, literal-aware.** `.reachy(` and its literal can be separated by a
  `// swiftlint:disable:next line_length` (`ReachyUI/Onboarding/OnboardingWelcomeStep.swift`), and skipping only
  whitespace reported nine _live_ onboarding sentences as stale — copy a reconciliation would have deleted.
- **`.reachy(_:)` in a doc comment is not a call site.** Four `///` mentions read as unparseable arguments until
  comments were gone.

**Key order is the file's own and is not sorted.** The seed is byte-sorted with five case-insensitive exceptions — the
fingerprint of entries Xcode's editor inserted into a hand-written list — so imposing either single rule produces a
diff the other tool undoes. New keys go in case-insensitively beside those five; the checker asserts formatting, never
ordering.

The 79 keys that _do_ interpolate are deliberately absent — their stored form carries `%@` / `%lld` placeholders whose
types cannot be read off the call site, and a wrong entry is worse than a missing one, which merely falls back to the
English key. Finish them by opening the catalogue in Xcode, which extracts the placeholders correctly. Rebuild the
working list with `grep -rnE '\.reachy\("[^"]*\\\(' Sources --include='*.swift'` — 79 call sites, 79 distinct keys.

**Three translated keys are _fragments_ of those English frames, so they read mixed until the interpolating pass
lands.** `"the robot"` fills `"Connected to \(target)"` / `"Connecting to …"` / `"Couldn't connect to …"`;
`"this robot runs an older one"` and `"The hardware ID never changes."` fill `RobotNameField`'s footer. They are
translated forward-correctly rather than pinned to English, so the interpolating pass completes them rather than
having to revisit them — but that pass is what makes those two sentences read whole. A fourth pair is worse and is
not an interpolation at all: `OnboardingScanStep` **concatenates** two catalogue keys (`"…or join "` +
`"its own reachy-mini-ap network…"`) to dodge a line-length warning. Both halves are translated so their join is
grammatical in all four languages, and the trailing space on the first half is load-bearing. Prefer merging them into
one key over adding a fifth of these.

## Applying a role — what happened

All seven ad-hoc sites now name a role: the viewport's three pieces of chrome (`.chrome`), the log console, the BLE
console and the onboarding footer (`reachyScrim`), and the running-app strip (`.window`). What to expect from the next
one:

- `ViewportStatus.loading` moved its reference image because `Radius.rect` is `.continuous` where
  `RoundedRectangle(cornerRadius: 12)` defaulted to `.circular`. That is the intended correction, not a regression.
- `background(_:in:)` taking a `ShapeStyle` defaults to `ignoresSafeAreaEdges: .all`; `reachySurface` uses the
  `ViewBuilder` form, which does not. A bar that today paints into the safe area (`LogConsoleView`, `OnboardingFlow`,
  `BLEConsoleScreen`) asks for it by name — `reachySurface(_:in:ignoringSafeArea:)`, of which `reachyScrim` is now
  the `.scrim` spelling rather than the only one.
- **The onboarding footer was the first of these to come back off `.scrim`, and it is a role change, not a fix to the
  role.** `.page` is what it takes now; the entry under Rules says why. Every `Onboarding —` reference moves with it,
  and the dark half moves furthest: the footer band renders as glass-white there today and becomes the page's own
  black. `Design — surfaces` gains a capsule for the new case.

## Both appearances, and what glass does to the dark half

Every preview is now captured twice — `Apps/ReachyUISnapshotTests/PreviewTests.stencil` forks Prefire's built-in
test template and loops the capture over `[.light, .dark]`, naming the dark file with a `-dark` suffix. The light
names are untouched, which is why adopting it re-recorded nothing: 500 new files, 0 modified.

The appearance travels as a **trait**, not as `preferredColorScheme` (which wants a window scene the snapshot host has
no equivalent of) and not as `\.colorScheme` in the environment (which moves SwiftUI's own colours and leaves
UIKit-backed ones light). swift-snapshot-testing feeds the collection to `setOverrideTraitCollection`, which reaches
both halves.

**`glassEffect` renders a light surface in both appearances, and it is opaque.** Measured on `Design — surfaces`: in
the dark capture `badge` and `window` flip correctly while `chrome`, `card` and `scrim` stay white capsules with
their white labels invisible on them. The two that flip are exactly the two roles with `glass == nil`. It is not the
trait failing to arrive: re-recording that gallery with the _simulator_ switched to dark produced both images
byte-for-byte identical to the run on a light simulator, so the injected trait is what decides and glass ignores it
either way.

What that means when reading a dark reference:

- Over a `.chrome`, `.card` or `.scrim` surface, a dark capture shows **the snapshot's white glass, not the device's**.
  Light-on-that is invisible in the image and legible on hardware. Do not "fix" a foreground because it vanished there.
- The roles that carry no glass — `.badge`, `.window` — and everything outside a surface are truthful, and that is
  where the dark half earns its keep: `LogConsoleView`'s level palette, the status captions, every screen background.
- A dark reference is therefore evidence about _content_, and evidence about glass only on device.
- **The navigation bar is one of those glass surfaces, so a toolbar item moves the dark reference and only the dark
  one.** Measured when the Live tab gained its options menu: of the 20 references for the five Live-tab root previews,
  the 5 `iPhone-…-dark` moved and the other 15 — light iPhone and both iPad — came back byte-identical, the iPad pair
  legitimately (no tab bar, so no menu) and the light iPhone pair because a white glyph on the bar's white glass is
  the bar. The delta was 196 × 43 px in the top-trailing corner, and cropping it showed the existing `Controller`
  glyph shifted left with the new one beside it. **Read the dark capture before concluding a toolbar item did not
  render** — the light one looked, convincingly, like a change that had not happened, and re-testing it with the
  condition removed reproduced the same empty bar.

## Previews

`Previews/` is excluded from the SwiftPM target and compiled only by the Xcode targets in `Apps/` — `#Preview` is an
external macro that ships inside Xcode's SDKs, not in the pinned swift.org toolchain. The same rules as
`ReachyUI/Previews` apply: anything a preview body names must be visible target-wide, because Prefire copies the body
into a generated file.

Adding a preview directory here means editing **six** files, not the five a target's wiring usually takes:
`Package.swift`, `Apps/Project.swift` (`sources` of _both_ preview-hosting targets), `Apps/.prefire.yml` (`sources`
and `testable_imports` in _both_ sections), this file, and `mise.toml` — where `prefire playbook` is handed an
explicit directory list in **two** tasks (`project` and `storybook`). Miss the `.prefire.yml` `sources` entry and the
previews compile while generating no tests at all, which reads as everything passing. Miss `mise.toml` and the
gallery is simply absent from the storybook, with no error anywhere.
