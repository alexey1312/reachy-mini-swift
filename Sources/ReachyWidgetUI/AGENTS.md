# ReachyWidgetUI

Shared widget views and App Intents. Depends on ReachyKit and ReachyDesign; ReachyUI may depend on it, never the
reverse.

- **What both surfaces draw lives here, and moves down rather than up.** An extension process cannot link `ReachyUI`,
  so a view the app and the widget both render belongs in this target: `AppArtwork` and `AppArtworkTile` first,
  `AppRowLabel` after it. The alternative is two copies that drift the first time one of them is edited — which is
  exactly what the dock strip and the launcher tile had become.
- **The macOS menu bar is the third surface, and it reads storage rather than a session.** `MenuBarContent`,
  `MenuBarContentView` and `MenuBarModel` are the popover behind `MenuBarExtra`; only the _scene_ is macOS-specific
  and it lives in the app target. `MenuBarContent` composes `RobotWidgetContent` and `RobotAppsWidgetContent` and
  **decides nothing** — the awake/asleep asymmetry, the staleness gloss, the tile states and the notice precedence are
  already decided next door, and restating any of them is how the popover and the widget start disagreeing on the same
  Mac. The one new piece is `refreshDates`, the deduplicated union of both halves: both file the running app's expiry,
  so without it the model wakes twice for one boundary.
  - **It reads the App Group stores because a session's lifetime is a window's.** `RobotSession` is `@State` inside
    `ReachyRootView`, so it exists only while a window does — and the whole point of a menu bar item is to still be
    there once the window is closed. Hoisting the session to the `App` would hold a 10 s sweep, a 3 s poll and a
    WebSocket open with nothing on screen. Nothing is lost: the session writes those same stores whenever a window is
    open, and when none is, `RobotWidgetContent` already says "Last seen …" rather than guessing.
  - **`MenuBarModel` is the timeline a `MenuBarExtra` does not have.** It re-reads on four triggers — the popover
    appearing, the app becoming active, a command returning, and each moment `MenuBarContent.refreshDates` files —
    and **nothing polls**: with no transition pending and the reading settled into stale there is no later moment to
    schedule, so it goes idle. Its `robot:` seam exists because `RobotIntentTarget.knownRobot` reads `KnownRobots.all`
    from a static that takes no injected defaults, so a model given a throwaway suite would still be told there is no
    robot.
  - **It has no error slot, and none is missing.** Every command writes its own failure to the transition store before
    it throws, and `RobotWidgetContent` renders that as the detail line with the button still on it — so the refresh on
    the way out _is_ the report, in the words the widget already uses. `isBusy` covers the window before the pending
    caption lands, since the marker is written inside the command's own prologue.
  - **"Running" is `.active` here and `.idle` on a tile, and that is the rule rather than an exception.** This target
    never grows a shared mapping from a domain state onto a tone. A tile is tinted, weighted and badged already, so a
    fourth green signal would make the grid a status board; a popover row has none of those, and the caption is the
    only thing naming which app holds the robot.
