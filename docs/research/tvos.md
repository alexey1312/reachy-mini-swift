# Hey Reachy on Apple TV

The 2026-10-14 platform review put the Apple TV idea as
"the robot's eyes on the big screen, and play with a game controller",
and rated a native app large because a TV interface is moved by focus.
This file records the first app:
what it is built from, what was measured, how the camera works, and what is left.

## What it is

`Apps/ReachyTV` is a tvOS 26 app with four screens of its own:
connect, a robot's state, the two decisions a connect can stop at, and driving.
It is not a port of ReachyUI.
That target does not compile for tvOS (about 75 errors in 26 files, measured on 2026-10-14),
and its screens are touch screens with forms, sheets and a five-tab shell.
A TV wants fewer and larger controls that the focus engine can reach.

What the TV shares is everything below the views:

| Shared                                              | From         | What the TV does with it                                          |
| --------------------------------------------------- | ------------ | ----------------------------------------------------------------- |
| `RobotSession`                                      | ReachyKit    | Handshake, status poll, `wake()`, `sleep()`, `startBackend()`     |
| `CandidateSweep`, `RobotBrowser`, `BonjourResolver` | ReachyKit    | Finds and reconnects to robots, as the phone's gate does          |
| `TeleopDriver`, `JoystickMapping`, `GamepadTeleop`  | ReachyTeleop | Drives the robot with a game controller or the Siri Remote        |
| `CameraSession`, `CameraVideoView`                  | ReachyMedia  | The robot's camera behind the drive screen, over LiveKit's WebRTC |
| `.reachy(_:)`, `Typography`, `reachySurface`        | ReachyDesign | Strings in the one catalogue, type roles, the legend's card       |

Two things moved down for this, and neither changes behaviour on the phone:

- **`ReachyTeleop` is a new target.**
  `JoystickMapping`, `GamepadMapping`, `GamepadTeleop`, `TeleopDriver` and `HeadAim` moved out of ReachyUI,
  which now imports it.
  Their tests moved to `Tests/ReachyTeleopTests` unchanged except for the import.
- **`CandidateSweep` moved from ReachyUI to ReachyKit**,
  so the TV reconnects to the last robot and retries known addresses by the same rules as the phone.

ReachyDesign needed one gate: tvOS has no `.bar` material, so `.scrim` and `.window` take `.regular` there.

### Why tvOS 26

