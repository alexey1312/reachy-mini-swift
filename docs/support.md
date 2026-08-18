---
layout: page
title: Support
permalink: /support.html
---

# Support — Hey Reachy

Hey Reachy is an independent, open-source client for the Reachy Mini. Everything below is answered in public, so the
fastest route is usually an issue rather than an email.

## What you need

- **A Reachy Mini, or none at all.** The app is a pure network client for the robot's daemon: on a **Wireless** robot
  that daemon runs on the robot itself, and on a **Lite** one it runs on the computer the robot is plugged into —
  which is also where its Wi-Fi, its updates and its caches live, so those cards are not shown for it. With no robot,
  the Connect screen's **Simulator** choice starts one the app carries: the robot's own shape and movement, with no
  camera, no app store and no Wi-Fi behind it. There is still no account to create.
- **Daemon 1.9.0 or newer.** Newer 1.x daemons connect with a compatibility warning; older or different-major versions
  are refused before any command is sent.
- **iOS 18 or macOS 15.** The Mac version is on the
  [App Store](https://apps.apple.com/app/hey-reachy/id6799644194) and also ships as a notarized zip on every
  [release](https://github.com/alexey1312/reachy-mini-swift/releases). iPhone and iPad are in review; until they land,
  one [TestFlight link](https://testflight.apple.com/join/CGjefT9a) covers all three.

## Getting help

- **[Open an issue](https://github.com/alexey1312/reachy-mini-swift/issues)** — the best place for a bug or a feature
  request. Include your daemon version (the Robot tab shows it), your device and OS, and what you expected instead.
- **TestFlight feedback** — take a screenshot inside the app, or use _Send Beta Feedback_ in TestFlight. Both reach the
  developer with the build and device details attached.
- **Email** — [akakoulin.dev@gmail.com](mailto:akakoulin.dev@gmail.com) for anything that does not belong in public.

## First-run snags

**The app cannot find the robot.** iOS asks for the Local Network permission the first time the app looks for a robot,
and discovery finds nothing until it is granted. If it was dismissed, turn it back on in Settings → Hey Reachy → Local
Network. Failing that, type the robot's address by hand in the field under the robot list on the Connect screen —
`reachy-mini.local` or its IP.

**A Lite robot or a simulated daemon is not reachable from a phone.** Both are the same daemon run on a computer, and
it binds that computer's loopback unless it was started with `--fastapi-host 0.0.0.0`. Same Wi-Fi or not, the
connection is refused by that computer before the daemon ever sees it.

**Bluetooth setup does not complete.** The Bluetooth provisioning path is written against the daemon's own
`bluetooth_service.py` and verified against stubs, but it has not yet run against real hardware — treat it as the least
proven part of the app, and please report what you see. The fallback is to join the robot's own hotspot and set Wi-Fi
up over that.

**Nothing loads after a network change.** Robots are identified by hardware id rather than by address, so the same
robot on a new IP is still the same robot; pull to refresh, or reconnect from the Connect screen.

**The 3D scene is missing on a remote session.** A session through the Hugging Face relay carries commands and the
camera, but not the 3D scene — its URDF and meshes are fetched over plain HTTP, which the relay does not carry.

## A note on your network

The robot's daemon provides no authentication and no encryption of its own. Use Hey Reachy on a trusted private network
or on the robot's own access point — never through a port forward or a public address. Reaching a robot from outside
its network goes through the Hugging Face relay, which brokers a WebRTC session between two peers authenticated with
the same account, so the daemon's port is still never exposed.

## Privacy

Nothing is collected — see the [privacy policy](privacy.html).

## Not affiliated with Pollen Robotics

Hey Reachy is unofficial. For questions about the robot itself, its firmware or its warranty, contact
[Pollen Robotics](https://www.pollen-robotics.com).
