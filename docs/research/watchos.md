# watchOS: what the watch does for Hey Reachy

On 2026-10-19, after the tvOS and visionOS releases,
the question was which Apple Watch scenarios make sense.
This file records what Apple's documentation and this repository say,
what ships with no watch app,
what a watch app would cost,
and the device check that decides the next step.
Issue #75 holds the earlier history.

## The shape

```
Apple Watch ──①──▶ iPhone ──LAN────▶ Reachy Mini
            ──②──▶        ──relay──▶
   ✗ direct: LAN HTTP, WebSocket, Bonjour, WebRTC
```

The watch cannot reach the robot.

- [TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)
  calls WebSocket, Network framework and Bonjour "low-level networking".
  watchOS allows it only for audio streaming, a CallKit VoIP call and DeviceDiscoveryUI.
  So the state stream `/api/state/ws/full` and discovery are closed on a watch.
- Apple DTS says that `URLSession` to a LAN address "won't work by default"
  ([forum thread 785846](https://developer.apple.com/forums/thread/785846)).
  Nobody has tried it on a device here.
- Neither `stasel/WebRTC` nor `livekit/webrtc-xcframework` has a watchOS slice.

So every command goes through the iPhone, by one of two routes.

1. **The system route.**
   watchOS 26 shows an iPhone app's controls in Control Center and the Smart Stack,
   and runs the action on the iPhone
   ([WWDC25 session 334](https://developer.apple.com/videos/play/wwdc2025/334/), 04:44).
   A control whose action brings the iPhone app forward does not appear.
   An iPhone Live Activity appears in the Smart Stack the same way.
   Neither needs a watch app.
2. **The app route.**
   A watch app calls `WCSession.sendMessage`,
   and the system wakes the iOS app in the background.
   This works only while the watch app is in the foreground:
   in the background `isReachable` is false outside special modes such as a workout.
   So a watch widget or a Siri intent that runs on the watch has no live channel to the phone.

## What ships with no watch app

| Surface                                      | State                       | Notes                                                                                     |
| -------------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------- |
| Running-app Live Activity in the Smart Stack | Shipped in 0.6.1            | `supplementalActivityFamilies([.small])`; the Stop with double tap is new, see below      |
| Nine iPhone controls                         | Should appear on watchOS 26 | All nine run in the widget extension and open nothing; nobody has checked them on a watch |
| Notifications for finished jobs              | Shipped                     | iOS forwards them to the watch while the iPhone is locked                                 |
| Siri                                         | Does not work               | App Shortcuts must come from a watch app on the watch itself                              |

The Siri row comes from
[WWDC23 session 10102](https://developer.apple.com/videos/play/wwdc2023/10102/), 22:05.
The new Siri in watchOS 27 has not been checked against it.

All nine controls dial a LAN address (`RobotIntentTarget.connection`),
so none of them works away from home.
Three are configurable (`promptsForUserConfiguration`):
the move, the app and the sound.
Whether a person can configure them on the watch is unknown.

## The Stop on the watch card

The `.small` layout now draws the Stop button,
and the extension marks it `.handGestureShortcut(.primaryAction)`.
Apple lists remote Live Activities from iOS among the places where double tap presses the primary action
([Enabling the double-tap gesture on Apple Watch](https://developer.apple.com/documentation/watchos-apps/enabling-double-tap)).
Double tap exists on Series 9 and later and on Ultra 2 and later.

The price is CarPlay.
`.small` is also the CarPlay layout,
and "buttons and toggles on Live Activities don't perform actions in CarPlay"
([Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)).
No API tells the watch and CarPlay apart.
The rule in `Sources/ReachyWidgetUI/AGENTS.md` is that a button that might do nothing is worse than none.
The [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities#watchOS)
puts the same choice another way:
leave buttons out of the watch layout if people are likely to watch the activity while driving.
Nobody follows a desk robot's app from the road, so the Stop goes in.
It stays only if the device check shows that it works on the watch.

The card also got the lock screen's insets, 12 pt across and 8 pt down.
The first recording showed the artwork against the card's edge,
because the closure draws to the edges and `.small` had no padding.
The HIG asks for even margins inside the rounded shape.
Whether the Smart Stack adds margins of its own is part of the device check.

## Scenarios

| Scenario                                 | Route        | Verdict                                                          |
| ---------------------------------------- | ------------ | ---------------------------------------------------------------- |
| Stop a move, an app or a sound           | 1            | Now: three controls exist                                        |
| Wake, sleep, power off                   | 1            | Now: three controls exist                                        |
| Play a move during a demo                | 1            | Now: `PlayMoveControl`, if it configures on the watch            |
| Start a robot app                        | 1            | Now: `ToggleRobotAppControl`                                     |
| A job finished                           | notification | Now: no work                                                     |
| A move grid with no setup                | 2            | Later, with a watch app                                          |
| Robot state on the watch face            | 2            | Later; the daemon API reports no battery level                   |
| Siri on the wrist                        | 2            | Later; App Shortcuts must live in the watch app                  |
| Control away from home                   | 2            | Later; the iPhone must open the relay in the background          |
| A dictated line for the conversation app | 2            | Later; `conversation.say` takes it as something to answer        |
| The head follows the wrist               | 2            | No: the bridge adds latency, and it runs only with the screen on |
| The robot's camera on the watch          | none         | No: no WebRTC on the watch and no snapshot route on the robot    |
| Voice through the watch                  | none         | No: the robot hears the room itself                              |
| Reactions to heart rate                  | none         | No                                                               |
| A watch app with no iPhone               | none         | No: it has nothing to talk to                                    |

## What a watch app costs

- **Code.** `ReachyKit` compiled for watchOS 11 with no change on 2026-10-14.
  `ReachyDesign` and `ReachyWidgetUI` compiled for watchOS 26 after two fixes,
  `Material.bar` and CoreSpotlight.
  The watch app must not link `ReachyMedia`.
- **Tuist.** The target is `product: .app` with `destinations: [.appleWatch]`,
  and `ReachyMini` depends on it with `.when([.ios])`, as it does on `ReachyStickers`.
  Tuist writes no watch keys for an `.app` target,
  so `WKApplication`, `WKCompanionAppBundleIdentifier` and `WKRunsIndependentlyOfCompanionApp` go in by hand
  (the fixture `generated_ios_app_with_watch_application` at Tuist 4.212.0, and tuist#6281).
- **Build and CI.** The watch app builds inside the iOS app,
  so `build:app:ios` and the `App Build (iOS + widget)` job compile it.
  No sixth macOS slot is necessary.
- **Release.** The watch app ships in `Watch/` inside the iOS archive.
  Register its bundle ID before an Xcode Cloud run.
  Keep its versions on `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`,
  because App Store Connect refuses a watch version that does not match the iOS one.
  If the watch app links `ReachyWidgetUI`, it gets a second `Metadata.appintents`,
  and `Scripts/check-appintents-metadata.sh` fails until it learns about it.
- **App Store.** Apple Watch screenshots are required, in one size for all locales.
  The watch bundle needs its own `PrivacyInfo.xcprivacy`,
  because `ReachyKit` reads `UserDefaults`, a required-reason API.
  The repository has no privacy manifest at all today.
- **Tests.** swift-snapshot-testing 1.19.6 and Prefire 6.1.0 make no image snapshots on watchOS.
  Maestro does not drive a watch; XCUITest does, from Xcode 12.5.
  The Simulator never shows the TN3135 block,
  and `transferUserInfo` does not work there,
  so the bridge needs a paired device.

## The device check

Run it on watchOS 26 or later, with the iPhone on iOS 26 or later,
locked, and on the robot's Wi-Fi.
Use the TestFlight build that carries the Stop on the watch card.

1. List the controls that the watch's Control Center gallery shows for Hey Reachy.
2. Wake, sleep, play a move, stop it and play a sound from the wrist.
   Note the seconds from the tap to the motion.
3. Try to configure the move, app and sound controls on the watch.
4. Repeat the commands with Hey Reachy closed, and again with the iPhone off the robot's Wi-Fi.
5. Start an app on the robot with Hey Reachy open, then lock the iPhone.
   On the watch, find the card in the Smart Stack, press its Stop, and then try double tap.
6. Look at the card in CarPlay (Simulator → I/O → External Displays → CarPlay).

The results go in this file.
