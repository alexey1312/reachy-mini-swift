# iOS 27, Xcode 27 and this app

Issues #56, #57, #58 and #74 all cite `docs/research/apple-ecosystem-growth.md`. That file is in no commit and in
no branch — the reasoning behind the P0 label lives only in the issue bodies. This file replaces it. It records
what the SDK move demands, what was measured on a local Xcode 27 install, and which of the audit's findings
survived a check against the code.

Everything below was verified against the tree at the time of writing. Claims that did **not** survive are kept and
marked, because a corrected claim is worth more than a deleted one.

## §0 The SDK move

### Measured on Xcode 27.0 Beta 6 (27A5252f), 2026-08-29

| Task                         | Result                                                                                          |
| ---------------------------- | ----------------------------------------------------------------------------------------------- |
| `mise run build:app` (macOS) | 0 errors. `actool` compiles the macOS variant of the Icon Composer `.icon`                      |
| `mise run build:app:ios`     | 0 errors, widget controls included                                                              |
| `mise run snapshots:build`   | `** TEST BUILD SUCCEEDED **`, 0 errors, artifact `…_iphonesimulator27.0-arm64-x86_64.xctestrun` |

**No source change was necessary.** See `@ContentBuilder` below for why one was expected and did not arrive.

New warnings, all from Swift 6.3 rather than from the SDK: 42 × `NonSendableSuperclass` in the Prefire-generated
test classes (the forked `PreviewTests.stencil` writes them), and 5 × `SendingRisksDataRace` in `ReachyMedia`
(`RobotCallController.swift:251,267,286`, `ConversationDelegateAdapter.swift:46,52`). They are warnings today and
an error in a later language mode.

### `@ContentBuilder` is not an adoption task

`ContentBuilder` is a type alias for `ViewBuilder`. The win comes from the SDK rebuilding its own shared components
around `TupleContent`, which carries no domain until its elements give it one, so `Group { Group { … } }` no longer
multiplies the overload search at every level. Published measurements put a five-level
`Section → Group → ForEach` at 1 050 052 constraint scopes / 11.06 s under Xcode 26.6 against 189 / 26.97 ms under
Xcode 27 beta 4.

Three consequences for this repository:

- The improvement arrives with the SDK. There is nothing to annotate, so the separate commit issue #56 budgets for
  `Sources/ReachyUI/Previews/**` and `Apps/ReachyStorybook` has no content.
- The real cost runs the other way. Once the builder stops supplying a protocol for every expression, calls that
  leaned on that implicit context can go ambiguous — positional `.overlay(Color…)`, an empty `Group {}`, elaborate
  conditional branches. **This tree has none.** The compile above is the evidence.
- Issue #56's premise does not hold. `Sources/ReachyUI/Previews` is a flat `enum PreviewScene` of small
  `static func … -> some View` wrappers, not nested containers — the previews are already written the way the
  workaround advice recommends, so the pathological shape is absent.

The third use, a custom multi-domain DSL built on `TupleContent`, has no consumer here: the repository declares no
`@resultBuilder`, and the three `@ToolbarContentBuilder` properties are single-domain.

Source: <https://fatbobman.com/en/posts/contentbuilder-explained/>

### Snapshot identifiers

Two of the four move. `REACHY_SNAPSHOT_SIM` (`iPhone 17 Pro`) exists on the iOS 27 runtime; `simulator_device`
(`iPhone18,1`) is still the iPhone 17 Pro model id, confirmed with `simctl list devicetypes`; `snapshot_devices`
are `ViewImageConfig` names that appear in every filename and must not move. `REACHY_SNAPSHOT_OS` goes to `27.0`
and `required_os` to `27`.

**`required_os` is compiled into the generated tests, not read at run time.** Editing `.prefire.yml` without
rebuilding leaves the old value in `…PreviewsTests.generated.swift`, where it is a `fatalError`, not a failed
assertion:

```
Fatal error: Switch to iOS 26 for these tests. (You are using NSOperatingSystemVersion(majorVersion: 27, …))
```

