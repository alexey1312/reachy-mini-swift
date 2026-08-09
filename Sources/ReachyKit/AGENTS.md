# ReachyKit

Transport + domain core. No UI imports (SwiftUI/UIKit forbidden here). Swift 6 strict concurrency.

- `openapi.json` + `openapi-generator-config.yaml` → client generated at build time by the OpenAPIGenerator plugin
  (types + client, idiomatic naming). Refresh spec: `./bin/mise run update-spec` (fetches + normalizes null-type
  anyOf branches the generator can't handle — see `Scripts/normalize-openapi.py`).
- Pydantic `Optional[X]` without a default is _required and nullable_; the normalizer must also drop such properties
  from `required`, or the generated Swift field is non-Optional and a real null throws (`DaemonStatus.backend_status`).
- WebSocket endpoints are hand-written (not in the spec) — see `Transport/`.
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
