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

### The swift.org toolchain cannot pair with the macOS 27 SDK

`swift build` and `swift test` take their compiler from `.swift-version` (6.3.0, through swiftly) and their SDK from
whatever `xcode-select` points at. With Xcode 27 selected, that pairing fails: `mise run test` ends with a batch of
`initializer is inaccessible due to 'private' protection level` and `cannot be constructed because it has no
accessible initializers` across `Sources/ReachyUI`, plus `ld` warnings about `building for macOS-11.0` against
dylibs built for 13.0.

Those errors are cascade, not cause. The cause is one line above them —
`Sources/ReachyUI/Settings/SystemUpdateCard.swift:61`, a `@ViewBuilder` property wrapping a `switch`, reported as
`the compiler is unable to type-check this expression in reasonable time`. A failed expression poisons the rest of
the module, and the accessibility errors are the wreckage.

The same sources, the same SDK, and Xcode 27's own Swift 6.4 build clean:

```bash
xcrun swift build --target ReachyUI   # Build complete! (49.23 s)
```

So the tree is not broken; the toolchain pairing is. **Nothing is changed here for it.** swift.org has no 6.4
release to move `.swift-version` to, and CI is unaffected — `lint-test` stays on `macos-15` with
`DEVELOPER_DIR=Xcode_26.2`, so it pairs 6.3 with the macOS 26.2 SDK exactly as before. Locally, run `swift build`
and `swift test` with Xcode 26 selected, or reach for `xcrun swift` and accept Xcode's compiler.

This is the measured form of the tooling-matrix gap in §2.

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

| Gap                                             | Where                                                                                                                           | Note                                                                                                                     |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Resizability audit                              | `Sources/ReachyUI/FloatingViewportModifier.swift:149-182`                                                                       | **Measured, and it costs nothing.** See §2.1                                                                             |
| The `.soft` scroll edge effect                  | `Sources/ReachyDesign/ReachyChrome.swift:47`, one consumer at `Sources/ReachyUI/LogConsoleView.swift:74`                        | **Settled on a running app: `.soft` stays.** See §2.1                                                                    |
| Menu icons ~~needs `preferredImageVisibility`~~ | `Menu {` in `LogConsoleView`, `SceneViewport`, `SoundboardScreen`, `AppStoreScreen`, `LiveTab`, `RobotFilesScreen`              | **Closed — nothing to do.** See §2.1                                                                                     |
| Tooling matrix                                  | `mise.toml` — swiftlint, swiftformat, swift-syntax, and Prefire pinned `.exact` to 5.7.0 behind a forked `PreviewTests.stencil` | #57 moves the CI image but not the parsers, and the `@State` macro passes through them                                   |
| Snapshot coverage is two fixed sizes            | `Apps/.prefire.yml` (`iPhone 16 Pro`, `iPad Pro 11`)                                                                            | still open: a third size costs +816 references and ~100 MB of LFS, so #114 measured it and declined                      |
| The combined privacy prompt                     | camera, microphone, Bluetooth, local network and location in one dialog                                                         | the first-run gate and the smoke test that walks it may both shift                                                       |
| Stricter TLS                                    | `ws://<host>:8443`, `Sources/ReachyKit/Transport/CameraSignalingClient.swift:4`, plus `NSAllowsLocalNetworking`                 | signaling is plaintext                                                                                                   |
| macOS 27 drops Intel — **done, and earlier**    | `Scripts/release-macos.sh`                                                                                                      | Apple opened it on 2026-09-01 for any Mac App Store app requiring macOS 13+; the archive is `ARCHS=arm64` and asserts it |

### §2.1 The three visual rows, resolved

**Menu icons — closed, nothing to do.** `preferredImageVisibility` is UIKit only. It is a property of
`UIMenuElement` and `UIMenuLeaf` (`UIMenuElement.h:68`, `UIMenuLeaf.h:33`, `API_AVAILABLE(ios(27.0))`), and SwiftUI
exposes no counterpart — its `swiftinterface` has no `ImageVisibility` of any spelling, and its only menu modifiers
are `menuOrder`, `menuActionDismissBehavior` and `menuIndicator`. Every menu here is a SwiftUI `Menu`, so there is
no knob to set. Re-open this row only when SwiftUI ships one.

