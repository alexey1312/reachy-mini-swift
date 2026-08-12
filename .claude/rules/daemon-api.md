---
paths:
  - "Sources/ReachyKit/**"
---

# Daemon API knowledge

Base: `http://<host>:8000/api`. Port is configurable in our client (upstream hardcodes 8000).

## Spec

- REST: OpenAPI 3.1 at `Sources/ReachyKit/openapi.json`; canonical source
  `https://raw.githubusercontent.com/pollen-robotics/reachy_mini/main/docs/source/API/openapi.json` (main is ahead of
  develop there). Refresh with `./bin/mise run update-spec` — it also normalizes `anyOf: [X, {type: null}]` branches
  that swift-openapi-generator silently drops (`Scripts/normalize-openapi.py`). Swagger UI at `http://<host>:8000/docs`
  when a daemon runs.
- **The committed spec describes a daemon newer than 1.9.0, so a generated call can 404 on a supported robot.** `main`
  is where it comes from, and 1.9.0 is the baseline we accept — the generator cannot know the difference, and neither
  can the version string (a newer daemon still reports `1.9.0` until it is bumped). Five routes are in the spec and
  absent from 1.9.0: `daemon/robot-name` (both verbs), `apps/start-app/{app}/no-evict`, and the three
  `hf-auth/oauth/device/*`. Diff against the robot itself (`curl http://<host>:8000/openapi.json`) before building a
  screen on a route, and gate the feature on a probe rather than on the version — `RobotConnection.handshake` reads
  `robot-name` for the display name and takes its 404 as `supportsRename = false`.
- WebSockets are NOT in the spec (FastAPI omits them). Known endpoints (from
  `reachy_mini/src/reachy_mini/daemon/app/routers/`):
  - `/api/state/ws/full` — full robot state (primary; take everything from here, REST `state/*` is fallback).
    Accepts query parameters that the spec cannot show. Defaults, read off `routers/state.py`:
    `frequency=10.0` (NOT 20 — and since the handler sleeps *after* building each frame, the real rate is a little
    lower), `with_head_pose=true`, `with_body_yaw=true`, `with_antenna_positions=true`, everything else false,
    including `with_head_joints` and `use_pose_matrix`. Modelled in `StateStreamOptions`.
    - **Never send `with_target_*`.** The frame builder asserts on them and the loop's blanket `except` swallows it,
      so the socket stays open and delivers nothing ever again. The only outward sign is a deduplicated
      `Skipping full-state frame:` line in the daemon journal. `StateStreamOptions` cannot express these on purpose.
  - `/api/move/ws/set_target` — live teleop
  - `/api/move/ws/updates`, `/api/move/ws/raw/write`
  - `/logs/ws/daemon` — daemon journal (NOTE: mounted at app root, not under `/api`, and ONLY with
    `--wireless-version` — absent on the simulator, upgrade rejected with 403)
  - `/api/apps/ws/apps-manager/{job_id}` — install/remove job stream (prefer over polling `job-status`)

## Wireless-only routes

- `/wifi/*` and `/update/*` mount at the app ROOT (no `/api`) and only under `--wireless-version`. The committed spec
  is generated without that flag, so they are absent from it and the generated client cannot reach them — hand-write
  them. A Lite robot 404s; gate on `DaemonStatus.wireless_version`.
- `/update/ws/logs` sends each line as a text frame AND then a `JobInfo` JSON frame repeating those same lines —
  decode JSON first and ignore its `logs`, or every line doubles. The job ends with `systemctl restart`, which kills
  the daemon before a terminal `done`: the socket closing is completion, confirmed by reconnecting and comparing
  versions. `available_version: "unknown"` means the ROBOT could not reach PyPI, not that the check failed.
- The daemon's own source is installed at `.venv-sim/lib/python3.12/site-packages/reachy_mini/` — read
  `daemon/app/routers/*.py` and `daemon/app/services/bluetooth/` there rather than guessing a shape. It is a
  specification (project rule 1), never code to port.
