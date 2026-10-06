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
  called — outgoing only, so no ringtone and no PushKit.
- **`Apps/Project.swift` declares two background modes, and only one of them is about the
  background.** `audio` keeps the WebRTC session running when the app leaves the foreground.
  **`voip` is what entitles the app to perform a call transaction at all** — without it
  `ConversationManager.perform` throws `unentitled` and no call is ever created. #111 shipped
  with `audio` alone on the reasoning that `voip` is "for receiving calls via PushKit"; that is
  the wrong reading of the key, and the symptom was the whole feature silently degrading to the
  bare microphone on every tap. It brings no PushKit with it: nothing registers for a VoIP push
  and `reportNewIncomingConversation` is still never called. Declaring `voip` without PushKit is
  a question App Review can ask (guideline 2.5.4) — this app really does carry two-way VoIP
  audio, and the justification belongs in App Review Information beside the `network.server` one.
  `CallProjectLockstepTests` holds both modes.
- **The call history renders `Handle.value` verbatim, and that is the only place a name can go.**
  Not `displayName`, and not a membership update: `Conversation.Update(members:activeRemoteMembers:)`
  was reported on a device and the Recents row went on printing the value. So the handle carries the
  robot's own name and falls back to `deduplicationKey` — a row reading `b68ff6bbe47f0608` names
  nothing to anybody, and one was reported from the field. **That fallback is unreachable today, and
  it is worth knowing why before hunting for it**: `robot_name` is required in the daemon spec, so a
  LAN handshake names even a robot nobody renamed (`reachy_mini`), and `CentralRobot.displayName`
  ends in `peerID` rather than in nil. A hardware-id row therefore comes from a build older than
  this entry, not from a live path. What could bring the fallback back is a spec refresh that makes
  `robot_name` optional, which is why `RobotConnectionHandshakeTests` holds the property rather than
  this paragraph alone. The cost is that a Recents redial arrives
  naming the robot by **name** while a donated intent names it by **identity**, which is why
  `CallRequestRouting.decide` takes both and `CallRequestInboxTests` holds each direction.
  `activeCall.robotID` stays the identity throughout (rule 4); only the handle is human-facing.
- **Every step of the start chain logs** to subsystem `com.alexey1312.ReachyMini`, category
  `RobotCall` — the start being attempted, the system performing an action and the state it left
  behind, every ending and its cause, permission refused, no robot identity, `perform` throwing,
  action timeouts, unexpected actions, manager resets. "The mic button does nothing" is diagnosed
  by reading that category in Console.app with the device attached; it shipped once with every
  one of those paths silent, which is why this bullet exists. **Nothing here may be `.debug`** —
  the log store drops that level by default, so a `.debug` line is a line that is not there when
  the field report arrives. That is what happened to the one message naming the attempted start.
- **The `#if os(iOS)` is a platform fork, not a version gate.** LiveCommunicationKit is
  `@available(macOS, unavailable)` outright — no macOS floor bump brings it back, unlike the
  Control Centre widgets' fork. The public surface is cross-platform so no caller carries an
  `#if`; on macOS `toggleMic`/`startCall` degrade to the direct `setMicEnabled` toggle the app
  always had, bit for bit.
- Fulfilling an `EndConversationAction` **is** the end signal — `reportConversationEvent` after it
  double-ends the conversation, which is why `performedEnd`'s effects carry no report and only
  endings the system did not initiate (`sessionBecameIneligible`) do.
- **The app hangs up through the system, not locally, and it must be able to hang up at all.**
  `CallEndButton` sits beside the microphone whenever `activeCall` is filled, and `endTapped` emits
  `performEndAction` — a real `EndConversationAction` through `ConversationManager`, so the Lock
  Screen's End and this one are one funnel and the ending still arrives back as `performedEnd`.
  It exists because #111 only ever _received_ that action: ending belonged to the system UI alone,
  and **iOS does not draw its call UI over the app that owns the call** — which is exactly where
  somebody watching the robot is sitting. Reported from the field as a call that could not be
  stopped, seven minutes long. A refused end closes the call locally rather than leaving a dead
  button, the same lesson `startFailed` carries.