ReachyDesign's surfaces use Liquid Glass, which is tvOS 26, and RealityView, for a later 3D twin, is tvOS 26 too.
At a tvOS 18 floor ReachyDesign failed on `Glass` and `glassEffect`; `.bar` fails at any floor.
tvOS 26 runs on every Apple TV HD and 4K
([AppleInsider](https://appleinsider.com/articles/25/06/06/which-apple-tv-sets-will-run-the-new-tvos-26)),
so the floor costs no hardware.
The shared WebRTC change (`68f24d56`) names the same floor.

### Running it

```bash
./bin/mise run build:app:tv
```

Then install `Apps/DerivedData/Build/Products/Debug-appletvsimulator/ReachyTV.app` on a tvOS simulator
with `xcrun simctl install`, and start it with `xcrun simctl launch <udid> com.alexey1312.ReachyMini`.
With `mise run sim-daemon` running on the same Mac, it connects by itself.

## Input

- **A game controller drives, and moves no focus.**
  The Info.plist declares no `GCSupportsControllerUserInteraction`.
  With it, the left stick and the B button would also move focus and go back,
  and they already turn the body and reset.
  So the Siri Remote moves through the screens, and a controller drives on the drive screen.
  The mapping is the phone's (`Sources/ReachyUI/AGENTS.md`, "A game controller").
- **The Siri Remote is a pad.**
  `GamepadTeleop` takes its micro gamepad on tvOS only, with absolute touch positions:
  where the thumb rests on the touch surface is the deflection,
  lifting it recentres the head, and holding it at the side turns the body,
  as the phone's touch pad does.
  Play/Pause resets.
  The most recently used of the remote and a controller drives.
- **Safety stays in the daemon** (project rule 2).
  Both inputs write one target through `TeleopDriver`, with the same slew limiter as the phone,
  and only while the robot is awake and no power transition runs (pollen-robotics/reachy_mini#1430).

## What was measured

### On the tvOS simulator, 2026-10-17

Xcode 27.0, an Apple TV 4K (3rd generation) simulator on tvOS 27.0,
and `mise run sim-daemon` (daemon 1.12.0, MuJoCo) on the same Mac.

| Check                      | Result                                                                                      |
| -------------------------- | ------------------------------------------------------------------------------------------- |
| `mise run build:app:tv`    | 0 errors. No warning in `Apps/ReachyTV` or ReachyTeleop                                     |
| ReachyKit for tvOS 26      | Builds unchanged                                                                            |
| ReachyDesign for tvOS 26   | Builds after the `.bar` gate. At tvOS 18 it also failed on `Glass`                          |
| Launch                     | The connect screen, with "Searching…" until a robot answers                                 |
| Connect                    | By itself, over loopback, through `CandidateSweep`; the robot screen shows `127.0.0.1`      |
| Wake                       | The daemon logged `POST /api/motors/set_mode/enabled`, then `POST /api/move/play/wake_up`   |
| Drive screen               | Opens `/api/move/ws/set_target`, and claims the controller                                  |
| `mise run test`            | 2313 passed, among them the 48 moved to `ReachyTeleopTests` and the 4 `CandidateSweepTests` |
| `mise run lint`            | Passes                                                                                      |
| `mise run snapshots:build` | Passes; Prefire's generated tests import ReachyTeleop                                       |

**No physical controller was paired to this Mac, and a session cannot press the remote's buttons.**
So the drive path below the controller was driven by a temporary harness, not committed:
the app's own `session.wake()`, then the real `TeleopDriver` over the real channel,
with the targets a held right stick and a held left stick produce.
The robot's pose, read from `/api/state/full` four times a second:

| Step                        | Target                            | Robot                             |
| --------------------------- | --------------------------------- | --------------------------------- |
| Look, stick up and left     | yaw 32°, pitch −20°               | yaw 31.9°, pitch −20.0°           |
| Turn and roll, held for 1 s | yaw 66.4°, body 34.4°, roll 10.3° | yaw 65.9°, body 34.4°, roll 10.0° |
| Reset                       | 0                                 | 0 within 2.5 s                    |

Two things found on the way, both worth knowing before the next run:

- **The tvOS simulator has a game controller of its own.**
  `GCController` lists an extended gamepad named "Gamepad",
  `GamepadTeleop` picked it, and the drive screen showed the controller's legend.
  Its sticks rest at zero, and the robot stayed at neutral the whole time,
  which is the "only a change is reported" rule doing its job.
- **`sim-daemon` cannot show a sleeping robot.**
  The MuJoCo backend answers `Enabled` to every motor-mode read and ignores every write
  (`daemon/backend/mujoco/backend.py`, `get_motor_control_mode` and `set_motor_control_mode`),
  so `isAwake` is always true there, and only the daemon's log can show that a wake was sent.

Not checked, and each needs a device or a person at the simulator:
a real controller and a real Siri Remote driving, Menu leaving the drive screen,
the discovery list with a robot in it (the sweep connected over loopback first),
and the Local Network prompt, which a simulator never shows.

## The camera

stasel/WebRTC ships no tvOS slice.
The shared change that makes it conditional and adds `livekit/webrtc-xcframework` for tvOS and visionOS
is #207 (`68f24d56`), and the camera branch is stacked on it and on the TV app.
The drive screen opens the phone's own `CameraSession` on the robot's `:8443` signalling
and draws ReachyMedia's `CameraVideoView` full bleed behind the legend,
with the phone's words for each state of the stream and a Try again button for a stall.
It runs while the robot sleeps, so Drive opens whenever the backend runs:
the screen is for watching as much as for driving, and the controller drives only once the robot is awake.
The microphone stays off; the robot's own sound plays on the TV.

- **LiveKit's tvOS simulator slice is arm64 alone** (`tvos-arm64-simulator`, 150.7871.3),
  and a generic simulator destination links x86_64 too, which fails on every `LKRTC` symbol.
  The TV target excludes x86_64 for the simulator SDK.
  Building ReachyMedia alone, as #207 was checked, never links, so only an app shows this.
- **A muted microphone track is attached all the same**, because the robot's `webrtcsink` never renegotiates.
  iOS holds libwebrtc in manual audio mode, so capture starts only on the first unmute.
  Nothing sets that mode on tvOS, and whether a sending audio stream then opens an input is a device check.
  A process with no usage string is killed when it does,
  so the TV declares `NSMicrophoneUsageDescription`, in the words of the phone's camera string.
  A receive-only audio path for the TV would remove the question; it is a change to `CameraSession`.

Measured on the same simulator and `sim-daemon`:
the app linked once x86_64 was excluded,
opened `:8443` (the signalling server logged a new listener and its `list`),
sent `POST /api/media/acquire`, and showed "Waiting for camera".
The daemon had no producer to offer: its sender failed at start on `GstOsxAudioSrc`
with `not-negotiated (-4)`, with `Jump Desktop Microphone` as this Mac's default input,
which is the failure the root `CLAUDE.md` records for `test:sim`.
**So no picture has been seen on a TV yet.** That needs a real robot, or this Mac with another default input.

## What is left

- **The relay and Hugging Face sign-in.**
  `ASWebAuthenticationSession` exists on tvOS 16 and later, without `prefersEphemeralWebBrowserSession`,
  but a TV has no browser to sign in with; Hugging Face's device-code OAuth is the natural flow.
  Until then the TV reaches robots on its own network only.
- **Moves, sounds and apps.**
  The session already carries them; each needs a focus-driven screen.
  JS apps cannot run: tvOS has no WebKit, so `AppSettingsScreen` and the hosted web apps have no TV form.
- **A controller that also moves focus.**
  The tvOS way is to host the drive screen in a `GCEventViewController` with `controllerUserInteractionEnabled`
  off, read the controller's Menu button to leave, and then declare `GCSupportsControllerUserInteraction`.
- **The first run.**
  The TV skips it; the phone's app runs it.
- **The 3D twin.** RealityView is tvOS 26; ReachyScene has not been built for tvOS.
- **Power off, settings, themes.** The TV uses the default theme.
- **Shipping, the user's half.** The app is release-ready on this side:
  it shares the iPhone app's bundle identifier (`com.alexey1312.ReachyMini`), as the visionOS app does,
  so it is the same App Store app (universal purchase);
  `mise run theme:icons` writes its layered icon and top shelf images;
  `ITSAppUsesNonExemptEncryption` is false;
  Xcode Cloud's build-number stamp covers it, and `check-appintents-metadata.sh` accepts a tvOS bundle,
  which carries no App Intents by design.
  What is left is outside the repository: a tvOS archive action for the scheme `ReachyTV`
  in the Xcode Cloud workflow, the tvOS platform and its screenshots in App Store Connect, and TestFlight.
  The two usage strings are English only: the TV app has no `InfoPlist.xcstrings` yet.
- **CI.** No job builds the TV app, because the five macOS slots are spent.
  `mise run build:app:tv` is the only thing that compiles the TV shell and ReachyTeleop's tvOS branch.
