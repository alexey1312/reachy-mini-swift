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

So the reply shapes for those commands can be verified **only through a real peer connection**.
That is why the relay features in this app are covered by unit tests and previews and not by a
live check: the app drives the data channel over the Hugging Face relay, and a LAN session opens
one it deliberately does not command over.

Two findings that came out of the same session and are worth keeping:

- `imu_data` arrives **unsolicited** at 50 Hz, so a reply naming a `type` is indistinguishable from
  a broadcast. That is the live evidence behind `RemoteControlChannel.Correlation.typed`, which was
  written from the sources alone.
- `GET /api/state/imu` answers **404** on that robot despite being in the committed spec. The
  client treats an absent reading as "no IMU" rather than as a failure, so the State screen's
  Motion section simply does not appear there.