- A call ends on `.failed`, robot asleep/disconnected, or the viewport target dissolving —
  **never on merely leaving `.streaming`**. `CameraSession` self-heals through `.connecting`
  (a stalled attempt's one retry, a failed peer, a LAN lull) and the mic track comes back with `attachMicTrack`'s
  `track.isEnabled = isMicEnabled`, so a call rides a renegotiation out. `RootCallLifecycle` in
  ReachyUI owns that predicate.
  `.stalled` ends a call the way `.failed` does:
  the session has stopped asking after two attempts, so there is nothing left to carry it.
  **Known remainder: `.failed` is not only a stream that died.** `CameraSession.accept()` sets it
  on its own renegotiation path when the peer cannot be built or a description is refused, and
  over the relay `CentralSignalingTransport` yields `.failed` routinely. `callMustEnd` treats any
  of those as terminal, so a renegotiation the session would have healed from can still end the
  call. Left alone until it is observed; this is where to start if a call dies mid-stream.
- **The viewport gate reads `keepsSessionAlive`, not `hasActiveCall`.** `activeCall` fills only
  once the system hands the start back, so the permission ask and the callservicesd round trip
  before it were an unguarded window — and a suspend there destroys the `CameraSession` the call
  is being placed over. `RobotCallController.session` is a **weak** reference, and
  `ViewportModel.stopCamera()` drops the last strong one, so every later `applyMic` lands on nil
  while the replacement session starts at `isMicEnabled == false`. The first-ever tap lands in
  exactly that window, because the microphone prompt takes the scene out of `.active`.

## Negotiation: a deadline, one retry, then `.stalled` (#155)

**`.streaming` means the peer connection is `connected` — ICE and DTLS both up —
and not that the offer named a video track.**
libwebrtc fires `didAdd rtpReceiver` while it _applies the offer_,
before the robot has seen an answer at all.
`.streaming` used to be declared right there,
so the 10 s watchdog behind it, which asked "not streaming yet?", was always told no and never once fired.
Measured with the answer dropped:
`.streaming` twelve seconds later, the robot's peer still `new`, zero restarts —
a black picture with no spinner, for as long as the app stayed open.
`videoTrack` is still taken at that early moment, so the view is attached before the first frame;
it is the phase that waits.

- **An attempt is one subscription to signaling, and it has 15 s to connect**
  (`defaultNegotiationDeadline`, in `CameraSession+Negotiation.swift`).
  The clock covers every step — the offer that never comes, the answer the robot never gets, ICE stuck in
  `checking` — and stops only for `.waitingForProducer`, which is the robot answering rather than stalling.
  **It starts again at `.sessionRequested`**, which both carriers send when they ask a producer for a session.
  A producer that registers after the wait — a robot just woken, a media server restarted —
  is otherwise a peer status that only the signaling client sees,
  and a robot that then never offered sat in `.waitingForProducer` for ever, with no deadline and no retry.
- **On the LAN this deadline is the only thing that ends a stall.**
  The daemon (1.10+) has a 12 s watchdog of its own,
  but it reports a stuck peer to central only — as `ice_negotiation_timeout` or `peer_connection_failed`;
  for a peer on its own `:8443` socket it logs `stuck mid-negotiation` and does nothing.
  Over the relay those two codes count as a stall exactly like the deadline passing
  (`RemoteSessionEnd.isNegotiationStall`); every other code stays `.failed`, with no retry offered,
  because retrying a robot somebody took is how two devices fight over it.
- **The first stall starts over from the top; the second in a row is `.stalled`.**
  Starting over is a new subscription, not the old one resumed:
  on the LAN a fresh socket and `startSession`, over the relay a fresh event stream and a fresh ask —
  `disconnect()` alone never asked again over the relay, so the ICE-failure restart it used to be was a
  dead end there.
  `.stalled` drops signaling, ends the robot's half and closes both channels,
  and the viewport offers **Try again** (`retry()`), which refills the budget.
  Connecting refills it too, so a stream that drops after working gets the same one retry.
- **Starting over overlaps the old attempt, and three things keep it from leaking into the new one.**
  `CameraSignalingClient` clears only the socket its own loop opened;
  `accept` re-checks `peer === peerConnection` after every await;
  and `peer(_:changedTo:)` ignores a verdict from any peer but the current one —
  a closed peer still reports, and its `failed` would count against its successor.
- **The tests stand the robot up in-process.**
  `ReachyMediaTests` offers from a second peer connection (`LoopbackRobot`) the way `webrtcsink` does,
  and connects to it in milliseconds — so the stall is caused, by not carrying the answer,
  rather than waited out.
  The robot sends video and the `data` channel and **no audio**:
  an audio m-line makes the session attach its microphone track,
  and on macOS, where nothing holds libwebrtc in manual audio mode,
  a sending audio stream starts the capture device —
  which a test process with no usage description is killed for.
  `sim-daemon` was not the reproduction because it could not be:
  on the Mac this was measured on its WebRTC producer never registers
  (the default input is a virtual eight-channel device; see the root `CLAUDE.md`).

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

**`isAudioEnabled` is a change, not a command — and this is the entry that cost a day.** libwebrtc
raises and drops its audio unit on the _transition_ of that flag, so assigning `true` to a flag
already `true` restarts nothing. The recipe every CallKit+WebRTC guide prints
(`audioSessionDidActivate` then `isAudioEnabled = true` in `didActivate`) assumes the flag is off
whenever no call is up. **It is not off here**, because `cameraSessionStarted()` turns it on for
passive listening — the robot is audible with no call at all. Two correct pieces, incompatible
only together.

What that produced in #111: starting a call made the system interrupt the app's session and stop
the audio unit, `didActivate` arrived ~80 ms later, the handover assigned `true` to `true`, and
the call was **silent in both directions** while passive audio had worked a second earlier. So
`callWillStart()` now sets `isAudioEnabled = false` deliberately, `callDidActivate` turns it back
on, `callDidDeactivate` drops it again and `reclaimForApp` restores it. Every one of those four
lines is load-bearing; deleting any leaves a state where the unit never comes back.

The measurement, because no amount of reading the code shows it — the order is the whole proof:

```
14:12:25.550  Call starting                              (ours)
14:12:26.280  Session interrupted, will stop iounit      (AURemoteIO)
14:12:26.280  Stopping AURemoteIO
14:12:26.356  System activated the call's session        (ours, from didActivate)
```

Read it with `xcrun devicectl device sysdiagnose --destination` and a predicate on
`Starting AURemoteIO`/`Stopping AURemoteIO` beside subsystem `com.alexey1312.ReachyMini`; the
`.notice` lines in `MediaAudioSession` exist to sit next to those and are not decoration.
**A silent call is diagnosed by that timeline and by nothing else** — the daemon's own
"Setting up incoming audio playback" appears whether or not a single sample ever arrives.

**`CameraSession.micVolume` is the only gain anywhere in the call**, and it exists because the
robot has none. The daemon adds no software gain to any playback path and its mixer is already at
100, so a robot cannot play its own sounds louder to match a call — the call has to come down. It
is applied in `attachMicTrack` as well as in the setter, because a renegotiation builds a new
`RTCAudioSource` and the old one's gain goes with it. Measurements, and why the two sources differ
by 10–17 dB in the first place, are in `docs/research/audio.md`.

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
- A healthy robot's camera still comes up at once: "Connecting…" now holds until the peer connects
  rather than until the offer is read, which on the LAN is well under a second. A camera that
  hangs on "Connecting…" for 15 s and then retries is the deadline at work — check the daemon's
  log for `stuck mid-negotiation` before blaming the client.

Untested by design, and the reason in one line each: `RobotCallController`'s adapter needs
callservicesd; `WebRTCDataChannel` and the audio side of `CameraSession` need a live robot on the
other end. What can be held is held: `CallLifecycleTests` (the decision table),
`CameraSessionNegotiationTests` (the negotiation, against a peer connection in the same process),
`CameraSessionCandidateTests` (the one pure static), `CallProjectLockstepTests` (the Info.plist and
metadata declarations the framing leans on).
