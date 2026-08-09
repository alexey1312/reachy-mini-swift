# ReachyMini — Agent Instructions

Native Swift client (macOS/iPadOS/iOS) for the Reachy Mini Wireless robot. Pure network client to the robot daemon's
HTTP/WebSocket API. Swift 6, strict concurrency.

## Environment Setup — MANDATORY

The development environment is installed **only** via:

```bash
./bootstrap.sh
```

It installs all pinned tools (swiftformat, swiftlint, hk, dprint, actionlint, git-cliff, xcsift, tuist) through the
self-contained `./bin/mise` binary and wires git hooks (`core.hooksPath .githooks`).

- **Never** install tools globally (`brew install swiftlint`, `npm i -g`, etc.).
- **Never** call tools bare (`swift build`, `swiftlint`) — always `./bin/mise run <task>` or `./bin/mise x -- <tool>`,
  which guarantees pinned versions and PATH.
- Swift itself is managed by swiftly via `.swift-version`, not by mise.
- Tool versions are pinned in `mise.toml` + `mise.lock`. After editing `[tools]`: `trash mise.lock && ./bin/mise lock`.
  Find updates with `./bin/mise latest <tool>` — `mise outdated` reports nothing here, because an exact pin always
  matches its own request.
- The `hk` version in `mise.toml` must match the `hk@X.Y.Z` package URI in `hk.pkl` (bump together).
- `mise run project` (tuist generate) needs a one-time `./bin/mise x -- tuist auth login` — the project is connected
  to tuist.dev (`alexey1312/reachy-mini-desktop-app-swift` in `Apps/Tuist.swift`). That handle names the **tuist.dev
  project**, not this repository, and deliberately keeps the pre-rename name: renaming the GitHub repo does not rename
  the server-side project, so "fixing" it to match `reachy-mini-swift` points generation at a project that does not exist.
- Run every `tuist` command from `Apps/` — `Tuist.swift` lives there and tuist only searches _upward_, so from the repo
  root it finds no manifest and reports the project as unconnected to the server (`run 'tuist init'`).
- Use `mise run inspect:bundle [path]` rather than `tuist inspect bundle`: it handles the cwd, defaults to the iOS
  device bundle, and rejects a macOS one (which keeps `Info.plist` under `Contents/`, where the command wants it at
  the root). Size numbers only mean something off a Release archive — a Debug bundle carries `__preview.dylib`,
  `*.debug.dylib` and the provisioning profile, none of which ship.
- Do **not** set `enableCaching` — without a running cache daemon every compile task waits out a CAS socket deadline,
  and CI has neither the daemon nor cache credentials (this repo is not connected to the tuist.dev project).
- `Package.resolved` **oscillates between the two build systems, and neither is wrong.** `xcodebuild` resolves the
  whole Tuist workspace and writes back to the root package's file, adding five pins (Prefire, swift-snapshot-testing,
  swift-syntax, swift-custom-dump, xctest-dynamic-overlay); `swift build` / `swift test` see only the root package and
  strip them again. Merging a branch that predates them drops them silently too — git sees a clean delete on one side.
  Commit the 25-pin version (run `mise run project` or any snapshot task last), never hand-edit it, and expect the
  file to show as modified after a plain `mise run test`.

## Quick Reference

