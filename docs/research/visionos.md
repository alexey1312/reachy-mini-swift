# visionOS: head teleoperation from Apple Vision Pro

The goal: the reader turns their head, the robot turns its head,
and the reader watches the robot's camera in a window.
This file records what was measured on 2026-10-17,
what only a headset can answer,
and what is left.
It builds on the scratch port of 2026-10-14,
whose findings are in the memory file `apple-platforms-feasibility.md`;
that port's diffs are gone, so the work below was done again.

## The shape

```
Apple Vision Pro                                 Reachy Mini
┌──────────────────────────────────────┐
│ ReachyVision window (ReachyRootView) │  WebRTC  ┌─────────┐
│   Live tab: camera ◀────────────────────────────│ camera  │
│   "Follow my head" ──┐               │          │         │
└──────────────────────│───────────────┘          │         │
                       ▼                          │         │
  HeadphoneTeleop.shared (the hub)                │         │
    ▲ readings          │ HeadAim                 │         │
    │                   ▼                         │         │
  HeadsetTracker   TeleopDriver.aim ── ws/set_target ─▶ head │
    ▲  (ARKit device anchor, 50 Hz)   (slew limiter,│        │
    │                                  daemon limits)        │
  HeadsetTrackingSpace (empty, mixed) └─────────────┴─────────┘
```