- **The widget extension now has a Mac destination, and it carries only half of itself there.** `ReachyWidget` is
  `destinations: [.iPhone, .iPad, .mac]`, so a macOS build embeds
  `ReachyMini.app/Contents/PlugIns/ReachyWidget.appex` and the Mac gets `RobotStatusWidget` and `ReachyAppsWidget`.
  Two things stay behind, and neither is a preference:
  - **The nine Control Centre controls are `#if os(iOS)`.** `ControlWidget` is _not_ iOS-only any more —
    the SDK says `@available(iOS 18.0, macOS 26.0, watchOS 26.0)` — but this app deploys to macOS 15, so the
    ceiling is the deployment target. Raise it to 26 and they can return behind an availability check rather than a
    platform check. Issue #60 predates that and still calls the type iOS-only.
  - **The three `accessory*` families are `@available(macOS, unavailable)`.** They are Lock Screen and StandBy
    surfaces the Mac does not have, so naming one in `supportedFamilies` fails the Mac build outright.
    `RobotStatusWidget.supportedFamilies` builds the list up rather than writing one literal, because **`#if` is not
    legal inside a container literal** — it fails as "expected expression in container literal", which reads as a
    typo rather than as a grammar rule.
  - **The entitlements became two files.** A macOS app extension must be sandboxed, and
    `com.apple.security.app-sandbox` is a macOS-only key that fails an iOS build against any provisioning profile —
    the same split, and the same reason, the app target already documents. The Mac file **does** carry
    `com.apple.security.network.client`, and the tempting reasoning against it is wrong: the extension does more than
    read the snapshot, because `RobotWidgetView` and `RobotAppsWidgetView` draw `Button(intent:)` and an interactive
    widget button runs its intent in _this_ process, which then reaches the robot over plain HTTP. Without the key the
    sandbox refuses that connection before it leaves — the button does nothing and says nothing, the same silent shape
    `.claude/rules/networking.md` records for `network.server` and WebRTC. No `network.server`: no ICE here, so
    nothing arrives unsolicited.
  - **It signs, installs and registers — measured, not assumed.** The mise tasks pass `CODE_SIGNING_ALLOWED=NO`, so
    they prove compilation and embedding only. A signed build needs `DEVELOPMENT_TEAM` **and**
    `CODE_SIGN_STYLE=Automatic` (a Tuist project sets neither, and without the style every target fails as "requires
    a provisioning profile", including ones whose profiles already exist). With both, Xcode mints
    `Mac Team Provisioning Profile: com.alexey1312.ReachyMini.Widget` on demand — **the App Group needs no manual
    macOS registration**, because the App ID already carries it from iOS. The signed appex came out with
    `app-sandbox`, the group and `network.client`, and `pluginkit -m -p com.apple.widgetkit-extension` then lists
    `com.alexey1312.ReachyMini.Widget`. Check entitlements with
    `codesign -d --entitlements :- <path>.appex | plutil -p -`, never by the exit code.
  - **Still unmeasured: how it looks.** No reference image covers a Mac widget or the menu bar item — the suite
    renders views, never a desktop — so the Mac gallery and the popover's AppKit chrome are a device check.
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
- **`RobotEntity` contributes an identity and never an address.** A shortcut is written once and persists whatever
  entity it captured, while the same robot answers at a different address tomorrow (rule 4) — so
  `RobotIntentTarget.knownRobot(id:)` looks the robot up in `KnownRobots` when the intent _runs_, and the entity's
  `host` exists only to tell two robots apart in the picker. A named robot the app has since forgotten throws
  `.noKnownRobot` rather than falling through to the first in the list: a shortcut that silently retargets is worse
  than one that says it cannot run.
  - **The parameter is optional on all six existing intents, and that is what kept their phrases working.** An
    unfilled optional is not requested, so "Wake up Hey Reachy" still means the last robot connected to; naming one
    is the addition, not the requirement. Adding it is still a change to `Metadata.appintents` — read the built
    file rather than trusting a green build.
  - **`RobotEntityQuery` touches no network, unlike `RobotAppQuery`.** There is nothing to ask: the list _is_
    `KnownRobots`, and a robot is not less known for being switched off. Reachability is the intent's problem —
    hiding an unreachable robot here would mean a shortcut that cannot be written while the robot naps.
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
- **The status widget's button is one control chosen from the reading, and the rule is asymmetric on purpose.**
  `RobotPowerControls` argues against a state-driven control because a `StaticControlConfiguration` has no data
  behind it and cannot expire — that reasoning does **not** transfer to a widget, which corrects itself on a
  schedule: `RobotStatusProvider.getTimeline` already files an entry at the freshness boundary. What decides it is
  the snapshot asymmetry recorded below — awake may be believed, asleep may not. So `.sleep` is offered only off
  `isAwake == true`, and `.wake` off everything else including a stale reading, because `RobotPower.resume()`
  resolves both meanings of a false `isAwake` itself and because an imperative is not a claim about the present.
  A transition in flight offers nothing at all; `.unknown` offers nothing and lets the tap fall through to
  `widgetURL`. **`Widget — no robot` is the reference that proves the button is conditional**, and it came back
  byte-identical when the button landed — which is also what made the other 76 movements readable.
  - **A _configurable_ control may draw a name, and that does not reopen the argument.** `PlayMoveControl` and
    `ToggleRobotAppControl` (`Apps/ReachyWidget/Sources/RobotActivityControls.swift`) read their own saved
    configuration through an `AppIntentControlValueProvider` that touches nothing — no robot, no cache, no network —
    so what they draw is what the reader chose, which cannot go stale the way a reading can. They stay imperatives
    all the same: the button says which move it plays, never whether one is playing. `ToggleRobotAppControl` is the
    "toggle the running app" #66 asks for and is deliberately **not** a two-state toggle, for the reason
    `RobotPowerControls` gives.
  - **A configurable control's parameter and its action are one intent, unlike a widget's.** A widget's
    configuration decides what a _view_ draws and the tap runs something else (`RobotAppsConfigurationIntent` then
    `RobotAppTileIntent`); a control has no view to decide, so its configuration **is** its argument and
    `MoveControlConfigurationIntent` / `RobotAppControlConfigurationIntent` perform the work themselves — through
    `RobotMoveCommand` and `RobotAppCommand`, sharing nothing with their Shortcuts twins but the command.
  - **They are the first widget buttons that depend on metadata extraction**, which is the trade a picker costs.
    `RobotAppTileIntent` takes plain `String`s precisely so a tile never does; a control's Edit sheet has no such
    option, because the system builds it out of `Metadata.appintents`. Both are therefore in
    `Scripts/check-appintents-metadata.sh`'s `REQUIRED_APPEX_ACTIONS` beside the widget's — being
    `isDiscoverable = false` does not keep an intent out of that file, it records a flag in it.
  - **`.promptsForUserConfiguration()` is not decoration.** Without it an unconfigured control's first tap reaches a
    `perform` that throws `needsValueError()`, and Control Centre has nowhere to prompt from — the reader gets a
    button that fails silently.
  - **`invalidatableContent()` here takes no condition, unlike the tile's.** A pending tile is still on screen, so
    `RobotAppTileView` can key the flag off its state; this button is gone the moment a transition is pending, so a
    condition off `isPending` would be false at every call site and switch the dimming off rather than drive it. The
    tap it has to cover is the one that _starts_ the transition, when nothing is pending yet.
- **`RobotPowerCommand` is the power half of `RobotAppCommand`, and it closed a gap older than the button.** No
  power intent used to write a snapshot or reload a timeline, so waking from Control Centre left the widget saying
  "Asleep" until the app next ran. Four callers now share it: Control Centre, Siri, Shortcuts and the widget.
  - **`recordRunningApp` cannot record a wake.** It is one reading of one question and clears the app fields when
    handed nils — right for sleeping and powering off, which release the app first, wrong for waking, which stops
    nothing. `RobotSnapshotStore.recordPower` is the writer that moves the motors alone.
  - **`.startingBackend` writes nothing about the motors and stays pending.** `resume()` waits for none of a 90 s
    cold start, so `isAwake: true` there would be the widget's version of pretending the job is done.
- **`RobotPowerTransitionState` is `RobotAppLaunchState` with one rule that one does not have.** A pending marker is
  **superseded by a snapshot taken after it started**: the extension is not running to clear its own marker, so a
  wake tapped on the widget and finished with the app open would otherwise say "Waking up…" for the rest of the
  window. Its windows are per transition, because a cold start outlives a wake by minutes and one window would be
  wrong for one of them. `failureWindow` deliberately _references_ the launcher's constant rather than restating it.
- **Every moment `RobotWidgetContent.refreshDates` files lands a millisecond _past_ its boundary, the freshness one
  included.** Each entry is rebuilt from the stores at its own date, and `RobotSnapshotStore.state(at:)` calls the
  boundary itself fresh (`treatsTheBoundaryAsFresh` pins that) — so an entry filed at exactly `takenAt + freshness`
  comes back saying "Awake" and the reading is never retired, leaving the hourly policy as the next thing that
  could. A reading carrying an app hides the mistake, because that app's own expiry lands a millisecond later; an
  idle one has no later entry at all. `schedulesTheStalenessFlipPastTheBoundary` therefore asserts on the state
  rebuilt at that date rather than on the date itself, so it fails the way the widget does.
- **The status widget's layout is handed in, never read from `\.widgetFamily`.** That environment key defaults to
  `.systemMedium` outside a widget, so a view reading it would draw every small preview card wide.
  `RobotStatusWidget` is the one place the family is read — the same division `ReachyAppsProvider.limit(for:)` draws.
  `.systemMedium` had **no reference at all** before this and rendered the compact layout stretched over twice the
  width; every widget preview was pinned to 158×158.
  - **`layout(for:)` was a ternary, and that made adding a family a silent bug.** `family == .systemSmall ?
    .compact : .wide` sent every family nobody had thought about to the 338 pt row — so declaring
    `.accessoryCircular` would have rendered that row inside a 76 pt ring with nothing to say it had. It is an
    exhaustive `switch` now, and `default` still answers `.wide` because `WidgetFamily` grows on its own schedule;
    that is the safe end of the mistake rather than the silent one, since a family nobody declared cannot be
    installed.
  - **The three accessory families carry no wake/sleep button**, and only one of them could not. `.accessoryInline`
    is a single line the system builds itself out of a `Text` and an `Image`, and a `Button` in it is discarded; the
    other two are a decision — a 76 pt ring holding a capsule has nothing left to say what the robot is doing. The
    whole surface falls through to `widgetURL`, so a tap opens the Robot tab, where the button is.
  - **Each family shows a different half of the reading, and the first recording is what decided which.**
    `.accessoryRectangular` is the only one with room for both, so it draws the robot's name over its state.
    `.accessoryCircular` draws the glyph and **nothing else**: it carried `content.title` at first and the reference
    came back with "kitchen" clipped to "kitcher" — 76 pt less padding is 68, and `minimumScaleFactor` gave up
    before the name did. The symbol already encodes the state, which is what `symbolName` is chosen for, so the
    words are spoken to VoiceOver instead of drawn. `.accessoryInline` shows `detail` rather than `title`, because
    that line sits beside the clock and the robot's name is the one thing its owner already knows.
  - **What the accessory references prove is the layout and the wording, not the rendering.**
    `AccessoryWidgetBackground` is a system material and a material does not render headless — the same rule the
    rest of `ReachyDesign/AGENTS.md` records for glass. The vibrant treatment the Lock Screen applies, and whether
    each family is legible under it, is a device check. `supportedFamilies` is not covered at all: previews render
    `RobotWidgetView` directly, never through WidgetKit, which is the same blind spot that once hid
    `@Parameter(size:)`.
- **An intent's metadata does not localize; everything else here does, its dialogs included.** `AppIntent.title`,
  `DisplayRepresentation` and the widgets' `configurationDisplayName` stay bare `LocalizedStringResource` against the
  main bundle, because that metadata is baked into `Metadata.appintents` at build time, where a runtime bundle URL has
  nothing to resolve against. An `IntentDialog` handed back from `perform()` is not extracted at all — it is built
  while the intent runs — so it takes `.reachy(_:)` like every rendered string. Reasoning in
  `Sources/ReachyDesign/AGENTS.md`.

## The intents, and who each one is for

Seven protocols with no session around them — `RobotPower` (in `ReachyKit`), `RobotAppLauncher`, `RobotAppRelease`,
`RobotSleep`, `RobotShutdown`, `RobotMovePlayer` and `RobotSoundPlayer` — and **still** three pieces of bookkeeping,
`RobotAppCommand`, `RobotPowerCommand` and `RobotMoveCommand`. Each has a twin in `RobotSession`,
and the twins are not shared code on purpose: a session reads its own cached state and reports each failure onto a
screen, while an intent has seconds, one client, and one sentence. Say which is which in the doc comment when adding
the next pair.

- **`RobotMovePlayer` exists because both of the daemon's move traps are silent.** A play route never touches the
  motor mode, so an asleep robot accepts it, plays the sound and does not move; and `play_move` takes its guard
  non-blocking, so a play issued over a running move is accepted, answered with a plausible UUID, and moves nothing.
  Waking and clearing the slot are therefore not politeness — without either, the intent reports success over a robot
  that did nothing. Both are pinned by mutation: delete the wake and `wakesBeforePlaying` goes red, delete
  `clearTheFloor` and three tests do.
  - **The wake-up animation is a move task, so it is cleared like any other.** `RobotPower.wake()` waits for it, but
    that wait is bounded and returns normally when the budget passes; someone who asked for a dance asked for the
    dance, not for the stretch in front of it.
  - **Parking is skipped between two moves and performed after a stop**, which is the one flag `clearTheFloor` takes.
    A `goto` is a move task of its own, so parking between them would occupy the slot the next play needs — the same
    rule `RobotSession.clearTheFloor` follows.
  - **`RobotMoveCommand` keeps less bookkeeping than its two siblings, deliberately.** A move is not a state
    `RobotWidgetContent` draws, so there is no pending marker and no timeline reload for the move itself. What it
    does write is `MovePlaybackRecord` — the app's only way to name a move that is already playing, since
    `GET /api/move/running` answers with task ids alone — and a snapshot **only when the call woke the robot**.
- **`RobotSoundPlayer` is the fourth of these with no `Command` beside it, and the absence is the entry.** Its three
  siblings exist to write a snapshot, file a pending marker or reload a timeline. A sound is none of those:
  `RobotWidgetContent` has no place for one, playing wakes nothing, and there is no equivalent of `MovePlaybackRecord`
  to keep — no route reports a sound as playing, so there would be nothing true to write down. What was left is the
  connection budget, and that lives on the player as `perform(robot:_:)` rather than in a type with nothing else in it.
  - **It deliberately does none of what `RobotMovePlayer` must.** No wake, no `clearTheFloor`, no parking: the speaker
    is not a motor, so a parked robot plays perfectly well; a sound is not a move task, so it occupies no slot and
    there is nothing to park. It also needs no readiness probe, because a torn-down backend answers `play_sound` with
    an honest 503 — the one refusal on that surface that reports itself.
  - **What it does check is presence, and that is why it exists at all.** `play_sound` answers `{"status": "ok"}` for
    a name that matches nothing, and uploads live in `/tmp` — so a shortcut naming a sound the robot lost over a
    restart would report success into silence for ever. The listing is one round trip, spent on the failure that is
    silent instead of on the one that answers.
  - **An intent never uploads, and that is a budget decision rather than a missing feature.** Sending a sound again
    means reading bytes out of the App Group library and posting up to 25 MiB into a GStreamer probe the daemon
    budgets at five seconds; a control has a few seconds in total. So `Failure.notOnRobot` names the sound and points
    at the Sounds screen, which is the one place that can fix it.
- **`MoveEntity`'s identifier is the whole move, and `SoundEntity`'s is its filename — the two that resolve with no
  cache.**
  `dataset#move`, because the daemon gives a move no id at all and a dataset name is itself `owner/name` (so a slash
  would have to be read from the right as a convention). `RobotAppEntity` cannot do this — its id is a Space slug
  that means nothing until it is joined against an installed list — which is why a year-old move shortcut still runs
  against a sleeping robot and an app one does not.
  - **`MoveEntityQuery` reads the cache and never writes it.** Listing costs a Hugging Face round trip _per dataset_
    and there are three, so a live top-up would make the picker wait on the robot. Writing is worse than slow:
    `RobotSession.persistMoveIndex` carries `moveIndexTakenAt` across each write so the record ages as one unit, and
    a second writer stamping `Date()` would re-date every library the app had merely read off disk — the index would
    then never expire. The cost of reading only is that a library nobody has opened in the app is absent from the
    picker.
  - **`SoundEntityQuery` goes one step further and reads no cache either** — the list is this device's own library
    (`SoundLibraryStore`), so it is instant, needs no network from a process with seconds, and is the superset: the
    robot's copy is whatever survived its last restart. The cost is a sound that is _only_ on the robot, uploaded from
    another device; it is playable from the app's screen and absent from this picker, because nothing in this process
    could have the bytes to send it again.

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
  - **`RobotAppControlConfigurationIntent` is a third, and it is not one too many.** A control's argument has to be a
    `ControlConfigurationIntent` — that is the type the system builds an Edit sheet from — so it can be neither of
    the two above whatever it takes. All three share `RobotAppCommand` and nothing else, which is the rule rather
    than the exception here.
- **`isDiscoverable = false` does not remove an intent from `Metadata.appintents`** — it is recorded there as a flag.
  Reading the built metadata to check what Shortcuts offers means reading `isDiscoverable`, not looking for an
  absence:
  `python3 -c "import json; d=json.load(open('Apps/DerivedData/Build/Products/Debug-iphoneos/ReachyMini.app/Metadata.appintents/extract.actionsdata')); print({k: v['isDiscoverable'] for k, v in d['actions'].items()})"`.
  The same file's `autoShortcuts` is the extracted `ReachyShortcuts`, phrase templates and parameter presentations
  included — the only way to see that a parameterized phrase compiled into anything.
  **Release runs this check automatically**: `Scripts/check-appintents-metadata.sh` asserts every Shortcuts-facing
  action, a non-empty `autoShortcuts` and the appex's four configuration intents, from every Release build task and
  from both release archives before upload. It exists because extraction failing is a warning, never a build error —
  TestFlight 0.1.1 archived green and installed with no actions in the Shortcuts app at all. **A new discoverable
  intent owes that list an entry**, or its extraction can fail in a release and nothing goes red.
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
  - **And it may only be believed about the robot the command is aimed at.** There is one snapshot, it describes
    whichever robot the app last talked to, and an intent now names its own — so every `assumeAwake` goes through
    `RobotSnapshotStore.freshReading(for:)` rather than reading `.fresh` directly. Without that check "Play the
    happy dance on _the other robot_" took the connected robot's `isAwake`, skipped the wake, and the daemon
    accepted a play over disabled motors: the sound, no motion, and a dialog saying it was playing. Passing `nil`
    is what the widget's own buttons mean and is unaffected.
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

## The two that answer instead of commanding

`RobotAwakeIntent` and `RunningAppIntent` (`RobotStatusIntents.swift`) are the only intents here that reach no robot
at all: the answer is already in the App Group snapshot, written by whichever process last spoke to one. No
`RobotIntentTarget.connection`, no timeout budget, and no failure mode beyond having nothing to report — which is
also what makes them safe in the extension's own process, the one with no screen to raise a Local Network prompt
from.

- **A snapshot may be believed when it says awake and never when it says asleep**, and a _spoken_ answer is where
  that finally bites. The widget's tile glosses a false `isAwake` as "Asleep" and gets away with it, because the one
  word sits beside a wake button that resolves both meanings by itself (`RobotPower.resume()`). A sentence is the
  whole answer somebody gets, so `RobotStatusReport` says **not awake** and names both readings — parked motors are
  a motor mode, a stopped backend is a ninety-second job, and sending someone to the wrong one is the failure.
  `refusesToChooseBetweenAsleepAndOffline` is the test; delete the second half of that sentence and it goes red.
- **`freshReading(for:)` is deliberately not what these call.** It collapses stale and wrong-robot into one `nil`,
  which is right for a caller about to _command_ a robot and wrong for one about to _describe_ it — "I have no
  reading" and "my reading is old" are different answers. `RobotStatusDialog` uses `state(at:)` and makes the robot
  check itself, so a stale reading survives as stale.
- **Every sentence stays a `LocalizedStringResource` until `IntentDialog` takes it.** Flattening to `String` first
  and handing that back would put the finished sentence through format substitution a second time — and a robot's
  name is free text somebody typed, so a robot called "100% Reachy" is all it takes. Interpolating into the resource
  keeps the name an argument rather than part of the key.
- **`ReachyShortcuts` is now at ten of ten.** The next intent worth speaking has to displace one; the system takes
  the first ten and drops the rest without saying so. **`PlaySoundIntent` and `StopSoundIntent` are the first two to
  be turned away by that**, deliberately: displacing a working phrase for a new one is a trade nobody asked for. They
  are discoverable in Shortcuts, indexed as `SoundEntity` rows, and available as Control Centre buttons — everything
  but the spoken form.

## Entities in Spotlight

`EntityIndexing.swift` conforms `RobotAppEntity`, `MoveEntity` and `SoundEntity` to `IndexedEntity` (iOS 18 /
macOS 15, this app's floor exactly). That is a **fourth** system beside the three `ReachyUI/AGENTS.md` names, and the distinction is the
point: App Shortcuts put commands in Spotlight, the icon's menu is UIKit's, `ReachySpotlightIndex` files two
destinations that open two tabs — and an indexed `AppEntity` carries its _type_, so Spotlight can pair the row with
the intents that take it. Searching for a dance offers to play it. A destination row never could.

- **The `attributeSet` is overridden for the keywords alone.** The default derives title and subtitle from
  `displayRepresentation` and stops, which indexes "Dance Party" and not `dance_party` — and the entry point is what
  the daemon's status, the robot's journal and every log line call that app. `ReachyEntityKeywords.list` also splits
  on `_` and `-`, which is what puts `dance` in as a term of its own; a search index sees `dance_party` as one token.
- The app-side half is `ReachyEntityIndex` in `ReachyUI`, which is where the delete-vs-`deleteAllSearchableItems`
  trap is written up.

## The running-app Live Activity

`RunningAppActivityContent.swift`, `RunningAppActivityView.swift`, `RunningAppActivityAttributes.swift` and
`RunningAppActivityIntents.swift` here; the decisions live in `ReachyUI` (`RunningAppActivityPlan`), and the
`ActivityConfiguration` in `Apps/ReachyWidget/Sources/RunningAppActivity.swift`. Issue #61.

- **A Live Activity is not a widget, and the one difference decides the whole design: it has no network and no
  timeline.** It runs in its own sandbox over whatever the app last handed it, inside a **4 KB** ceiling for
  attributes plus state together. A widget can correct itself on a schedule; this cannot correct itself at all. With
  no push entitlement in this project, the content freezes the moment the app stops getting processor time — one
  poll cadence after the phone goes in a pocket.
- **So `staleDate` is the only scheduled state change a card ever gets**, and it is spent on the one moment that
  matters for the state being written: `RobotSnapshotStore.freshness` for a running app, `startingDeadline` and
  `stoppingDeadline` for the two transitions, `actionFailureWindow` for a refusal. Each is **named**, never restated
  as a number — the running one has to equal the widget's boundary or the same Lock Screen carries two claims about
  one robot, which is what `MenuBarContent` exists to prevent.
- **`isStale` means one thing: no reading has arrived since T. Never a verdict.** The flip is a timer, not a
  reading, so a frozen card may not say "stuck", "failed" or "unreachable" — `RunningAppModel.refresh` already
  refuses to time a transition off a read that did not arrive, and this is the same rule on a surface nobody is
  watching. What it may say is the app it last saw, the robot's name, the **age of the reading**, and Stop.
- **The age is the one self-updating element, and elapsed run time is deliberately absent.** `Text(_, style:
  .relative)` measures this device's clock against a date this device stamped, so it goes on being true with no
  process. A run _duration_ would not: `RobotAppStatus` carries `app`, `state` and `error` and nothing else — the
  daemon reports no start time — so "running for 4:12" would count from when this phone first looked, which is right
  only when this phone started the app. No progress bar either: **a bar may only be drawn against a duration the
  robot promised**, and `startingDeadline` is a timeout while the end of a stop is a SIGKILL.
- **`ActivityAttributes` are fixed at request time, which is why a different app replaces the card rather than
  renaming it.** The app's identity — title, artwork — lives there because it is what does not move for the life of
  one run. The case is a poll race rather than the ordinary path: the daemon runs one app at a time, so A→B with no
  idle reading in between means the poll missed a 1.5 s gap.
- **The Stop button is a fourth intent sibling, not a conformance on `StopRobotAppIntent`.** `LiveActivityIntent`
  relocates execution into the _app's_ process, and that one is a deliberate extension citizen — 15 s budget,
  `network.client` in the Mac entitlements, four shipped callers. Same argument that keeps `RobotAppTileIntent`,
  `ToggleRobotAppIntent` and `RobotAppControlConfigurationIntent` three types. `isDiscoverable = false` does not keep
  it out of `Metadata.appintents`, so it owes `Scripts/check-appintents-metadata.sh` an entry, and it has one.
- **No Stop button for a robot known only over the relay.** `RobotIntentTarget.connection` dials a LAN address by
  design, so `canStop` is written by the app at every update and the card draws no button when it is false — falling
  through to `widgetURL`, the same choice the three accessory families already made.
- **Everything decidable is in `ReachyUI` and nothing decidable is behind the `#if`.** ActivityKit is iOS-only and
  `mise run test` is SwiftPM on macOS, so a rule inside the fence is a rule no test can hold. Two files import
  ActivityKit here and both are adapters. **Only `mise run build:app:ios` compiles any of it**; the check that it
  really did is `nm …/ReachyWidget.appex/ReachyWidget.debug.dylib | grep RunningAppActivity`, which is silent on a
  macOS build.
- **What no reference image can prove**, and it is most of the surface: the Lock Screen's real height against the
  160 pt truncation point, every Dynamic Island presentation, StandBy, the Watch and CarPlay, whether `staleDate`
  flips when claimed, and that the system ends a card at eight hours. The previews render `RunningAppActivityView`
  directly, never through ActivityKit — the same blind spot `supportedFamilies` already has.
