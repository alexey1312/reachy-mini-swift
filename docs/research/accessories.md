# Pollen's accessories: the NFC hats and the Hoverboard

On 2026-10-29 Pollen announced two accessories for Reachy Mini.
This file records what each one needs from this app,
what upstream has written for it, and when to start.
Upstream was read on 2026-10-31.
Nothing in this file is released yet,
so read the upstream branches again before you start the work.

## What Pollen announced

| Accessory      | Price             | Fits              | Ships               |
| -------------- | ----------------- | ----------------- | ------------------- |
| Accessory Pack | $35 (€30 in EU)   | Lite and Wireless | end of January 2027 |
| Hoverboard     | $149 (€135 in EU) | Wireless only     | end of January 2027 |

The Accessory Pack has an NFC module that goes into the head with four screws.
It also has three magnetic hats (pirate, chef and crown), four spare tags and eight magnets.
A hat's tag "switches Reachy Mini to that character",
and a spare tag can be tied "to a new personality or your own code".

The Hoverboard is a two-wheel base with its own battery and anti-tip supports.
The store says:
"Control the wheels and Reachy Mini's head using the Reachy Mini App,
with dual joysticks and live camera feedback."
The "Reachy Mini App" is Pollen's mobile app
(`pollen-robotics/reachy_mini_mobile_app`, App Store id6766823749).
The store lists "Bluetooth, Wi-Fi & USB-C connectivity",
but it does not say how the base connects to the robot.

Neither product page names an API, an SDK or a software version.

## Upstream on 2026-10-31

The daemon's `main` is `1.14.0.dev0` (`3d58a506`), and v1.13.0 (2026-10-26) is the latest release.
No code for either accessory is on the `main` branch of any Pollen repository.