The headset is one more `HeadTracker` behind the hub that #196 built for AirPods.
The claims, the gate (awake, no power transition, pollen-robotics/reachy_mini#1430),
the measured reach, `TargetSlewLimiter.headTracking` and every way back to neutral are the same code.
Safety stays in the daemon (project rule 2).

## Measured

### The toolchain

- Xcode 27.0 (27A266a) carries the visionOS 27.0 SDK and its simulator SDK.
- `xcrun simctl list runtimes` listed iOS 27.0 and 27.1, tvOS 27.0 and watchOS 27.0,
  and no visionOS runtime.
  `xcodebuild -downloadPlatform visionOS` then installed visionOS 27.0 (24M362), 7.52 GB.

### The launch

On the `Apple Vision Pro` simulator, visionOS 27.0, the Debug simulator build launches
to the connect gate in a window: the stepper, the Nearby and Remote segments,
the Bluetooth setup row and the manual address field.
A fresh install opens the "Set up a robot" sheet over the gate first, as on the iPhone.
Its footnote says "iOS will ask for permission", which is wrong on visionOS.

### The tracker in the simulator

A temporary patch, not committed, switched the shared hub on at launch, switched it off
8 s later, and logged the tracker to OSLog. No robot was connected, because the hub
takes readings whether or not a surface claims it. Read with `simctl spawn … log stream`:

| Time (s) | Event                                                             |
| -------- | ----------------------------------------------------------------- |
| 0.00     | Hub `off` → `setOn(true)` → `waiting`                             |
| 0.20     | `WorldTrackingProvider.isSupported` is true                       |
| 0.24     | `session.run` returns; the first anchor makes the hub `following` |
| 0.62     | `HeadsetTrackingSpace` appears; `openImmersiveSpace` `opened`     |
| 8.0      | `setOn(false)` → `off`                                            |
| 8.6      | The space disappears; no pose arrives after it                    |

- Poses arrive at about 45 per second against the 50 asked for.
- The app's own window stays in view while the mixed space is open.
- In the simulator `session.run` did not wait for the space, and anchors arrived before it opened.
  So the retry in `HeadsetTracker.run(_:)` never ran here; whether a headset refuses the run
  outside a space is still open.
- The pose stayed at zero, because nothing moved the simulated head.
  The controls that move it are in Device Hub, which this run did not drive.

### WebRTC

- `livekit/webrtc-xcframework` 150.7871.03 ships `xros-arm64` and `xros-arm64-simulator` slices
  with `minos 26.0`, and tvOS slices with `minos 17.0`.
  The zip is 69 MB and matches the checksum in its manifest.
- Its symbols carry an `LK` prefix (`RTC_OBJC_TYPE_PREFIX`),
  on enums and the SSL functions as well as on classes.
  `Sources/ReachyMedia/WebRTCNames.swift` maps them back.
- Its visionOS slice has no `RTCMTLVideoView`,
  and its `RTCEAGLVideoView` header needs OpenGL ES, which visionOS does not have.
  `SampleBufferVideoView` draws through an `AVSampleBufferDisplayLayer` instead.
- Its tag `150.7871.03` resolves in SwiftPM as `150.7871.3`.
- The simulator slices are arm64 only, so a generic visionOS simulator build failed to link x86_64.
  `EXCLUDED_ARCHS[sdk=xrsimulator*] = x86_64` on the app fixes it;
  every Mac that runs a visionOS simulator is Apple silicon.

### What the visionOS SDK refuses

Each of these compiled on iOS and macOS and failed on visionOS with "is unavailable in visionOS":

| Symbol                                         | Where                                      | What visionOS does instead |
| ---------------------------------------------- | ------------------------------------------ | -------------------------- |
| `glassEffect`, `Glass`, `GlassEffectContainer` | `ReachySurface`, `ReachySurfaceGroup`      | The role's material        |
| `.glassProminent`                              | `ReachyButton`                             | `.borderedProminent`       |
| `scrollEdgeEffectStyle`                        | `ReachyChrome`                             | Nothing to soften          |
| `ToolbarSpacer`                                | `LogConsoleView`                           | The groups sit together    |
| `inspector`, `inspectorColumnWidth`            | `ViewportColumnModifier`                   | The viewport stays inline  |
| `ControlConfigurationIntent`                   | `ControlConfigurationIntents`              | No controls                |
| `CMHeadphoneMotionManager`                     | `HeadphoneTeleop` (now `HeadphoneTracker`) | `HeadsetTracker`           |

`#available(iOS 26.0, macOS 26.0, *)` does not keep these out, because its `*` passes on visionOS.
They sit behind `#if !os(visionOS)` instead.
One more fork is a choice and not a refusal:
the floating viewport's dock bleed is zero on visionOS, because a headset has no screen cutout,
although `effectiveGeometry.interfaceOrientation` compiles there.

Citadel's fork of swift-nio-ssh fails differently:
`Unable to resolve module dependency: 'NIO'` in `NIOSSH`, because it imports `NIO` without depending on it.
Citadel is now linked on iOS and macOS only, and `RobotFileSystems.ssh(robot:)` answers nil elsewhere.

### What built

- `ReachyMedia` for the visionOS, tvOS and iOS simulators (PR #207).
- `ReachyDesign`, `ReachySSH`, `ReachyScene`, `ReachySimulator`, `HuggingFaceAuth`,
  `ReachyWidgetUI`, `ReachyMedia` and `ReachyUI` for the visionOS simulator.
- The `ReachyVision` app for `generic/platform=visionOS Simulator`:
  an arm64 bundle of 63 MB in Debug, `LiveKitWebRTC.framework` embedded,
  `UIDeviceFamily` 7, bundle ID `com.alexey1312.ReachyMini`.
- `mise run test` and `mise run lint` on macOS.

### The Live tab's 3D view

Measured on 2026-10-17 in the `Apple Vision Pro` simulator,
with a temporary `onGeometryChange3D` probe that logged each view's `Rect3D` in the global space.

| View              | Before: origin (x, y, z) and size | After                     |
| ----------------- | --------------------------------- | ------------------------- |
| `RealityView`     | 0, 92, 0 — 1100 × 628 × 540       | 0, 92, 0 — 1100 × 628 × 0 |
| View switcher     | 0, 92, **540** — 108 × 60         | 0, 92, 0 — 108 × 60       |
| Teleoperation pad | 864, 532, **540** — 236 × 188     | 864, 532, 0 — 236 × 188   |

- **A flexible `RealityView` takes the window's offered depth, and a 2D overlay lies on its front face.**
  At 540 pt nearer the eye than the window, perspective pushed the view switcher past the leading edge
  and over the title, and the pad past the trailing edge.
  `.frame(depth: 0)` on the visionOS branch of `RobotSceneView` puts both back on the window.
- **A window ignores the `PerspectiveCamera`** and draws the entities at real size from the centre of the view.
  The robot, 0.39 m tall with its base at the origin, rose past the window's top edge.
  `RobotSceneView` now scales it to 70 % of the view, centres it and stands it in front of the window.
  At 80 %, perspective drew its base past the window's bottom edge.
- `Sources/ReachyScene/AGENTS.md` has the rules that follow from this.

### The head

- `queryDeviceAnchor` works only while the app has an immersive space open,
  and needs no authorization.
  Apple's sample "Placing entities using head and device transform" says both.
  So "Follow my head" opens an empty, mixed `HeadsetTrackingSpace`,
  and closing the space from the Digital Crown switches the hub off.
- An immersive space is a second scene,
  so it needs `UIApplicationSupportsMultipleScenes = true` ("Presenting windows and spaces").
  The iPhone app sets it to false on purpose for its quick-action scene delegate.
  That is why visionOS is a target of its own and not a fourth destination of `ReachyMini`.
- ARKit's frame is documented: right-handed, y up, the device looking along -z.
  `HeadsetAttitude` decomposes the pose as Ry(yaw) · Rx(pitch) · Rz(roll),
  which gives yaw positive turning left, pitch positive looking up and roll positive with the left ear down.
  The daemon's frame (x forward, y left, z up, `from_euler("xyz", …)`) puts the robot's roll positive
  with the right ear down, so `HeadphoneMotionMapping.headset` turns `rollSign` round
  and keeps the measured reach (yaw ±40°, pitch 35° down and 30° up, roll ±30°, a 35° tilt cone).
- Readings are relative to a reference, as with AirPods,
  but angle by angle rather than one rotation against another:
  ARKit knows where gravity is, so a reference taken looking a little down keeps a turn a pure turn.
- `HeadsetAttitudeTests` (10) and `HeadTrackerHubTests` (7) hold the geometry, the signs and the hub's side.
  Flipping `rollSign` back turns two of them red.

## Needs a headset, or at least a visionOS simulator

- **The signs and the feel.** They follow from documented frames, and they are still a device check,
  as they were for AirPods. A wrong sign is one number in `HeadphoneMotionMapping.headset`.
- **Whether `session.run` throws on a headset** when it starts before the space has opened.
  It did not in the simulator. `HeadsetTracker.run(_:)` retries every 500 ms in case it does,
  and logs each refusal to the `HeadsetTracker` category.
- **A moving pose.** The simulator run read a still head;
  a turn in the simulator moves the camera through Device Hub, and a headset does the rest.
- **The picture.** `SampleBufferVideoView` has never drawn a frame.
  The robot sends H.264, which arrives as a VideoToolbox buffer and goes to the layer as it is;
  the simulator daemon may send VP8, which goes through the I420 copy.
- **Turning away from the window.** The window is fixed in the room,
  so a 40° turn moves the picture toward the edge of the view.
  How far a reader can turn and still watch is the main open question about the feel.
- **Audio.** `MediaAudioSession` now configures `.playAndRecord` / `.videoChat` on visionOS as on iOS,
  without the call framing, which stays iOS only.
- **The window.** Its first size (1100 × 720) is a guess, and the materials that replace glass have not been seen.
- **Local network and Bluetooth prompts**, which visionOS shows like iOS.

## Left

- **A head-locked camera.** Inside the immersive space the picture could ride on the head
  (`AnchorEntity(.head)`), so it stays in view whatever the head does.
  That is a different screen and a different decision; this change keeps the window.
- **Orbit and zoom in the 3D view.** The gestures move the `PerspectiveCamera`, which a window ignores,
  so on visionOS they do nothing. Turning the `stand` entity instead is the likely way.
- **Copy that names iOS.** `OnboardingWelcomeStep` says "iOS will ask for permission" on visionOS too.
- **Widgets** on visionOS. The app shares the iPhone's intents and its ten App Shortcuts,
  and `Scripts/check-appintents-metadata.sh` holds the visionOS archive to them,
  without the Live Activity intent, because visionOS has no Live Activities.
- **SFTP**, until Citadel's swift-nio-ssh fork depends on the module it imports.
- **CI.** No job builds visionOS; the five macOS slots are spent.
  `xcodebuild -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyVision -destination 'generic/platform=visionOS Simulator' build`
  is the local check.
- **A release.** The target shares the iPhone app's bundle ID,
  so its first upload replaces the compatible iPad app that Apple Vision runs today.
  Xcode Cloud archives it with the scheme `ReachyVision`;
  `ci_post_clone.sh` stamps its build number with the iPhone app's,
  because both inherit the project-level `CURRENT_PROJECT_VERSION`.

## For TestFlight

- **The icon** is a solid image stack that `mise run theme:icons` generates
  beside the six Icon Composer bundles (`AGENTS.md` has the layers).
- **`ITSAppUsesNonExemptEncryption` is false**, as on the iPhone, so a build does not wait on export compliance.
- **`CFBundleIconName` is `AppIcon`**, as on the iPhone, because `actool` leaves it out.
