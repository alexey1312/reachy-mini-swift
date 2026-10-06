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
- **Every hand-written JSON call goes through `JSONCodec`** (`ReachyJSON`), naming `.daemon`, `.web` or `.stored`.
  There is no default profile on purpose: a default is how thirty files ended up taking Foundation's settings without
  deciding to. `.stored` is frozen — records from shipped builds are on disk, and a changed strategy makes them
  undecodable, which every store here reports as an empty cache rather than as an error. The generated OpenAPI client
  is outside all of this: `Converter` builds its own `JSONDecoder` with no injection point. Reasoning and the
  swift-yyjson measurements: `docs/adr/0004-one-json-codec.md`.
- `RobotAPIClient` supplies throwing defaults for everything except `handshake`, `daemonStatus`, `wakeUp` and
  `gotoSleep` — every test double must implement those four. `/wifi/*` and `/update/*` live on separate protocols so
  doubles for the connection surface stay small.
  **A throwing default is not a way to say "this client cannot"**:
  to a screen gating on something else it looks exactly like a real surface.
  The audio levels and the test sound were defaults throwing `URLError(.unsupportedURL)`,
  Settings drew its Audio section for the in-app simulator because that one reports its backend ready,
  and the section printed "NSURLErrorDomain error -1002" —
  while over the relay the Test sound button answered the same.
  They are `AudioLevelClient` and `TestSoundClient` now, gated by `canAdjustAudio` and `canPlayTestSound`.
  The relay was first read as having no test sound and is a `TestSoundClient` too since #169:
  the LAN route only calls `play_sound("impatient1.wav")`, which the data channel carries by name.
  A capability the next client may lack belongs on a protocol of its own the same way.
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
  app's behalf), so parking on top of it puts two motions on one robot,
  and the daemon runs both — they write the head target in turn. Bounded by `appStopTimeout` and never fatal: a refusal is
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
  - **From 1.10.0 the daemon parks the robot itself, and over the LAN the session then sends nothing (#154).**
    A freed app slot schedules `reset_to_sleep()` 1.5 s later, and no motion or motor route cancels it,
    so either of the two parkings above would run beside it rather than instead of it.
    `daemonParksAfterApps` decides — LAN, a version known to be ≥ 1.10.0, and a media server,
    which the reset needs and `--no-media` removes —
    and `followDaemonParking` shows the daemon's sleep as `.goingToSleep` until a reading says asleep.
    The status cannot name the loop the reset runs on,
    so the media server is read off `camera_specs_name` and `media_released`,
    the state now rather than at the backend's start.
    When the reset never comes, the session parks nothing for a robot somebody else woke:
    whoever cancelled the reset owns the robot.
    A robot it woke for the app gets the sleep it was owed,
    because a daemon with no loop for the reset leaves it awake with its torque on.
    `sleep()` over a running app takes the same path (#166):
    the release it opens with is what schedules the reset,
    so it watches it under its own `.goingToSleep` through the same `watchIdleReset` —
    and, because somebody asked for sleep, chases a reset that never comes.
    The relay keeps the session's own parking, because every data-channel frame cancels the reset first.
    Why each condition holds, with the daemon's line numbers, is in `.claude/rules/daemon-api.md`.
- **The daemon has exactly one move slot and does not guard it, and everything in `RobotSession+Moves` follows from
  that.**
  `play_move` opens with `if not self._try_start_move(): return` (`backend/abstract.py`),
  and `_try_start_move` is `RLock.acquire(blocking=False)`.
  Every HTTP, WebSocket and data-channel route runs `play_move` as a coroutine on the one event-loop thread,
  so the lock is re-entrant there and the guard never refuses.
  A second play is accepted and **runs beside the first**:
  the two write the head target in turn at 100 Hz, and the second `play_sound` restarts the music,
  so the robot jerks as if every command came twice.
  The daemon's own comment says "a double-tap is a no-op"; it is not, on any version from 1.9 to `main`.
  So every move the daemon runs is stopped before a play, not only the one this session remembers:
  `clearTheFloor` calls `MovePlaybackClient.stopRunningMoves()`,
  which on the LAN lists `GET /api/move/running` and stops each uuid,
  and over the relay reads `get_state`'s `is_move_running` and sends one `stop_move`,
  because the relay can name only the move it started itself.
  A move that will not stop throws, and the play is not sent.
  `releaseMove` runs the same sweep before `goto_sleep`,
  and the parking claims its phase before its `goto` is sent, so no library row is live while it runs.
  Whatever is added next owes the same.
  - **The relay's `stop_move` is awaited by its command, never by its `stopped` key.**
    The ack is `{"status": "ok", "command": "stop_move", "stopped": …}`,
    and the channel routes a frame by `command` before any other key,
    so a wait on `stopped` never matched and sat out the whole reply budget after the robot had stopped.
  - **A play that times out may still start.**
    Both move routes load the dataset before they answer, and the daemon preloads only the two Pollen libraries
    (`DEFAULT_DATASETS`); a cold load of the Music one took about 15 s.
    So the LAN index and play ride `hubClient`,
    and after a timeout `playMove` reads the running list once and adopts what it finds —
    named after the play when it is the only task, since the floor was cleared just before.
    Over the relay the handle outlives the timeout, so `runningMoveUUIDs` can confirm it.
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
  The UUID is `nil` while the `goto` is in flight:
  `recentre` claims the phase before it sends the request,
  because a row tapped before the reply played beside the parking — over the relay, for the whole walk.
- **Parking is followed by the same poll as a dance, never timed against `recentreDuration`.** A `goto` can be
  cancelled — `playMove` does exactly that — or fail, and the phase has to end when the task does. It is also skipped
  in three places on purpose: between two dances (it would run beside the second), after a stop the daemon rejected
  (the move is still running), and while the robot is asleep (motors disabled, so the task travels nowhere).
- **`RobotSession.swift` is at SwiftLint's file and type limits.** Recorded moves moved out to
  `RobotSession+Moves.swift` when adding parking crossed both at once. New session behaviour belongs in a
  `RobotSession+<Feature>.swift`, not in the class body.
  `+Moves` reached the file limit in turn, and adoption moved out to `RobotSession+MoveAdoption.swift`;
  the relay's moves live in `RemoteRobotConnection+Moves.swift` for the same reason.
- **The app catalogue and the move index outlive the process, in the app group's
  `Library/Caches/ReachyMini/catalogue`.** `Cache/` holds one
  `RobotCatalogueCache` actor with two slots, not two stores: both need the same atomic write, the same
  identity-keyed layout and the same eviction, and all they differ in is payload and freshness — which is exactly
  what `RobotCatalogueRecord` carries (apps 24 h, the same window and the same "menu, not reading" argument as
  `RobotAppsCache`; moves 7 days, because only Pollen publishing a dance changes a dataset index). It differs from
  `GeometryCache` in three deliberate places, each written up beside the code: no manifest marker (one file, so
  `.atomic` makes completeness free), softer eviction (four robots, not one) and a refused
  oversized write that leaves the previous record standing rather than erroring.
  - **The group container is what makes an App Intent able to read it**, and it used to be the process's own
    `Caches`. An extension has a caches directory of its own, so `MoveEntityQuery` — which answers out of the moves
    slot — found an empty directory there and offered Shortcuts a picker with nothing in it. The apps slot never
    showed the bug because the widget reads `RobotAppsCacheStore`, which was in the group suite already. A bundle
    naming no group falls back to its own `Caches`, the same degradation `KnownRobots.defaults` makes, and nothing
    is migrated across the move: every record here is recoverable from the robot.
  - **The catalogue is stored whole, as `[RobotApp]`, not as `RobotAppSummary`.** The widget's `RobotAppsCache` keeps
    five fields because a widget installs nothing; a screen has to draw a card from this and `installApp` hands the
    object back to the daemon unchanged, so a field lost here is a field the robot would never receive.
  - **Whole means megabytes, and the first ceiling was set from a guess.** Measured against a Wireless robot on
    2026-08-12: `list-available` answers 406 apps in 3.74 MB and the record encodes to **3.84 MB**, of which 3.2 MiB
    is `extra.siblings` — the Hub's file listing per Space, which nothing in this app reads and the daemon uses only
    as Check 2 of `_find_metadata_for_entry_point`. `maxRecordBytes` was 2 MB, so **every** write was refused and the
    cache stored a catalogue not once between shipping and 2026-08-12; the only trace was a `warning` nobody was
    reading, which is why it looked like a cache that did nothing rather than a cache that was told no. It is 8 MB
    now, and four robots of it is what the eviction window costs. The guard against the next round of this is a test
    fixture built to the measured size (`storesACatalogueTheSizeARealRobotAnswers`), not the log line.
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
- **The sound library is two libraries, and the robot holds the throwaway one.** `SoundboardClient` is the capability
  (`PresenceClient`'s shape: conforming _is_ the capability, so a relayed session reports it unavailable rather than
  failing a button), `RobotConnection+Sounds` the four routes, `SoundLibraryStore` the device's own copy. What decides
  the whole design is that uploads land in `/tmp/reachy_mini_sounds` and `GET /api/media/sounds` lists that directory
  and nothing else: a reboot empties it, no route returns a sound's bytes, and the built-in assets are playable by name
  but not enumerable. So the device owns the library and the robot is a cache in front of it — measured facts and the
  two-stage upload validation are in `.claude/rules/daemon-api.md`.
  - **`play_sound` answers `{"status": "ok"}` for a name that matches nothing**, the same shape `wobbling/enable` has.
    Every play in this app is therefore preceded by a listing — `SoundboardModel.play` sends the file first when the
    robot is not known to have it, and `RobotSoundPlayer` refuses by name. Delete either and the feature reports
    success into silence for ever, which is the one failure mode this surface has and the only one it cannot report.
  - **`SoundLibraryStore` is in `Library/Application Support`, not `Caches`, and that is the whole distinction.**
    Everything under `Cache/` is recoverable from the robot; a sound the user imported is not, because `/tmp` is the
    volatile copy. It is also the one store here **not keyed by robot identity**: a library belongs to a person, not
    to a unit, and keying it per robot would make a second robot start empty for no reason a reader could name.
  - **A name is refused, never sanitised.** The filename _is_ the identity — it is the play argument, the delete path
    component and `SoundEntity.id` — so a silently rewritten one makes the device's copy and the robot's two different
    sounds and a saved shortcut point at neither. `RobotSound.isSafeName` covers what each of those three places
    would break on, beside `basename` and `isAllowedExtension` — the daemon's rules belong to the value, not to the
    store that keeps it.
  - **The upload is the one hand-written `multipart/form-data` in the repository** (`SoundUpload`), on `hubData`'s 35 s
    session rather than the 3.5 s generated client: the daemon runs a GStreamer probe its own comment budgets at five
    seconds. The generated multipart payload was the alternative and is a drop-in; it was not taken because nothing
    here had exercised it, while these bytes are asserted exactly by `StubURLProtocol.bodies(for:)` and were posted at
    a real robot before being trusted. The client-side extension and size checks exist so a 25 MiB body is never put
    on the network to be refused — and the size one is the only cap there is, since the daemon's is declared and never
    applied.
- **`robotError` is the robot's connection and power, and nothing else.** It was `lastError`, every funnel in the
  session wrote to it, and that is the second half of the same bug: a genuine Apps failure surfaced on the Robot tab
  too. Now `withClient`, `withAppsClient`, `withWiFiClient`, `withHFAuthClient` and `withUpdateClient` only throw —
  no assignment, and **no `robotError = nil` on success either**, because a listed catalogue is no evidence that the
  robot woke up. `playMove` throws and `stopMove` returns `[String]` for the same reason. The writers are
  `RobotSession+Power` and `RobotSession+Connect`, through `report(_:)`, and that is the whole list. Connection and
  power live here because they have no screen of their own — they are the state of the robot rather than of a
  feature. Everything else belongs to the model behind the screen that asked;
  `RobotSessionErrorOwnershipTests` is what holds the line.
- `BLECommand` is the whole set the robot answers — anything else comes back as `ECHO:`. On daemon 1.9.0 that
  includes `SET_NAME`: its dispatch has no such branch, and it does not mount `POST /api/daemon/robot-name` either —
  that route postdates the release, so on 1.9.0 a robot cannot be renamed at all. `handshake` probes the route and
  reports `supportsRename`; the field is greyed out rather than left to 404 on save.
  1.10.0 adds both (#1298), and `BLELink.rename(to:)` reads the echo as `.unsupported` rather than as a failure —
  it is the only way to tell the two apart before the robot is on a network, which is where onboarding names it.
- **The conversation surface is one capability with two arms, and the LAN one multiplexes.**
  `ConversationClient`/`ConversationChannel` (`Session/`) is the capability — conforming _is_ it, the
  `DaemonLogClient` shape — with `ConversationRPCClient` dialling the app's own port and
  `RemoteConversation` going through the daemon's JSON-RPC relay. Both vend **one**
  `AsyncStream<ConversationEvent>`: the merge is unavoidable on either arm (three `broadcasts(ofType:)` over the
  relay, a fan-out table over one socket on the LAN), so it belongs below the protocol rather than in every
  consumer — and order between the notifications is meaning, which separate streams do not have.
  `canControlConversation` composes the conformance with `predatesRelayCommands`, exactly as `canControlRunningApp`
  does and for the same reason.
  - **`ConversationRPCClient` is an actor because a transcript is a call per frame.** It was a socket per call, and
    its own doc named the trigger for changing: push-to-talk sends `conversation.mic` twice per utterance, and a
    WebSocket handshake between letting go of a button and the robot ceasing to listen is latency nobody can
    explain. The five fields carry the same names as `RemoteControlChannel` so a reader of one knows the other; the
    socket follows demand (`!listeners.isEmpty || inFlight > 0`), so a screen holding a channel pays for one
    connection, a dock tapping a button pays for one per tap, and an abandoned channel holds nothing even if
    `close()` was never reached. `ConversationRPCRequestTests` proves both halves by counting the server's accepted
    connections — one test would pass against a server that could only count to one, so there are two.
  - **Every stream here uses `AsyncStream.makeStream`, never the builder form.** The builder closure is what a
    closure capturing the escaping continuation nests inside, and that shape sends `ClosureLifetimeFixup` into a
    walk it does not return from. An actor has no `withLock` to nest either, which is the structural half of the
    same guard.
  - **`RemoteControlChannel.Failure.rpc(code:message:reason:)` was appended so three screens could stop being one
    string.** `throwIfRPCError` folded the code and the reason into prose, so `-32601` (this build has no such
    method — retire the control), `not_running` (the app is gone) and `app_unavailable` (there and silent) were
    indistinguishable over the relay. `errorDescription` composes the identical sentence, and a test pins it: no
    screen's wording changed. `ConversationFailure` is the shared vocabulary both arms throw, with `-32601` mapped
    in exactly one initialiser so the two cannot drift.
- **The relay has a store of its own, and it is narrower than the LAN's on purpose (#158).**
  `RobotAppsClient` carries two flags that part only over the relay:
  `offersAppStore` is the daemon's own store — installed list, jobs, removals, updates, the startup app —
  and `installsFromCatalogue` is `apps.install`, one call answered at the end.
  `RobotSession.canBrowseApps` is either; `canInstallFromCatalogue` carries the 1.10.0 gate.
  - **The catalogue is the Hub's, read by this device**, because the relay has no listing verb:
    `HubAppCatalogue` runs the very query `apps.install` searches, so every card is installable by name,
    and `RemoteRobotConnection.availableApps()` answers with it.
    Each slug is listed once, as the most-liked Space carrying it, because that is the one the daemon resolves:
    a fork's card would install somebody else's app and then read as installed.
    That puts it through `RobotSession.appCatalogue()`, which is why that function **persists only when
    `canManageApps`** and `warmCatalogues` **warms only then**:
    the record on disk is the daemon's own list, installed rows and all,
    and over the relay it would be a list nothing can confirm, or overwritten by one that has nothing installed.
    An install over the relay still forgets that record, for the reason every LAN job does.
  - **The relay's status reply carries no `source_kind`**, so a running app is decoded from its three fields
    rather than as an `AppInfo`, which threw for every running app until this change —
    the reply shapes are in `.claude/rules/daemon-api.md`.
    Every relay test double had built the status itself, which is how that shipped:
    `RemoteRobotAppsTests` decodes the daemon's own bytes.
  - **A silence after `apps.install` is unknown, but a dead relay is not**, and the plain protocol cannot tell the
    two: both leave it answering. One `apps.status` can, since the relay runs each frame in a task of its
    own — asked before the install, so pollen-robotics/reachy_mini#1421 costs ten seconds rather than a sheet held
    for three minutes, and after a silence, for a relay that died meanwhile.
    That second probe is `RemoteControlChannel.call`'s own, after any timed-out call:
    `.relaySilent` needs `get_version` to answer and `apps.status` to stay silent.
    `get_version` alone named a slow `apps.stop` or a slow app a dead relay, with the advice to restart the robot.
    `apps.stop` also waits 30 s, not the reply budget, because the daemon answers it only after the app exits.
  - **`offersRestart` is a third flag for the same reason.** There is no `apps.restart`,
    and a Restart left on a throwing default was a button answering `NSURLErrorDomain -1002` —
    unreachable only while the decoding bug kept the relayed dock empty.
- **`FirstWakeUpClient` is the data channel's alone, and that is the daemon's doing, not a gap here.**
  The robot keeps one `first_wake_up_completed` flag that Pollen's apps gate their first-run wizard on (#157),
  and it is answered by `process_command` alone:
  no daemon up to `main` has a REST route, and `/ws/sdk` runs `set_first_wake_up` while answering nothing.
  **The LAN reaches it through a data channel of its own** —
  the robot builds one for a peer on its `:8443` signaling exactly as for one from central —
  which the UI opens through `FirstRunServices.openLANChannel`, because a peer connection is `ReachyMedia`.
  Where that does not open in eight seconds, `FirstRunRecordStore` is the fallback the owner chose:
  a robot this device meets for the first time (captured in `settle` before `KnownRobots.remember`, or one set up
  over Bluetooth a moment ago) is offered the run, one left pending is offered it again, and one settled either way
  is never opened a channel for again — so the WebRTC wait is a once-per-robot-per-device cost.
  **The session reads it inside `settle`, before `phase = .connected`, for the reason `warmCatalogues` runs there**:
  the root's fork picks the first run or the shell on `.connected`,
  and a flag learned a moment later would draw the shell and then take it away (#169).
  `offersFirstRun` is the result, gated on `predatesRelayCommands` —
  a 1.9.x robot is not worth a peer connection, and on the LAN its record decides;
  a failed read over the relay offers nothing, and no failure is reported.
  `finishFirstRun()` is the only write, and it withdraws the offer **before** writing,
  so a relay gone quiet cannot hold the owner on the last screen over bookkeeping they never see.
  `isWritingFirstRunFlag` is true for the length of the write,
  because on the LAN the write travels on the channel the root closes once nothing holds it.
  This device records the robot as settled only after the robot confirms the write.
  `wake()` no longer writes it — #157 had it do so, and the first run wakes the robot partway through.
  When a route lands, `RobotConnection` conforms and nothing above the protocol moves.
- **`SleepPosition` is the one check that can see a wiring mistake before the motors are powered** (#169).
  It compares the snapshot's `head_joint_positions` and `antennas` with the cranks that hold `SLEEP_HEAD_POSE` —
  not the daemon's `SLEEP_HEAD_JOINT_POSITIONS`, a more forward-tilted pose some 47° away on two neck motors —
  and `SleepPositionTests` re-derives those targets through `StewartIK`, so they are a cache of a solve.
  The bands and the hysteresis are Pollen's mobile app's, the swap rule the desktop wizard's;
  both apps' figures are hardware guesses until a unit settles on them.