- `/wifi/*` routes, from `routers/wifi_config.py`: `GET /wifi/prov_key`, **`POST`** `/wifi/scan_and_list` (a POST
  because it rescans first; uncapped, unlike the 180-byte BLE reply), `POST /wifi/connect_sealed`,
  `GET /wifi/status`, `GET /wifi/error`, `POST /wifi/reset_error`, `POST /wifi/forget?ssid=`, `POST /wifi/forget_all`.
  Plaintext `POST /wifi/connect?ssid=&password=` exists and must never be called — the PSK would go in a query string.
- `connect_sealed` answers `400 decrypt_failed` for a wrong PIN **and** for a `kid` older than the 600 s rotation, and
  409 while another `nmcli` operation runs. It returns immediately and joins on a background thread; on failure it
  removes the connection and re-raises its own hotspot, so the reason ends up in `GET /wifi/error`, not in the reply.
- `GET /wifi/status` is `{mode: hotspot|wlan|disconnected|busy, known_networks, connected_network}` — a joined station
  is `wlan`, not `connected`, and there is **no IP address in it**. The BLE status characteristic is the mirror image:
  live address, no network names. Neither contains the other.
- `POST /wifi/forget` answers 404 for a network the robot never saved and 400 for `Hotspot`. Everywhere else in
  `/wifi/*` and `/update/*` a 404 means the route was never mounted, i.e. a Lite robot.
- **`/cache/*` is the third root-mounted wireless router**, and the easiest to miss: `main.py` guards `cache`, `logs`,
  `update` and `wifi_config` behind the same `args.wireless_version`. Two routes, both `POST`, both from
  `routers/cache.py`: `/cache/clear-hf` deletes `/home/pollen/.cache/huggingface`, `/cache/reset-apps` deletes
  `/venvs/apps_venv/`. Each answers **200 whether it deleted anything or found the directory already gone** — the
  difference lives only in an English `message` the daemon composes, so there is nothing machine-readable to branch
  on and `CacheMaintenanceClient` drops it. A failed `shutil.rmtree` is a 500 with a `detail`.
- **`reset-apps` is `rmtree` and nothing else.** It does not stop the running app, does not ask the daemon to release
  it, and puts no environment back: an app left running has the interpreter it is executing in deleted underneath it.
  Nothing on the robot prevents that, so a client that offers the button owns the guard — `MaintenanceModel`
  refuses while `runningApp` is busy and names the app to stop. It also invalidates **every** answer the session is
  holding about apps, and in two places for two reasons: `RobotSession.resetApps()` drops `appCatalogueCache` and
  `installedAppsCache` — the same pair an install or a remove job drops, because the store would otherwise go on
  offering Open and Remove on rows whose venv is gone — and `MaintenanceModel` re-reads the running app after it,
  which is the one reading the caches do not cover.
  - **It takes each app's instance data with its code, and reinstalling does not bring that back.** `.env`,
    `startup_settings.json` and `user_personalities/` live *inside*
    `/venvs/apps_venv/lib/python3.12/site-packages/<package>/`, so credentials and settings go with the `rmtree`. The
    card's copy has to say so; "every installed app, and the Python environment they share" is true and reads as
    recoverable, which is how it was lost on 2026-08-08.
  - **Nothing reports what a deleted venv used to hold**, so the list is unrecoverable over REST — after the fact only
    `journalctl` on the robot could say what had been installed. `MaintenanceModel.installedSummary` names the apps in
    the confirmation for exactly that reason: it is the last moment those names exist anywhere the user can see.
  - It has no `summary` or `description` in `openapi.json`, and the name says *cache*. Absent documentation is not
    evidence of a harmless endpoint — that inference is what turned a stuck app into lost data.
- `GET /api/daemon/hardware-id` answers one key, `{"hardware_id": "<16 hex>"}` = `sha256(usb serial)[:16]` — the same
  string as mDNS TXT `unit_id` and BLE characteristic `…cdef7`. It is a join key: never reshape it.

## Hugging Face on the robot (`/api/hf-auth/*`)

The robot's **own** account, which is not this app's — read `daemon/app/routers/hf_auth.py` and
`apps/sources/hf_auth.py` in `.venv-sim`. Linking hands the robot a copy of a token so it can register with central;
this app keeps its own in the Keychain (ADR 0003).

- `POST /save-token`, `DELETE /token`, `GET /status` → `{is_logged_in, username}`.
- `GET /relay-status` → `{state, message, is_connected}`. A Lite robot answers `state: "unavailable"` with
  "Coming soon to Lite version" — a state the relay's own enum does not contain, so decode it tolerantly.
