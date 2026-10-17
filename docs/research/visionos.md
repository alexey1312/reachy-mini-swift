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
- `xcrun simctl list runtimes` lists iOS 27.0 and 27.1, tvOS 27.0 and watchOS 27.0,
  and **no visionOS runtime**.
  So everything below was compiled and none of it was launched.

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

- **Launch.** The app has not been launched; the visionOS runtime is not installed on this Mac.
  The first check is that it reaches the connect gate.
- **The signs and the feel.** They follow from documented frames, and they are still a device check,
  as they were for AirPods. A wrong sign is one number in `HeadphoneMotionMapping.headset`.
- **Whether `session.run` waits or throws** when it starts before the space has opened.
  `HeadsetTracker.run(_:)` retries every 500 ms in case it throws, and logs each refusal
  to the `HeadsetTracker` category.
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
- **An app icon.** visionOS wants a three-layer image stack, and the Icon Composer bundles do not cover it.
  The build has no icon at all.
- **App Shortcuts, widgets and the Spotlight rows** on visionOS. `ReachyShortcuts` is in the iPhone target.
- **SFTP**, until Citadel's swift-nio-ssh fork depends on the module it imports.
- **CI.** No job builds visionOS; the five macOS slots are spent.
  `xcodebuild -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyVision -destination 'generic/platform=visionOS Simulator' build`
  is the local check.
- **A release.** The target shares the iPhone app's bundle ID,
  so an upload would replace the compatible iPad app that Apple Vision runs today.
  That is a decision for a release, not for this change.