**The `.soft` scroll edge — settled, and `.soft` stays.** The modifier survives in the 27 SDK
(`ScrollEdgeEffectStyle.automatic` / `.hard` / `.soft`), so the availability gate needs nothing. No reference could
answer the rest: the effect draws where content passes under a bar, and the preview renders no bar —
`Console-installer-log-iPhone-16-Pro` is a plain page of log text, so re-recording a variant would compare two
identical images. A standalone probe answered it instead, replicating the console's list — monospaced lines under an
inline navigation bar, scrolled by the app because the simulator here takes no touches. On an iPhone 17 Pro running
27.0, `.automatic`, `.hard` and no modifier at all render **the same frame to the byte**; only `.soft` differs, over
the first 150 pt, which is the band the effect draws in. What the other three put there is a hairline under the bar,
and over a log tail that reads as one more row separator — which the list hides on every other row. The revision
therefore did not make the override redundant; it left `.soft` as the only value that removes the rule.

**Resizability and `dockBleed` — measured, and it costs nothing.** The concern was real in shape: `dockBleed` picks
its edge from the window scene's interface orientation, and under 27 orientation is a preference. The analysis said
the failure degrades to nothing rather than to something wrong, because the branch only chooses _which_ side while
the amount always comes from `geometry.safeAreaInsets`. That is now a measurement, taken with the standalone probe
`Sources/ReachyUI/AGENTS.md` describes, extended to print both orientation readings beside the insets:

| Configuration                            | reader     | insets            | orientation    | bleed         |
| ---------------------------------------- | ---------- | ----------------- | -------------- | ------------- |
| iPhone 17 Pro, full screen, portrait     | 402 × 778  | t62 b34 **l0 r0** | portrait       | none          |
| iPhone 17 Pro, landscapeLeft             | 750 × 382  | **l62 r62**       | landscapeLeft  | leading 62    |
| iPhone 17 Pro, landscapeRight            | 750 × 382  | **l62 r62**       | landscapeRight | trailing 62   |
| iPad Pro 11, window, no request          | 417 × 1158 | t32 b20 **l0 r0** | portrait       | none          |
| iPad Pro 11, window, landscape requested | 1210 × 397 | t10 b10 **l0 r0** | landscapeLeft  | leading **0** |
| iPad Pro 11, `UIRequiresFullScreen` set  | unchanged  | unchanged         | unchanged      | unchanged     |

The first two rows reproduce the figures already recorded in `FloatingViewportModifier.swift`, which is what
certifies the probe before any of its new numbers are believed. Three things follow:

- **The resized window is harmless.** Requesting landscape on iPadOS 27 rotates the interface inside a window whose
  shape on the display does not change — orientation as a preference, in one screenshot — and the horizontal insets
  there are zero. The inset only exists where a cutout does, and that is a full-screen iPhone, where the window _is_
  the display.
- **`UIWindowScene.interfaceOrientation` is deprecated in the 27 SDK**, `ios(13.0, 26.0)`, in favour of
  `effectiveGeometry.interfaceOrientation`, which is available from iOS 16 and so needs no gate at this deployment
  target. The two answered alike in every configuration above, so the swap moves nothing; it stops the app asking a
  question the system has stopped promising to answer. Done.
- **`UIRequiresFullScreen` no longer works**, so the iPad half of the probe recipe in `AGENTS.md` was corrected
  along with it. An iPad measurement under 27 is a window measurement, whatever the plist says.

No test was added. The mapping lives under `#if !os(macOS)` and `mise run test` is SwiftPM on macOS, so it has no
runner short of the XCUITest bundle — and reaching a docked floating viewport there needs a live video source. The
probe is what caught the inverted mapping in the first place, and it is what settled this.

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
  real system paths. Nine controls plus Siri, Spotlight and Handoff are covered only indirectly today. **Schemas are
  the part of this worth having, and they are §3.1 below** — most of the rest of this list turns out to be
  unreachable from here.