```bash
./bin/mise run build          # Debug build (piped through xcsift)
./bin/mise run build:app      # Build the ReachyMini app target (generates first)
./bin/mise run build:app:ios  # Same, for iOS — the only task that compiles the widget
./bin/mise run device         # Build, install and launch on the connected iPhone
./bin/mise run test           # All tests, parallel
./bin/mise run test:filter T  # Filter tests
./bin/mise run lint           # SwiftLint --strict + actionlint + hk lockstep
./bin/mise run format         # Format all (hk fix --all)
./bin/mise run format-check   # CI formatting check
./bin/mise run project        # tuist generate (Apps/)
./bin/mise run inspect:bundle # Upload an iOS bundle-size analysis to tuist.dev
./bin/mise run sim-daemon     # Simulated robot daemon (MuJoCo, LAN-reachable)
./bin/mise run test:sim       # Integration tests against a running sim-daemon
./bin/mise run test:smoke     # XCUITest: boot the app on a simulator, walk the gate
./bin/mise run test:smoke:sim # Same plus the full user path against a running sim-daemon
./bin/mise run release:ios    # Archive Release and upload to TestFlight (docs/release.md)
./bin/mise run release:macos  # Archive, notarize, staple and zip for Developer ID
./bin/mise run update-spec    # Refresh + normalize daemon OpenAPI spec
./bin/mise run test:snapshots # Snapshot-test every ReachyUI preview (iOS Simulator)
./bin/mise run test:snapshots:record  # Re-record the reference images
./bin/mise run storybook      # Browsable catalogue of every preview, on a simulator
```

