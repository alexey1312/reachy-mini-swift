# Apple Vision Pro screenshots

The four App Store screenshots of the visionOS app (`en-US/`), first taken for 0.7.2,
and how to take them again.
App Store Connect keeps the visionOS set apart from the iPhone and iPad sets,
under the display type `APP_APPLE_VISION_PRO`, which takes one size: 3840 × 2160.
The Apple Vision Pro simulator captures at exactly that size,
so nothing here is scaled, cropped or composed.

| File                  | Screen                                                      |
| --------------------- | ----------------------------------------------------------- |
| `1-head-tracking.png` | Live → Controller: the head pad and "Follow my head"        |
| `2-robot.png`         | Robot: connected, awake, the robot's name and software      |
| `3-moves.png`         | Moves: the dances the robot can play                        |
| `4-connect.png`       | Connect: nearby robots, Bluetooth setup and a typed address |

Each one is the app as it runs, against `mise run sim-daemon`.
That is why the Robot screen says "Model: Simulation".

## What they do not show, on purpose

- **The camera.** Against this Mac's `sim-daemon` the camera never streams
  (the WebRTC producer fails on the default audio input; the root `AGENTS.md` has the measurement),
  so "Follow my head" over the picture never appears.
  The Controller screen offers the same switch, and that is the screen in the set.
  Do not stand a picture in for the stream.
- **The Live tab's 3D view.** On visionOS the robot model rises out of the top of the window,
  and the view switcher and the toolbar overlap the title.
  That is a layout bug to fix, not a screen to ship.
- **Discover.** It opens on the community notice, and passing it is an agreement.

## Taking them again

You need the visionOS simulator runtime (`xcodebuild -downloadPlatform visionOS`, 7.5 GB),
a booted `Apple Vision Pro` simulator and a generated project (`mise run project`).
Run everything from the repository root.

1. Build and install the app:

   ```bash
   xcodebuild -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyVision -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -derivedDataPath Apps/DerivedData build
   ```

   ```bash
   xcrun simctl install booted Apps/DerivedData/Build/Products/Debug-xrsimulator/ReachyVision.app
   ```

2. Take the connect screen **before** `sim-daemon` runs.
   The simulator probes loopback, so with a daemon up the app connects before anything can be captured.
   `--reachy-smoke` shows the gate with no sweep and without the "Set up a robot" sheet,
   whose footnote names iOS on visionOS too:

   ```bash
   python3 screenshots/visionos/capture.py smoke connect 8
   ```

3. Start the robot: `mise run sim-daemon`.
   The first start after a new `.venv-sim` waits about eight minutes on GStreamer's registry scan;
   it is ready when `curl http://127.0.0.1:8000/api/daemon/status` answers.
4. Launch the app once and let it connect.
   A robot it has never set up opens the first-run flow in place of the tabs.
   Tap **Skip setup**, or, with the app stopped, mark that robot settled in the app group:

   ```bash
   xcrun simctl get_app_container booted com.alexey1312.ReachyMini groups
   ```

   ```bash
   xcrun simctl spawn booted defaults write <group container>/Library/Preferences/group.com.alexey1312.ReachyMini ReachyKit.firstRunRecords -dict reachy_mini settled
   ```

5. Reach each screen and capture it with `xcrun simctl io booted screenshot <file>`.
   With the Mac's screen unlocked, tap through Device Hub: Robot, Moves, and Live → Controller.
   With the screen locked, Device Hub draws no window,
   so apply `navigate.py`, rebuild and install as in step 1, and let `capture.py` choose the screen:

   ```bash
   python3 screenshots/visionos/navigate.py
   ```

   ```bash
   python3 screenshots/visionos/capture.py controller head-tracking
   ```

   Then `robot robot` and `moves moves`, and revert the edits before anything else:
   `git checkout -- Sources/ReachyUI/Shell`.
6. Copy the four captures over the files in `en-US/`, and drop their alpha channel:

   ```bash
   swift screenshots/visionos/flatten.swift screenshots/visionos/en-US/*.png
   ```

## Uploading

Into the en-US localization of the visionOS version, through the release key:

```bash
mise run asc -- screenshots upload --app 6799644194 --version-id <visionOS version id> --locale en-US --device-type APP_APPLE_VISION_PRO --path screenshots/visionos/en-US --replace --dry-run
```

Drop `--dry-run` and add `--confirm` to replace the set, then read it back.
On a version whose set is still empty, as 0.7.2's was, leave out `--replace` too.
`--path` is the locale folder and not this one, because `asc` tries to decode every file it finds there:

```bash
mise run asc -- screenshots list --version-id <visionOS version id> --locale en-US
```

The upload takes the files in name order, which is the order the store shows them in.
