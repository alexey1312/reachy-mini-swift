# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Bug Fixes

- Pin project task to mise's tuist binary by @alexey1312

- Parse host:port user input in RobotAddress by @alexey1312

- RobotScreen link row stretched to fill the form by @alexey1312

- Wake/sleep motor power and connecting to a stopped daemon by @alexey1312

- Drop the ATS-blocked .home probe, reach a local daemon from the simulator by @alexey1312

- Unblock the simulated daemon's GStreamer plugin scan by @alexey1312

- **test**: Stop the readiness race test racing the CI runner by @alexey1312

- **test**: Wait on conditions in the throttle test, not on durations by @alexey1312

- **spike**: Render a missing simulation flag as an em dash by @alexey1312

- **ui**: Stop the viewport backdrop from tinting the floating tab bar by @alexey1312

- Grey out the robot name field on daemons that cannot rename by @alexey1312

- Keep a remote session's control channel alive across re-negotiation by @alexey1312

- Let the Control Centre buttons actually run by @alexey1312

- **ui**: Stop pinning colours in the live viewport, and its camera to one scene by @alexey1312

- **scene**: Place the head at the height the daemon reports  by @alexey1312 in [#3](https://github.com/alexey1312/reachy-mini-swift/pull/3)

- **ui**: Stop the Moves tabs showing the previous library's rows  by @alexey1312 in [#4](https://github.com/alexey1312/reachy-mini-swift/pull/4)

- **ui**: Pin the asleep status to the top of the Live tab  by @alexey1312 in [#5](https://github.com/alexey1312/reachy-mini-swift/pull/5)

- **tooling**: Avoid reinstalling tracked LFS hooks  by @alexey1312 in [#13](https://github.com/alexey1312/reachy-mini-swift/pull/13)

- **ui**: Stop the sweep from wiping the Hugging Face robot list  by @alexey1312 in [#16](https://github.com/alexey1312/reachy-mini-swift/pull/16)

- **errors**: Show every failure on the screen that caused it  by @alexey1312 in [#20](https://github.com/alexey1312/reachy-mini-swift/pull/20)

- **apps**: Name a wedged app slot, and say why the daemon refused  by @alexey1312 in [#26](https://github.com/alexey1312/reachy-mini-swift/pull/26)


### Documentation

- Close phase 0 — on-device checks passed on iPhone 17 Pro by @alexey1312

- Log console copy/export design spec by @alexey1312

- Correct the state stream rate and the kinematics porting rule by @alexey1312

- Record the SwiftPM/app-target split and the one-RealityView rule by @alexey1312

- Record the daemon backend gate and device-build identifiers by @alexey1312

- Cover package consumption and third-party licenses by @alexey1312

- Record the tuist working-directory, bundle and caching traps by @alexey1312

- Record this session's tooling and test-flake lessons by @alexey1312

- Fix the ReachyUI platform floor and the silent sim-test skip by @alexey1312

- Spec the known-robots list on the connection screen by @alexey1312

- Correct the sim-daemon Bonjour claim and record the preview-compilation trap by @alexey1312

- Write down the relay and correct a note that overstated itself by @alexey1312

- **readme**: Present the app as Hey Reachy and catch the status up to reality

- **readme**: Add live-robot screenshots


### Features

- Initial project skeleton — tooling, ReachyKit transport core, CI by @alexey1312

- Sim-daemon task on pinned python 3.12, resolve O-1/O-2 research questions by @alexey1312

- Live simulator integration — recorded fixtures, gated sim tests, WebRTC signaling research by @alexey1312

- Tuist app project with phase-0 spike screen by @alexey1312

- Phase-1 connection core — RobotSession, discovery in ReachyKit, ReachyUI screens by @alexey1312

- Live teleop controller — SetTargetClient + joystick UI by @alexey1312

- Recorded moves screen — dances, emotions, music libraries by @alexey1312

- Daemon log console by @alexey1312

- Network resilience — path monitor, auto-reconnect, forget robot by @alexey1312

- Improve playback and robot discovery by @alexey1312

- Daemon compatibility policy, stream diagnostics, pinned simulator by @alexey1312

- Webrtc camera and two-way audio by @alexey1312

- Gate robot controls on backend and motor state by @alexey1312

- Log console copy, export, search and lossless pause by @alexey1312

- 3d robot viewer driven by the live state stream by @alexey1312

- Solve the Stewart platform's passive joints for the 3d viewer by @alexey1312

- Stage the connection and gate it on real backend readiness by @alexey1312

- Persistent robot viewport with a 3D/camera switch and audio levels by @alexey1312

- **tasks**: Add inspect:bundle for tuist bundle-size analysis by @alexey1312

- Provision, onboard and recover a robot over Bluetooth by @alexey1312

- Snapshot every screen state and browse them in a storybook by @alexey1312

- Keep known robots in the connection list with a live reachability status by @alexey1312

- Install apps on the robot and reach it from anywhere by @alexey1312

- Put the robot's state on the Home Screen and in Control Centre by @alexey1312

- Smooth every teleop movement and let the joystick turn the body  by @alexey1312 in [#6](https://github.com/alexey1312/reachy-mini-swift/pull/6)

- **widget**: Let the Home Screen start the robot's apps  by @alexey1312 in [#7](https://github.com/alexey1312/reachy-mini-swift/pull/7)

- Make relay sessions fully interactive  by @alexey1312 in [#8](https://github.com/alexey1312/reachy-mini-swift/pull/8)

- Run device builds with one command, and cover the widget in CI  by @alexey1312 in [#9](https://github.com/alexey1312/reachy-mini-swift/pull/9)

- **ui**: Add unified content loading states  by @alexey1312 in [#10](https://github.com/alexey1312/reachy-mini-swift/pull/10)

- **ui**: Show running app dock across the interface  by @alexey1312 in [#11](https://github.com/alexey1312/reachy-mini-swift/pull/11)

- **widget**: Tell the Home Screen when an app crashed  by @alexey1312 in [#12](https://github.com/alexey1312/reachy-mini-swift/pull/12)

- **repowise**: Add for check by @alexey1312

- **design**: Add a design system, one string catalogue and a tab shell  by @alexey1312 in [#14](https://github.com/alexey1312/reachy-mini-swift/pull/14)

- **permissions**: Make refused access visible and actionable  by @alexey1312 in [#18](https://github.com/alexey1312/reachy-mini-swift/pull/18)

- **apps**: Follow the conversation app's semantic turn state  by @alexey1312 in [#19](https://github.com/alexey1312/reachy-mini-swift/pull/19)

- **files**: Browse and change the robot's own files over SFTP  by @alexey1312 in [#22](https://github.com/alexey1312/reachy-mini-swift/pull/22)

- **power**: Tear the robot's backend down from the Robot screen  by @alexey1312 in [#25](https://github.com/alexey1312/reachy-mini-swift/pull/25)

- **shortcuts**: Reach wake, sleep, power off and every app from outside the app  by @alexey1312 in [#27](https://github.com/alexey1312/reachy-mini-swift/pull/27)

- **viewport**: Morph the floating window into its edge tab  by @alexey1312 in [#28](https://github.com/alexey1312/reachy-mini-swift/pull/28)

- **app**: Draw the Hey Reachy icon and accent colour


### Miscellaneous Tasks

- **tuist**: Move off the deprecated Tuist initializer by @alexey1312

- Point tooling at the renamed repository by @alexey1312

- Compile the app target, guard tool drift, automate dependency bumps by @alexey1312

- Report real build failures and unbreak the app-build job  by @alexey1312 in [#1](https://github.com/alexey1312/reachy-mini-swift/pull/1)

- Generate the storybook playbook before tuist, unbreaking project generation by @alexey1312

- Remove leftover scratch_diff.txt from the repository root  by @alexey1312 in [#29](https://github.com/alexey1312/reachy-mini-swift/pull/29)


### Other

- **deps**: Update mise, hk and swiftlint by @alexey1312

- Merge pull request #2 from alexey1312/feat/known-robots-list

Keep known robots in the connection list with a live reachability status by @alexey1312 in [#2](https://github.com/alexey1312/reachy-mini-swift/pull/2)

- Float the live viewport and redesign the connection flow  by @alexey1312 in [#15](https://github.com/alexey1312/reachy-mini-swift/pull/15)

- Reach an app's own settings, clear the robot's caches, forget every network 

* fix(ui): stop the running-app sheet printing the crash twice

The sheet's State row inlined `RobotAppStatus.error`, which the daemon
fills with its own summary line plus the tail of the app's stderr rather
than the single traceback line the type documented. Under a two-line
limit that rendered `Process exited with code 1 / INFO: connection
rejected (403 For…` — the opening of the very output printed in full two
rows below it, under a heading that promised a state.

`RunningAppCaption.label` now takes a `Failure`. The dock passes
`.inline` because its one caption line is the only place a crash can be
read; the sheet passes `.shownSeparately` and leaves the tail to
`failureRow`.

The references never caught it because `previewCrashed` was a single
`ModuleNotFoundError` line, and a one-line tail renders identically
whether a surface prints it once or twice. It is a real multi-line tail
now, so `Dock — crashed`, `Running app — crashed` and
`Root — dock, crashed app` need re-recording.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016HyTiSsgV55maMf2wNfLBp

* feat(apps): reach a running app's own settings from the sheet

An app's settings were unreachable from this client: the daemon has no
route for any of them, it only reports the port the app binds
(`extra["custom_app_url"]`), and the app serves its own page there — the
conversation app logs `Serving settings UI from …/static` as it comes up.
Until now that port was used for one thing only, reading
`conversation.turn` off `/rpc`.

`RunningAppSheet` gains a Settings row onto `AppSettingsScreen`, a
`WKWebView` on `http://<robot>:<customAppPort>/`. A web view rather than a
native screen because a native one could only be written against
Conversation App 1.0's `/rpc` and would leave every other app with no
settings at all.

`RobotSession.appSettingsURL(for:)` builds the URL — the app's port, the
session's host — and answers nil without a declared port, without a LAN
address, or for a relay session. No fallback to 7860, unlike
`ConversationRPCClient`: a background stream nobody sees may guess, a row
someone taps may not. The sheet adds `state == .running` and
`isReachable`, because the process serving the page is the process that
crashes.

`.ready` gets no reference — the web view renders nothing headless and is
unmounted under `reachyPreviewMode`, and unlike `CameraViewport.streaming`
it grows no chrome to capture over it. `.loading` and `.failed` are
covered, and `Running app — conversation` gains the row while
`Running app — running` keeps the sheet without it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016HyTiSsgV55maMf2wNfLBp

* feat(settings): clear the robot's caches and forget every network

The robot's own dashboard has a Maintenance card this client had no
equivalent of, and no route in the committed OpenAPI spec explains why:
`/cache/clear-hf` and `/cache/reset-apps` mount at the app root under
`--wireless-version`, exactly like `/wifi/*` and `/update/*`, so the spec
(generated without the flag) does not carry them and the generated client
cannot reach them. Hand-written as `CacheMaintenanceClient`, gated behind
`canPerformMaintenance` so a Lite robot and a relay session show nothing.

`MaintenanceCard` puts both behind a confirmation. Only one needs a rule:
`reset-apps` is `shutil.rmtree("/venvs/apps_venv/")` and nothing else — the
daemon does not stop the running app first, so its interpreter is deleted
underneath it. `MaintenanceModel.blockingApp(_:)` refuses while an app is
busy and the card names the app to stop, and a successful reset re-reads
the current app, whose venv has just gone.

`WiFiSettingsCard` gains "Forget all" over `/wifi/forget_all`, which the
transport already implemented and nothing called. One route rather than a
loop over the rows: the per-network route answers 409 while another nmcli
operation runs.

Both `Settings — wireless robot` and the Wi-Fi card references move; five
Maintenance previews are new.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016HyTiSsgV55maMf2wNfLBp

* fix(apps): record the references, and forget what reset-apps deleted

Five things the branch was missing. The first is the one that mattered:
**no reference image shipped with it at all**, while its own commit
messages named the ones that had to move. 28 references were stale and 28
did not exist — `Dock — crashed`, `Running app — crashed` and
`Root — dock, crashed app` against the multi-line `previewCrashed` tail,
`Running app — conversation` against the new Settings row, `Wi-Fi — on a
network` and `Wi-Fi — join failed` against "Forget all", plus the seven new
previews. Nothing else in the suite moved, which is what a re-record is
supposed to look like.

`PreviewRobotClient` now speaks `CacheMaintenanceClient`. The gate reads
`client is any CacheMaintenanceClient`, so without the conformance
`canPerformMaintenance` was false in every preview and the Maintenance
section appeared in **none** of the `Settings —` references — the note
claiming `Settings — Lite robot` proved the gate was certifying a section
that was absent from both sides of it. `WiFiConfigClient` and
`DaemonLogClient` are on that client for exactly this reason. Which
reference shows it turns out to be decided by scroll position:
`Settings — backend stopped` drops the audio section and pulls Maintenance
into frame, while `Settings — wireless robot` keeps it below the fold and
correctly did not move. `MaintenanceModelTests` asks
`PreviewRemoteRobotClient` for the negative case now, which is the client a
relay actually uses.

`RobotSession.resetApps()` drops `appCatalogueCache` and
`installedAppsCache`. Both live on the session, both survive a
`load(refresh: false)`, and `rmtree("/venvs/apps_venv/")` makes every entry
in them fiction: uninstalling everything from Settings left the Apps tab
offering Open and Remove on rows the robot no longer had. It is the same
invalidation `startingJob` already does for an install or a remove, and
`MaintenanceModel`'s `refreshCurrentApp()` covers the one reading the
caches do not. Mutating the assignment away turns the new test red.

`AppSettingsScreen`'s coordinator goes through `RobotSession.message(for:)`
instead of reproducing it. `guard !isCancellation` plus `describe` behaved
identically for the reader and skipped the only place a failed call is
logged, which is the second path around that funnel `ReachyKit/AGENTS.md`
says is worth as much as no funnel at all.

Last, the branch failed `mise run lint`: `PreviewScenes.swift` sat exactly
on the 400-line limit and its enum body on the 300-line one, so the new
scene broke both, and `RunningAppModelTests.swift` went over as well. The
Settings scenes move to `PreviewSettingsScenes.swift` beside the app ones,
and the caption tests to `RunningAppCaptionTests.swift` — they test a pure
mapping and needed no model, no session and no client to begin with.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>

---------

Co-authored-by: Claude <noreply@anthropic.com> by @alexey1312 in [#21](https://github.com/alexey1312/reachy-mini-swift/pull/21)

- Give a running app its own identity, and one page to reach it 

* fix(apps): give a running app its own identity, and one page to reach it

Three faults with one origin, all of them invisible to the reference
images.

`AppManager.start_app` files a running app's status as
`AppInfo(name=app_name, source_kind=INSTALLED)` with an empty `extra`,
so the daemon reports no title, no emoji, no description and no
`custom_app_url` for the app it is running — while
`list-available/installed` carries all four under the same entry point
name. The Settings row added in #21 was therefore hidden on every real
robot: `customAppPort` was nil, and `appSettingsURL(for:)` correctly
refused. The conversation caption went on working only because
`ConversationRPCClient` falls back to 7860 and this deliberately does
not. `RobotSession.describedFromInstalled` joins the two lists, at most
one extra call per connection; an unmatched name passes through
untouched, because a wrong match would put somebody else's settings port
on this app.

`RunningAppSheet` is gone. It and `AppDetailSheet` were one object shown
as two half-pages — the split was about which models the root owned, not
about the app the reader was looking at, and the running half was missing
exactly the metadata above. `AppDetailSheet` is now the only page about
an app; the store row and the dock both open it, and which sections
appear is decided by the app's state. `AppStoreModel` and
`AppInstallModel` moved to `ReachyTabShell` so the two surfaces cannot
hold separate copies. The merge surfaced a real gap the references then
caught: Start was gated on "has a status" rather than on `isBusy`, so a
crashed app offered Dismiss and no way to try again.

`tabBarMinimizeBehavior(.onScrollDown)` shrinks the tab bar into the row
the dock occupies, so scrolling any list down with an app running took
the whole tab bar off screen. `reachyMinimizingTabBar(_:)` takes a flag
and the shell passes `.never` while the dock is up. No reference could
have caught it — nothing scrolls in a snapshot.

Only the five `Running app —` previews moved; a full re-record brought
every other reference back byte-identical.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>

* chore: drop a scratch file the pre-commit hook swept into the merge

---------

Co-authored-by: Claude Opus 5 <noreply@anthropic.com> by @alexey1312 in [#23](https://github.com/alexey1312/reachy-mini-swift/pull/23)

- Put the running-app dock in the tab accessory, so the tab bar survives 

* fix(apps): put the running-app dock in the tab accessory so the tab bar survives

With an app running there was no tab bar on screen at all. The dock was mounted
as a bottom `safeAreaInset` on the root `TabView`, on the reasoning that growing
that view's safe area would push the bar up and leave the strip below it — the
Telegram shape. A `safeAreaInset` does not shrink the frame it is applied to, and
that safe area does not cross into the tab bar's controller or into the tabs'
hosting controllers, so nothing moved. Measured with a pixel diff of the recorded
references: with the dock up the tab's content was byte-identical to the dock-free
capture for the top 63% of the frame, and the bar was absent from the image
entirely. It shipped that way in #11 and three root references have been recording
it since, read as confirming the opposite.

The strip is now the platform's own slot — `tabViewBottomAccessory`, the one Apple
Music holds its mini-player in — with a real fallback, because the API is
`@available(macOS, unavailable)` and its `isEnabled:` overload is iOS 26.1. So the
fork is not "iOS 26 or below" but "does this platform place a tab accessory": every
macOS lands with iOS 18 on a bottom inset applied to each tab's content, which is
the one place the strip lands above the bar rather than under it.

Measured on a booted iPhone 17 Pro / iOS 26.4 rather than reasoned about:

- the system draws its own glass capsule, so the strip draws no surface there — an
  opaque fill inside it renders as a second, differently rounded capsule
- an accessory with empty content on 26.0 still leaves a blank capsule and still
  holds 56 pt of safe area, which is why the native branch requires 26.1
- the slot contributes exactly 56 pt to a tab's bottom safe area (139 with, 83
  without)
- order against the floating viewport's overlay is free
- on iPad the bar is at the top and the accessory lands at the bottom of the
  content, so no second size-class branch is needed

Also here, because the fix moves what they depend on:

- the tab bar minimises again. It was switched off because a minimised bar shrank
  into the row the opaque strip occupied; the accessory is that row.
- `FloatingViewport.available(in:)` subtracted the safe area from a `GeometryReader`
  that was already inset by it, at both ends — the window sat 112 pt off, which no
  reference could show because the snapshot host zeroes the device safe area.

Reference cover: `PreviewScene.root` forces the fallback placement, because an
enabled accessory blanks the entire capture the way `.buttonStyle(.glass)` does —
recorded once without it and the root came back with no Form on it at all. The
system placement is uncapturable; the two new `Dock — inline` captures cover the
minimised row, which no root preview can reach because nothing scrolls in a
snapshot.

* test(apps): capture the dock in the system's accessory, which no root reference shows

`PreviewScene.root` forces `ReachyTabAccessoryStyle.legacy` on every root preview,
so each one renders the fallback's `.standalone`. That left `.expanded` — the shape
every iOS 26.1 device draws — with no reference at all, while three comments said
the root captures covered it.

`Dock — expanded` captures it standalone. What blanks a capture is the system's
glass container, not the placement value, and a component preview mounts none, so
the row photographs fine. The image certifies an absence: the strip must draw no
surface of its own there, and putting a background back would make it `Dock —
running`.

Also corrects `ReachyPlacedAccessory`'s note. The fallback sets no placement, so it
resolves to the key's default `.standalone` — the one shape that has to back
itself — not to `.expanded`. by @alexey1312 in [#24](https://github.com/alexey1312/reachy-mini-swift/pull/24)

- **release**: Version the app and shape it for archive


### Refactor

- **app**: Rename ReachySpike to ReachyMini and brand it Hey Reachy



