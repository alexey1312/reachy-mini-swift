# iPhone Duo

iPhone Duo is Apple's foldable iPhone.
It has an outer display that behaves like a small iPhone,
and an inner display that is regular by regular and folds down the middle.
It shipped on 2026-10-23 on iOS 27.1.
This file records what the app does on it, what was measured, and what is left.
The work follows the iPhone Duo Agent Skill (`alexey1312/iPhone-Duo-Agent-Skill`):
a read-only scan, an SDK check, a tiered plan, then changes, each checked on the simulator.

## Toolchain

Xcode 27.1 (27A9275), iOS SDK 27.1.
The same Xcode carries the macOS, tvOS and visionOS SDKs at **27.0**,
so every iOS 27.1 API in shared code sits behind `#if os(iOS)` as well as `if #available(iOS 27.1, *)`.

**The linked SDK alone decides what iPhone Duo gives the app.**
Built with the iOS 27.0 SDK, the app is boxed beside the status bar and keeps horizontal bars.
Built with the iOS 27.1 SDK, it is edge to edge and its bars go vertical.
No Info.plist key selects one or the other.
CI therefore builds with `/Applications/Xcode_27.1.app`,
and `require_duo_sdk` (`Scripts/release-env.sh`) refuses an older iOS SDK
in `release-ios.sh` and in Xcode Cloud's `ci_post_clone.sh`.
The Xcode version of the Xcode Cloud workflow is a setting in App Store Connect,
so it has to be moved to Xcode 27.1 there.

**The iOS 27.1 simulator runtime has one device type, `iPhone Duo`.**
Both builds of it — 24A94425, which Xcode installs, and 24A94232, a separate download — say so,
and the `xcode-27` runner image matches.
That is why the snapshot references stay on iOS 27.0 with `iPhone 17 Pro` (root `AGENTS.md`).

## The scan

`duo_scan.py` over 933 source files found the app already scene-based (`swiftui-app`),
with three DUO004 and two DUO009 matches:

| Finding                  | Where                                                    | Outcome                                                                                                                    |
| ------------------------ | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| DUO004 orientation       | `FloatingViewportModifier.swift`, `dockBleed`            | **Kept.** It asks which end of the screen has no cutout, which no geometry answers, and `ReachyUI/AGENTS.md` documents it. |
| DUO009 `connectedScenes` | `FloatingViewportModifier.swift`, the orientation lookup | Fixed: the root reads its own scene (`WindowSceneHandle`).                                                                 |
| DUO009 `connectedScenes` | `WebAuthenticationBrowser.swift`, the sign-in anchor     | Fixed: the screen that starts a sign-in passes its own window; the old lookup is the fallback.                             |

Nothing names Face ID.
The phone's own camera is never used, so the camera capture accessory and the camera direction coordinator do not apply.
Widgets and a Live Activity already exist, with every Live Activity presentation, so the app has a place in StandBy.

## What the simulator showed

Measured on 2026-10-26 on the iPhone Duo simulator (iOS 27.1)
with a probe that reproduces the shell (`.sidebarAdaptable`, five tabs, an overlay reader, an optional inspector)
and with the app itself against `mise run sim-daemon`.
Poses were set with the third-party `hinge` CLI.
The probe's numbers are in points.

| Pose                          | What the shell gets                                                                                                                                                                          |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1 closed, outer portrait     | 382 × 644, safe area `l0 tr84 b34`; `toolbarVerticalEdge == .trailing`; the tab bar and every item with a symbol stand on the trailing side; a text-only "Done" stays horizontal at the top. |
| P1 with the running-app strip | The strip stays at the bottom under the vertical tab bar; the tab's bottom inset grows from 34 to 72.                                                                                        |
| P2 outer landscape            | 594 × 432; **one** side inset, 84, on the camera and bar side (`l0 tr84` or `l84 tr0`).                                                                                                      |
| P3 open flat, inner landscape | 951 × 669 display, content 867 wide; `.sidebarAdaptable` draws a **vertical tab bar**, not a sidebar; the fold is x 455.5–495.5, inactive.                                                   |
| P5 book pose                  | The fold is active at x 455.5–495.5.                                                                                                                                                         |
| P4 inner portrait             | **Not run.** The app cannot rotate the inner display: `requestGeometryUpdate` answers `UISceneErrorDomain` 101. Rotation is a Device Hub control.                                            |

