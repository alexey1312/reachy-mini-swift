# ReachyMedia

The WebRTC session to the robot (`CameraSession` + its adapters), and since #78 the system-call
framing over it (`RobotCallController` + `CallLifecycle` + `MediaAudioSession`). Depends on
`ReachyKit` and the stasel/WebRTC binary framework, nothing else.

- **Linked by `ReachyUI` only, and `ReachyWidgetUI` must never gain the edge.** A widget process
  woken for a moment to draw two lines of text cannot afford to load a media stack —
  `Package.swift` states it beside the dependency list. That is also why `MicrophonePermission`
  lives here rather than in `ReachyKit` (the widget links ReachyKit, and AVFoundation is the same
  argument one framework smaller), and why `CallRobotIntent` lives in the app target rather than
  anywhere the appex links.

## The call framing (#78)

LiveCommunicationKit presents the two-way session as a system call — Recents, Lock Screen,
Dynamic Island. **System call UI only**: `CameraSession` keeps doing the media work, and the
integration is three types with one direction of trust:

- `CallLifecycle` is a pure reducer holding **every decision** — when a call starts (the user
  unmutes; passive viewing is never a call), what mute means inside one (an ordinary in-call mute,
  never an ending), and what each ending owes. The invariant every path holds: the microphone is
  live only while a call is active — with one deliberate exception: **a start the system refused
  opens the bare microphone anyway** (`startFailed`). The framing is garnish and the mic is the
  meal; this shipped the other way once, and a refused start read as a dead button.
  `CallLifecycleTests` is the whole table; change the reducer and the test in the same commit or
  not at all.
- `RobotCallController` is the thin adapter over `ConversationManager`, **untested by design** the
  way `WebRTCDataChannel` is: the framework only stands up on a device. Its `ConversationManager`
  is created when the first robot connects (`robotChanged` with a non-nil id) — early per Apple's
  guidance, because creating it inside the first tap's own start raced the system's registration
  on a device; still never from previews, the snapshot suite or the storybook, because
  `RootCallLifecycle` only calls `robotChanged` outside preview mode, and registering with the
  system's call service from a snapshot run is the class of side effect `CameraSession.deinit`'s
  guard exists to prevent. Never `invalidate()` it; `reportNewIncomingConversation` is never
  called (outgoing only, so no ringtone, no PushKit, no `voip` background mode — `audio` in
  `Apps/Project.swift` is what keeps a backgrounded call alive).
- **Every failure in the start chain logs** to subsystem `com.alexey1312.ReachyMini`, category
  `RobotCall` — permission refused, no robot identity, `perform` throwing, action timeouts,
  unexpected actions, manager resets. "The mic button does nothing" is diagnosed by reading that
  category in Console.app with the device attached; it shipped once with every one of those paths
  silent, which is why this bullet exists.
- **The `#if os(iOS)` is a platform fork, not a version gate.** LiveCommunicationKit is
  `@available(macOS, unavailable)` outright — no macOS floor bump brings it back, unlike the
  Control Centre widgets' fork. The public surface is cross-platform so no caller carries an
  `#if`; on macOS `toggleMic`/`startCall` degrade to the direct `setMicEnabled` toggle the app
  always had, bit for bit.
- Fulfilling an `EndConversationAction` **is** the end signal — `reportConversationEvent` after it
  double-ends the conversation, which is why `performedEnd`'s effects carry no report and only
  endings the system did not initiate (`sessionBecameIneligible`) do.
- A call ends on `.failed`, robot asleep/disconnected, or the viewport target dissolving —
  **never on merely leaving `.streaming`**. `CameraSession` self-heals through `.connecting`
  (watchdog, ICE failure, LAN lull) and the mic track comes back with `attachMicTrack`'s
  `track.isEnabled = isMicEnabled`, so a call rides a renegotiation out. `RootCallLifecycle` in
  ReachyUI owns that predicate.

## Audio-session ownership

`MediaAudioSession` is the **one** owner of `AVAudioSession` and of `RTCAudioSession` — every
mention of either stays in that file, which is what makes the handover auditable. Three states:

- `.app` — a camera session is up with no call: the app configures
  (`.playAndRecord`/`.videoChat`/`.defaultToSpeaker`) and activates itself, exactly the
  pre-#78 shape.
- `.call` — LiveCommunicationKit owns activation for the call's whole life. The app must not
  touch `setActive` in this state: `cameraSessionStopped()` is deliberately a no-op under
  `.call`, and the ownership flips back only in `callDidDeactivate`, which the system delivers
  through the manager's delegate.
- `.nobody` — release with `.notifyOthersOnDeactivation`, retried 5 × 200 ms because
  `setActive(false)` races WebRTC's audio unit winding down on a background thread; a `try?`
  there made the release silently not happen and other apps' audio stayed ducked. The reclaim
  after a call ends over a still-running camera reuses the same retry shape in the other
  direction.

WebRTC runs in **manual audio mode** from the first touch: `useManualAudio = true` is set in
`MediaAudioSession.init`, which `CameraSession.start()` reaches before any peer connection can
exist, and `isAudioEnabled` is the explicit lever thereafter. The ordering is always
activate-then-enable. If passive robot audio ever regresses on a device, the recorded fallback is
to enable manual audio lazily on the first call instead and accept a first-call glitch — measure
before reaching for it.

Known edge, accepted: if the system never delivers `didDeactivate` after a call (not observed,
but the contract does not promise ordering), the owner stays `.call` and a later
`cameraSessionStopped()` declines to release — the symptom would be ducked audio in other apps
after a call, and this entry is where to start.

## Device checks (nothing headless can cover these)

- Passive path first, before trusting any call work: robot audio audible while just viewing;
  mute/unmute with no call; other apps' audio un-ducks after leaving the camera.
- Unmute → system call UI appears, Dynamic Island while backgrounded, entry in Phone Recents.
- Lock-screen mute and End both land (mute keeps the call; End mutes and ends).
- The call survives backgrounding and leaving the Live tab; putting the robot to sleep ends it.
- A Recents-row tap relaunches into the Live tab and unmutes within the 60 s TTL — and does
  **not** unmute past it, or at a robot other than the one named.
- "Call Reachy" by voice; a relay call's End leaves the robot's control channel alive.
- A refused microphone: no ghost call, the blocked button state appears.

Untested by design, and the reason in one line each: `CameraSession`/`WebRTCDataChannel` need a
live peer connection; `RobotCallController`'s adapter needs callservicesd. What can be held is
held: `CallLifecycleTests` (the decision table), `CameraSessionCandidateTests` (the one pure
static), `CallProjectLockstepTests` (the Info.plist and metadata declarations the framing leans
on).