`build` / `test` are SwiftPM only — they never compile `Apps/ReachyMini`. Use `build:app` for that; CI runs it as a
separate job, so app-target breakage no longer reaches `main` unnoticed.
**`build:app` builds for macOS, where `ReachyWidget` does not exist** — the extension is `destinations: [.iPhone,
.iPad]` and `Project.swift` embeds it behind `condition: .when([.ios])`, so a macOS destination compiles none of its
sources and reports success over a widget that does not build. That is how `missing return` in
`ReachyAppsWidget.swift` reached `main` in #7. `build:app:ios` (`-destination 'generic/platform=iOS'`, unsigned) is
what covers it, and CI runs both.
`test:filter` matches type names (`RobotSessionAudioTests`), not `@Suite` display names.
`Apps/ReachyMiniUITests` is the one XCTest bundle in the repository — XCUITest has no swift-testing form. Its
queries go by visible label under `-testLanguage en`, the same trade the snapshot suite makes; Tier 2
(`test:smoke:sim`) is gated on `REACHY_SMOKE_HOST` exactly as `test:sim` is on `REACHY_SIM_HOST`, so a plain run
skips it silently. Tuist folds a `.uiTests` target into its host's scheme rather than generating one of its own —
there is no `ReachyMiniUITests` scheme, both smoke tasks test the `ReachyMini` scheme.
`SimulatorIntegrationTests` is gated on `REACHY_SIM_HOST`, so plain `test` **skips it silently and reports green** —
run `test:sim` against a live `sim-daemon` to exercise it.
`swift test --skip-build` runs the previously built binary: rebuild with `swift build --build-tests` after editing a
test, or the run silently verifies stale code.
Everything pipes through xcsift, which on long runs can truncate and report `status: incomplete` while hiding the real
result — verify the artifact, or rerun the tool directly
(`./bin/mise x -- swiftlint lint --strict Sources Tests Apps/ReachyMini`). Always pass those explicit paths — a bare
`.` walks into `Apps/DerivedData`, and swiftformat then "fails" on generated and vendored sources.
**swiftformat and `#expect` disagree about key paths, and the formatter wins.** `preferKeyPath` rewrites
`allSatisfy { $0.isTappable }` into `allSatisfy(\.isTappable)`, which the macro cannot expand: the build fails with
`call can throw, but it is not marked with 'try'` at `macro expansion #expect`, pointing at generated code rather
than at the line you wrote. So `mise run format` breaks a test that compiled a minute earlier, and undoing it by hand
is a loop — the next format run puts it back. Assert on a mapped array instead
(`map(\.isTappable).contains(false) == false`), which the rule leaves alone.
`mise run clean` only clears `.build` — `Apps/DerivedData` (Xcode's, several GB) is not touched.
**SwiftPM holds one `.build` lock per worktree**, so a second invocation waits instead of failing, printing
`Another instance of SwiftPM (PID: …) is already running` — a line that never appears when the output is piped
through `tail`. A run that timed out in your tool keeps running and keeps the lock, and every later command then
looks like the code under test is hanging. Check `pgrep -f 'swift-build|swift-test|swift-frontend'` before
diagnosing a hang, and run one SwiftPM process at a time.
**A hang with no test output at all is the compiler, not the code.** `ps -o command= -p <frontend-pid>` names the
`-primary-file` it is stuck on and `sample <pid>` names the pass. One shape found here: a closure nested inside an
`AsyncStream { continuation in … }` builder that captures the escaping continuation (e.g. `lock.withLock { … }`
assigning it to a stored property) emits a `convert_escape_to_noescape` that sends the `ClosureLifetimeFixup` SIL
pass into a dominator walk it does not return from — 20+ minutes of one core, no diagnostic, no timeout. It is a
diagnostic pass, so `-Onone` does not avoid it; flatten the nesting and lock by hand instead
(`Tests/ReachyKitTests/RemoteControlChannelTests.swift` carries the worked example).
Two files sharing a basename in one target fail as `couldn't build <name>.swift.o because of multiple producers`,
never as a redeclaration and never naming the other file — check `find Sources -name Foo.swift` before adding one.
`sim-daemon` **cannot** serve `/wifi/*` or `/update/*`: `--wireless-version` crashes on import (`.venv-sim` has
neither `nmcli` nor `cryptography`), and `main.py` would run robot-image maintenance on your Mac. Those routes are
covered by `StubURLProtocol` / `LocalWebSocketServer` and real hardware only. BLE likewise — the robot's GATT service
is Linux/BlueZ, so nothing simulates it.
`.venv-sim` does hold the daemon's own source (`lib/python3.12/site-packages/reachy_mini/`) — read
`daemon/app/routers/*.py` and `daemon/app/services/` there rather than inferring a route's shape. Still a
specification (rule 1), never code to port.
It is 1.3 GB and gitignored, but it is filled by `uv pip install`, which writes APFS clones instead of copying out
of its cache: a second worktree builds one in under a second and consumes ~6 MiB of actual disk. The venv itself is
still created by `python -m venv` — mjpython wants a real framework build, and `uv venv` was never tried against
mujoco. **Do not move it out of the worktree to share it between them**, and do not read the old advice to wait out
pip: an install that takes minutes now means a cold `~/.cache/uv`, not normal behaviour.
Both a relocated copy and a clean install into `~/.cache` leave the daemon stuck before it binds :8000, logging
`External plugin loader failed` — while the same venv under the worktree serves in four seconds. The cause is not
the scanner binary (it executes fine from either path) and was not identified; the shared-cache experiment is a
dead end, not an unfinished idea. Probe readiness on `/api/daemon/status` — **there is no `/api/status`**, so a
poll for it reports a healthy daemon as down.

**Device builds are one command: `mise run device`** (`Scripts/device-run.sh`, also the Conductor run button in
`.conductor/settings.toml`). It finds the phone itself — `devicectl list devices --json-output` carries both
identifiers per device, and they are not interchangeable: `hardwareProperties.udid` is what
`xcodebuild -destination 'id=…'` takes, `identifier` is the CoreDevice UUID `devicectl` takes, and swapping them
fails with "Timed out waiting for all destinations". The one thing it cannot discover is the signing team, which
lives in `~/.config/reachy-mini/device.env` — outside every worktree, so nothing is copied when a workspace is
created, and an exported `REACHY_DEVELOPMENT_TEAM` overrides it. Flags: `--build-only`, `--no-launch`,
`--device <udid>`; pass them after `--` (`mise run device -- --build-only`).
`devicectl` prints `Failed to load provisioning paramter list … No provider was found.` on every invocation and
succeeds anyway — check for `App installed:`, not for a clean stderr. A **locked** phone accepts the install and
refuses the launch; the script says so and exits 3 rather than reprinting the CoreDevice error wall.

**An App Group is not a wildcard capability.** `iOS Team Provisioning Profile: *` cannot carry one, so every target
that declares it — the app and each extension separately, each with its own App ID — needs it added once through
Xcode's Signing & Capabilities. `xcodebuild -allowProvisioningUpdates` reports `No Accounts` and cannot create it.
`Project.swift` already declares the entitlement and Tuist writes the `.entitlements`; what the Xcode step registers
lives in the Apple developer account, not in this repository, so it survives regeneration and cannot be scripted here.

Snapshots live in `Apps/` as an Xcode target because they need an iOS simulator, so `swift test` never sees them.
`mise run project` writes the storybook playbook before calling tuist: `Apps/ReachyStorybook/Generated` is gitignored
and `Project.swift` globs it unconditionally, so generation — and with it `build:app` and every snapshot task — failed
outright on a fresh clone and in CI until the generator ran. Do not drop that step.
`Apps/<App>/Previews/**` is in the storybook and snapshot targets' `sources` but **not** in the app target's
(`ReachyMini/Sources/**` only), so a helper the app itself must see belongs in `Sources/`.
**Previews compile only in the Xcode targets, so `swift build` cannot vet them** — and Prefire copies each preview
body into a generated file, where a leading-dot call resolves against the type expected _there_. A `static func`
helper for an element type therefore belongs on that element (`KnownRobotsModel.Entry.preview`), not on its owner:
the latter compiles under SwiftPM and fails the snapshot target 17 minutes later.
A new _directory_ of previews needs four edits, not one: `sources` in `Apps/.prefire.yml` (Prefire reads its own
list, not the target's), the `sources` of **both** preview-hosting targets in `Project.swift`, `testable_imports`
for any module those previews name — the generated file imports that list and nothing else — and the explicit
directory list `prefire playbook` is handed in `mise.toml`, which appears in **two** tasks (`project` and
`storybook`). Miss the first and the previews compile while generating no tests at all, which reads as everything
passing; miss the last and the previews are simply absent from the storybook, with no error anywhere.

**Four device/runtime identifiers are in play, and they deliberately do not match.** Changing one without the others
either re-records everything or fails the run outright:

| Identifier                     | Set in                               | What it is                                                                                           |
| ------------------------------ | ------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `iPhone 17 Pro`                | `mise.toml`, `REACHY_SNAPSHOT_SIM`   | The simulator the tests execute on. Renders every image.                                             |
| `iPhone18,1`                   | `.prefire.yml`, `simulator_device`   | The same machine as a model id. Prefire aborts on a mismatch.                                        |
| `iPhone 16 Pro`, `iPad Pro 11` | `.prefire.yml`, `snapshot_devices`   | `ViewImageConfig`s — frame size and traits, and the filename suffixes. Not devices anything runs on. |
| `26.4.1` / `26`                | `REACHY_SNAPSHOT_OS` / `required_os` | Full runtime for the destination; major only for Prefire's check.                                    |

So a reference named `…-iPhone-16-Pro.png` was rendered on an iPhone 17 Pro, at iPhone 16 Pro dimensions. A
different iOS runtime renders text differently and every reference would have to be re-recorded.
**Every preview is captured in both appearances**, by `Apps/ReachyUISnapshotTests/PreviewTests.stencil` — a fork of
Prefire 5.7.0's built-in test template, which is why the package requirement is `.exact` rather than
`upToNextMajor`. Light keeps the name it always had and dark takes a `-dark` suffix, so adopting it added 500 files
and modified none. What a dark reference can and cannot prove — glass renders light in both — is in
`Sources/ReachyDesign/AGENTS.md`. `simctl ui … appearance light` survives in `snapshots:_run` as belt and braces
only: the injected trait decides, measured by re-recording the surfaces gallery on a dark simulator and getting
byte-identical images.
**References are English-only**, pinned by `-testLanguage en -testRegion US` on the `xcodebuild test` line. Every
user-facing string is localizable, so a simulator left in another language re-renders all 1000 of them in it.
Run `test:snapshots` before `test:snapshots:record` — it names every reference that moved, which `record` then
overwrites blind. If _every_ reference moved, suspect the environment rather than the code: check one nothing could
have affected (`JoystickPad`) against HEAD with `git show HEAD:<png> | git lfs smudge > /tmp/old.png`.
**`record` deletes all ~1100 PNGs before it runs anything, so a snapshot target that fails to _build_ leaves you with
every reference gone** — and `git checkout` brings back only the tracked ones, not the new references an earlier run
had just written. Get `mise run snapshots:_run` to compile first, then record. This is easy to walk into because
`swift build` cannot see the mistake: `Previews/` is excluded from the SwiftPM target, so a preview that does not
compile is invisible until `mise run project` plus a snapshot build. Watch for `failed to produce diagnostic for
expression` in particular — it names the enclosing function and nothing else, and one cause is unifying an optional
`@MainActor` closure with `nil` in a ternary (`PreviewScene.advancedSection` uses an `if` for exactly that reason).
**Adding previews can move references belonging to screens you did not touch — but not in proportion to how many.**
Every preview holding an indeterminate `ProgressView` — anything named _loading_, _scanning_, _connecting_,
_waking up_, _building_ — captures that spinner at whatever phase it reached, and the phase depends on where in the
run the test lands, so what actually moves things is a shift in the run's timing rather than the act of adding a
preview. One session added fourteen previews and roughly twenty unrelated references moved in every run; three later
additions (eight previews, then one, then six — one of them carrying a spinner) moved none at all. So treat a wide
sweep as something to explain rather than to expect: it is not flakiness and not the environment — the same suite on a
clean HEAD passes, and re-recording settles it. Diff one to confirm nothing but the spinner moved before accepting it.
Reference images are
**Git LFS**; `bootstrap.sh` enables the filter, and without it they check out as text stubs. LFS uploads objects from
a `pre-push` hook, and `core.hooksPath` makes git ignore `.git/hooks` — so its four hooks are tracked in `.githooks/`
alongside the hand-written ones. Drop them and `git push` sends pointers with no data behind them.
Adding a reference image still needs an explicit `git add`: the LFS filter decides how a staged file is _stored_, and
the pre-commit hook only re-stages what it reformatted (`*.swift`, `*.md`) — neither one stages a PNG for you.
There is no CI job yet: local Xcode and the CI pin differ, so references recorded on one fail on the other.
`test:snapshots` compares the images either side of the run and fails if any had to be written — Prefire generates
`record: .missing`, so a reference that does not exist yet is created rather than compared.
The compact root used to capture as a near-blank ghost, which made `Root-connected`, `Root-no-camera` and
`Root-unreachable` byte-identical on iPhone — three references verifying nothing. Splitting the root into a gate and
a five-tab shell ended that: each root capture now renders the selected tab's content. Two iPhone captures may still
collide legitimately, when the state they differ in belongs to a tab neither is showing; that is a sign the preview
is pointed at the wrong tab, not that the capture is dead.
`Apps/.prefire.yml` carries no comments on purpose: Prefire's hand-rolled YAML parser reads a comment line ending in
`:` as a config key, warns, and moves on — a helpful comment silently becomes an unknown setting.
**Macros that ship with Xcode rather than with the toolchain break `swift build`.** The pinned swift.org toolchain has
no `SwiftUIMacros`/`PreviewsMacros` plugin, so `#Preview` and `@Entry` fail with "plugin for module … not found".
Previews therefore live only in `Sources/ReachyUI/Previews`, which `Package.swift` excludes from the target, and
environment keys are written out by hand — swiftformat's `environmentEntry` rule is disabled for that reason.

## Project Context

|                 |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Robot API       | `http://<robot>:8000/api`, OpenAPI 3.1 spec committed at `Sources/ReachyKit/openapi.json`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| State stream    | WebSocket `/api/state/ws/full`, 10 Hz by default (not in the OpenAPI spec — hand-written client)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Upstream        | `pollen-robotics/reachy-mini-desktop-app` + `pollen-robotics/reachy_mini` — **specification only, never copy code**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Packages        | `ReachyKit` (transport + domain) → `ReachyMedia` (WebRTC) / `ReachyScene` (RealityKit) → `ReachyUI` → `Apps/`. `ReachyDesign` (tokens + the `ReachySurface` facade) sits under everything on nothing at all — SwiftUI and no more — and is linked by both `ReachyUI` and `ReachyWidgetUI`; see `Sources/ReachyDesign/AGENTS.md`. `ReachyWidgetUI` sits under `ReachyUI` on `ReachyKit` alone — the widget's views and the App Intents the app and the extension share, plus `AppArtwork`, which the store rows draw too. It must **not** gain a `ReachyMedia` dependency: a widget process woken for a moment cannot afford to link WebRTC. That is what fixes the arrow's direction — anything both surfaces draw moves down into it, never the other way. |
| SSH             | `ReachySSH` (SFTP via Citadel) sits beside `ReachyKit`, not inside it, and `ReachyUI` links it. The reason is the widget: `ReachyWidgetUI` depends on `ReachyKit`, so SSH there would drag SwiftNIO into a process woken for a moment to draw two lines of text — the `ReachyMedia` argument again. It knows nothing about robots; host, port and credentials arrive as values. Read `Sources/ReachySSH/AGENTS.md` before touching it: Citadel needs a retroactive `Sendable` on `SSHClient`, a shared event loop group, and one SFTP session per connection, and each of those was measured rather than guessed.                                                                                                                                           |
| Off to the side | `HuggingFaceAuth` — this app's own HF session (sign-in, Keychain, renewal). Nothing in it knows what a robot is, and `ReachyKit` does **not** depend on it: a token reaches the robot as a value the UI passes in. `ReachyTestSupport` holds stubs shared by the test targets and is deliberately not a product.                                                                                                                                                                                                                                                                                                                                                                                                                                            |

## Project Rules

1. **Upstream is a spec, not a source.** Read the Pollen repos to learn behavior; do not port their code.
2. **Safety lives in the daemon.** All robot commands go through the daemon API. Never duplicate or bypass motion
   limits, gravity compensation, or collision checks client-side.
3. **Version handshake first.** Read the daemon version on connect; unknown JSON fields must not break decoding.
4. **Robot identity ≠ IP.** Identify robots by stable identity (robot name / hardware id from the daemon), never by
   address (one robot can appear at several addresses — upstream issue #269).
5. **URLs via `URLComponents` only** — bare string interpolation breaks on IPv6 literals. Drop `fe80::` link-local
   addresses unless carrying a zone ID.
6. **Conventional commits** — enforced by the commit-msg hook. The pre-commit hook stages _every_ modified `*.swift`
   and `*.md` (`stage` in `hk.pkl`), not only what you `git add` — separate unrelated edits with
   `git stash push <paths>` first, or they land in one commit. Only those two extensions: `.py`, `.json`, fixtures
   and hook scripts need an explicit `git add`, and a commit with nothing staged fails before the hook runs.
7. **Tests wait on conditions, not durations.** A fixed `Task.sleep` before an assertion is a CI flake waiting to
   happen: the suites are `@MainActor` and a loaded runner starves them. Poll the condition, and give an injected
   timeout headroom its deadline cannot cut short. **But where two paths end in the _same_ error and differ only in
   how long they take** — two timeout budgets, a retry against a first try — the error alone proves nothing: the
   wrong branch throws the very same thing, just later, and the suite passes green with only `test_time` quietly
   grown. There the duration _is_ the assertion. Measure a `ContinuousClock` span and bound it loosely enough that a
   loaded runner cannot cross it — separating milliseconds from tens of seconds leaves room to spare
   (`RemoteControlChannelTests.expectTimeout`). Mutate the branch and watch it go red before trusting it.
8. **A new screen ships with its previews.** Every screen, and every state a user can land in, gets a `#Preview`
   under `Sources/ReachyUI/Previews` and a recorded reference — `mise run test:snapshots:record`, then `git add` the
   PNGs, which no hook stages for you. A state that needs a live robot to reach is the one most worth capturing: add
   the injection seam (`Sources/ReachyUI/AGENTS.md`) rather than leave the state uncovered. Say so explicitly when
   something is deliberately not covered, as `SceneViewport.ready` is. `--parallel` also runs _suites_ concurrently, and `.serialized`
   orders only within one — a harness holding shared global state passes until a second suite uses it
   (`StubURLProtocol` binds stubs to their session for exactly this reason). Give async transport tests
   `.timeLimit(.minutes(1))`, or one hang stalls the whole run.
9. **Every string a user reads goes through `.reachy(_:)`.** A bare `Text("Connect")` is a bug, and a silent one:
   inside a library target a `LocalizedStringKey` resolves against `Bundle.main`, so it renders perfectly in English
   and can never be translated. Two spellings, and which one applies is decided by the type, not by taste:
   - **`.reachy("…")`** wherever SwiftUI takes a `LocalizedStringResource` — `Text`, `Button`, `Label`, `Section`,
     `LabeledContent`, `Toggle`, `Picker`, `TextField`, `ContentUnavailableView`, `navigationTitle`, `alert`,
     `accessibilityLabel`. This is the default; reach for it first.
   - **`String(localized: .reachy("…"))`** only where the value has to _stay_ a `String`: a model property a test
     asserts on, or a slot that also holds runtime text the robot sent (`RunningAppCaption.description` inlines a
     traceback, `.unknown(state)` carries the daemon's own word). Resolving early is the price of sharing the slot.

   Exempt, and only these: log lines, fixtures, identifiers, format strings, and the App Intents metadata — see
   `Sources/ReachyDesign/AGENTS.md` for why the last one is not an oversight. **Never show `String(describing:)` of a
   domain enum**; give it a caption type beside the screen, as `DaemonStateCaption` and `RunningAppCaption` do.
   Layout stays direction-relative too: `leading`/`trailing`, never `left`/`right`, and the mirroring SF Symbols
   (`chevron.forward`, `arrow.up.forward.square`) rather than the absolute ones, so a right-to-left language needs no
   second pass. `JoystickPad` keeps `.left`/`.right` on purpose — those are the robot's directions, not the reader's.
10. **A visual change names a token or a role, never a literal, a material or an OS version.** `Space.lg`,
    `Radius.rect(.lg)`, `Typography.detail`, `Tone.danger`, `.reachySurface(.chrome, in: .capsule)` — not
    `padding(16)`, not `RoundedRectangle(cornerRadius: 16)` (whose default corner style is `.circular` where every
    token is `.continuous`), not `.background(.regularMaterial)`. Every `if #available` for glass lives in
    `ReachyDesign` and nowhere else. Optical adjustments stay literals on purpose — a 1 pt gap in the dock is not
    rhythm. **Glass gets measured, never reasoned about**: it is invisible headless, renders its content vibrantly so
    colour collapses to black, blanks the entire capture under `.buttonStyle(.glass)`, and stays light in a dark
    reference. Each was found by re-recording and is written up with its measurement in
    `Sources/ReachyDesign/AGENTS.md`; add the next one the same way.

## Detailed Rules

Consult `.claude/rules/` when working in the matching area:

| File                          | When to consult                          |
| ----------------------------- | ---------------------------------------- |
| `.claude/rules/daemon-api.md` | Endpoints, WebSockets, timeouts, jobs    |
| `.claude/rules/networking.md` | Discovery, ATS, Local Network permission |

Per-target notes live beside the code: `Sources/{ReachyKit,ReachyUI,ReachyScene,ReachyDesign,ReachyWidgetUI}/AGENTS.md`
(`CLAUDE.md` is a symlink to it). **`ReachyDesign/AGENTS.md` is the design system's entire rulebook** — the tokens,
the `SurfaceRole` facade, the four things glass does headless, what a dark reference proves and what it does not, and
the localization catalogue. Read it before any visual change, not after one moved a reference.
Background reading: `docs/adr/` for accepted decisions, `docs/research/webrtc.md` for 8443 signaling quirks.