Three things were wrong on the first build of `main` with Xcode 27.1:

1. **On the inner display the tab bar was drawn blurred, with the five tabs unreadable.**
   The inner display is regular by regular, so the size class sent the viewport to the inspector column,
   and the inspector drew the vertical tab bar under it.
   `.defaultTabBarPlacement(.sidebar)` moves the tabs into a 280 pt sidebar instead,
   and with the column beside it the content keeps 207 pt of 951, so it was declined.
   The fix sends the viewport to the floating window whenever the window's bars are vertical.
2. **An inspector shown on the first frames stayed on screen, empty, after the placement left it.**
   The placement goes `.column` → `.floating` within the launch.
   A probe that took an inspector away one frame after showing it lost it cleanly, so the trigger is in the app's launch.
   The column now waits until the shell knows which way its bars stand (`FloatingViewportModel.barAxisIsKnown`).
3. **The floating window rested 56 pt above an empty strip on the outer display**,
   because it made room for a bottom tab bar that stands on the side there.

Every sheet's text-only "Done" and "Cancel" stayed horizontal at the top of a vertical bar.
They now carry the iOS 26 roles (`ReachySheetDismissButton`), which give each one a symbol.
The three "more" menus moved into the bar's own overflow menu (`ReachyOverflowMenu`, iOS 27),
and the item each screen exists for ranks high (`reachyVisibilityPriority`).

**The account avatar is not a `Label`, and that was measured.**
Wrapped in one to give it a title, the toolbar drew a signed-in avatar as the word "Account"
and an expired one as its warning glyph alone:
a toolbar takes only an `Image` out of a label's icon.
It stays a custom view with an accessibility label,
and on iOS 27.1 its item asks for the vertical bar with `axisBehavior(.verticalPreferred)`.

The Maestro flows pass on the closed Duo:
`connect-gate` as it is, and `sim-daemon` after one fix that has nothing to do with the Duo:
a fresh daemon offers the first run (#169), and the flow now skips it.
Maestro reads only the **outer** display — with the device open, its hierarchy and screenshots are the outer display's,
which is black — so the flows run closed.

## Pose matrix

| #        | State                  | Result                                                                                                      |
| -------- | ---------------------- | ----------------------------------------------------------------------------------------------------------- |
| P1       | Outer, portrait        | Passed: tab bar and toolbar vertical, window at the bottom corner, flows pass.                              |
| P2       | Outer, landscape       | Passed in the probe (insets above). The app was not rotated.                                                |
| P3       | Inner, flat, landscape | Passed after the fix: tab bar sharp, content full width, window at the bottom-trailing corner.              |
| P4       | Inner, portrait        | Not run: rotation has no command. The column still applies there, beside horizontal bars.                   |
| P5       | Book pose              | Passed for the bars. What crosses the fold is the subject of the next change.                               |
| P6       | Tabletop               | Not run: rotation has no command.                                                                           |
| P8       | Split View             | Not run.                                                                                                    |
| P9       | Multiple windows       | Not run: the app does not support multiple scenes yet.                                                      |
| P10, P13 | Cameras                | Not applicable: the app uses no camera of the phone's.                                                      |
| P14      | StandBy                | Not run: StandBy is unavailable in the iPhone Duo simulator (Xcode 27.1 known issues 187708663, 187708767). |
| P16      | Physical checks        | Not run: device only.                                                                                       |

## What is left

- The fold: content and controls that a book or tabletop pose splits — the Live tab's viewport and its joystick,
  and the centred empty states.
- Multiple windows, which the user decided to enable.
- The hinge as an opt-in control of the antennas.
- App Store screenshots for both displays, required from April 2027.
