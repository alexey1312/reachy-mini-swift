# ReachyWidgetUI

Shared widget views and App Intents. Depends on ReachyKit and ReachyDesign; ReachyUI may depend on it, never the
reverse.

- **What both surfaces draw lives here, and moves down rather than up.** An extension process cannot link `ReachyUI`,
  so a view the app and the widget both render belongs in this target: `AppArtwork` and `AppArtworkTile` first,
  `AppRowLabel` after it. The alternative is two copies that drift the first time one of them is edited — which is
  exactly what the dock strip and the launcher tile had become.
- `AppRowLabel` takes an `AppRowLayout` preset rather than loose numbers, and a `ReachyStatusLabel` already built.
  Each caller keeps its own mapping from a domain state onto a `StatusTone`, so this target never grows a rule about
  what "running" should look like — `RunningAppCaption` owns that for the app, `RobotAppTileView.statusTone` for the
  widget, and they disagree on purpose: a tile is already tinted and badged, and a fourth green signal would turn the
  grid into a status board.
- **No `AppIntentsPackage` conformance anywhere, and the absence is load-bearing.** Xcode 26 extracts this package's
  intents into each executable's own `extract.actionsdata` by itself, so the conformance chain the targets used to
  declare added only an `extract.packagedata` naming this package by mangled symbol. linkd resolves that name
  against the executable and cannot for a statically linked SwiftPM module — and a Debug install keeps the code in
  `ReachyMini.debug.dylib`, which iOS 26.4's linkd still probes under the old `*.preview.dylib` name — so one
  unresolvable include made it discard the bundle's **entire** metadata (`aggregateMetadataIsEmpty`): no Shortcuts
  section, no actions, no widget configuration, on every install path including Xcode's. The buttons kept working
  because a `ControlWidgetButton` holds its intent in code. Measured by reading linkd's log on the simulator either
  side of removing the conformances (`log show --predicate 'process == "linkd"'`);
  `Scripts/check-appintents-metadata.sh` fails on a reappearing `extract.packagedata`, so it cannot come back
  quietly.
- `RobotAppQuery.entities(for:)` restores saved configuration: never access the network or omit requested identifiers,
  because WidgetKit prunes missing selections. Live refresh belongs in `suggestedEntities()`.
- **An integer literal in `@Parameter(size:)` means _exactly_ that many, and it is a requirement the widget cannot
  render without.** `IntentCollectionSize` is `ExpressibleByIntegerLiteral` onto `init(exactly:)`, so
  `size: [.systemSmall: 2]` compiles to `min: 2, max: 2`. A robot with one installed app can then never satisfy the
  configuration, and the only symptom is the widget sitting in WidgetKit's redacted placeholder forever — no error,
  no crash, no "Edit Widget" that can be closed, and no buttons, because a placeholder has none. Write
  `.init(min: 0, max: n)`. The trap survives every test this repo has: previews render `RobotAppsWidgetView`
  directly, so nothing in `Metadata.appintents` is exercised by the snapshot suite. What does catch it is reading the
  built metadata — `python3 -c "import json; print(json.load(open('Apps/DerivedData/Build/Products/Debug-iphoneos/ReachyWidget.appex/Metadata.appintents/extract.actionsdata'))['actions']['RobotAppsConfigurationIntent']['parameters'][0]['typeSpecificMetadata'][1])"`
  — or adding it to a Home Screen.
- Extension processes are disposable; persist pending and failure state in App Group stores and reload affected
  timelines rather than relying on memory.
- On iOS 18, widget and Control Centre intents cannot open the app with `openAppWhenRun`; use `widgetURL` where an
  app-opening fallback is needed.
- **An intent's metadata does not localize; everything else here does, its dialogs included.** `AppIntent.title`,
  `DisplayRepresentation` and the widgets' `configurationDisplayName` stay bare `LocalizedStringResource` against the
  main bundle, because that metadata is baked into `Metadata.appintents` at build time, where a runtime bundle URL has
  nothing to resolve against. An `IntentDialog` handed back from `perform()` is not extracted at all — it is built
  while the intent runs — so it takes `.reachy(_:)` like every rendered string. Reasoning in
  `Sources/ReachyDesign/AGENTS.md`.

## The intents, and who each one is for

Five protocols with no session around them — `RobotPower` (in `ReachyKit`), `RobotAppLauncher`, `RobotAppRelease`,
`RobotSleep` and `RobotShutdown` — and one piece of bookkeeping, `RobotAppCommand`. Each has a twin in `RobotSession`,
and the twins are not shared code on purpose: a session reads its own cached state and reports each failure onto a
screen, while an intent has seconds, one client, and one sentence. Say which is which in the doc comment when adding
the next pair.

- **`RobotAppRelease` is the step both parking intents take first, and `RobotSleep` exists because of it.** Neither
  `move/play/goto_sleep` nor `daemon/stop` says anything to the app manager, so an app left running has the motors
  taken out from under it and dies on its next command — sleeping had to grow the same step powering off already
  had. It could not go into `RobotPower`: that one holds a `RobotAPIClient`, knows nothing about apps, and adding
  one would put the app manager inside the wake sequence too. **The wait is the part that is easy to drop**: a 200
  from `stop-current-app` is not the app letting go, so the reading is what says the robot is free. `.widgetIntent`
  cuts that budget to six seconds against the session's thirty, which is a real trade — the session waits for a slow
  stop, an intent gives up and parks anyway rather than being killed with nothing written down.
