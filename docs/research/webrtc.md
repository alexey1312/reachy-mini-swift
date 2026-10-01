# WebRTC signaling research (Phase 0 spike)

Probed against the simulated daemon v1.9.0 (`mise run sim-daemon`), 2026-08-03.

## Findings

- Port 8443 speaks **plain `ws://` — no TLS at all** (HTTPS probe fails, raw WebSocket connects). The
  "self-signed certificate on iOS" concern from the brief is moot, at least for the sim: nothing to pin or trust.
  Re-verify on real Wireless hardware.
- Protocol is the **GStreamer `gst-plugins-rs` webrtc signalling protocol** (same one `webrtcsink` ships):
  - on connect the server sends `{"type": "welcome", "peerId": "<uuid>"}`
  - `{"type": "list"}` → `{"type": "list", "producers": [...]}`
  - `{"type": "setPeerStatus", "roles": ["listener"], "meta": {}}` → `peerStatusChanged`
  - session flow (from the gst protocol, to verify live): `startSession` → `sessionDescription` (SDP offer/answer) →
    `ice` candidates → `endSession`
- `producers` is empty in the sim until media is acquired (`POST /api/media/acquire`; camera specs name is `mujoco`).
- Upstream client reference: `src/hooks/media/useWebRTCStream.ts` (STUN `stun.l.google.com:19302`, single H.264
  Constrained Baseline 3.1 stream + Opus).
  Daemon 1.11.0 loosened that on new robot images:
  webrtcsink drives the hardware encoder directly, the Constrained Baseline caps filter is gone from that path,
  and the bitrate adapts instead of sitting at 5 Mbps (upstream #1392).

## Phase 2 implications

- The signaling client is a trivial JSON-over-WebSocket state machine — no third-party dependency needed for it.
- The heavy decision remains the RTC stack itself (WebRTC.framework binary vs alternatives); H.264 CBP 3.1 + Opus are
  well inside WebRTC.framework's defaults.
- No TLS handling needed if hardware matches the sim; check the Wireless robot before assuming.

## Phase 2 verification (2026-08-03, sim daemon v1.9.0)

Implemented in `ReachyKit` (`SignalingMessage`, `CameraSignalingClient`) + `ReachyMedia` (`CameraSession`,
stasel/WebRTC binary xcframework). Verified live against the sim:

- Full session flow confirmed exactly as speced: `welcome` → `setPeerStatus(listener)` → `peerStatusChanged` →
  `list` → `startSession` → `sessionStarted` → `peer{sdp offer}` (robot is the offerer) → `peer{ice}` both ways →
  `endSession`. Error messages use `{"type": "error", "details": ...}`.
- The sim's producer registers as `meta.name == "reachymini"` (not `mujoco` — that's only the camera specs name).
- Gotcha: without `GST_PLUGIN_SCANNER` pointing into the venv, GStreamer's plugin loader fails silently, webrtcsink
  can't discover the Opus encoder ("No caps found for stream audio_0") and **no producer ever appears on :8443**
  while `/api/media/status` still reports `available: true`. `mise run sim-daemon` now sets it.
- Sim-gated test: `SimulatorIntegrationTests/webrtcSignaling` negotiates to a real SDP offer via `mise run test:sim`.

## The command protocol lives on the data channel, and nowhere else

Measured on 2026-09-01 against a Wireless unit on daemon 1.10.0, because the remote surface added
in that release is otherwise only readable from the daemon's sources.

`io/protocol.py` describes a request/reply protocol — `get_imu`, `get_robot_name`, `stop_move`,
`subscribe_pose` — and it is tempting to look for a WebSocket that speaks it, since the daemon has
one at `ws://<robot>:8000/ws/sdk`. **It does not answer commands.** Three things say so and they
agree:

- Connecting and sending `{"type": "get_robot_name"}`, `{"type": "get_imu"}` or an `apps.status`
  JSON-RPC frame yields no reply in eight seconds — only the 50 Hz broadcast of
  `joint_positions`, `head_pose` and `imu_data`.
- The vendor's own client, `reachy_mini/io/ws_client.py`, opens that exact URL and its
  `send_command` has no reply path at all: it sends, and reads broadcasts.
- `daemon/jsonrpc_relay.py` is mounted on the WebRTC data channel and `/ws/sdk` for `apps.*`, and
  routes everything else to the running app — not to the command handlers.

**It does run them, though, and that is a different thing from ignoring them.**
In 1.11.0 and on `main` `WSServer._handle_command` hands `process_command` a `send` that does nothing,
so a command over `/ws/sdk` takes effect and its reply is dropped.
A `set_*` sent there changes the robot with no way to learn that it did —
which is why `set_first_wake_up` is not sent that way (`.claude/rules/daemon-api.md`).

So the reply shapes for those commands can be verified **only through a real peer connection**.
That is why the relay features in this app are covered by unit tests and previews and not by a
live check: the app drives the data channel over the Hugging Face relay, and a LAN session opens
one it deliberately does not command over —
with one exception since #169:
the first wake-up flag has no other way in on the LAN,
so a connect to a robot this device has not settled opens a peer on `:8443` to ask for it
(`media_server.py` builds the `data` channel for every consumer, local or central).

Two findings that came out of the same session and are worth keeping:

- `imu_data` arrives **unsolicited** at 50 Hz, so a reply naming a `type` is indistinguishable from
  a broadcast. That is the live evidence behind `RemoteControlChannel.Correlation.typed`, which was
  written from the sources alone.
  **Corrected on 2026-09-30, and the correlation is gone:**
  `get_imu` is not answered with an `imu_data` frame at all.
  `process_command` replies `{"command": "get_imu", "imu": {…} | null}` —
  the reading nested, its `type` dropped, `null` where there is none —
  and upstream's own `test_get_imu_with_reading` / `test_get_imu_without_imu` pin that shape.
  A `type`-matched wait was therefore always answered by the next broadcast, never by the reply,
  and a robot with no reading timed out instead of saying so.
  The client now waits on the echoed command.
- `GET /api/state/imu` answers **404** on that robot despite being in the committed spec. The
  client treats an absent reading as "no IMU" rather than as a failure, so the State screen's
  Motion section simply does not appear there.
  The route is a 1.11.0 one (upstream #1341); the spec had been taken from `main` before that release.