- **Foundation Models**: the `LanguageModel` / `LanguageModelExecutor` protocols make one session work against the
  on-device model, Private Cloud Compute, MLX and third-party providers, which turns the on-device-or-cloud question
  in #72 and #73 from an architectural choice into configuration. Evaluations and the token-count API are new.
- **ARKit object tracking reaches iOS** with the visionOS API, so #77 is a shipped feature rather than a bet.
- `AsyncImage(request:)` with HTTP caching, for `HFAvatar` — the one network image in the app.
- `@Environment(\.appearsActive)` for the inactive Mac window; a sidebar on iPhone for the five-tab shell
  (`.sidebarAdaptable` is already set, `Sources/ReachyUI/Shell/ReachyTabShell.swift:120`); the Now Playing framework
  for the soundboard.

### §3.1 App Intents schemas, and which domains a robot client honestly fits (#74)

Every intent this app ships is its own type: the system knows nothing about `WakeRobotIntent` or `PlayMoveIntent`
beyond the ten phrases `ReachyShortcuts` spells out. A **schema** binds an intent to a system-defined domain the
assistant already understands, which buys natural language with no memorised phrase and no per-language work.

Measured against Xcode 27.0 Beta 6 rather than read: **`AppIntentSchemas.sqlite`**, in
`Toolchains/XcodeDefault.xctoolchain/usr/lib/AppIntentSchemas.framework/Versions/A/Resources/`, is the database the
metadata processor validates a conformance against. It carries every schema's parameters, its `openApp` flag, its
authentication policy and its per-OS availability — which is where every figure below comes from. Copy it out and
query it; it is the answer to "what does this schema actually require", and it does not agree with every tutorial.

**The names moved in 27.** `AssistantSchemas` → `AppSchema`, `@AssistantIntent(schema:)` → `@AppIntent(schema:)`,
`@AssistantEntity` → `@AppEntity(schema:)`. The old spellings are present and deprecated.

**One domain fits, and the refusals are the useful half of this entry:**

| Domain       | What the schema actually requires                                                                                                                                                                                          | Verdict                                                                                                                                                                     |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phone`      | `StartCallIntent.destination` is a union of `PhonePerson` / `[PhonePerson]` / `CallGroup`, and `PhonePerson` carries a **contact**. The system's own dialog reads "Ready to call ${destination} using ${applicationName}?" | **No.** #78 frames the WebRTC session as a system call and that framing is honest — but a robot is not a person, and this schema can only be adopted by claiming it is one. |
| `audio`      | `PlayAudioIntent.audioEntity` is a union of song, album, artist, playlist, podcast, audiobook, `AmbientSoundEntity`, news                                                                                                  | **No.** A soundboard clip played on the robot's speaker is none of those.                                                                                                   |
| `camera`     | `StartCameraCaptureIntent`, `StopCaptureIntent`, `FlipCameraIntent`                                                                                                                                                        | **No.** This app watches the robot's camera and captures nothing; the schema promises a recording that would never exist.                                                   |
| `files`      | `OpenFileIntent.target: FileEntity`, plus create / delete / move / rename                                                                                                                                                  | **No.** The SFTP browser is the _robot's_ filesystem, LAN-only and password-gated — not a document store an assistant should be handed mutating verbs over.                 |
| `assistant`  | `ActivateAssistantIntent`, availability `{"clients":16,"iOS":26.2}`                                                                                                                                                        | **Not adoptable** — restricted client set.                                                                                                                                  |
| **`system`** | `.system.search` / `.system.searchInApp` take `criteria: StringSearchCriteria`; `.system.open` takes an unconstrained `target: entity`                                                                                     | **Yes**, and only these.                                                                                                                                                    |

**The Swift protocol is older than the schema in both cases, which is what makes #74 affordable:**

|        | Protocol                                               | Schema binding                                                                                 |
| ------ | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| Search | `ShowInAppSearchResultsIntent` — iOS 17.2 / macOS 14.2 | `.system.search` — **iOS 18 / macOS 15**, at this app's floor. `.system.searchInApp` — iOS 27. |
| Open   | `OpenIntent` — **iOS 16 / macOS 13**                   | `.system.open` — iOS 27 only.                                                                  |

So the behaviour ships at the current deployment target and iOS 27 adds an annotation on top of working code.

**`.system.searchInApp` is not adopted, and that is a decision rather than an omission.** It is the 27 rename of
`.system.search`, which is deprecated there and still present and working. Declaring both would put two
near-identical search actions in the Shortcuts app on 27 and buy nothing below it, and which one an assistant
prefers cannot be answered without a 27 device. It goes in when the deployment floor reaches 27 and
`.system.search` can be removed in the same change.

**Both protocols supply `openAppWhenRun = true` from a framework protocol extension**, which the author never
writes and cannot decline. A conformance declared inside `ReachyWidgetUI` would therefore stamp `openApp` into the
**extension's** `Metadata.appintents` — the runtime failure `CallRobotIntent`'s header describes. Schema intents
belong in the app target beside it, and none may carry `#if os(iOS)`: `check-appintents-metadata.sh` reads the
macOS bundle too.