| Piece                                                                                     | Where                                                                                            | State                                        |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------- |
| REST `/api/nfc/{tag,status,enabled,dump,write,erase}`                                     | [reachy_mini#1448](https://github.com/pollen-robotics/reachy_mini/pull/1448)                     | open; its `winnie_nfc` driver is not on PyPI |
| JSON-RPC `nfc.status`, `nfc.tag`, `nfc.set_enabled`, `nfc.erase`, `nfc.write`             | reachy_mini branch `1204c-nfc-json-rpc` (`3698c020`)                                             | no PR                                        |
| `rfid.status`, `rfid.link_tag`, `rfid.erase`, `rfid.open_add_on_store`, pushed `rfid.tag` | conversation app branch `add-latest-nfc-mobile` (`c4b0e6e2`)                                     | no PR                                        |
| Privacy hat: `GET/POST /api/privacy`, `set_privacy`, `DaemonStatus.privacy`               | [reachy_mini#1455](https://github.com/pollen-robotics/reachy_mini/pull/1455)                     | open; the hat hookup waits for #1448         |
| `{"type": "overboard_drive", …}` on the data channel                                      | [reachy_mini_mobile_app#129](https://github.com/pollen-robotics/reachy_mini_mobile_app/pull/129) | open; a stub, and the daemon rejects it      |
| Direct Bluetooth LE to the base                                                           | the `reachy_mini_wheels_app` Space                                                               | not public                                   |

## The hats

### How a hat changes the personality

The robot does all of it.
The conversation app polls the daemon's reader on a thread of its own,
because a personality swap "has to keep working with no browser attached".

```
hat ── NFC tag, text "hf_<built-in>" or "usr_<name>"
 │
 ▼
CLRC663 reader board in the head
 │  serial link, owned by the daemon
 ▼
daemon ──── REST /api/nfc/*      (LAN)
 │     └─── JSON-RPC nfc.*      (WebRTC data channel)
 │  polled over HTTP
 ▼
conversation app on the robot
 │  1. swaps its own personality
 │  2. pushes rfid.tag on /rpc
 ▼
LAN: /rpc WebSocket ─────────────┐
relay: daemon forwards rfid.*  ──┴──► this app (nothing listens today)
```

The tag carries the personality itself, so a hat means the same thing on every robot.
A built-in personality is written as `hf_<name>`, and a user personality as `usr_<name>`.
Both have a prefix, so that a user personality cannot shadow a built-in one.
When the hat comes off, the app goes back to its default personality.
A blank tag starts a conversation that gives the tag a new personality,
and at its end the `create_accessory_personality` tool writes the token.

The branch adds two built-in profiles, `chef_bot_appetit` and `queen_antennette`.
Their names suggest the chef hat and the crown,
but the branch does not say which text a shipped hat carries.

`rfid.tag` and `rfid.status` carry the same object:

```json
{
  "connected": true,
  "enabled": true,
  "port": "/dev/ttyACM0",
  "driver_available": true,
  "error": null,
  "accessory": { "state": "known", "personality": "noir_detective", "content": "hf_noir_detective" }
}
```

| `accessory.state` | Means                                                         |
| ----------------- | ------------------------------------------------------------- |
| `unavailable`     | no reader is connected                                        |
| `none`            | no tag is on the reader                                       |
| `blank`           | a tag with no content                                         |
| `known`           | a personality that this robot has                             |
| `unknown`         | content that this robot cannot use, such as a deleted profile |

`rfid.link_tag {"personality": …}` writes a personality onto the tag on the reader,
and `rfid.erase {"full": false}` makes it blank.
Their errors carry a `reason`: `no_tag`, `no_personality`, or `profile_locked`,
which this app already reports for a personality change.
`rfid.open_add_on_store` opens the store page in a browser on the host that runs the conversation app,
and it always returns the URL for a host with no screen.

### The privacy hat

#1455 adds a privacy mode that the daemon owns.
It cuts the camera and the microphones for every consumer,
and plays a short sound to confirm.
A hat whose tag text is `privacy` switches it on, and that hookup comes after #1448.
Software cannot switch off a hat that is on the head.
The daemon saves nothing, so privacy mode is always off after a restart.
The REST surface is `GET/POST /api/privacy {"enabled": bool}`,
the data channel gets a `set_privacy` command, and `DaemonStatus` gets a `privacy` field.

### What this app adds

1. **Follow a personality that the robot changes.**
   This gap exists today, without any hat:
   `ConversationVoiceModel` reads the settings again only after its own change
   (`Sources/ReachyUI/Conversation/ConversationVoiceModel.swift:103`).
   On each `rfid.tag`, read the settings again rather than trust the payload.
2. **Listen for `rfid.tag`.**
   `ConversationEvent.decoded(from:)` returns nil for every method except three
   (`Sources/ReachyKit/Model/ConversationEvent.swift:151`).
   Add a case there, and add the method to `RemoteConversation.notificationMethods`
   (`Sources/ReachyKit/Central/RemoteConversation.swift:17`).
   Without that second step, the relay never subscribes to it.
3. **Show the hat.**
   Put a badge on the conversation screen for `none`, `blank`, `known` and `unknown`.
   Show nothing for `unavailable`, because most robots have no reader.
4. **Link and erase a tag.**
   Add `rfid.link_tag` and `rfid.erase` to both channel arms:
   `Sources/ReachyKit/Transport/ConversationRPCClient+Requests.swift` on the LAN,
   and `Sources/ReachyKit/Central/RemoteConversation.swift` over the relay.
   Both arms satisfy `ConversationChannel` (`Sources/ReachyKit/Session/ConversationClient.swift:30`).
   The controls go beside the personality picker
   (`Sources/ReachyUI/Conversation/ConversationVoiceSheet.swift:52`).
5. **Show privacy mode.**
   When #1455 is in a release, `mise run update-spec` brings `DaemonStatus.privacy`.
6. **Decide the capability by an answer, not by a version.**
   A robot without the branch answers `rfid.status` with "method not found".
   A capability here is a protocol conformance or a probe
   (`Sources/ReachyKit/Session/RobotSession+Capabilities.swift:18`).
7. **Test against fixtures.**
   `sim-daemon` has no reader.
   Use `StubURLProtocol` and `LocalWebSocketServer` with the payload shapes above.
   Rule 8 asks for one preview for each accessory state.

Out of scope: raw tag writes (`nfc.write`), the reader's on/off switch, and tag dumps.
The conversation app owns the hats, so this app does not need `/api/nfc` for them.
Those routes matter only for tags that run "your own code".
If they become necessary and the spec does not carry them,
write them by hand, as `Sources/ReachyKit/Transport/RobotConnection+WiFi.swift` does.

## The Hoverboard

### What is known

Pollen's app PR #129 drives the base from its telepresence tab.
It has two paths with the same command:

| Mode                          | Path                                 | State                          |
| ----------------------------- | ------------------------------------ | ------------------------------ |
| Normal                        | phone → data channel → daemon → base | the daemon side is not written |
| Manual (a switch in settings) | phone → base over Bluetooth LE       | a stub with a simulated signal |

The command is a legacy `{"type": …}` command on the same channel as `set_full_target`:

```json
{ "type": "overboard_drive", "linear": 0.42, "angular": -0.1, "seq": 17 }
```

- `linear` and `angular` are in [-1, 1].
  Positive `linear` is forward.
  Positive `angular` is a left turn (counter-clockwise from above, ROS REP-103).
- The phone applies a quadratic curve to both axes and rounds them to three decimals.
  The base maps them to real speeds.
- `seq` counts up on each link, so the receiver can find drops and reordering.
- A changed value goes out on the next 100 ms tick, so at most 10 Hz.
- A held value repeats every 500 ms as a heartbeat.
  The PR asks the base for a watchdog that stops after about one second of silence.
- On release, the phone sends three explicit STOPs (`linear = angular = 0`), and then nothing.

Today the daemon logs `WebRTC invalid command: … 'overboard_drive' …`
and replies `{"error": "Invalid command: …"}`.
The PR counts those replies to prove that the phone-to-daemon half works.

Manual mode parks the head, releases the robot's WebRTC session and shows only the wheels.
Its real Bluetooth link is to follow the protocol of a `reachy_mini_wheels_app` Space.
A search of Hugging Face and GitHub on 2026-10-31 found no such Space.

The PR itself lists four open questions:

- Does manual mode keep the robot session or release it?
- Does Bluetooth work with no robot at all?
- What stops the wheels when the app goes to the background?
- Does the daemon own an `overboard.*` namespace instead of a legacy command type?

Unknown: how the base connects to the robot, its speed and battery,
and whether the robot needs an OS update.

### What this app would add

1. **A Wheels stick on the camera screen.**
   The pad, the reset button and "Follow my head" sit in `TeleopPadCluster`
   (`Sources/ReachyUI/ViewportContent.swift:79`).
   The store's "dual joysticks" means the head pad stays and a second stick appears.
2. **A pacer of its own.**
   `TeleopDriver` moves a goal and has no heartbeat and no STOP,
   and the channels pace at 33 ms with a slew limiter.
   A held wheel stick must repeat, and a held head target must not.
   So the wheels need an actor of their own beside `RemoteTeleopChannel`,
   with the 100 ms tick, the 500 ms heartbeat and the STOP burst.
   It sends with `control.sendIfOpen("overboard_drive", payload: …)`
   (`Sources/ReachyKit/Central/RemoteControlChannel.swift:185`),
   which drops a frame when no peer is attached instead of queueing it.
3. **A LAN path.**
   LAN teleop uses the `/api/move/ws/set_target` WebSocket
   (`Sources/ReachyKit/Transport/SetTargetClient.swift:14`),
   and it carries only a full-body target.
   So the LAN needs the robot's own data channel through `RemoteRobotLink(address:)`
   (`Sources/ReachyMedia/RemoteRobotLink.swift:47`), which only the first run uses today,
   or a REST route that does not exist yet.
4. **A decision about the game controller.**
   Its left stick turns the body and moves the head up and down
   (`Sources/ReachyTeleop/GamepadMapping.swift:69`).
   Pollen's PR puts the wheels on that stick.
5. **Safety stays in the daemon (rule 2).**
   The watchdog belongs to the daemon or to the base.
   This app sends the heartbeat,
   and sends the STOP burst when the scene goes to the background.
6. **No Bluetooth link to the base yet.**
   The protocol is not public.
   Also, `BLETransport` is tied to the robot:
   its scan filter and `BLECharacteristicID` name the robot's UUIDs only
   (`Sources/ReachyKit/BLE/BLEGATT.swift:24`).
7. **The Apple TV app gets it cheaply.**
   It shares `ReachyTeleop`, so a game controller can drive the base there too.

## When to start

| Work       | Start when                                                                                              |
| ---------- | ------------------------------------------------------------------------------------------------------- |
| Hats       | #1448 and the `nfc.*` relay are on reachy_mini `main`, and `rfid.*` is on the conversation app's `main` |
| Privacy    | #1455 and its hat hookup are on reachy_mini `main`                                                      |
| Hoverboard | a daemon handler for the drive command is on `main`, and a base is at hand                              |

The `upstream-release` issue that each reachy_mini release opens here is the checkpoint.

Questions to ask Pollen:

- Does the base get a daemon-owned `overboard.*` namespace, or the legacy `overboard_drive` type?
- How does the base connect to the robot, and which side runs the watchdog?
- Will the `reachy_mini_wheels_app` Bluetooth protocol be public?
- Which tag text does each shipped hat carry?
