# ADR 0005: Maestro flows replace the XCUITest smoke suite

- Status: Accepted
- Date: 2026-09-07

## Context

`Apps/ReachyMiniUITests/Sources/SmokeTests.swift` was the one place the repository launched the real app binary, and
the only XCTest bundle in a tree that is otherwise entirely swift-testing. Ninety-nine lines, two tests: Tier 1 walked
the connect gate under `--reachy-smoke`, and Tier 2 connected to a live `sim-daemon` and tapped through five tabs,
gated on `REACHY_SMOKE_HOST` so a plain run skipped it.

It worked. What it cost was iteration. The CI job measured **9.9–10.7 min**, and almost all of it was compilation —
the test itself is a handful of taps. Locally the same applies: any edit to a query meant recompiling the app and the
test bundle before finding out whether the query was right. Tier 2, the interesting one, is local-only for the MuJoCo
venv, and that compile is a large part of why it was rarely run and never grew.

[Maestro](https://github.com/mobile-dev-inc/maestro) drives an _installed_ app from YAML, so the compile and the run
come apart. The question was never whether that is nicer — it is whether its iOS support could be trusted here.

## The risk that had to be measured first

Maestro's iOS support is a prebuilt XCUITest runner it unzips out of the CLI and launches through
`xcodebuild test-without-building`, talking to it over a local port. That runner is built against some Xcode, and it
has broken on successive ones: [#3327](https://github.com/mobile-dev-inc/maestro/issues/3327) (driver never connects,
Xcode 26.4), [#3218](https://github.com/mobile-dev-inc/maestro/issues/3218) (driver build fails, Xcode 26.4),
[#3538](https://github.com/mobile-dev-inc/maestro/issues/3538) (a transient AX failure tears the driver down and every
remaining flow then fails).

This repository is the hardest case for that. It is on **Xcode 27.0 beta 6** (27A5252f) with **iOS 27.0 as the only
runtime installed**, locally and on the `xcode-27` CI image — there is no iOS 26 to fall back to. And Maestro names
neither: its QuickStart still lists iOS 16/17/18, Maestro Cloud defaults to iOS 16, and nothing in the docs, the
CHANGELOG through `cli-2.10.0` (2026-08-31) or the issue tracker mentions iOS 27 or Xcode 27.

So nothing was committed until a throwaway spike answered it.

## What the spike measured, on 2026-09-07

|                                               |                                                                                                                          |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Driver attaches on iOS 27.0 / Xcode 27 beta 6 | **Yes.** On a stock simulator and on one 137/170 slimmed by `simslim` alike.                                             |
| SwiftUI hierarchy resolves                    | **Yes.** Text nodes present, plus `selected` / `checked` / `enabled` / `focused`, which is what the tab assertions need. |
| `--reachy-smoke` reaches argv                 | **Yes, unchanged.** See below.                                                                                           |
| Stability                                     | **3 runs, 3 passes**, 33–34 s each.                                                                                      |
| A flow re-run against the installed app       | **13 s**, against 9.9–10.7 min for the job it replaces.                                                                  |

Two things were found by running it that no amount of reading would have produced.

**The simulator's language is load-bearing and its failure is misleading.** `-testLanguage en -testRegion US` on the
old `xcodebuild test` line pinned English, and Maestro has no equivalent for a device it did not start itself. The
machine's `iPhone 17 Pro` was sitting at `ru-KZ`; every selector missed, and Maestro reported each one as an assertion
that was false — never as an untranslated string. The screenshot in the debug output is what settled it in seconds.
`Scripts/maestro-sim.sh` now pins `AppleLanguages`/`AppleLocale` with `simctl` before any run.

**The `--reachy-smoke` seam needed no Swift change**, which was not obvious. `launchApp: arguments:` is a key/value
map rather than an argv list, and Maestro prefixes a `-` to any key whose value is not a Boolean and which does not
already carry one (`IOSLaunchArguments.kt`). A Boolean value is passed through untouched, so `"--reachy-smoke": true`
lands in argv verbatim. Confirmed twice over: at source, and by A/B — with the flag the gate walk passes, and without
it `ConnectionScreen.appeared()` runs to its first-launch branch and presents the Bluetooth onboarding sheet over the
gate.

## Decision

Replace the XCUITest bundle with Maestro flows in `Apps/Maestro`, one per tier, ported one-for-one.

- `maestro` and `java` are pinned in `mise.toml` like every other tool. Maestro is a JVM application and this machine
  had no Java at all; the CI images already ship Temurin, and `jdx/mise-action` caches installs.
- `Scripts/maestro-sim.sh` resolves the simulator name to a UDID, boots it, pins its language, builds and installs.
  `test:smoke` builds; `test:flows` skips the build and is the fast loop the whole change exists for.
- The CI job keeps its slot on pull requests and drops its `if:` so it also runs on pushes to main. Since this is now
  the only job that launches the app binary, a pull request must not merge without it.

## What this gives up, stated plainly

**Assertion precision.** `app.buttons["Nearby"]` filtered by element type; `assertVisible: "Nearby"` matches text
anywhere in the hierarchy. With **zero** `accessibilityIdentifier`s in the repository there is no way to disambiguate
a repeated label, so the flow set is deliberately small and cannot grow much until identifiers land. That work is the
natural follow-up and it touches every screen in `Sources/ReachyUI`.

**`XCTAssertEqual(app.state, .runningForeground)`** has no Maestro equivalent. A trailing `assertVisible` on something
the app draws covers the same ground less directly.

**A toolchain that now includes a JVM.** ~450 MB across Temurin 21 and the 315 MB `maestro.zip`, in a Swift project.
Both are disabled on a Linux checkout, where there is no simulator to drive.

## Consequences

The repository has no XCTest bundle at all; every suite is swift-testing or a Maestro flow. A red flow now uploads a
screenshot and the full view hierarchy for the failing step, where a red XCUITest gave one log line.

The standing risk is unchanged and is the reason the spike is written down rather than summarised: Maestro releases
roughly monthly, its docs name no Xcode 27, and its driver has broken on Xcode point releases before. Every bump of
either is a re-run of the spike above. If the driver ever needs Maestro pinned behind a version this project needs,
the flows are pinning the toolchain, which is the opposite of what a test harness is for — revert then.