**`.system.open` costs almost nothing, and this is the reason:**

```swift
@available(macOS 15.0, iOS 18.0, *)
extension URLRepresentableIntent where Self: OpenIntent, Self.Value: URLRepresentableEntity {
    public func perform() async throws -> Never
}
```

Conform an entity to `URLRepresentableEntity` — iOS 18 / macOS 15, one `static var urlRepresentation` — and the
intent's whole `perform()` arrives for free: the system opens the entity's URL, which lands on the existing
`onOpenURL` → `ReachyDeepLink` → `RootLifecycle.follow` path. A `@UnionValue` target forfeits exactly this, because
`AppUnionValue` is iOS 27 and satisfies neither conditional extension, putting `perform()` back in our hands for the
same user-visible result.

**Three items in the §3 bullet above are out of reach from here, and each for a reason worth writing down:**

- **`ExecutionTargets`, `LongRunningIntent` and `CancellableIntent` are blocked by CI rather than by design.** All
  are `@available(anyAppleOS 27.0)`, and the intents they would go on live in `Sources/ReachyWidgetUI`. `lint-test`
  is pinned to `macos-15` with `DEVELOPER_DIR=Xcode_26.2` and runs `mise run test`, which is `swift build` over every
  SwiftPM target — and an iOS-27 symbol is simply **absent** from the 26.2 SDK, so `@available` does not save it and
  the module fails to compile. Nothing in `Sources/` may name an iOS-27 symbol until that job moves.
- **Onscreen awareness is out of reach for the same reason, and it is the one that reads as reachable.**
  `View.appEntityIdentifier` is annotated `@available(macOS 15.4, iOS 18.4, *)` — _below_ this app's floor — so it
  looks like a free adoption. That is its runtime availability; the declaration ships only in the 27 SDK.
  `_AppIntents_SwiftUI`'s interface in `MacOSX26.5.sdk` does not contain the name, and in the 27 SDK it does. Adopted
  once and reverted after `lint-test` failed with `cannot find 'appEntityIdentifier' in scope`; it goes in with the
  rest of §3 when that job can open a 27 SDK.
- **`supportedModes` buys nothing at this floor.** `openAppWhenRun` is `@available(iOS, deprecated: 26.0)`, and a
  deprecation only fires once the _deployment target_ reaches the deprecating version. At iOS 18 nothing warns, so
  the swap removes no diagnostic and changes no behaviour. It is a deployment-floor task.
- **`AppIntentsTesting` cannot catch what it was wanted for.** All 36 of its declarations are
  `@available(macOS 27.0, iOS 27.0, …)`; it ships only under `<Platform>/Developer/Library/Frameworks`, so
  `swift test` cannot reach it; and its surface — `IntentDefinitions.intents / entities / enums / valueQueries` —
  exposes no parameter metadata and no `IntentCollectionSize`. The `@Parameter(size:)` trap recorded in
  `ReachyWidgetUI/AGENTS.md` is therefore still invisible to it. An assertion over `typeSpecificMetadata` inside
  `check-appintents-metadata.sh` would catch it and costs no CI slot at all.

## §4 Order

`#57` → the resizability audit → `#56` → chrome and `.soft` → `preferredImageVisibility`. Everything up to and
including `.soft` is done (#114); `preferredImageVisibility` is closed as not applicable. Everything in §3 waits
until the tree is green again.
