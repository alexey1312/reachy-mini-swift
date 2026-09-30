---
layout: page
title: Privacy Policy
permalink: /privacy.html
---

# Privacy Policy — Hey Reachy

Last updated: 1 October 2026.

**Hey Reachy collects nothing.** There is no server behind this app, no account with the developer, no analytics, no
crash reporting SDK and no advertising. Nothing you do in the app is sent anywhere the app does not need to reach to
do its job.

## What the app talks to

**Your robot.** The app is a client for the daemon that runs on the Reachy Mini Wireless itself. Commands, the state
stream, camera and audio, the recorded moves, the file browser — all of it goes directly between your device and your
robot over your own network. None of it passes through the developer.

**Hugging Face, only if you sign in.** Signing in is optional and drives three features: installing robot apps from
Hugging Face Spaces, listing robots your account has linked, and reaching a robot outside its network through the
Hugging Face relay. The session is between your device and huggingface.co under your own account; the token is stored
in the system Keychain on your device and can be removed by signing out. See
[Hugging Face's privacy policy](https://huggingface.co/privacy) for what they do with it.

**Apple, for the platform features you use.** TestFlight feedback and crash reports go to Apple and are governed by
Apple's own terms.
Beyond that the app sends Apple one thing, and only when you use it:
when you hold **Talk from this device** in a conversation,
what you say is turned into text on your device if its language is supported there,
and otherwise by Apple's speech recognition service,
under [Apple's privacy policy](https://www.apple.com/legal/privacy/).
Only the resulting text goes to your robot; the recording is not kept.

## What stays on your device

Robot addresses and identities, your preferences, the Hugging Face token (in the Keychain) and any files you download
from the robot. Deleting the app removes them.

## Permissions

| Permission             | Why                                                                                                                                  |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| **Local Network**      | To find your robot over Bonjour and reach its daemon. The app scans for robots, not for anything else.                               |
| **Bluetooth**          | Only to put a new robot onto Wi-Fi, and only from that setup flow.                                                                   |
| **Microphone**         | To speak through the robot's speaker during a live session, and to talk to Reachy from this device while you hold the button.        |
| **Speech Recognition** | To turn what you say to Reachy into text before it is sent. On your device when it can; otherwise by Apple's speech service.         |
| **Camera**             | Never used to record. The permission string is declared because the WebRTC stack that receives the robot's video references the API. |

## Children

The app is not directed at children and collects no data from anyone, of any age.

## Changes

Changes to this policy are committed to this file, in
[the public repository](https://github.com/alexey1312/reachy-mini-swift), with the full history visible.

## Contact

Aleksei Kakoulin — akakoulin.dev@gmail.com, or an issue on
[GitHub](https://github.com/alexey1312/reachy-mini-swift/issues).
