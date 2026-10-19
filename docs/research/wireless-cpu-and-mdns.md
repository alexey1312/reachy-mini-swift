# Wireless CPU budget and mDNS name collision

This file records two measurements that a third party took on a real Reachy Mini Wireless.
This repository has no equivalent measurement.
The source is [`agentculture/reachy-mini-cli`](https://github.com/agentculture/reachy-mini-cli) (MIT):
a Python CLI and behaviour runtime that runs on the robot through the in-process `reachy-mini` SDK.
Every link below is a permalink to its commit `b7679868` (v0.54.0, 2026-09-06).

Read it as a specification, as project rule 1 says for Pollen's repositories.
Nothing here is ported, and nothing here was measured again on our robot.

## CPU on the Wireless

### What they measured

On 2026-08-19 their runtime ran on the Wireless as a `systemd --user` service.
It is a 50 Hz loop with face, video-clip, audio and GStreamer worker threads.

| Quantity          | Value                                                           |
| ----------------- | --------------------------------------------------------------- |
| Host load         | ~10 on 4 cores (aarch64)                                        |
| Their runtime     | ~200 % CPU, about ten runnable threads                          |
| Daemon            | ~85 % CPU                                                       |
| Runtime tick rate | ~6.8 Hz effective (4086 ticks in 598 s), against 50 Hz designed |
| Tick overrun      | p50 120 ms, p90 167 ms, max 1075 ms, against a 20 ms budget     |

Sources:

- [`docs/evidence/2026-08-19-t6-wireless-live-acceptance.md`](https://github.com/agentculture/reachy-mini-cli/blob/b7679868717d667d5d2aa8d373a60a1ad0b7b7e8/docs/evidence/2026-08-19-t6-wireless-live-acceptance.md)
  gives the load, the tick rate and the overruns.
- [`docs/specs/2026-08-18-pettable-wireless-168.md`](https://github.com/agentculture/reachy-mini-cli/blob/b7679868717d667d5d2aa8d373a60a1ad0b7b7e8/docs/specs/2026-08-18-pettable-wireless-168.md)
  gives the per-process figures, in its "Resolved vagueness" section only.
- Issues [#97](https://github.com/agentculture/reachy-mini-cli/issues/97) (open: the loop reaches 23 Hz, not 50, even on their development box)
  and [#168](https://github.com/agentculture/reachy-mini-cli/issues/168) (closed: the robot could not feel a pat at that tick rate).

Their own conclusion is that more Python threads cannot help on this host:
the spec calls thread-level separation "exhausted on the Wireless (GIL + scheduler starvation at load ~10)".
The fix they shipped makes one detector work at the low tick rate.
It does not bring the loop back to 50 Hz.

### What the measurement does not show

- The daemon's ~85 % was measured with their runtime beside it.
  That runtime reads camera frames through the daemon's local IPC,
  so the figure is not an idle baseline, and the evidence does not separate the two loads.
- The evidence does not state the daemon version on the unit.
  Their SDK pin is `>=1.9.0,<1.10`, but the robot's daemon comes from the robot's own image.
- Nothing measures what the load did to the daemon's HTTP API, the state WebSocket or WebRTC.

### What it means for this client

- This client keeps all its logic off the robot.
  The only robot load it adds is the daemon's own work for each request and stream.
  The measurement supports that design: the Pi has no CPU to spare once a heavy process runs on it.
- Every process on the robot shares the same four cores:
  a Python app that the daemon starts, the conversation app that Pollen now runs on the robot,
  and a third-party runtime such as this one.
- The daemon reports only its own apps through `/api/apps/current-app-status`.
  A `systemd` service such as their runtime is not visible to this client.
  That runtime sends head poses through the SDK on every tick,
  so it would contend with the moves this app sends.
  This follows from their design; nobody measured it with this app.
- When the camera, teleoperation or the state stream lag on one robot and not on another,
  read the robot's load average first (`uptime` over `ssh pollen@<robot>`).
  Do not blame the client before you know the load.

## mDNS name collision

### What they measured

On 2026-08-08 one LAN held two daemons:
a Wireless, and a Lite tethered to a Linux box on the same network.
The box also ran their CLI.

| Unit     | `robot_name`  | `wireless_version` | `hardware_id`      | Address                     |
| -------- | ------------- | ------------------ | ------------------ | --------------------------- |
| Wireless | `reachy_mini` | `true`             | `a89063c05ae79779` | `192.168.1.162`             |
| Lite     | `reachy_mini` | `false`            | `37a38ce3a26e0727` | `127.0.0.1` (from that box) |

- On that box, `reachy-mini.local` did not resolve,
  and `reachy-mini-2.local` resolved to the Wireless.
  So `ssh pollen@reachy-mini.local`, the command in Pollen's documentation, failed.
  Their reading is that `-2` is avahi's collision suffix,
  because the Lite's host took the base name first.
- Both daemons report the same `robot_name`.
  Only `hardware_id` tells them apart.
- They also timed a unicast sweep: `GET /api/daemon/status` to every host of each local IPv4 `/24`.
  Twenty cold runs probed 254 hosts each,
  in 3.749 / 3.861 / 3.975 s (min / mean / max), and none reported a wrong unit.
  The sweep skips loopback, so it could not find the Lite at all.

Sources:

- [`docs/evidence/2026-08-08-wireless-discovery-verification.md`](https://github.com/agentculture/reachy-mini-cli/blob/b7679868717d667d5d2aa8d373a60a1ad0b7b7e8/docs/evidence/2026-08-08-wireless-discovery-verification.md)
- [`docs/evidence/2026-08-08-wireless-discovery-20runs.csv`](https://github.com/agentculture/reachy-mini-cli/blob/b7679868717d667d5d2aa8d373a60a1ad0b7b7e8/docs/evidence/2026-08-08-wireless-discovery-20runs.csv)
  (the twenty runs)

### What it means for this client

- Rule 4 holds as written: a robot is its hardware id, never its name or its address.
  The name is not even unique between two units on one desk.
- `CandidateSweep` (`Sources/ReachyUI/Connect/CandidateSweep.swift`) tries candidates in this order:
  the last address, `127.0.0.1` on macOS and in the simulator, `reachy-mini.local`,
  and then each Bonjour result when it resolves.
  It connects to the first daemon that answers.
  `RobotSession.connect(to:automatically:)` does not compare that daemon's hardware id
  with the robot this device remembers.
  So when two daemons share a LAN and the remembered address has moved,
  the static fallback can connect automatically to the other unit.
  This follows from the code on 2026-10-19; nobody reproduced it with two robots.
- This client has no unicast sweep.
  Such a sweep would find a robot on a network where multicast does not pass.
  Central already covers that case for a user who signed in to Hugging Face.
  If a sweep is ever added, their timing (~3.9 s for 254 hosts) is the cost to expect.
