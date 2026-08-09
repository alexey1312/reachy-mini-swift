# reachy-mini-swift

**Hey Reachy** — a native macOS / iPadOS / iOS client for the **Reachy Mini Wireless** robot by
[Pollen Robotics](https://www.pollen-robotics.com).

[![CI](https://github.com/alexey1312/reachy-mini-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/alexey1312/reachy-mini-swift/actions/workflows/ci.yml)

> [!NOTE]
> Unofficial project, not affiliated with Pollen Robotics. This is **not a fork** of the official
> [desktop app](https://github.com/pollen-robotics/reachy-mini-desktop-app) — it is an independent Swift client for
> the robot daemon's documented HTTP/WebSocket API. The upstream repositories are used as a behavioral specification,
> not as a source of code.

## Highlights

- **Connect and discover** — Bonjour discovery, manual addresses, IPv6, automatic reconnect; robots are identified by
  hardware id, never by IP.
- **Live control** — joystick teleop of the 6-DoF head, antennas and body rotation, with the WebRTC camera and
  two-way audio (talk through the robot's speaker).
- **3D viewer** — a RealityKit scene built from the robot's own URDF and meshes, mirroring it in real time.
- **Moves** — browse and play the daemon's recorded moves.
- **App store** — install, update and remove robot apps from Hugging Face Spaces, following each job over the
  daemon's job socket; a dock shows the running app everywhere in the client.
- **Bluetooth setup and recovery** — PIN-authenticated onboarding that sends Wi-Fi credentials over an encrypted BLE
  channel, plus a recovery console (raise the hotspot, restart the daemon, software reset) for a robot that fell off
  the network.
- **Remote access** — reach your robots from outside their network through the Hugging Face relay; commands travel on
  a brokered WebRTC data channel, the daemon's port is never exposed.
- **Files** — an SFTP browser for the robot's filesystem.
- **At home on Apple platforms** — status and apps widgets, Control Center power controls, Siri / App Intents
  (wake, sleep, power off, launch any installed app), Home Screen quick actions, full localization readiness.

_Screenshots and a one-minute demo from a live robot are on their way._

<!-- Drop three PNGs into docs/media/ and uncomment:
<p align="center">
  <img src="docs/media/store.png" width="260" alt="App store tab" />
  <img src="docs/media/teleop.png" width="260" alt="Teleop with the 3D viewer" />
  <img src="docs/media/onboarding.png" width="260" alt="Bluetooth onboarding" />
</p>
Demo video: <link>
-->

## Scope

- **Wireless only.** On the Wireless model the daemon runs on the robot itself (`http://reachy-mini.local:8000`), so
  this app is a pure network client. The Lite model (daemon on a USB-connected computer) is out of scope for v1 — a
  Lite owner can still connect if the daemon runs on a reachable host in the same network.
- **Camera is WebRTC-only.** The daemon exposes no MJPEG endpoint, so video and two-way audio go through WebRTC.

## Architecture

| Package           | What                                                                                                                 |
| ----------------- | -------------------------------------------------------------------------------------------------------------------- |
| `ReachyKit`       | Generated OpenAPI client, WebSocket state stream, discovery, BLE provisioning, URDF and kinematics. No UI framework. |
| `ReachyMedia`     | WebRTC camera and two-way audio session, plus its video view.                                                        |
| `ReachyScene`     | RealityKit scene built from the robot's own URDF and meshes.                                                         |
| `ReachyUI`        | The screens: connect gate, five-tab shell, teleop, store, onboarding, settings.                                      |
| `ReachyDesign`    | Design tokens and the surface facade — SwiftUI and nothing else, linked by every UI layer.                           |
| `ReachyWidgetUI`  | Widget views and the App Intents the app and the widget extension share. Depends on `ReachyKit` alone — no WebRTC.   |
| `ReachySSH`       | SFTP via Citadel. Knows nothing about robots; host, port and credentials arrive as values.                           |
| `HuggingFaceAuth` | The app's own Hugging Face session: OAuth sign-in, Keychain storage, renewal. Knows nothing about robots.            |
| `Apps/`           | Thin app shells and the widget extension, generated with [Tuist](https://tuist.dev).                                 |

The dependency shape is deliberate: `ReachyKit` sits at the bottom with no UI; `ReachyMedia` and `ReachyScene` build
on it; `ReachyUI` composes everything; `ReachyDesign` sits under all UI layers and depends on nothing at all.
`ReachyWidgetUI` never links WebRTC — a widget process woken for a moment cannot afford it — and `ReachySSH` sits
beside `ReachyKit` for the same reason. `ReachyTestSupport` holds stubs shared by the test targets and is
deliberately not a product.

## Using the packages

All eight packages are public SPM products, so another app can depend on them directly. `ReachyKit` is the only one
robots strictly need, and the only one that pulls in no UI framework.

```swift
.package(url: "https://github.com/alexey1312/reachy-mini-swift.git", branch: "main"),
```

Pin a revision or a tag if you need a stable API. Minimum platforms are macOS 15 and iOS 18 — `RealityView` in the 3D
viewer sets that floor.

## Getting started

```bash
./bootstrap.sh
```

That's it — one script installs all pinned tools via a self-contained [mise](https://mise.jdx.dev) binary (`bin/mise`)
and wires git hooks. Swift itself is managed by [swiftly](https://www.swift.org/swiftly/) via `.swift-version`.

```bash
./bin/mise run build        # build the Swift packages
./bin/mise run test         # run the test suites
./bin/mise run build:app    # build the app itself (macOS)
./bin/mise run device       # build, install and launch on a connected iPhone
./bin/mise run sim-daemon   # run a simulated robot daemon (MuJoCo) — no hardware needed
./bin/mise tasks            # list everything else
```

`device` needs a one-time signing setup: put your team id in `~/.config/reachy-mini/device.env` — the script tells
you how on first run.

## Development without hardware

The daemon supports a MuJoCo simulation mode. `./bin/mise run sim-daemon` creates a project-local environment from
`Scripts/sim-requirements.txt`; the tested daemon baseline is pinned to **1.9.0**. Point the app (or an iPhone on the
same trusted network) at the Mac. The daemon's OpenAPI spec is committed at `Sources/ReachyKit/openapi.json` and
refreshed with `./bin/mise run update-spec`.

## Testing

- `./bin/mise run test` — the SwiftPM suites: transport, session, models, BLE protocol, SSH, auth.
- `./bin/mise run test:snapshots` — every SwiftUI preview rendered on a pinned simulator and compared against
  ~1250 reference images (light and dark), stored in Git LFS. The approach is
  [ADR 0002](docs/adr/0002-preview-driven-snapshot-testing.md).
- `./bin/mise run storybook` — the same previews as a browsable catalogue on a simulator.
- `./bin/mise run test:sim` — integration tests against a running `sim-daemon`; the plain `test` run skips them.

## Compatibility and network security

Daemon 1.9.0 is the minimum tested version. Newer 1.x daemons connect with a compatibility warning; older or
different-major versions are rejected before commands are sent. See
[ADR 0001](docs/adr/0001-daemon-compatibility-and-lan-security.md) for the policy.

> [!WARNING]
> The daemon provides **no authentication or encryption**. Use this client only on a trusted private LAN or the
> robot's own access point. Never expose daemon port 8000 through port forwarding or a public address.

Reaching a robot from outside its network does **not** change that. It goes through the Hugging Face relay, which
brokers a WebRTC session between two peers that have both authenticated with the same account; the daemon's HTTP port
is never exposed, and commands travel on the session's data channel instead. See
[ADR 0003](docs/adr/0003-remote-access-over-the-hugging-face-relay.md).

## Status

Working today: connection, discovery and network resilience; joystick teleop; recorded moves; the daemon log console;
the WebRTC camera with two-way audio; the 3D viewer; the robot app store over the daemon's job socket; Hugging Face
sign-in (public OAuth client with PKCE, token in the Keychain), private Spaces and remote access through the relay;
the SFTP file browser; Bluetooth onboarding and recovery; widgets, Control Center controls, Siri shortcuts and quick
actions.

Open, and stated honestly:

- **The Bluetooth path has not run against real hardware yet.** It is written against daemon 1.9.0's
  `bluetooth_service.py` — including the encrypted Wi-Fi join (X25519 + HKDF-SHA256 + AES-GCM) — and verified against
  stubs. The question that gates it is whether the ~260-byte sealed payload fits a single BLE write on iOS; the
  fallback over the robot's own hotspot is implemented. The full hardware checklist is
  [docs/research/ble-provisioning.md](docs/research/ble-provisioning.md). The GATT protocol is not published upstream
  and its desktop client is being reworked, so treat the protocol as unstable.
- The Stewart platform's passive joints are computed client-side for the 3D view — the daemon reports them only under
  the Placo kinematics engine.
- A remote session carries commands and the camera but not the 3D scene, whose URDF and STL are HTTP-only.

Background research lives in [docs/research/](docs/research/), accepted decisions in [docs/adr/](docs/adr/).

## License

[Apache 2.0](LICENSE). [NOTICE](NOTICE) carries the attribution, the non-affiliation statement and the third-party
notices for the bundled dependencies (Apple's swift-openapi packages, Apache 2.0; Google WebRTC, BSD 3-Clause).
"Reachy Mini" is a product name of Pollen Robotics, used here solely to describe compatibility.
