# ReachyKit

Transport + domain core. No UI imports (SwiftUI/UIKit forbidden here). Swift 6 strict concurrency.

- `openapi.json` + `openapi-generator-config.yaml` → client generated at build time by the OpenAPIGenerator plugin
  (types + client, idiomatic naming). Refresh spec: `./bin/mise run update-spec` (fetches + normalizes null-type
  anyOf branches the generator can't handle — see `Scripts/normalize-openapi.py`).
- Pydantic `Optional[X]` without a default is _required and nullable_; the normalizer must also drop such properties
  from `required`, or the generated Swift field is non-Optional and a real null throws (`DaemonStatus.backend_status`).
- WebSocket endpoints are hand-written (not in the spec) — see `Transport/`. **Every socket pump wraps `receive()`
  in `withTaskCancellationHandler`**, because `URLSessionWebSocketTask.receive()` does not observe task cancellation
  (`ConversationRPCClient.read` documents the mechanism): without the `onCancel` `socket.cancel`, a cancelled
  consumer stays parked until the robot's next frame and the socket leaks. All four stream clients carry the
  pattern — keep the next one in step, and close the socket on every exit path, not only the throwing one.
- Unknown JSON fields must never break decoding (daemon updates independently of this app).
- `RobotAPIClient` supplies throwing defaults for everything except `handshake`, `daemonStatus`, `wakeUp` and
  `gotoSleep` — every test double must implement those four. `/wifi/*` and `/update/*` live on separate protocols so
  doubles for the connection surface stay small.
- Bluetooth layers as `BLETransport` (CoreBluetooth behind a seam; `FakeBLETransport` is the only stand-in, since the
  robot's GATT service is Linux/BlueZ) → `BLECommandPump` (one command at a time, write→read→maybe-notify) →
  `BLELink` (`@MainActor @Observable`, the screens' state). One link per transport: the response characteristic
  carries no correlation id, so a second pump on the same transport would race the first for its replies. Provisioning
  and recovery are therefore two halves of `BLELink`, not two session types (`BLELink+Recovery.swift`).
- Provisioning is written against `WiFiProvisioningTransport`, not against BLE: `BLEProvisioningTransport` and
  `RobotConnection` both implement it, so the sealing and the screens are shared and the HTTP path is available if the
  ~260-byte sealed payload turns out not to fit one ATT write. `WiFiConfigClient` adds the settings-only routes.
- **`Permissions/` answers "may we", never "can we", and the two are not the same question.**
  `BluetoothPermission` reads the _class_ property `CBCentralManager.authorization`, which builds no
  central and so raises no prompt — the only way to report Bluetooth on a screen that must not ask. It
  cannot report a switched-off radio or absent hardware: `CBManagerAuthorization` has no such case, and a
  Simulator with no radio still answers `.notDetermined`. That axis stays `BLEAvailability`, and it costs a
  live central, which costs the prompt. Local Network has no status API at all, so `LocalNetworkProbe`
  observes one instead — and **`NWBrowser` reaching `.ready` is not a grant**: it gets there while the
  system prompt is still on screen. Only `PolicyDenied` proves refusal and only an arriving browse result
  proves consent; `.ready`, an empty result set and the timeout all resolve `.undetermined`. So a granted
  permission on a robot-less network reads as unknown, which is deliberate — the screen says so in words
  rather than guessing. `looksPolicyDenied` lives there and `RobotBrowser.permissionLooksDenied` forwards
  to it; there is one copy of that string match.
- `RemoteDataChannel` is the seam under a remote session, and the **end of `messages()` is terminal**:
  `RemoteControlChannel` reads it as "the session is over" and fails every waiter with `.closed`. A peer being
  replaced must therefore not end it — every WebRTC negotiation replaces the peer, the _first offer included_, so
  conflating the two broke remote control on the very first handshake and left the reader deaf for good (it now
  re-subscribes, `endReading`). `WebRTCDataChannel` splits the two: `detachPeer()` is a gap (sends go back to
  waiting, the stream lives), `close()` is an ending. `isOpen` exists for the same distinction one layer up — a
  command issued while the channel is between peers is timing a negotiation, not a robot, and gets `openingTimeout`
  (30 s) rather than the reply budget (10 s). Ask it afresh; the opening wait comes back after every ICE failure.
- A bare `Error` enum reaches the UI as `<Module>.<Type> error <n>`, where `n` is the case's **declaration index**:
  `RemoteControlChannel.Failure error 2` is `.closed`, the third case. None of these enums carry `LocalizedError`, so
  counting cases is how a screenshot names a root cause.
- **A cancelled call is not a failure, and `URLSession` disagrees loudly.** An abandoned task arrives as
  `NSURLErrorCancelled` (-999) whose entire `localizedDescription` is the word **"cancelled"** — verified against a
  real cancelled task, not the synthetic `URLError(.cancelled)`, which carries no `userInfo` and prints the generic
  NSError sentence instead. `describe` passed that word straight through, so leaving the Apps tab before the
  catalogue arrived printed it in red monospace on the robot screen. **`RobotSession.message(for:)`
  (`RobotSession+Errors.swift`) is the single filter**, and the only place daemon failures are logged: it answers
  `nil` for a cancellation, the sentence otherwise. `nil` means _leave what is on screen alone_ — an abandoned call
  learned nothing, so it may neither report a failure nor clear one still being read. Recognise cancellation by code,
  never by text, and unwrap `ClientError` first. **Never call `describe` to fill a message slot**; it does not
  filter, and a second path around `message(for:)` is worth exactly as much as no filter at all. It stays public only
  for App Intents, which have no slot to fill.
- **The daemon says almost nothing about the app it is running, so the session joins it back.**
  `AppManager.start_app` files the status as `AppInfo(name=app_name, source_kind=INSTALLED)` and no `extra` at all —
  no title, no emoji, no description, no `custom_app_url`. Every one of those is in
  `list-available/installed`, keyed by the same entry point name, so `describedFromInstalled` looks it up and
  `recordRunning` never sees the bare version. The cost is one extra call per connection: the lookup is skipped when
  `card` is already filled, and `installedAppsCache` lives exactly as long as install, remove and `reset-apps` let
  it. An unmatched name passes through untouched — a local app with no Hub card is still an app, and a wrong match
  would put somebody else's settings port on this one. Nothing above this layer should re-derive it:
  `RobotSession.runningApp`, the dock, the app page and the widget snapshot all read the joined value.
- **Both rungs of the power ladder hand the robot back first, and the wait is the part that matters.**
  `releaseRunningApp()` (`RobotSession+Power`) stops the app holding the robot and then polls until the daemon stops
  naming it — `sleep()` and `powerOff()` both go through it, because neither transition tells the app manager
  anything: `Daemon.stop` drops the media server and the JSON-RPC relay and never touches it, and
  `move/play/goto_sleep` is an animation while `motors/set_mode/disabled` is a switch. An app left running has the
  motors taken out from under it and dies on its next command, which is what "sleeping killed my app" turned out to
  be. The **wait** is not politeness: a 200 from `stop-current-app` is not the app letting go (the daemon sets
  `stopping` before any I/O and clears its own slot on the last line, past the return-to-zero it performs on the
  app's behalf), so parking on top of it puts two motions on one robot and `play_move` takes its guard
  non-blocking — one of the two silently does nothing. Bounded by `appStopTimeout` and never fatal: a refusal is
  reported and a timeout is ignored, because a head held up for the daemon's one-way `stopping` wedge is the worse
  outcome. The intent-side twin is `RobotAppRelease` in `ReachyWidgetUI`, on a much shorter budget.
- **An app start is the mirror image of that hand-back, and the daemon does neither end.**
  `apps/start-app/{name}` is **not** behind the `get_backend` dependency, so it answers 200 at a robot with no
  backend at all — the app then dies seconds later on `WSClient.wait_for_connection` — and at a _sleeping_ robot it
  starts the app over disabled motors, where every command is accepted, swallowed, and reported as `running`. There
  is no error anywhere. `RobotSession+AppLifecycle` is the client's half: `claimRobotForApp()` frees the move slot,
  wakes a parked robot and **refuses a stopped backend** rather than spending the 90 s start budget inside somebody's
  Start button; `parkAfterApp()` gives the robot back. The widget's `RobotAppLauncher` reads the same readiness and
  answers a stopped backend differently on purpose — it has seconds, so it kicks `daemon/start?wake_up=true` and says
  so. Neither may lose its half without the other gaining it, the same pact `wake()` and `RobotPower.resume()` have.
  - **`runWake(client:startingBackend:)` exists so the failure can be thrown instead of filed.** `wake()` is that
    plus `report(_:)`, which is right for a Wake up button — power has no screen. A Start that failed belongs to
    `AppStoreModel.lastError`, because `robotError` is connection and power and is not a fallback for anything. It
    also re-reads the status after the animation: `lastStatus` was fetched _before_ the motors were enabled, so
    without it `isAwake` reports a sleeping robot for up to a poll interval, and both the parking guard and the
    widget snapshot believe it.
  - **`recordRunning` is where an app is seen to let go, and the transition is what fires — never the reading.**
    Every successful status read passes through it, so the explicit Stop, a crash, a self-exit and an app that
    vanished between two polls are one case; a read that threw never arrives, so a Wi-Fi blip concludes nothing. The
    stop re-reads and the poll reads again a moment later, both legitimately seeing the same cleared slot — anything
    keyed on "is idle" rather than "went idle" parks the robot twice, which is what `parksExactlyOnce` holds.
    `resetConnectionState` writes `runningApp` directly and so fires nothing, which is correct: a disconnect is not
    a release.
  - **What the parking is depends on who woke the robot.** `AppLifecycleState.wakeOwner` is taken rather than read,
    so it is spent once; `wake()`, `sleep()` and `powerOff()` clear it, because once a person has taken the power
    decision the robot's state is theirs. A robot this session woke goes back to sleep, one the user woke gets the
    zero pose, and a power transition already in flight gets neither — `releaseRunningApp` reaches the release from
    inside a transition that is already parking, and a `goto` sent into that is the two-motions-one-slot bug again.
- **The daemon has exactly one move slot, it refuses the second caller in silence, and everything in
  `RobotSession+Moves` follows from that.** `play_move` opens with `if not self._try_start_move(): return`
  (`backend/abstract.py`) — non-blocking, no error, and the route has _already_ filed a fresh UUID through
  `create_move_task`. So a second play is accepted, answered with a plausible id, and moves nothing. Three separate
  bugs were that one fact: a relaunched app tapping over a dance it had forgotten, `goto_sleep` skipped over a
  running move while `set_mode/disabled` cut the motors mid-pose a moment later, and a parking `goto` swallowing the
  tap that followed it. `clearTheFloor` and `releaseMove` are the two ways the slot is emptied first; whatever is
  added next owes the same.
- **`GET /api/move/running` answers UUIDs and nothing else, and it does not know what a dance is.** No dataset, no
  name — and `wake_up`, `goto_sleep` and `goto` are `create_move_task` calls too, so they appear in it exactly like a
  recorded move. Two consequences, both load-bearing: a move adopted on connect gets `MovePlayback.identity == nil`
  and the screen says so rather than guessing, and the adoption is skipped entirely while `powerTransition != nil` or
  the robot's own standing-up animation reads as playback. `MovePlaybackStore` is what closes the naming gap — one
  `UserDefaults` record of the last play, matched by UUID, keyed by `RobotIdentity.deduplicationKey`. A robot woken by
  something other than this session still slips through; the monitor clears it within a poll or two, which is the
  accepted cost of covering the relaunch case at all.
- **`MoveActivity` is one value because the phases are mutually exclusive.** `currentMove` and `isStoppingMove` are
  derived from it, not stored beside it, so `.stopping` and `.recentring` cannot both be true. `.recentring` carries
  a bare UUID rather than a `MovePlayback`: parking is not playback, has no row to highlight, and must leave
  `currentMove` nil or the screen offers Stop over a move nobody started.
- **Parking is followed by the same poll as a dance, never timed against `recentreDuration`.** A `goto` can be
  cancelled — `playMove` does exactly that — or fail, and the phase has to end when the task does. It is also skipped
  in three places on purpose: between two dances (it would refuse the second), after a stop the daemon rejected (the
  move is still running), and while the robot is asleep (motors disabled, so the task travels nowhere).
- **`RobotSession.swift` is at SwiftLint's file and type limits.** Recorded moves moved out to
  `RobotSession+Moves.swift` when adding parking crossed both at once. New session behaviour belongs in a
  `RobotSession+<Feature>.swift`, not in the class body.
- **The app catalogue and the move index outlive the process, in `Caches/ReachyMini/catalogue`.** `Cache/` holds one
  `RobotCatalogueCache` actor with two slots, not two stores: both need the same atomic write, the same
  identity-keyed layout and the same eviction, and all they differ in is payload and freshness — which is exactly
  what `RobotCatalogueRecord` carries (apps 24 h, the same window and the same "menu, not reading" argument as
  `RobotAppsCache`; moves 7 days, because only Pollen publishing a dance changes a dataset index). It differs from
  `GeometryCache` in three deliberate places, each written up beside the code: no manifest marker (one file, so
  `.atomic` makes completeness free), softer eviction (four robots, not one — these are kilobytes), and a refused
  oversized write that leaves the previous record standing rather than erroring.
  - **The catalogue is stored whole, as `[RobotApp]`, not as `RobotAppSummary`.** The widget's `RobotAppsCache` keeps
    five fields because a widget installs nothing; a screen has to draw a card from this and `installApp` hands the
    object back to the daemon unchanged, so a field lost here is a field the robot would never receive.
  - **The directory name is `SHA256(deduplicationKey)` and the raw key is _also_ inside the record.** A robot's name
    is free text somebody typed, so a `/` or a `..` in it would leave the cache directory on write —
    `GeometryCache.isSafeMeshName` refuses such a name and hashing is cheaper. The copy inside the file is what makes
    a tampered directory unable to hand over another robot's menu, and `RobotCatalogueCacheTests` puts a file at the
    wrong path to prove it.
  - **`warmCatalogues` runs inside `settle`, before `phase = .connected`, and that placement is the feature.** The
    gate lifts on `.connected` and `ReachyTabShell` builds `AppStoreModel`/`MovesModel` immediately after, so the
    models seed synchronously in their initialisers. A screen `.task` runs _after_ the first frame, so a model
    reading disk itself would still draw one spinner — which is the whole thing this was built to remove. It costs
    one file read against `readinessTimeout`'s eight seconds; `finishConnected` was not an option because it is
    synchronous.
  - **Every store call is `await`ed, never `Task { … }`.** Two detached tasks against one actor have no order
    between them, so a revalidation still in flight could land its pre-install list _after_ the `remove` an install
    fired to delete it. Awaiting inside calls that are already async puts them in the order the session made them,
    and costs a suspension rather than a block — the encode happens on the actor.
  - **Install, remove, update and `reset-apps` delete the record; disconnect does not.** "The robot's app list as of
    the moment it started changing" is not old, it is wrong: `source_kind` is what the job is moving. Disconnect
    keeps it for the reason written over `RobotAppsCacheStore.clear` — a cache that dies when a robot is let go
    never survives the cold start it exists for. The move index is invalidated by nothing here.
  - **The move index keeps the date of its oldest library, and `persistMoveIndex` is where that happens.** It is one
    file, so listing any single library rewrites all of them — and since freshness is the only thing that ever
    invalidates this slot, stamping that rewrite with `Date()` re-dates every library the session merely read off
    disk. Open a different library every few days and the first one never expires. `RobotSession.moveIndexTakenAt`
    carries the warmed record's date across the write instead, so the record ages as one and costs a full re-listing
    every `freshness` — which is what every launch cost before this cache existed. The apps slot needs none of this:
    `persistCatalogue` is only ever handed a list that was just fetched whole.
  - **`catalogues` is the one `RobotSession` dependency defaulting to `nil` rather than to a real store.** The other
    three write into `UserDefaults`, which a test replaces with a suite; a file system has no suites, and a default
    of `.default` would have every `--parallel` suite sharing one `Caches` directory. The production convenience
    `init` names `.default` explicitly, and `withTemporaryCatalogueCache` is how a test gets a real one.
- **`robotError` is the robot's connection and power, and nothing else.** It was `lastError`, every funnel in the
  session wrote to it, and that is the second half of the same bug: a genuine Apps failure surfaced on the Robot tab
  too. Now `withClient`, `withAppsClient`, `withWiFiClient`, `withHFAuthClient` and `withUpdateClient` only throw —
  no assignment, and **no `robotError = nil` on success either**, because a listed catalogue is no evidence that the
  robot woke up. `playMove` throws and `stopMove` returns `[String]` for the same reason. The writers are
  `RobotSession+Power` and `RobotSession+Connect`, through `report(_:)`, and that is the whole list. Connection and
  power live here because they have no screen of their own — they are the state of the robot rather than of a
  feature. Everything else belongs to the model behind the screen that asked;
  `RobotSessionErrorOwnershipTests` is what holds the line.
- `BLECommand` is the whole set the robot answers — anything else comes back as `ECHO:`. Renaming is **not** in it:
  daemon 1.9.0's dispatch has no `SET_NAME` branch, and it does not mount `POST /api/daemon/robot-name` either — that
  route postdates the release, so on 1.9.0 a robot cannot be renamed at all. `handshake` probes the route and reports
  `supportsRename`; the field is greyed out rather than left to 404 on save.
