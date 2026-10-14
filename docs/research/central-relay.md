# The Hugging Face central relay

How a robot on someone else's network becomes reachable, and what the relay does and does not carry. Written against
the daemon's own client (`.venv-sim/lib/python3.12/site-packages/reachy_mini/media/central_signaling_relay.py`) and
this app's `Sources/ReachyKit/Central/`. Specification, never code to port (rule 1).

Decisions taken on top of this live in [ADR 0003](../adr/0003-remote-access-over-the-hugging-face-relay.md).

## What it is

A Hugging Face Space — `https://pollen-robotics-reachy-mini-central.hf.space`, overridable through
`REACHY_CENTRAL_URL` on the robot and `CentralRelayClient.Configuration.baseURL` here. Both ends authenticate with a
Hugging Face token, and central only ever introduces two peers that presented one for the same account.

It is a **signalling broker, not a tunnel.** Once the WebRTC session is up, video, audio and the data channel flow
peer-to-peer; central sees none of it. The daemon's HTTP port is never exposed, which is why remote access does not
weaken ADR 0001's position.

## Routes

Everything is HTTP with `Authorization: Bearer <hf-token>`.

| Route                   | Shape                                                                                    |
| ----------------------- | ---------------------------------------------------------------------------------------- |
| `GET /events`           | Server-sent events, one JSON message per `data:` line. The inbound half of signalling.   |
| `POST /send`            | One JSON message. The outbound half; some messages answer synchronously in the response. |
| `GET /api/robot-status` | `{robots: [...]}` — the account's robots as central currently sees them.                 |
| `GET /health`           | Unauthenticated liveness.                                                                |

## Message vocabulary

Modelled in `Sources/ReachyKit/Transport/SignalingMessage.swift`, shared with the LAN path — the robot's own
`webrtcsink` signalling server speaks the same dialect on port 8443, which is why one transport seam serves both.

- `welcome(peerID)` — first frame on `/events`; the id central knows this client by.
- `setPeerStatus(roles, name)` — how a peer announces itself. `["listener"]` for this app, `["producer"]` for a robot.
  The `name` is what the robot's owner sees holding their robot.
- `list` → `producerList([Producer])` — robots available to this token.
- `startSession(peerID)` → `sessionStarted(peerID, sessionID)`, or a rejection.
- `sdp(sessionID, type, sdp)` and `ice(sessionID, candidate, …)` — the negotiation itself.
- `endSession(sessionID, reason)` — either side.

## Things that cost time to find out

- **Announce before reporting a connection.** Central evicts peers with no recent inbound traffic, and the robot's own
  relay registers as a producer before flipping its state to connected. A listener that reports itself connected
  before sending `setPeerStatus` is visible to nothing.
- **Presence in the listing _is_ the online signal.** Central sweeps a peer whose lease lapsed, so a robot that is off
  is absent rather than listed as offline. The UI shows an empty list, never a greyed-out robot.
- **Rejections carry short reason codes**, and they mean genuinely different things — `robot_busy` (something is
  running on it, worth retrying), `local_app_started` (somebody walked up to the robot; retrying takes it from them),
  `install_id_takeover` (the same account opened it elsewhere; retrying starts a bouncing match). Modelled in
  `RemoteSessionEnd`, which also carries an unknown code through verbatim so a bug report can name it.
- **1200 requests a minute per token.** Retrying through a `429` turns a limit into a ban, so `rateLimited` is its own
  failure rather than another `http(Int)`.
- **60 s of silence ends the stream.** Central keepalives well inside that; `readTimeout` matches the robot's budget.
- **`unauthorized` is not worth retrying** — the same token will be refused again. It is the signal to ask for a fresh
  sign-in, which is what `YourReachiesModel.State.needsSignIn` renders.
- **Central lists more than Reachy Minis.**
  Since September 2026 a Micro Duck (`pollen-robotics/microduck`) registers on the same server,
  under the same Hugging Face account, with `kind: "microduck"` in its `meta`.
  A Reachy Mini daemon sends no `kind` at all.
  Central stores `meta` as it arrives and classifies `kind` only for its public counters
  (`docs/META_CONTRACT.md` and `robot_kinds.py` in `pollen-robotics/reachy_mini_central_signalling`):
  `kind`, else the `robot_type` alias, else Reachy Mini,
  compared without case and without any character outside `a-z0-9`.
  `RobotKind` repeats that rule,
  and `CentralRelayClient.robots()` and the daemon's proxied list keep only Reachy Minis,
  because every screen that lists a robot offers to drive it.

## What cannot be tested here

`sim-daemon` cannot stand in for central: it has no token, registers no producer, and `test:sim` therefore never
exercises any of this. Both ends are unit-tested against stubs — `CentralRelayClient` and `CentralSignalingTransport`
over `StubURLProtocol` — but the joint needs a live `RTCDataChannel`, which does not exist outside a real peer
connection. That part is verified by hand, on hardware.
