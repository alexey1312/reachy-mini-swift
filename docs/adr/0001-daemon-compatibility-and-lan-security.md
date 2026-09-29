# ADR 0001: Daemon compatibility and LAN security

- Status: Accepted
- Date: 2026-08-03
- Amended: 2026-08-04 — "Decision: recovering from an unsupported daemon"
- Amended: 2026-09-30 — the tested baseline moves apart from the minimum

## Context

The daemon updates independently, its OpenAPI document has no stability guarantee, and its hand-written WebSockets
are outside that document. Daemon 1.9.0 is the version verified against the simulator and recorded state fixture.
The daemon exposes motion commands over plaintext HTTP/WebSocket and has no authentication API.

## Decision: compatibility

- Daemon 1.9.0 is the minimum supported version.
  The tested baseline is `DaemonCompatibilityPolicy.testedVersion` — 1.11.0 at the 2026-09-30 amendment —
  and is raised whenever a release has been verified against it;
  the minimum moves only by a decision of its own.
- Handshake reads status/version before identity or any robot command.
- A parseable 1.x version below 1.9.0, or any different major version, is rejected with an actionable error.
- A newer 1.x version is allowed with a persistent compatibility warning. Unknown JSON fields remain tolerated.
- A missing or malformed version is allowed in limited/unknown mode with a warning, because older deployments may
  omit metadata even when their endpoint shape works.
- Optional endpoint failure disables that feature; it must not invalidate an otherwise healthy session.
- `Scripts/sim-requirements.txt` pins the simulator baseline. Updating it requires updating the policy, fixture and
  compatibility tests together after a live simulator check.

## Decision: recovering from an unsupported daemon

Amendment, 2026-08-04. Rejecting an unsupported version by throwing out of the handshake left the user on a "Try
again" button that could never work — the version does not change by retrying. Rejection is kept; the dead end is not.

- The handshake reports the verdict instead of throwing. The session halts on a dedicated `needsDaemonUpdate` step,
  latched even for automatic attempts so the periodic rescan stops re-probing a robot it has already identified.
- **No command reaches an unsupported daemon.** This is enforced in code, not by navigation: `assertSupportedDaemon()`
  guards wake, sleep and every call routed through `withClient`. Keeping the control screens unmounted is a layout
  decision and does not count as enforcement.
- The routes that stay open are `GET /api/daemon/{status,hardware-id,robot-name}` and `/update/*`. These are reads and
  version negotiation, not the command surface, and `/update/*` is the only route that can end the condition.
- `/update/*` is mounted only under `--wireless-version`. A Lite robot cannot self-update, so it is told to use the
  official desktop app over USB rather than offered a button that must fail.
- Success is inferred by reconnecting and comparing versions. The update ends with `systemctl restart`, which kills
  the daemon before it can report a terminal job status, so neither the log socket nor `/update/info` can confirm it.

## Decision: security

Version 1 supports only a trusted private LAN or the robot's own access point. The UI states that transport is
unauthenticated and unencrypted. Users must not expose port 8000 through port forwarding, a public IP, or an
untrusted network. Client-side tokens or a fake pairing screen are explicitly rejected: without daemon support they
provide no security.

Authenticated remote access is a release blocker, not a client-only follow-up. It requires an upstream daemon
protocol for pairing, authenticated HTTP/WebSocket requests and transport encryption. Credentials must then live in
Keychain and be injected centrally by ReachyKit.

## Consequences

Anyone with network access to the daemon can command the robot. Server-side motion limits remain the safety boundary.
The compatibility warning is informative for newer/unknown daemons; unsupported versions are refused before commands
and routed to the robot's own update flow instead.