- `POST /refresh-relay`, `GET /central-robot-status`.
- **No route ever returns the token.** `/status` answers a boolean and a username; the OAuth flow below answers a
  status and a username. Delegating sign-in to the robot therefore cannot give this app a token of its own — that was
  checked before building on it.
- OAuth on the robot: `GET /oauth/configured|start|begin|status/{session_id}|callback`, `DELETE /oauth/session/{id}`.
  `start` returns `{auth_url, session_id}` to poll; `begin` 302s straight to Hugging Face for a phone that can only
  open one URL. The default client id is Pollen's own (`71146982-…`, `HF_OAUTH_CLIENT_ID` to override) and its
  redirects point at the **robot** (`http://reachy-mini.local:8000/api/hf-auth/oauth/callback`, or localhost for Lite),
  so it cannot be reused by a client with a custom scheme.
- Daemon 1.9.0 does not mount `hf-auth/oauth/device/*` even though the committed spec has it (see the spec-ahead-of-
  firmware trap above).

## Bluetooth service

Read `services/bluetooth/bluetooth_service.py` in `.venv-sim` — the dispatch table is one `if/elif` chain and settles
most questions in a glance.

- It is **its own systemd unit** (`reachy-mini-bluetooth`, working directory `/bluetooth`), not part of the daemon.
  Every recovery script ends with `systemctl restart reachy-mini-daemon`, so the Bluetooth link survives all of them —
  including `SOFTWARE_RESET`, which erases `/venvs` while the service sits outside it. `PING` therefore proves the
  robot is there, never that a reset finished.
- The commands are exactly `PING`, `STATUS`, `JOURNAL_{START,READ,STOP}`, `PIN_*`, `UPDATE_{CHECK,START,INFO}`,
  `WIFI_{KEYEX,STATUS,SCAN,CONNECT_ENC,FORGET}`, `CMD_*`. Anything else falls through to `ECHO:`. **There is no
  `SET_NAME`** — renaming is `POST /api/daemon/robot-name`, which 1.9.0 does not mount either, so such a robot cannot
  be renamed at all: its name is whatever `--robot-name` the daemon was started with (default `reachy_mini`).
- The PIN is the last five characters of the Pollen audio device's USB serial (`38fb:1001`, read from
  `/sys/bus/usb/devices/*/serial`), compared verbatim: not necessarily digits, never case-folded. Do not uppercase the
  input field. Upstream states that serial is printed on the robot — it is **not** a separate code, and no route
  exposes it, which is the point. With no audio board attached the daemon falls back to a fixed `46879`.
- `CMD_*` clears the robot's own auth flag in a `finally`, so the PIN is needed again after every script — whether it
  succeeded or not. Its handler also returns `None` on success, so the reply encoder crashes and the GATT write
  reports an error for a script that ran perfectly.
- `_read_journal` returns `buffer[:480]` and **deletes what it returned**. One BLE read carries ~182 bytes, so the
  remainder of every large chunk is lost for good, and a line is regularly cut in half — `BLEJournalReader` carries the
  tail. The LAN journal is the authoritative one; say so in any UI that shows this.
  - The journal is a byte stream, not a message, so `BLEResponseParser` returns `.payload` **verbatim**. Trimming it
    (as every other reply is trimmed) eats the trailing newline that says the last line is complete, and the reader
    then glues that line onto the next chunk — one corrupted line per read boundary, which looks like nothing at all
    when a chunk holds a single line.
  - `journalctl` exits on its own; the GLib watch removes itself on HUP and every later read answers
    `ERROR: Journal not running`. That is a `JOURNAL_START` away from fixed, not a terminal state.
- `…cdef6` is `", ".join(...)` over the robot's `commands/` directory with `.sh` stripped, `"None"` when empty, in
  `os.listdir` order. Read it; never hardcode the list, and sort it before showing it.

## `stopping` is a one-way door, and no client can open it

Burned on 2026-08-08: `reachy_mini_conversation_app` sat in `state: stopping` indefinitely, both stop and start
answered 400, and the search for another REST way out found `/cache/reset-apps` — which deleted every installed app
and its credentials. The mechanism is entirely daemon-side, in `apps/manager.py`:

