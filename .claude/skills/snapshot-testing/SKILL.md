---
name: snapshot-testing
description: Previews, Prefire, the storybook and the recorded reference images. Use when adding or changing a #Preview, running or re-recording snapshots (test:snapshots, test:snapshots:record, snapshots:build, storybook), touching Apps/.prefire.yml or the snapshot/storybook targets in Project.swift, or when references move unexpectedly.
---

# Previews, snapshots and the storybook

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