- **`RobotAppLauncher.stop()` parks the robot at zero and must never sleep it.** An app leaves the head wherever its
  last frame put it, and the daemon does not pick it up (`.claude/rules/daemon-api.md`). The session restores what
  the robot _was_ — asleep, if it woke it for the app — but that memory is in-process, and it must not become a
  shared App Group record: it would be the first one with two writers and no arbitration, and unlike
  `MovePlaybackRecord` it would _authorise a motion_ on the strength of something written by a process that has since
  died. So an intent offers the one restoration it can defend, and the app's own poll performs the fuller one
  whenever it is running. The `goto` is one request and no wait — the daemon answers with a task id and plays the
  move afterwards — so it fits the 15 s budget where a `goto_sleep` plus its animation would not.
- **`RobotAppCommand` is the bookkeeping half and there are four callers**: the widget tile and Shortcuts' start,
  stop and toggle. Pending state, the snapshot write and both timeline reloads live there once. A caller with no tile
  behind it (`StopRobotAppIntent`) passes no `appID` and files no pending caption — `RobotAppLaunchState` is keyed by
  app, and "stop whatever is running" names none.
- **`RobotAppTileIntent` and `ToggleRobotAppIntent` do the same thing and must stay two types.** The tile's takes
  plain `String`s so a widget button never depends on metadata extraction; the Shortcuts one takes a
  `RobotAppEntity` so the picker exists. The tile's is the one that is `isDiscoverable = false`.
- **`isDiscoverable = false` does not remove an intent from `Metadata.appintents`** — it is recorded there as a flag.
  Reading the built metadata to check what Shortcuts offers means reading `isDiscoverable`, not looking for an
  absence:
  `python3 -c "import json; d=json.load(open('Apps/DerivedData/Build/Products/Debug-iphoneos/ReachyMini.app/Metadata.appintents/extract.actionsdata')); print({k: v['isDiscoverable'] for k, v in d['actions'].items()})"`.
  The same file's `autoShortcuts` is the extracted `ReachyShortcuts`, phrase templates and parameter presentations
  included — the only way to see that a parameterized phrase compiled into anything.
  **Release runs this check automatically**: `Scripts/check-appintents-metadata.sh` asserts the six Shortcuts-facing
  actions, a non-empty `autoShortcuts` and the appex's configuration intent, from every Release build task and from
  both release archives before upload. It exists because extraction failing is a warning, never a build error —
  TestFlight 0.1.1 archived green and installed with no actions in the Shortcuts app at all.
- **`RobotAppLauncher` reads the running app exactly once per call.** Every path goes through one private
  `runningApp()` and none may add a second `currentAppStatus` — the whole budget is a few seconds.
  `RobotAppLauncherTests.readsTheStatusOnce` holds that line.
- **Every headless surface owes the way back up from Power off, and none of them had it.** `RobotShutdown` tears the
  backend down, and everything behind `get_backend` — `motors/*` included — then answers 503. So `WakeRobotIntent`
  sent `motors/set_mode` at a robot that could only refuse, and the widget's tile did the same through
  `RobotAppLauncher`: powering off from Control Centre or Shortcuts worked, and nothing but the app's own Wake up
  button could undo it. `RobotPower.resume()` (in `ReachyKit`) is the fix and **`daemon/start?wake_up=true` is what
  makes it fit the budget** — the daemon enables the motors and plays the animation itself once the backend is up, so
  one accepted call is the whole sequence and nothing has to be polled. A cold start is ninety seconds; an intent has
  seconds, so neither the intent nor the tile waits for it. The intent says so in its dialog and the tile refuses with
  `Failure.startingBackend` rather than racing the start.
- **A snapshot can say "awake" and be believed; it cannot say "asleep".** `RobotSnapshot.isAwake` is false for a
  parked robot _and_ for a torn-down backend, and those take opposite sequences — so `RobotAppLauncher` skips the
  status read only on `assumeAwake == true`, and asks the daemon for anything else. The round trip that saves is
  still at most one either way, which is the invariant `asksTheDaemonWhenUnsure` measures.
- **A running app has no title, so nothing may speak the daemon's word for one.** `AppManager.start_app` files the
  status as `AppInfo(name=…, source_kind=INSTALLED)` with an empty `extra`, so `RobotApp.title` off a
  `current-app-status` or a `start-app` reply _is_ the Python entry point — Siri saying `dance_party` where the store
  says "Dance Party". `RobotAppTitles` is the join, keyed by entry point name against the cache `RobotAppQuery`
  already fills; the two entity-taking intents use `app.title` and skip it. **A stub will not catch this**:
  `StubAppsClient.status(name:title:)` injects a `cardData.title` no real robot sends, which is the same
  fixtures-carry-metadata trap that hid the app-settings row for a release
  (`Sources/ReachyUI/AGENTS.md`). `RobotAppTitlesTests.aRunningStatusCarriesNoTitle` pins the premise itself.
  `RobotAppLauncher.Failure.busy` still names the app the daemon's way, and is the one sentence left to join.
- **The Home Screen icon's menu is not here and cannot be.** It is UIKit's, not App Intents'; `ReachyQuickAction` in
  `ReachyUI` owns it and explains the split. Nothing declared in this target reaches it.