- `:283` sets `STOPPING` **before any I/O**, so a wedge anywhere after it is permanent.
- `:275-279` `stop_current_app` raises on `STOPPING` → HTTP 400 `No app is currently running`.
- `:99-106` `is_app_running()` counts `STOPPING` as alive → `start_app` answers `An app is already running`.
- `:357-369` `restart_current_app` calls both and inherits both failures.
- `:355` `current_app = None` is the **last line**, after three unbounded awaits (`process.wait()` after the kill,
  `await monitor_task`, `goto_target`). Only the 20 s subprocess wait at `:301` has a timeout. So a status that still
  names the app means the coroutine is stuck *past* the kill: the app is already dead, the slot is not.
- The robot-app lock is released in the monitor's `finally` (`:255-261`), i.e. **before** the untimed return-to-zero.
  So `robot-app-lock-status` reports `free` while `current-app-status` still names the app. Neither is lying.
- Unchanged in upstream `1.10.0.dev0`. Not fixed above us.

**No parameter exists to do this differently.** `POST /api/apps/stop-current-app` takes nothing at all — no body, no
`force`, no `timeout` (the internal `stop_current_app(timeout=20.0)` is not exposed); `start-app/{name}` takes only
its path component. `check-updates?force=` is the only `force` anywhere in the daemon.

**Nor can a client cause it.** Two hypotheses were checked and both are dead: uvicorn 0.52.1 does **not** cancel the
ASGI task when the client disconnects (`connection_lost` only sets `cycle.disconnected`, in both `h11_impl.py` and
`httptools_impl.py`; the sole `.cancel()` is the keep-alive timer, and there is no `BaseHTTPMiddleware` in the chain),
so our 35 s and 6 s budgets cannot abort a stop in flight. And `play_move` takes its guard **non-blocking** and
simply returns when a move is running (`backend/abstract.py:412`), so nothing we hold — teleop, the state stream, the
camera — can stall return-to-zero.

**`POST /api/daemon/restart` does not clear it.** It restarts the motor backend, not the FastAPI process that holds
the slot (`daemon/daemon.py:473-536`, whose own docstring says so). The only ways out are `systemctl restart
reachy-mini-daemon` — reachable from this app as BLE `CMD_RESTART_DAEMON`, which the `reachy-mini-bluetooth` unit runs
as root — the tail of `POST /update/start`, or a power cycle.

**Which await hung is answerable, from the robot's journal.** The daemon's own log lines bracket every one, so the
last `apps.manager.runner` line names the place: `App stopped successfully` → stuck on `await monitor_task`;
`App did not stop within timeout, forcing termination` → stuck on the kill/reap; `Returning robot to zero position` →
stuck inside `goto_target`; `Could not return to zero position:` → not stuck at all, the slot would have cleared.

Client-side, `RunningAppModel` puts a deadline on the two transitional states (40 s stopping, 120 s starting) and the
dock then names the wedge and refuses both controls, because the daemon can only answer 400 for either. **Only a poll
that answered advances that deadline** — an unreachable robot leaves the last status in place, and timing it as if it
were fresh reports a Wi-Fi blip as a wedged daemon. And the two are not one situation: a stuck `stopping` means the app
is dead and the slot is not, while a stuck `starting` means nothing ever ran, so `WedgedAppNotice` reads the state
rather than assuming a stop.

## An app's own control surface (`/rpc`) — not the daemon's

A robot app may serve its own settings and semantic status on a port of its own. The daemon only reports it, in
`AppInfo.extra["custom_app_url"]`, and it reports it **unresolved**: `local_common_venv._get_custom_app_url_from_file`
regex-scrapes the literal out of the app's `main.py`, so what arrives is the app's *bind* address. Conversation App
1.0 declares `http://0.0.0.0:7860/`.

- **Take the port, discard the host.** `0.0.0.0` dialled from a phone is the phone. The robot's address belongs to
  the session; `RobotApp.customAppPort` exists to make that split hard to get wrong, and the daemon's own relay
  rewrites the host to `127.0.0.1` for the mirror-image reason. The key can be absent or explicitly `null` when the
  scrape found nothing, so every caller carries a default.
