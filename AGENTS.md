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
- Tool versions are pinned in `mise.toml` + `mise.lock`. After editing `[tools]`, lock **that tool only**:
  `./bin/mise lock <tool>`, which is purely additive. `trash mise.lock && ./bin/mise lock` re-resolves the fuzzy
  selectors too — `python = "3.12"` stayed 3.12.13 but its python-build-standalone build moved a release forward on
  every platform, so adding one tool arrived as a 14-line unrelated diff.
  Find updates with `./bin/mise latest <tool>` — `mise outdated` reports nothing here, because an exact pin always
  matches its own request. `latest` also hides releases younger than `minimum_release_age` (a day-old `asc` 3.7.0
  read as 3.6.1, with the real answer only in `ls-remote`'s trailing warning); an exact pin installs one anyway.
- A `github:` tool takes **`bin=`** to name a bare binary asset and `exe=` to name one inside an archive, and picking
  the wrong one fails late: `[exe=asc]` installs an unrunnable `asc_3.7.0_macOS` and only errors at "couldn't exec
  process". Prefire ships a tarball and so uses `exe`; `asc` ships the binary itself and uses `bin`.
- The `hk` version in `mise.toml` must match the `hk@X.Y.Z` package URI in `hk.pkl`, and the `prefire` pin in
  `[tools]` must match the `.exact` requirement in `Apps/Project.swift` — the forked `PreviewTests.stencil` is only
  valid against that one version. Bump each pair together; `mise run lint` enforces both lockstep pairs.
- `mise run project` (tuist generate) needs a one-time `./bin/mise x -- tuist auth login` — the project is connected
  to tuist.dev (`alexey1312/reachy-mini-swift` in `Apps/Tuist.swift`). That handle names the **tuist.dev project**,
  which happens to match this repository's name only because the pre-rename project was deleted and recreated;
  renaming the GitHub repo does not rename the server-side project, so check `tuist project list` before assuming
  the two stay in step. Deleting the old project took its build and bundle history with it.
- Run every `tuist` command from `Apps/` — `Tuist.swift` lives there and tuist only searches _upward_, so from the repo
  root it finds no manifest and reports the project as unconnected to the server (`run 'tuist init'`).
- Use `mise run inspect:bundle [path]` rather than `tuist inspect bundle`: it handles the cwd, defaults to the iOS
  device bundle, and rejects a macOS one (which keeps `Info.plist` under `Contents/`, where the command wants it at
  the root). Size numbers only mean something off a Release archive — a Debug bundle carries `__preview.dylib`,
  `*.debug.dylib` and the provisioning profile, none of which ship.
- `mise run share [path]` uploads a built app to tuist.dev Previews and prints the share link. The default path is
  the `mise run device` product because that one is signed with the personal team — a preview of the unsigned CI
  build would not install on a device. The server refuses an identical re-upload (`duplicate_app_build`): rebuild or
  bump the build number before sharing again.
- **The Xcode compilation cache is on by default** — `enableCaching` in `Apps/Tuist.swift` reads `TUIST_CACHE_ENABLED`
  (default true) and bakes `COMPILATION_CACHE_*` settings into the generated project, pointing at the Unix socket of a
  per-user LaunchAgent that `tuist setup cache` creates once (bootstrap.sh runs it best-effort; it needs a tuist.dev
  session). A missing daemon is **not** the cliff it used to be: the plugin fails fast on an absent socket and the
  local CAS inside DerivedData keeps serving hits — an incremental rebuild measured 23 s with the daemon and 22 s
  without. CI still defaults `TUIST_CACHE_ENABLED=false` at the workflow level; only the two app-build jobs ask
  `.github/actions/xcode-workspace` for `compilation-cache: "true"`, and even they flip the variable only once the
  `tuist setup cache` step sees a live socket — a fork has no session to start one with, and a `.sock` file outlives a
  dead daemon, so existence is not liveness. **On CI it has been measured and it does not pay** — do not switch it on
  for the other jobs without new evidence. Two things were wrong with the obvious theory, and both were corrected
  before measuring: the generated project carries `COMPILATION_CACHE_*` but no `SWIFT_ENABLE_EXPLICIT_MODULES`,
  without which the Swift compiler caches nothing and says so at every build ("swift compiler caching requires
  explicit module build"); and that setting cannot come from `Apps/Project.swift`, because a project's build settings
  do not reach the SPM package targets Xcode builds as implicit projects — which is all of ReachyKit, ReachyUI and
  ReachyMedia. Passing it through `REACHY_XCB_EXTRA` does reach them. With both fixed and the cache service up in all
  four Xcode jobs, a populate-then-read pair on one commit (run 31462908387, attempts 1 and 2) came out at **13.1 min
  against 13.2 without any of it** — one job faster, two slower. Reverted. A runner's DerivedData is empty every time,
  so only the remote CAS can help, and it does not help enough to see.
  **Cache keys embed absolute paths**, so hits only come from
  a stable DerivedData path: a clean rebuild in the same DD replays from cache (119 s → 39 s measured), while the same
  build in a different DD misses every key and re-uploads everything. `Apps/DerivedData` and CI's fixed workspace path
  both qualify; a first build with an empty cache pays a population surcharge. Everything is named after the project
  handle (`alexey1312_reachy-mini-swift` in the LaunchAgent, socket and ci.yml): renaming the tuist.dev project
  orphans all three silently — exactly how the pre-rename project's agent was found dead here. The agent's first
  start can lose a race and exit 1; KeepAlive restarts it, check `launchctl list | grep tuist.cache`.
- **Build insights reach tuist.dev through a scheme post-action, not through a command.** `tuist generate` writes
  `tuist inspect build` into every generated scheme's build action (and `tuist inspect test` into
  `ReachyUISnapshotTests`' test action), pointing at the mise-installed binary by absolute path. That post-action
  reads the `.xcactivitylog` in `Apps/DerivedData/Logs/Build`, and **`xcodebuild` writes one only when a result
  bundle is requested** — Xcode.app writes one unconditionally. So every recorded build run came from the GUI, while
  `mise run build:app` ran the post-action, got "couldn't find the most recent activity log", and left the build
  green: a post-action's exit code is not the build's. Hence `-resultBundlePath` on the xcodebuild tasks; drop it and
  the insights silently stop. `tuist xcodebuild build` is the alternative the docs name, but it would have to wrap
  the xcsift pipe.
- **On CI the post-action also needs a session, and it comes from OIDC, not a secret.**
  `permissions: id-token: write` plus a `tuist auth login` step, which the pinned CLI answers with "Detected CI
  environment, authenticating with OIDC…". A fork's workflow gets no id-token, so the step is skipped there by
  design. What OIDC does require is the GitHub **repository connected to the server project** — and installing the
  Tuist GitHub app on the account is only half of that: the connection is a second, per-project step, and without it
  the server refuses the exchange with "No projects linked to the repository". The readable indicator is
  `repository_url`, which `tuist project show` prints only into the session log, not to the terminal; while it is
  `null`, OIDC has nothing to authorize against and PR comments cannot arrive either. The step warns rather than
  fails on that, deliberately: `app-build-ios` is what compiles the widget, and telemetry must not be what reddens it. Fallback if the connection is not wanted: an account token with the `ci`
  scope group (`tuist account tokens create alexey1312 --scopes ci --name github-ci`) in a `TUIST_TOKEN` secret —
  `tuist project tokens` is deprecated, and a user session is interactive.
  `Apps/Tuist.swift` sets `optionalAuthentication: true` so a fork can still generate, which is exactly what makes a
  missing session invisible: nothing fails, the data just never arrives. Check for `is_ci: true` after changing
  anything here — the CLI's own `build list` decoder is broken in 4.203.1 and errors on a 200 response, so read the
  JSON out of `~/.local/state/tuist/sessions/*/logs.txt`.
- `Package.resolved` **oscillates between the two build systems, and neither is wrong.** `xcodebuild` resolves the
  whole Tuist workspace and writes back to the root package's file, adding five pins (Prefire, swift-snapshot-testing,
  swift-syntax, swift-custom-dump, xctest-dynamic-overlay); `swift build` / `swift test` see only the root package and
  strip them again. Merging a branch that predates them drops them silently too — git sees a clean delete on one side.
  Commit the 25-pin version (run `mise run project` or any snapshot task last), never hand-edit it, and expect the
  file to show as modified after a plain `mise run test`. `mise run lint` fails when the copy at `HEAD` has lost the
  workspace pins — it reads the commit rather than the working tree, precisely because the tree legitimately
  oscillates.

## Quick Reference

```bash
./bin/mise run build          # Debug build (piped through xcsift)
./bin/mise run build:app      # Build the ReachyMini app target (generates first)
./bin/mise run build:app:ios  # Same, for iOS — the only task that compiles the widget's controls
./bin/mise run device         # Build, install and launch on the connected iPhone
./bin/mise run test           # All tests, parallel
./bin/mise run test:filter T  # Filter tests
./bin/mise run lint           # SwiftLint --strict + actionlint + lockstep/pin checks
./bin/mise run format         # Format all (hk fix --all)
./bin/mise run format-check   # CI formatting check
./bin/mise run project        # tuist generate (Apps/)
./bin/mise run inspect:bundle # Upload an iOS bundle-size analysis to tuist.dev
./bin/mise run share          # Upload a built app to tuist.dev Previews (share link)
./bin/mise run sim-daemon     # Simulated robot daemon (MuJoCo, LAN-reachable)
./bin/mise run test:sim       # Integration tests against a running sim-daemon
./bin/mise run test:smoke     # XCUITest: boot the app on a simulator, walk the gate
./bin/mise run test:smoke:sim # Same plus the full user path against a running sim-daemon
./bin/mise run release:ios    # Archive Release and upload to TestFlight (docs/release.md)
./bin/mise run release:macos  # Archive, notarize, staple and zip for Developer ID
./bin/mise run asc -- ...     # App Store Connect CLI with the release key loaded
./bin/mise run update-spec    # Refresh + normalize daemon OpenAPI spec
./bin/mise run theme:colors   # Regenerate Theme*.colorset from ReachyTheme.palette
./bin/mise run theme:icons    # Regenerate the six AppIcon*.icon bundles from the palette
./bin/mise run test:snapshots # Snapshot-test every ReachyUI preview (iOS Simulator)
./bin/mise run test:snapshots:record  # Re-record the reference images
./bin/mise run snapshots:build        # Compile previews + snapshot target, run nothing (CI's preview job)
./bin/mise run storybook      # Browsable catalogue of every preview, on a simulator
```

`build` / `test` are SwiftPM only — they never compile `Apps/ReachyMini`. Use `build:app` for that; CI runs it in a
job of its own, so app-target breakage no longer reaches `main` unnoticed.
**`build:app` now compiles `ReachyWidget`, but only the half the Mac can run.** The extension is
`destinations: [.iPhone, .iPad, .mac]` and the app embeds it unconditionally, so a macOS build produces
`ReachyMini.app/Contents/PlugIns/ReachyWidget.appex` and the two reading widgets in it. The nine Control Centre
controls stay `#if os(iOS)` — `ControlWidget` is `@available(iOS 18.0, macOS 26.0, …)` and this app deploys to
macOS 15 — and so do the three `accessory*` families, which are `@available(macOS, unavailable)`. **So the old trap
survives in a narrower form**: a macOS build still reports success over code it never compiled, and that code is now
`RobotPowerControls`, `RobotActivityControls` and `RobotSoundControls`. That is how `missing return` in
`ReachyAppsWidget.swift` reached `main` in #7. `build:app:ios` (`-destination 'generic/platform=iOS'`, unsigned) is
still the only task that compiles the controls, and CI runs both — in two jobs split by platform, `App Build (macOS)`
and `App Build (iOS + widget)`, each doing its Debug and Release configuration back to back. To tell the two apart at
the artifact level, read the debug dylib: `nm …/ReachyWidget.debug.dylib | grep WakeRobotControl` answers on iOS and
is silent on macOS.
**The standard macOS runner is three M1 cores**, measured rather than assumed: `macos-15` reports 3 cores / 7 GiB /
`Apple M1 (Virtual)`, and `macos-15-xlarge` reports 5 cores / 14 GiB / `Apple M2 Pro (Virtual)`. The xlarge label does
resolve on this account, so the only thing standing between this project and roughly twice the compile throughput is
that larger runners are billed — including on public repositories, where the standard ones are free. Three cores is
why compilation dominates every number in this file. **Two images are in play, and not for performance**: the two
app-build jobs run on `macos-26` with Xcode 26.4.1 because `actool` on 26.2 fails `CompileAssetCatalogVariant` for the
macOS variant of an Icon Composer `.icon`, and 26.4.1 exists only on that image. Everything else stays on `macos-15`
with 26.2 — the simulator-bound jobs because their runtime and device identifiers are pinned to what that image
carries. `macos-26`'s own core count has not been measured, so every timing quoted here is a `macos-15` number.
**The previews job and the smoke job compile the same packages twice, on purpose.** Both build Debug for the iOS
Simulator into the same `Debug-iphonesimulator` products directory, so one job running them in sequence really does
reuse: the smoke step measured 9.9–10.7 min as its own job against **7.4** after the preview build in the same job.
It is still the wrong trade — one job costs 2.2 + 5.2 + 7.4 against two costing max(8.2, 13.1), and the merged run
came out at 15.6 min against 13.2. Serialising five minutes of previews to save three of smoke loses. Revisit only if
the goal becomes runner minutes rather than wall clock, or if a fifth slot is worth more than two minutes.
**CI's shape is dictated by five macOS slots.** A personal GitHub account gets five concurrent macOS jobs, and
`ci.yml` spends exactly five, so splitting a job further only buys a queue — that is why the four app builds are two
jobs and not a four-way matrix. It is also why the four heavy jobs carry `if: github.event_name == 'pull_request'`:
merging used to run them a second time over the tree the PR had already proved, and two runs of five jobs against
five slots is what turned a 22-minute CI into 30 (4.7 min of queueing for the app build, 8.1 for the smoke test,
measured on run 31425771024). A push to `main` is `Lint & Test` plus `Warm the SPM cache`, which is what a squashed
commit can still get wrong plus the one thing only a main run can do. Nothing gates on `lint` any more either;
`needs: lint` cost every other job a serial 40 s.
**A cache belongs to the ref that wrote it**, and that is what `warm-cache` exists for. GitHub scopes a cache created
on `refs/pull/N/merge` to that PR alone; `refs/heads/main` is the one ref every PR can read. Making the Xcode jobs
`pull_request`-only therefore left nothing to write the `SourcePackages` cache on main, and every PR restored an
empty one — 101 s of package resolution per job, measured on run 31460604091, with the 691 MB entry sitting
uselessly on `refs/pull/47/merge`. Anything cached for the Xcode jobs needs a producer that runs on a push.
**The Release tasks compile, they do not ship, and their settings say so.** `build:app:release` passes
`ONLY_ACTIVE_ARCH=YES` because Xcode's Release default is `NO`: the macOS build was compiling arm64 _and_ x86_64 in
sequence, 8.5 minutes against Debug's 3.0, for a second target triple that catches nothing the first does not
(WebRTC's macOS slice is `macos-x86_64_arm64`, so even the link is covered). Both Release tasks also pass
`DEBUG_INFORMATION_FORMAT=dwarf` to drop the dsymutil pass. `Scripts/release-macos.sh` / `release-ios.sh` archive
with the defaults, so what ships is still universal and still carries dSYMs — check there, not here, before
concluding a slice is missing.
`REACHY_XCB_EXTRA` is the seam for settings that belong to CI and not to a laptop: every xcodebuild task in
`mise.toml` interpolates it, and `ci.yml` sets it to `COMPILER_INDEX_STORE_ENABLE=NO`. Index-while-building stays on
locally because Xcode.app reads that index out of the same `Apps/DerivedData` these tasks write to.
The four Xcode jobs share `.github/actions/xcode-workspace`: mise, an `Apps/DerivedData/SourcePackages` cache (the
package graph was being resolved from scratch in every job — 82 s, 97 s, 108 s), the OIDC session, an optional
`tuist setup cache`, and **one** `tuist generate`. The build steps then run under `MISE_TASK_SKIP_DEPENDS: "true"`,
because every `mise run build:app*` otherwise re-runs its `depends = ["project"]` — that cost the old single
app-build job four generations for one workspace. The variable takes `true`/`false`, not `1`, and rejects anything
else outright. **The step order inside that action is load-bearing**: `Apps/Tuist.swift` reads `TUIST_CACHE_ENABLED`
_at generation_, so a cache service started after `tuist generate` is a service the project was never told about —
the socket comes up, the step reports success, and nothing is cached. Generation stays last for the same reason the
SourcePackages restore comes first.
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
**Two classes of macOS crash leave no trace a normal search finds** — no `Fatal error`, no `NSException`, nothing on
stderr, and no file in `~/Library/Logs/DiagnosticReports` (which may not exist at all). Both call
`abort_with_payload`, which is not a Swift trap: a **main-actor assertion** prints
`BUG IN CLIENT OF LIBDISPATCH: Assertion failed: Block was expected to execute on queue [com.apple.main-thread]`, and
**TCC** prints `[com.apple.TCC:access] … must contain an NS…UsageDescription key`. So the search is
`log show --last 3d --predicate 'process == "ReachyMini" AND (eventMessage CONTAINS "LIBDISPATCH" OR eventMessage
CONTAINS "usage description")'` — grepping for `Assertion failure` / `NSException` / `Fatal error` returns nothing and
reads as "the app never crashed", which is how a reported sign-in crash was three times declared unreproducible.
**Only trust TCC's version when the app was launched through LaunchServices**: running the binary directly, or under
`lldb`, makes TCC read the _parent's_ Info.plist, so a correct bundle is killed anyway. For a real backtrace, sign a
copy with `com.apple.security.get-task-allow` added and run `lldb --batch -k "bt all" -k "quit" -o run -- <binary>`.
Addresses in that log are hex — `IPv4#0a184ea1` is 10.24.78.161.
Everything pipes through xcsift, which on long runs can truncate and report `status: incomplete` while hiding the real
result — verify the artifact, or rerun the tool directly
(`./bin/mise x -- swiftlint lint --strict` with the explicit path list the lint task in `mise.toml` names,
`Apps/ReachyWidget` included). Always pass those explicit paths — a bare
`.` walks into `Apps/DerivedData`, and swiftformat then "fails" on generated and vendored sources.
**`mise run lint` and `mise run format-check` work on a Linux checkout, and four separate things had to be true for
that** — each of them a way the linter was silently unavailable off a Mac, which is how a `--strict`
`function_body_length` violation reached CI with `swiftformat`, `dprint` and `Scripts/check-catalogue.py` all green.
They are wired now; the entries are here because each failure reads as something else.

- **SwiftLint needs SourceKit, and dies before reading a single rule without it**:
  `SourceKittenFramework/library_wrapper.swift:58: Fatal error: Loading libsourcekitdInProc.so failed`. So disabling
  the SourceKit-dependent rules (the `json_codec_only` custom rule and its `match_kinds`) does not help. The library
  ships in the swift.org toolchain, and `Scripts/install-sourcekit.sh` extracts it and the runtime it links —
  **324 MB out of a 3.3 GB toolchain**, straight out of the download stream, into
  `$XDG_CACHE_HOME/reachy-mini/sourcekit` (outside the worktree, so `mise run clean` cannot take it and worktrees
  share one copy). `Scripts/sourcekit-env.sh` is what the tasks source to find it; both directories go on
  `LD_LIBRARY_PATH`, because only the libraries under `swift/host/compiler` find each other by rpath. There is no
  Swift compiler afterwards and none is wanted: `swift build` / `swift test` stay out of reach because the targets
  import SwiftUI and CoreBluetooth.
- **`sh` is not bash here.** mise runs an inline task with `sh -c`, which is bash on macOS and **dash** on Linux,
  where `set -o pipefail` — two dozen occurrences in `mise.toml` — fails as `set: Illegal option -o pipefail`. The
  fix is a `#!/bin/bash` shebang inside the `run` block, the way `project` and `storybook` already have one;
  `unix_default_inline_shell_args` is _not_ available, because mise ignores that setting outside the global config
  ("ignored for security reasons") and warns about it on every invocation.
- **Four of the pinned tools are macOS binaries** (tuist, xcsift, Prefire, asc), so `mise install` fails outright and
  `set -e` used to end `bootstrap.sh` before it wired the git hooks. Its Linux branch writes those four into
  `disable_tools` in the gitignored `mise.local.toml` — a file rather than an exported variable, so a later
  `mise run lint` in a fresh shell still works. The one that then goes missing inside a task is xcsift, which the
  lint task pipes swiftlint through; it falls back to `swiftlint --quiet` instead.
- **The pre-commit hook does not go through a task.** It is `mise x -- hk run pre-commit`, so it sources
  `sourcekit-env.sh` itself — without that line every commit on a Linux checkout fails inside hk's swiftlint step.
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

**App icons are six Icon Composer bundles, generated — `./bin/mise run theme:icons`.** They live at
`Apps/ReachyMini/Resources/AppIcon*.icon` and are ordinary opaque resources: Tuist references each as one file, so
the existing `resources: ["ReachyMini/Resources/**"]` glob needed no change and nothing decomposes them into
`icon.json` plus `Assets/`. A second run must leave the tree clean — `JSONSerialization` is called with `.sortedKeys`
precisely so it does. There is **no asset catalogue for the app icon**: a `.icon` shadows a same-named `.appiconset`
completely (measured — the catalogue contributed zero renditions), so re-adding one is a silent no-op, and iOS 18–25
is served by the back-deployment rasters `actool` derives. Alternate icons are declared twice — in
`ReachyTheme.alternateIconName` and in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES[sdk=iphone*]` — and only
`ThemeIconNameTests` keeps them in step; a mismatch fails inside `setAlternateIconName` on a device and nowhere
earlier. **No reference image covers any of this** — the suite renders views, never a Home Screen, so an icon change
is a device check plus one iOS 18 simulator install. Each extra icon is ~624 KiB in `Assets.car`.
**`docs/media/icon.png` is a copy of the shipping render, not a second rendering of it** — the README shows the
default theme's icon, and it is refreshed by hand from a macOS build:
`iconutil -c iconset <app>/Contents/Resources/AppIcon.icns -o <dir>` and then its `icon_128x128@2x.png` (256 px,
which is the size the README already used). Do **not** re-add a gradient-plus-glyph composer to the script to
generate it: that would be a second answer to "what does the icon look like" that can drift from `actool`'s,
which is exactly the divergence deleting the asset catalogue removed. It shipped stale once already — the README
carried the coral icon for the whole of the theming work.

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
**A successful `record` reports every test as failed** — 1488 failed / 0 passed is what a clean recording looks like,
because swift-snapshot-testing fails a test whenever it writes a reference. The exit code says nothing;
`git status -- '*__Snapshots__*'` says what actually moved. Check the PNGs are still _there_ first
(`find Apps -path '*__Snapshots__*' -name '*.png' | wc -l`) — that count is the one thing separating a recording from
the build failure that deletes all of them.
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
alongside the hand-written ones. Drop them and `git push` sends pointers with no data behind them — which is what
their own generated message invites you to do, and it is the wrong reading of the failure: git-lfs is pinned in
`mise.toml` rather than installed globally, so all four exit 2 with "not found on your path" on a checkout where
nothing put it on a bare PATH, and for `pre-push` that blocks every push. They try the bare call first (a Mac that
has one behaves exactly as before) and fall through to `bin/mise x --`.
Adding a reference image still needs an explicit `git add`: the LFS filter decides how a staged file is _stored_, and
the pre-commit hook only re-stages what it reformatted (`*.swift`, `*.md`) — neither one stages a PNG for you.
No CI job _compares_ references — local Xcode and the CI pin differ, so references recorded on one fail on the
other. What CI does run is `preview-build` (`mise run snapshots:build`): build-for-testing on a generic destination
compiles every preview, the Prefire generation and the snapshot target, so a preview that does not compile fails the
PR instead of surfacing minutes into a local run — or after `record` has already deleted every reference.
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
10. **A repeated visual value names a token or role; a one-off stays native and local.** Add a token at the second
    independent consumer, not when one component gains a second host. Existing roles may be composed with native
    modifiers (`Typography.detail.weight(.medium)`) instead of multiplying aliases. Optical literals carry a short
    reason when their value is otherwise surprising.

    Shared surface and chrome behavior belongs in `ReachyDesign`; a one-off platform API keeps its availability
    check beside its caller and moves only when another caller needs the same behavior. Glass still gets measured on
    device: it is invisible headless, renders content vibrantly, and stays light in dark references.

    After visual work, run the narrow greps below. Name the directories — a bare `Apps` walks into DerivedData:

    ```bash
    set -- Sources/ReachyUI Sources/ReachyWidgetUI Sources/ReachyDesign Apps/ReachyMini Apps/ReachyWidget
    grep -rn --include='*.swift' -B1 '\.font(\.' "$@"            # raw fonts
    grep -rn --include='*.swift' -B1 -E '\.(foregroundStyle|tint|fill|background)\(\s*\.(red|orange|green|white|black)' "$@"
    grep -rn --include='*.swift' -E '\.padding\((\.[a-z]+, )?[0-9]+\)|spacing: [0-9]+' "$@"
    ```

11. **JSON goes through `JSONCodec`.** `.daemon` for what the robot said, `.web` for Hugging Face, `.stored` for what
    this app wrote — and `.stored` may not change without a schema bump, because records from shipped builds are on
    disk. A `JSONDecoder()` under `Sources/` outside `ReachyJSON` is a SwiftLint error; the rule does not reach
    `Tests/`, so a fixture there may still name one — and a test that decodes a daemon payload through a bare
    `JSONDecoder()` never exercises the date rule and proves nothing about the production path. Two sanctioned
    exceptions carry their reason in the code: `SetTargetClient` and `ReachyKitError`.

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

**`docs/` is also the GitHub Pages root**, served at `https://alexey1312.github.io/reachy-mini-swift/` by Pages' own
Jekyll (Settings → Pages → Deploy from a branch → `main` → `/docs`). There is no workflow, no mise task and no Ruby
pin — nothing in CI builds it, and none of the five macOS slots is touched. The site is `_config.yml`, `_layouts/`,
`index.html`, `assets/site.css` and the two markdown pages `privacy.md` / `support.md`; `media/` and `privacy.md` are
shared with the README and with App Store Connect rather than copied, which is the whole reason the site lives here
instead of in a `site/` directory of its own. Four things follow from that:

- **`exclude` in `_config.yml` is a denylist.** `adr/`, `research/`, `superpowers/` and `release.md` are kept out of
  the built site; a new file _inside_ those directories is excluded for free, but a new **top-level** `docs/*.md`
  becomes a public marketing page unless it is added to that list.
- **Every page sits at the same depth and every path is relative** — `index.html`, `privacy.html`, `support.html`, all
  flat `permalink`s. That is what keeps one set of hrefs valid from disk, under `jekyll serve`, and under the
  `/reachy-mini-swift` baseurl. A nested page would need `relative_url` on every link instead.
- **The palette is `ReachyTheme.graphite`**, hand-copied into `assets/site.css` (accent `#3E4757` / `#A9B6CC`, the
  icon's own gradient stops `#9AA6B8` → `#3E4757`). It is a third hand-kept copy alongside the colour and icon
  scripts, and no test checks it.
- **Marketing, support and privacy URLs in `metadata/` point at this site**, so it must be live before
  `asc metadata push` runs — review fails on a 404 privacy URL. `docs/privacy.md` keeps resolving at its github.com
  blob URL too, which is what the previously-pushed value points at.

Local preview needs Ruby, which is deliberately not pinned: use
`docker run --rm -v "$PWD/docs":/srv/jekyll -p 4000:4000 jekyll/jekyll:4 jekyll serve --baseurl /reachy-mini-swift`,
or point Pages at a feature branch — deploy-from-branch accepts any branch, so a site change is reviewable before it
is merged.