Reached through `test:snapshots:record`, that deletes every reference and then crashes on every test. Rebuild the
snapshot target after changing the pin, and prove one test class runs before recording.

**Not every reference moves.** Issue #56 states that all of them do, for glass and for text rendering together, and
that the usual advice to check a control reference does not apply. Measured against the iOS 27 runtime before
re-recording, `JoystickPadPreviewsTests` passed all four of its tests unchanged. The control reference still works.

### CI images

`macos-26` carries Xcode 26.6 at most, so issue #57's "a `macos-26`-class image" does not reach Xcode 27. The
label is **`xcode-27`** (announced in actions/runner-images#14404): macOS 26.5.2, arm64, Xcode 27.0 beta 4 as the
only Xcode on the image, iOS 27.0 the only simulator runtime, `iPhone 17 Pro` present. A standard label, not
`-xlarge`, so the five concurrent macOS slots are unaffected.

The versioned path on that image is `/Applications/Xcode_27_beta_4.app` and it moved from `_beta_3` at the last
rollout. Point `DEVELOPER_DIR` at the `/Applications/Xcode_27.0.app` symlink, or leave it unset — `Xcode.app`
already resolves to 27 there.

`warm-cache` moves with the build jobs. It is the only job that writes the `SourcePackages` cache on
`refs/heads/main`, and a package graph resolved by a different Xcode does not serve the jobs that read it.
`lint-test` stays: it is SwiftPM against the swift.org toolchain and never opens the iOS SDK.

The local install (beta 6) and the image (beta 4) are different builds. That is safe here for one reason only: no
CI job compares reference images. `preview-build` compiles them.

## §1 What iOS 27 requires

| Requirement                                         | Consequence                                                                                 | State here                               |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `UIApplicationSceneManifest`                        | the app does not launch                                                                     | declared, `Apps/Project.swift:132` (#95) |
| `UIDesignRequiresCompatibility` ignored             | Liquid Glass is mandatory and its appearance changed                                        | accepted; drives the re-recording        |
| Resizability turns on when built against the 27 SDK | iPhone apps resize on iPad and in iPhone Mirroring                                          | **open**, see §2                         |
| `@State` is a macro (TN3211)                        | lazy initialisation, back-deployed to iOS 17; breaks a default plus an assignment in `init` | audited, #95                             |
| Deployment target below 15.0                        | an error, not a warning                                                                     | clear: iOS 18.0 / macOS 15.0             |

**Corrected from the audit.** A claim that `UILaunchScreen` causes an upload rejection does not apply. The
deprecated keys are `UILaunchStoryboardName` and the launch-image entries, and neither appears in the tree. The
dictionary form at `Apps/Project.swift:105` and `:298` is the replacement Apple recommends.

Apple has announced no deadline for the iOS 27 SDK. The floor is still Xcode 26 / the iOS 26 SDK.

## §2 Gaps the P0 issues do not cover

Each row was checked against the tree.

| Gap                                  | Where                                                                                                                           | Note                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Resizability audit                   | `Sources/ReachyUI/FloatingViewportModifier.swift:142-180`                                                                       | `dockBleed` branches on `UIWindowScene.interfaceOrientation`, and its own comment records that the values were measured by forcing `UISupportedInterfaceOrientations`. Orientation is a preference under 27, not a contract. **Do this before the re-recording** — otherwise the references freeze whatever `dockBleed` then computes |
| The `.soft` scroll edge effect       | `Sources/ReachyDesign/ReachyChrome.swift:47`, one consumer at `Sources/ReachyUI/LogConsoleView.swift:74`                        | `.automatic` has a new appearance in 27 and Apple asks for overrides to be reviewed. A separate commit after the re-recording, or it is indistinguishable from the images that moved                                                                                                                                                  |
| Menu icons                           | `Menu {` in `LogConsoleView`, `SceneViewport`, `SoundboardScreen`, `AppStoreScreen`, `LiveTab`, `RobotFilesScreen`              | hidden by default on iPadOS and macOS 27 without `preferredImageVisibility`; they disappear silently                                                                                                                                                                                                                                  |
| Tooling matrix                       | `mise.toml` — swiftlint, swiftformat, swift-syntax, and Prefire pinned `.exact` to 5.7.0 behind a forked `PreviewTests.stencil` | #57 moves the CI image but not the parsers, and the `@State` macro passes through them                                                                                                                                                                                                                                                |
| Snapshot coverage is two fixed sizes | `Apps/.prefire.yml` (`iPhone 16 Pro`, `iPad Pro 11`)                                                                            | under resizability no reference exercises a narrow or a wide window                                                                                                                                                                                                                                                                   |
| The combined privacy prompt          | camera, microphone, Bluetooth, local network and location in one dialog                                                         | the first-run gate and the smoke test that walks it may both shift                                                                                                                                                                                                                                                                    |
| Stricter TLS                         | `ws://<host>:8443`, `Sources/ReachyKit/Transport/CameraSignalingClient.swift:4`, plus `NSAllowsLocalNetworking`                 | signaling is plaintext                                                                                                                                                                                                                                                                                                                |
| macOS 27 drops Intel                 | `Scripts/release-macos.sh`                                                                                                      | the universal slice stops being obligatory                                                                                                                                                                                                                                                                                            |

Searched for and **absent**, so not problems: `UIScreen.main`, `userInterfaceIdiom`, the deprecated `UIApplication`
status-bar accessors, `MXMetricManager`, On Demand Resources, `.onMove`.

## §3 New API worth having

Ordered by how close each sits to something the app already does.

- **Toolbars.** `visibilityPriority(_:)`, `ToolbarOverflowMenu`, `ToolbarItem(placement: .topBarPinnedTrailing)`,
  `toolbarMinimizeBehavior(_:for:)`, `ToolbarPlacement.statusBar`, `ForEach` and `EmptyView` inside toolbar
  builders. The direct remedy for a toolbar in a narrow window, which resizability now makes reachable.
- **`.reorderable()` + `.reorderContainer(for:)`** — reordering in any container. The known-robots list has no
  `.onMove` today.
- **`swipeActionsContainer()`** — swipe actions outside `List`, so a `LazyVGrid` can carry them.
- **`systemExtraLargePortrait`** — a new widget family on iOS, iPadOS and macOS 27.
- **Live Activities**: `supplementalActivityFamilies([.small])` puts an activity on Apple Watch and the CarPlay
  dashboard **without a watchOS app**, which covers much of #75 from inside #61; a landscape Dynamic Island
  (`isDynamicIslandLimitedInWidth`); StandBy.
- **App Intents**: `LongRunningIntent`, `CancellableIntent`, `ExecutionTargets`, `EntityCollection`,
  `SyncableEntity`, `RelevantEntities`, `@UnionValue`, and **`AppIntentsTesting`**, which drives intents through the
  real system paths. Nine controls plus Siri, Spotlight and Handoff are covered only indirectly today.
- **Foundation Models**: the `LanguageModel` / `LanguageModelExecutor` protocols make one session work against the
  on-device model, Private Cloud Compute, MLX and third-party providers, which turns the on-device-or-cloud question
  in #72 and #73 from an architectural choice into configuration. Evaluations and the token-count API are new.
- **ARKit object tracking reaches iOS** with the visionOS API, so #77 is a shipped feature rather than a bet.
- `AsyncImage(request:)` with HTTP caching, for `HFAvatar` — the one network image in the app.
- `@Environment(\.appearsActive)` for the inactive Mac window; a sidebar on iPhone for the five-tab shell
  (`.sidebarAdaptable` is already set, `Sources/ReachyUI/Shell/ReachyTabShell.swift:120`); the Now Playing framework
  for the soundboard.

## §4 Order

`#57` → the resizability audit → `#56` → chrome and `.soft` → `preferredImageVisibility`. Everything in §3 waits
until the tree is green again.