- **`current-app-status` does not carry any of it.** `AppManager.start_app` builds the status as
  `AppInfo(name=app_name, source_kind=INSTALLED)` with an empty `extra`, so the running app arrives with no title,
  no emoji, no description and **no `custom_app_url`** — while `list-available/installed` has all four for the same
  entry point name. A client that reads the port off the status alone therefore never offers an app's settings on a
  real robot. `RobotSession.describedFromInstalled` joins the two; do not add a route for it, there isn't one.
- **The same port serves the app's own settings page, at `/`** — the conversation app logs `Serving settings UI from
  …/static` as it comes up. There is **no daemon route for any of it**: an app's configuration (personalities,
  voice, backend) is reachable only by dialling that port, which is why the app shows it in a `WKWebView`
  (`AppSettingsScreen`) rather than natively. `RobotSession.appSettingsURL(for:)` builds it and, unlike
  `ConversationRPCClient`, does **not** fall back to 7860: a background stream nobody sees may guess, a row someone
  taps may not, and an absent key is the daemon's only signal that an app serves no page at all.
- **The page dies with the app process.** It is served by the app, not by the daemon, so a crashed app takes its own
  settings down with it — at its worst exactly when a bad setting is what crashed it. A profile directory under
  `user_personalities/` with no `profile.md` in it does that: `Failed to initialize tools`, exit code 1, and the
  settings that would fix it unreachable until the app starts. Fix that class of thing on the robot.
- **Conversation App 1.0 speaks JSON-RPC 2.0 over WebSocket `/rpc`.** The REST `/api/v1/*` + SSE
  `/api/v1/conversation_events` of v0.10.0 is retired, not extended. It ships with SDK `1.10.0rc2` **in the app's own
  venv**, so `/rpc` answers on a robot whose daemon is still 1.9.0.
- **Consume `conversation.turn` `{state}`, not `conversation.activity` `{reason}`.** The app's own web UI subscribes
  to `activity` and maps the raw reasons itself (`static/js/orb.js`); `turn` carries the mapped
  `listening / thinking / speaking / ready`, deduplicated server-side, and the comment beside it in `console.py` says
  it is there "for clients without that mapping (mobile)". Copying the frontend is the wrong instinct here.
  Also broadcast: `conversation.transcript` `{role, text, final}`, `conversation.level` `{role, rms}`,
  `conversation.phase`. Request methods include `conversation.status`, `conversation.mic`, `conversation.say`,
  `conversation.interrupt`, `personalities.*`, `voices.*`, `backend.config`.
- **There is no initial state to fetch.** `conversation.status` returns backend/connection config, not a turn, and
  `turn` is push-only and emitted on change. A client attaching mid-conversation legitimately knows nothing until the
  next transition — `RunningAppCaption` leaves the daemon's "Running" in place, which is the correct answer, not a
  gap to paper over.
- A newer daemon relays the same frames over the WebRTC DataChannel (`daemon/jsonrpc_relay.py`), which is what a
  remote session would need. On 1.9.0 there is no relay, so `RunningAppModel.conversationStreamKey` returns nil
  without a LAN address rather than pretending.

## MVP endpoint subset (what upstream actually calls)

`daemon/status|start|stop`, `daemon/hardware-id`, `daemon/robot-name`, `state/full`, `move/set_target`,
`move/play/wake_up`, `move/play/goto_sleep`, `move/play/recorded-move-dataset/{dataset}/{move}`,
`move/recorded-move-datasets/list/{dataset}`, `motors/set_mode/{mode}`, `apps/job-status/{id}`, `kinematics/info`.

## Timeouts (from upstream `src/config/daemon.ts` — battle-tested values)

- Healthcheck request timeout: 2 s (3.5 s over Wi-Fi); status poll every 3 s (5 s Wi-Fi).
- Connected-state hysteresis: require 2 consecutive successful probes to go "connected"; downgrade immediately on
  failure.
- Job polling: 500 ms; app install timeout 60 s, remove 90 s, start 120 s; stale-job 90 s.

## Facts

- **`control_loop_stats` is the only live health telemetry the daemon publishes, and two fields beside it are dead.**
  `backend/robot/backend.py` refreshes the dictionary once a second with `mean_control_loop_frequency` (~100 Hz on
  healthy hardware), `max_control_loop_interval`, `nb_error` (cumulative since the backend started) and
  `motor_controller`. It fills them only after averaging more than one interval, so the first second of a backend
  carries a controller name and nothing else, and **only the real robot backend fills it at all** —
  `MujocoBackendStatus` and `MockupSimBackendStatus` carry a motor mode and an error and no loop, and
  `RemoteRobotConnection` synthesises a relayed status from the motor mode alone. An empty dictionary is therefore
  the normal answer for three ordinary situations, not a fault. Read through `DaemonStatus.controlLoop`.
  - **`last_alive` and `ready` are in the schema and daemon 1.9.0 never writes either.** `RobotBackendStatus` is
    built once at backend start-up with `last_alive=None, ready=False`; the control loop then updates
    `self.last_alive` — the backend's own attribute, not the status object's field — and `get_status()` refreshes
    only `error` and `motor_control_mode` before handing the same instance back. So the wire carries
    `"last_alive": null, "ready": false` for the entire life of a perfectly healthy robot, and a "last seen 3 s ago"
    row built on it reads as a robot that has never answered. Readiness is `state == .running`, which is what
    `DaemonStatus.isBackendRunning` uses.
  - **There is no CPU, memory, temperature or disk anywhere in the API.** `psutil` is a daemon dependency and is
    used only to manage processes (`apps/manager.py`) and to list network interfaces (`daemon/utils.py`); no route
    reports any of it. Those come from `/proc` and `/sys` over SSH — `ReachySSH/SystemMetricsReader` — which is
    LAN-only by construction. Do not go looking for an endpoint.
- Daemon process ≠ robot backend. `/api/daemon/status` answers 200 with `backend_status: null` while the backend is
  torn down (`daemon.stop()` sets `self.backend = None`); every route behind the `get_backend` dependency
  (`move/*`, `state/*` incl. `ws/full`, `motors/*`, `kinematics/*`, `volume/*`) answers **503 "Backend not running"**.
  `camera/*` uses `get_daemon` instead, and `/logs/ws/daemon` is mounted at the app root — both outside that gate.
- **Every motion route files a task in one module-level `move_tasks` dict**, so `goto`, `wake_up`, `goto_sleep` and a
  recorded move are indistinguishable in `GET /api/move/running` — which returns `[{uuid}]` and no other field. There
  is no route that names a running move. `POST /api/move/stop` awaits the cancellation before answering, so a 200
  means the slot is already free.
  - `/api/move/ws/updates` pushes `move_started` / `move_completed` / `move_failed` / `move_cancelled` with the uuid,
    but **only to listeners already attached** — nothing is sent on connect. Same shape as `conversation.turn`: a
    client joining mid-move learns nothing until the next transition, so a `GET /running` is needed regardless and
    the socket buys only latency. `RobotSession` polls and does not open it.
  - `POST /api/move/goto` is the "return to neutral" the daemon performs for itself after an app releases the robot,
    and **it is not all zeros** — the antennas are not, see the app-release entry below.
    **The generated Swift is not the shape the spec suggests**: `head_pose`'s `anyOf` becomes
    `HeadPosePayload` with one optional per branch (`value1` = `XYZRPYPose`), not an enum, and `antennas`
    (a `prefixItems` tuple) has no generated type at all — it arrives as `OpenAPIRuntime.OpenAPIArrayContainer`.
    An omitted field means "leave that axis alone", so all three are sent explicitly.
- **`target_head_pose` is measured from the base, not from the body, and `target_body_yaw` does not carry the head
  with it.** `AnalyticalKinematics.ik` hands the Stewart platform `head_yaw − body_yaw` (`inverse_kinematics_safe`,
  whose own comment speaks of "the relative yaw between the body and the head"; the Placo engine spells it
  `T_world_frame` and files body yaw as a separate *joint* task). Measured against the shipped
  `reachy_mini_rust_kinematics`, not read off the docs: `(head 30°, body 30°)` returns the six joints of neutral
  bit-for-bit, and `(head 0°, body 30°)` those of `(head −30°, body 0°)`. Nothing in `openapi.json` says so — the
  schema is a bare `number` with no description — and the same convention governs `FullState.head_pose` on the way
  back, which is why `PassiveJointSolver` subtracts body yaw before solving. A client that turns the body without
  adding the same angle into the head pose gets a head that holds its absolute direction and unwinds from the torso.
  - **Two limits follow, and the first one bites silently.** `inverse_kinematics_safe` clamps `body_yaw` so that
    `|head_yaw − body_yaw| ≤ 65°` (`max_relative_yaw`) — so commanding `body_yaw = 180°` with the head left at world
    zero turns the body **65°** and reports nothing. It works the other way too: a large head yaw makes the daemon
    raise body yaw on its own. The second is `max_body_yaw = 160°`, matching the URDF's `yaw_body` limit of
    ±2.79253 rad; past it the body simply stops. Angles must arrive pre-wrapped to `[-π, π]` — `body_yaw = 200°`
    comes out as −95°.
  - `automatic_body_yaw` is what enables all of that, it defaults to **true**, and `set_automatic_body_yaw` exists
    only on the ZMQ/WS command protocol — there is no HTTP route for it, so anything going through REST or
    `ws/set_target` gets the default. Every backend (robot, mujoco, mockup) shares it, so `sim-daemon` reproduces
    both the frame and the clamps.
- **`apps/start-app/{name}` checks nothing at all, and is outside the `get_backend` gate.** It depends on
  `get_app_manager`, so it answers **200 with a torn-down backend** — the subprocess then dies a few seconds later
  when `WSClient.wait_for_connection` never sees a joint frame, and the daemon files `AppState.ERROR` long after the
  POST returned. At a *sleeping* robot it is worse, because nothing fails: the app runs, reports `running`, and every
  motion it sends is swallowed by disabled motors. `wake_up()` is called from exactly four places in the package and
  none of them is an app start. The daemon does know the sequence — `startup_app.wake_or_start_startup_app_if_idle`
  enables the motors, awaits the animation and only then starts — but it is reachable only by touching an antenna,
  never over REST. The client owns it: `RobotSession.claimRobotForApp` and `RobotAppLauncher.startFreeRobot`.
- **The daemon's return-to-zero after an app is not observed on hardware, and the crash path has none.**
  `AppManager.stop_current_app` ends with `goto_target(INIT_HEAD_POSE, antennas=[-0.1745, 0.1745], duration=1.0)`
  unless the head is within `SLEEP_POSE_MAGIC_DISTANCE` (10 magic-mm) of the sleep pose — present in 1.9.0 and in
  `1.10.0.dev0` alike, and reported as not happening on a real unit. `monitor_process` releases the robot-app lock in
  its `finally` and does nothing else, so an app that **exits or crashes** leaves the head wherever its last frame
  put it in every version. So the client parks it, and `[-0.1745, 0.1745]` is the pose to send: ~±10°, "to reduce
  shaking at vertical", and `RobotConnection.zeroAntennas` is the one copy of it. A `goto` issued after
  `stop-current-app` has answered is safe — that route is synchronous, so its 200 lands past the daemon's own
  attempt — and upstream `de6902d8b` adds a debounced `goto_sleep` 1.5 s after the app lock frees, which a robot on
  a newer daemon would run *alongside* the client's parking. Re-check this the next time the robot is updated.
- Wake/sleep are multi-step protocols, not single calls: `motors/set_mode/enabled` → 300 ms → `move/play/wake_up`;
  sleep reverses it (animation first, `set_mode/disabled` only after it finishes). The play routes never touch the
  motor mode — an asleep robot accepts them, plays the sound, and does not move.
  - **Sleeping does not stop the app either**, the same gap `daemon/stop` has. `set_mode/disabled` is a switch and
    the app manager is never told, so an app is still driving when the motors go and dies on its next command. Both
    the client's sleep and its power-off therefore stop the app first *and wait for the daemon to stop naming it* —
    a 200 from `stop-current-app` is not the app letting go (see the `stopping` section above), and parking on top
    of the return-to-zero the daemon runs on the app's behalf puts two motions on one robot, where `play_move`'s
    non-blocking guard silently drops one of them. `RobotSession.releaseRunningApp` and `RobotAppRelease`.
- `daemon/start?wake_up=<bool>` returns a job id immediately and starts the backend in the background (409 while
  another job runs); poll `daemon/status` until `running`. With `wake_up=true` the daemon enables the motors itself.
  - **That flag is what lets a caller with no time wake a robot at all.** `motors/set_mode` is behind `get_backend`
    and 503s while the backend is down, so the wake protocol above cannot even begin there — but one accepted
    `start?wake_up=true` is the entire sequence, performed daemon-side, and the poll is only how you learn it
    finished. A client that has seconds rather than ninety asks and reports, it does not wait: `RobotPower.resume()`
    against `RobotSession.wake()`.
- **`daemon/stop?goto_sleep=<bool>` is the "Power off" of the official app, and it is the mirror image of start** —
  a job id at once, 409 while another job runs, poll `daemon/status` until `stopped`. What it stops is the *backend*;
  the daemon's own HTTP server stays up, which is what makes `daemon/start` the way back and why the connect gate can
  offer it. `state == error` is a finished stop too, not a reason to keep polling: `Daemon.stop` records a failed
  sleep that way and tears the backend down regardless, so the error belongs on screen (`backendFault` already reads
  `status.error`) rather than being reported as a timeout.
  - `goto_sleep=true` is a **more** careful shutdown than the client's own sleep protocol: `daemon.py` enables the
    motors, `await`s the animation, and only then disables them. `RobotPower.sleep()` never enables them first, so
    performing a client-side sleep beforehand adds nothing and delays the parking.
  - **It does not stop the running app.** `Daemon.stop` closes the JSON-RPC relay and the media server and never
    touches `app_manager`, so an app left running has its backend disappear underneath it. Same shape as the
    `reset-apps` guard: the client owns it, and `RobotSession.powerOff` stops the app first.
- No MJPEG endpoint exists. Camera is WebRTC-only (signaling `ws://<host>:8443`, GStreamer webrtcsink, single H.264
  Constrained Baseline 3.1 stream, Opus audio, STUN `stun.l.google.com:19302`).
- Daemon 1.9.0 is the minimum and tested API baseline. Enforce
  `DaemonCompatibilityPolicy` during the first status handshake: reject older/different-major versions, warn for
  newer 1.x or unknown versions, and tolerate unknown JSON fields. See `docs/adr/0001-daemon-compatibility-and-lan-security.md`.
- The daemon has no authentication or encryption. v1 supports trusted private LAN/robot AP only; never imply that a
  client-side token adds security and never expose port 8000 publicly.
- 9 actuators: `body_rotation`, `stewart_1..6`, `left_antenna`, `right_antenna`. Safety limits are clamped server-side.
- `passive_joints` in the state stream is `null` unless the daemon was launched with `--kinematics-engine Placo`; the
  default `AnalyticalKinematics` never computes them and there is no API to switch engines. The 21 Stewart passive
  joints are therefore worked out client-side, for 3D visualization only. Upstream's `kinematics-wasm` crate describes
  the behavior to reproduce — read it as a specification, never as code to port.
- URDF + STL meshes are served by the daemon: `GET /api/kinematics/urdf` (a `{"urdf": "<xml>"}` object, ~250 KB) and
  `GET /api/kinematics/stl/{filename}` (raw bytes as `model/stl` — its docstring claiming to return a *path* is
  stale). The generated client cannot fetch the STL: it declares `application/json` for every response.
- `GET /api/kinematics/info` reports only `{"info": {"engine", "collision check"}}` — no joint names, no limits. Those
  live in the URDF alone.
- DoA angle (microphone direction of arrival) is in radians: 0 = left, π/2 = front/back, π = right.
- Speaker and microphone levels are `GET|POST /api/volume/{current,set}` and `/api/volume/microphone/{current,set}`,
  both `{"volume": 0…100}` in and `{volume, platform, device}` out. There is no separate "sensitivity" concept —
  microphone sensitivity *is* its input level. Wrapped as `AudioLevel`.
  - **`POST /api/volume/set` plays a test sound on every accepted call** (it is in the route's own description).
    Send it once a slider gesture ends, never on each change, or the robot beeps continuously.
  - Out-of-range values come back as 422, so both setters map `.unprocessableContent` explicitly.
  - On `sim-daemon` these routes drive the **host Mac's own** speaker and mic (`platform: Darwin`), not a robot.
    Note the level before testing and restore it after.
