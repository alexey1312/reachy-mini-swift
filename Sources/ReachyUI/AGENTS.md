# ReachyUI

Shared SwiftUI views for all platforms (macOS/iPadOS/iOS). Depends on ReachyKit and ReachyMedia (WebRTC camera).

- Adaptive layouts, not per-platform copies; `#if os(iOS)` only for platform-exclusive APIs (Settings deep link etc.).
- `horizontalSizeClass` is unavailable on macOS — guard size-class branching with `#if os(macOS)` (always regular there).
  The root used to build a two-column `HStack` for a regular width and hide the Live tab on a compact one;
  `.tabViewStyle(.sidebarAdaptable)` does that adaptation itself, and it is iOS 18 / macOS 15, not an iOS 26 API.
  Reaching for the size class to fork a _layout_ is still a sign the layout is being forked rather than adapted.
- **There is exactly one size-class branch, in `FloatingViewportModifier`, and it is not a layout fork.** The floating
  viewport asks a different question: not "how wide is this" but **"does the shell draw a tab bar or a sidebar"**. A
  sidebar keeps the Live tab beside every other destination, so there is nothing to float out of it and no second
  place the viewport could go; a tab bar hides it, which is the whole reason the window exists. `.sidebarAdaptable`
  makes that decision on the size class and offers no way to ask what it decided, so the modifier reads the same input
  and writes `FloatingViewportModel.hasTabBar`. False collapses `placement` to `.inline` everywhere — the exact
  behaviour this target had before the window existed, including `viewportIsOnScreen`. This entry used to say nothing
  in the target branched on the size class; do not "restore" it by deleting the branch.
  - **`dockBleed(in:)` in the same file is the second branch on how the device is held, and it passes the same test.**
    It reads `UIInterfaceOrientation`, and it asks neither "how wide" nor "how tall" but **"which end of this screen
    has no cutout in it"** — because that is the one thing no amount of geometry will say. iOS reports the landscape
    safe-area inset on both sides whatever side the Dynamic Island is physically on, so a docked tab reaching for the
    glass has to be told which end to reach at or it goes under the island. It forks no layout: one point moves by up
    to 62 pt, and everything else about the overlay is unchanged. A third branch owes an answer of the same kind —
    a question the size class cannot answer at all, not a screen it looks better on.
    - **Both of its cases shipped inverted first, and nothing in this repository could have caught it.**
      `UIInterfaceOrientation.landscapeLeft` **is** `UIDeviceOrientationLandscapeRight` — the enum is defined as the
      device's with left and right swapped, and Apple's "home button on the right side" sentence documents the
      _device_ constant. Carry that sentence across and every case comes out mirrored. The unit tests cannot see it,
      because `bleed` arrives at `tabCentre` as a number somebody else decided; a snapshot cannot, because the
      stencil zeroes the safe area; and the two landscape orientations are mirror images of each other, so an
      inverted mapping is wrong in both and looks equally plausible in both. Right: `.landscapeLeft` puts the home
      indicator at the **leading** end, `.landscapeRight` at the trailing one.
    - **What did catch it is the standalone-probe harness, and this is the recipe.** A ~100-line SwiftUI app built
      with a bare `swiftc -target arm64-apple-ios18.0-simulator`, replicating only the overlay
      (`TabView` + `.overlay { GeometryReader { … } }`), drawing the tab twice — once flush with `bounds`, once with
      the bleed — over a HUD of the numbers it read. `UILaunchScreen` in its `Info.plist` is **not optional**:
      without it iOS runs the app in legacy compatibility mode at a scaled size and every safe-area figure is a lie.
      Orientation is forced through `UISupportedInterfaceOrientations` rather than by rotating the simulator, which
      needs an accessibility permission `osascript` does not have. Then `simctl io booted screenshot` and a throwaway
      `swiftc` bounding-box script over `CGImageSourceCreateWithURL` — the framebuffer stays portrait while the
      interface rotates, so the app's landscape x-axis is the image's **y**, and eyeballing that is how a 20 pt error
      gets called close enough. Measured on an iPhone 17 Pro: reader 750 × 382, `l62 r62`; the tab flush with
      `bounds` at 62 pt from the glass and the bled one at 0, in **both** orientations, with the island's own
      bounding box starting 14 pt in at the opposite end. The portrait run reproduced the 402 × 778 / t62 b34 already
      recorded in `FloatingViewportModifier`, which is what certified the probe as a faithful replica before any of
      its landscape numbers were believed.
- **Navigation is `ReachyRouter` plus two destinations.** `ReachyRootView` owns what outlives a screen and picks the
  gate or the shell; `Navigation/` holds the router, the effect cluster and the sheet stack; `Shell/` holds the five
  tabs. The five are unconditional — a tab that comes and goes forces the shell to catch its disappearance and drag
  the selection elsewhere, which is what `onChange(of: offersLiveTab)` used to do. An unavailable feature renders an
  unavailable state inside its own tab instead.
- **The Home Screen icon's menu is UIKit's, and `AppShortcutsProvider` does not fill it.** The two systems look alike
  and are not: App Shortcuts (`ReachyShortcuts`, in the app target) reach Spotlight, Siri, the Shortcuts app and the
  Action button, run in the background, and may number ten; the icon's menu is `UIApplicationShortcutItem`, holds
  four, is iOS-only, and **always launches the app**. So declaring a fourth intent puts nothing in the menu, and
  nothing in the menu runs headless. `Navigation/QuickActions.swift` owns that half:
  - The items are **installed at runtime**, from `RootLifecycle`'s `.task`, so their titles come from the one
    catalogue — a static `UIApplicationShortcutItems` entry is localized through `InfoPlist.strings`, which this app
    does not have. Price: the menu is empty until the first launch.
  - `QuickActionInbox` has a `shared` because UIKit builds the scene delegate that fills it and there is no
    initialiser to inject through. Its `Pending` carries a monotonic token: SwiftUI notices a _change_, so two
    identical taps have to arrive as two values or the second never runs.
  - A tapped command **selects the Robot tab and runs only against a connected session**. On a cold launch that
    means it is dropped — the gate is up and the tab was the default anyway. Queueing it until the session settles
    is a change to the one guard in `RootLifecycle.runQuickAction`.
  - The delegate itself is `Apps/ReachyMini/Sources/QuickActionSceneDelegate.swift`, the only UIKit in the app
    target. Overriding the scene configuration does **not** cost SwiftUI its window — verified by installing on a
    booted simulator and screenshotting, which is the only thing that can say so.
  - **What actually got installed is readable without a long press.** SpringBoard files the items per app, so
    `strings ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Library/FrontBoard/applicationState.db | grep
    SBSApplicationShortcutItem` prints each title next to its type after one launch. A build proves none of this:
    the items are written at runtime.
- **The running-app dock is a tab accessory, and it is not a `safeAreaInset` on the `TabView`. Do not put it back.**
  It was one for five releases, on the reasoning that growing the `TabView`'s safe area would push the bar up and
  leave the strip below it — the Telegram shape. A `safeAreaInset` does not shrink the frame it is applied to, and
  that safe area does not cross into the tab bar's controller or into the tabs' hosting controllers. Measured off the
  references with a pixel diff: with the dock up, the tab's content was **byte-identical** to the dock-free capture
  for the top 63% of the frame and the tab bar was **absent from the image entirely**. With an app running there was
  no tab bar on screen at all. `ReachyTabAccessory` holds the replacement and the reason each half exists.
  - **The tab bar minimises again, and that reverses the previous entry here.** It was switched off because the bar
    shrank into the row the opaque strip occupied and the whole bar went with it. The accessory _is_ that row, so
    minimising is now the interaction rather than the thing that breaks it: `reachyMinimizingTabBar()` takes no flag.
    Nothing scrolls in a snapshot, so no reference covers this in either direction — it is a device check.
  - **The old entry read `Root — dock on the apps tab` as showing the bar where the layout puts it.** It showed the
    bar buried. When a reference is the evidence for a claim about layout, say which pixels — and see
    `ReachyDesign/AGENTS.md` on why no reference can be evidence about the safe area at all.
- **The floating window and its edge tab are one view, and the morph depends on that.** They used to be two
  branches of a `switch` returning structurally different views — which gave them different SwiftUI identities, and
  nothing geometric interpolates across an identity boundary. `withAnimation(Motion.dock)` was therefore left with
  only the default opacity transition, so "collapsing into the tab" was a 0.28 s crossfade between two differently
  sized things in two places on screen. One identity animates its frame, its position and its corner radii instead
  (`UnevenRoundedRectangle` is `Animatable` and `RectangleCornerRadii.animatableData` is `VectorArithmetic` —
  compiler-checked, not assumed, which is why `Radius.flush(to:_:)` returns that type for the round case too).
  **`matchedGeometryEffect` is still ruled out** for the reason it always was: it keeps source and destination alive
  at once, and a second `RealityView` takes the robot from the first.
  - **`settling` is what keeps RealityKit out of the animation, and it is not cosmetic.** Assigning `rest` directly
    took `isStreaming` false in the same runloop turn the animation started, and `RootLifecycle` answers that
    synchronously — `viewport.setActive(false)` → `pauseStream()` on the main actor, a stall landing on the frames
    the animation was trying to draw. The geometry follows `drawn`, the mounted renderer follows `placement`, and
    they differ for exactly as long as the animation runs. Both directions want that gap: docking keeps the renderer
    mounted while it fades, undocking keeps the stream off until the window has finished growing. Every caller owes
    `finishSettling()` from the animation's completion handler — and `onDisappear` owes it as well, for the reason
    `endDrag()` is there: an animation on a subtree that is already gone may never report a completion, and every way
    into the model guards on `settling == nil`, so a missed one would leave the window unable to move again with
    `isStreaming` still true over one the reader had put away. **That one is behind `reachyPreviewMode`, and the
    references are why**: a frozen `settling` is the only static evidence about the morph there is, and adopting it on
    teardown destroyed it between captures — `Floating viewport — undocking` came back with a switcher and a spinner
    in three of its four references, the first matching byte-for-byte and the rest rendering `.floating`. See the
    previews section on why three and not four.
  - **The expansion is three properties, and they are only correct together.** `size`, `centre` and `pictureSize` each
    fork on `isExpanding`, and nothing else in the target reads it. Fork one and not the others and the window grows to
    the screen around a 160 pt picture, or centred on the corner anchor it was resting at with three quarters of itself
    off screen. No reference covers it — `isExpanding` lasts one animation and hands over to the Live tab — so this
    entry is the cover.
  - **The window's chrome goes outside the `clipShape`.** Moved inside it once, and the references named it exactly:
    the switcher capsule is inset by `Space.xs` and meets a 16 pt continuous corner, so the corner shaved it. The
    three floating captures carrying a switcher or a badge all moved and `Floating viewport — no camera`, which
    carries neither, did not. `windowOnly(_:)` is where that lives.
  - **The window's shadow is cast by a background twin of its surface, never by the subtree.** `.shadow` on the
    composite re-rasterised a live `RTCMTLVideoView`/`RealityView` on every video frame and offset tick — and it
    changed what it wrapped: the `.window` role's `.bar` material muddied to gray in the shadow's offscreen pass, and
    the chrome's overhang past the rounded corner dragged a shadow bulge along. The measurements are in
    `ReachyDesign/AGENTS.md` under the `.shadow`-over-a-material entry; 36 references moved when the twin landed,
    every bounding box hugging the window rect plus its shadow.
  - **The drag is a pure function of the gesture, and `.position` never sees it.** `dragTranslation` stores the
    translation minus the `activation` SwiftUI reported when it woke the recogniser up — that first `onChanged`
    already carries everything the finger travelled before `minimumDistance`, so taking it at face value teleported
    the window by a speed-dependent amount at every touch-down. Nothing about the screen is captured, which is what
    makes a rectangle that changes under a finger (the running-app strip arrives on a poll, 68 pt) re-clamp rather
    than drift. The live delta rides a render-time `.offset` in `DragOffset`, a modifier of its own so that
    `FloatingViewport.body` does not read `dragTranslation` and is not rebuilt per touch event; `.position` carries
    only the resting point, because it is a layout modifier and driving it from the gesture ran a layout pass over a
    subtree hosting a rendering `RealityView`. `endDrag()` hangs off `onDisappear` as well — SwiftUI can drop a
    `DragGesture` without ever ending it, and this subtree really is unmounted mid-gesture.
  - **The gesture is measured in `.floatingViewportBounds`, never `.local`.** It is attached inside the very subtree
    `DragOffset` displaces, so a locally-measured translation had the drawn offset fed back into it one frame late —
    `offset(t) = Δfinger(t) − offset(t−1)`, a non-decaying alternation: the window vibrated at frame rate, tracked at
    half the finger's speed, and the polluted `predictedEndTranslation`/`velocity` picked wrong corners and seeded
    the spring wrong. The named space (declared on the overlay's `GeometryReader` in `FloatingViewportModifier`) is
    the rectangle `bounds` and `.position` already live in and the one thing a drag cannot move. The model needed no
    change — translations reach it as pure values, which is also why no model test could have caught this.
  - **A release is decided by `predictedEndTranslation`, not by where the finger stopped.** That is what makes a
    flick enough to dock, and `Motion.absorb(velocity:)` is seeded from `DragGesture.Value.velocity` so a thrown
    window continues instead of restarting from a standstill. A spring's initial velocity is a fraction of the
    _journey_ per second, so `releaseDistance(for:in:)` exists to tell the view how long the journey is — it shares
    `resolved(_:in:)` with `dragEnded` rather than duplicating the branch.
  - **A gesture may hide the window only in the corner it already holds.** A throw whose predicted point lands
    nearest a _different_ corner is aimed at that corner, however much sideways speed it carries — a fast vertical
    flick predicts hundreds of points of x from a few degrees of drift, and used to trip the 44 pt overshoot and
    hide the window at the top of an edge. The corner-equality guard in `resolved(_:in:)` also pins the edge for
    free (a point clamped against an edge is always in that edge's half), so reaching the far edge takes two
    gestures: park in a corner there, then push out. VoiceOver's explicit "Hide at…" actions go through
    `beginDocking` and stay free to pick either edge.
  - **The switch on the Live tab is a fourth input to `placement`, not a fourth state.** `isEnabled` collapses every
    placement to `.inline`, which is the shape a regular width already had — so the tab draws the viewport,
    `isStreaming` goes false, and `RootLifecycle` needed no change at all. It is the only one of the four inputs that
    outlives the app (`FloatingViewportPreferences`, `UserDefaults.standard`, absent reads as on), and that is exactly
    what separates it from the docked tab: a tab at the edge is somewhere the window _is_, so it belongs to the
    connection, while "do not offer it" does not. **Switching it back on resets `rest` to a corner**, because
    restoring a window that was thrown at an edge returns a 44 pt tab and reads as a switch that does nothing —
    which is the complaint the switch exists to answer. The menu is behind `floating.hasTabBar` rather than a second
    size-class read, and it is a menu rather than a bare glyph because what a reader finds is a word.
- **A move belongs to the robot, not to the Moves screen, and `onDisappear` no longer stops one.** It used to:
  leaving the tab killed the dance. That was indefensible next to restoring a move across a relaunch — force-quit the
  app and the dance survived, glance at the camera and it did not. `MoveActivityBar` is the strip that replaced the
  bare Stop button, because two of the four phases have no control at all: an adopted move (`/api/move/running` names
  nothing, so it says "A move is running on the robot" with no row highlighted) and the second of parking, which
  offers no Stop because there is nothing left to stop. Showing the parking phase is not decoration — it holds the
  daemon's one move slot, so a screen silent about it would claim an idle robot while it was still travelling.
  `MovesModel.rowsAreEnabled(_:)` owns the tap gate rather than the view: every phase in it is a phase where
  `_try_start_move` would drop the play without a word.
- **`.unreachable` belongs to the shell, not the gate.** Only `.idle` and `.connecting` show the gate. A network blip
  must not pull the tab bar out from under a finger, and the robot screen already reports the state in place.
- **The gate's fork has progress conditions, and they only ever delay.** For `.connected`, `isConnectedEnough` waits
  until `progress.displayed` has caught the session and `progress.holdsGate` is false. Crossing that line throws the
  gate's whole subtree away, so the equality check keeps the child phase observer alive long enough to see the final
  transition, and the hold then keeps its three checkmarks on screen — on a local network the stages can resolve in
  tens of milliseconds and otherwise read as an unexplained flash. `.unreachable` bypasses both conditions: it is a
  later network blip that belongs to the shell and must never resurrect the gate.
  `ConnectProgressModel` therefore lives in the root, not in the gate: it holds each stage on screen for a floor of
  `dwell`, holds one further `dwell` after the last frame, and releases on a `maxHold` ceiling that depends on
  nothing. At `dwell: .zero` it never holds at all, which is what every preview injects and why the reference images
  behave as they did before it existed.
- **Anything conditional on "an attempt is running" mounts and unmounts every 10 s.** The candidate sweep beats on
  that period and an automatic attempt falls back to `.idle` rather than `.failed`, so the phase walks
  `idle → handshaking → idle` forever while nothing answers. This was a reported bug — the screen visibly compressed
  and expanded — and it had **two** sources, not one: the connection stepper as a form section, and the `robotError`
  section, because `beginAttempt` clears `robotError` while `failAttempt` sets it for automatic attempts too (its
  `guard !automatically` comes after the assignment). Fixing only the first leaves the symptom intact. The rail is now
  mounted for the whole life of the gate, its detail slot reserves one caption line whether or not there is anything
  to say, and `robotError` is shown only once `automaticConnectionAllowed` is false. Before adding anything to this
  screen, ask what it does on that heartbeat. **`.disabled(!phase.acceptsConnectionChoice)` is on that heartbeat too**
  — the Hugging Face segment carried it and went dead every 10 s under a finger, which is the third instance of the
  same bug and the reason `YourReachiesSection` is now the one segment nothing disables: a robot on the relay is not
  on this Wi-Fi, so a sweep of this one says nothing about whether it can be reached.
- **Privacy permissions are one screen and four in-place refusals, and the split is deliberate.**
  `Settings/Permissions/` holds the overview: `PermissionsScreen` reports Bluetooth, Local Network and
  the microphone, and offers each one an action. Its governing rule is that **opening it must never raise
  a prompt** — `refresh()` reads only what can answer without asking, and every prompting path is behind a
  button. Bluetooth is the awkward one: there is no `requestAuthorization` for it, so "Allow" builds a
  short-lived central, which is exactly what `CoreBluetoothTransport` says to do only behind a screen that
  has explained itself. This screen, with a "why" under every row, _is_ that screen; opening it still is
  not. It is reachable from Settings **and** from the gate through `router.showsPermissions`, because the
  Settings tab does not exist until a robot has answered and two of the three permissions are what
  answering takes. A `Button` and a sheet rather than a `NavigationLink`: `PreviewScene.connection` has no
  `NavigationHost`, and adding one would put an empty large-title bar on all thirteen references.
  `PrivacySettingsLink` is the one deep link — the same six lines used to sit in three screens, each under
  `#if os(iOS)`, so on macOS a refusal was reported with **no way at all to act on it**. It is `public`
  only because `DeviceCheckView` calls it. And the Local Network banner now lives in
  `ConnectionScreen.privacySection`, outside the route segments, for the reason `setUpSection` is: it used
  to sit in `NetworkRobotsSection`, where only one of the three routes could show it, while the manual
  address — where a blocked user goes next — failed just as silently.
- Leaves stay injectable rather than reading the router: `ConnectionScreen.showRemoteRobots` is optional because its
  absence is what hides `YourReachiesSection` in previews. The router is the shell's business.
- All robot interaction goes through `RobotSession` / `RobotBrowser` from ReachyKit — no direct URLSession here.
- Screen logic belongs in a `@MainActor @Observable` model beside the view (`MovesModel`, `LogConsoleModel`), covered
  by `Tests/ReachyUITests`; the view stays thin. `@Observable` does honour `didSet`, so derived caches can live there.
- **A model must never be constructed inside a `.sheet` content closure.** SwiftUI re-runs that closure on every
  update of the view the sheet hangs off, so the model is silently replaced by a fresh, empty one — and `.task` does
  not run a second time, so nothing refills it. `RootSheets` hangs off `ReachyRootView`, whose body reads
  `session.phase`, and the candidate sweep walks that `idle → handshaking → idle` every 10 s: "Your Reachies" listed
  the account's robots and then swapped them for a permanent spinner within seconds of opening. The model now lives in
  the root's `@State` and `YourReachiesScreen` adopts it into `@State` of its own, the way `HFAccountSection` already
  did — which is why the sign-in card never showed the same symptom despite being built the same way. The rule reads
  the same for `NavigationLink(destination:)` and for anything else that takes a `@ViewBuilder` the parent re-runs.
- Content catalogues use `contentLoading(isPresented:title:)` for their initial or uncached load. The model must
  distinguish "never answered" from a real empty result and expose loading before `.task` gets its first turn, so the
  first frame never lies with an empty-state. A refresh keeps any rows already on screen; only a request with no data
  gets the centred, lightly robot-themed label. Every such state gets a frozen preview and recorded snapshots.
- `Section` has no title-plus-footer overload: `Section("X") { … } footer: { … }` fails to compile with a misleading
  "generic parameter 'Content' could not be inferred". Either `Section("X") { … }` or the full
  `Section { … } header: { Text("X") } footer: { … }`.
- A container view taking a closure argument _and_ two trailing `@ViewBuilder`s trips SwiftLint's
  `multiple_closures_with_trailing_closure`. Pass the extra behaviour as a child view instead
  (`OnboardingBackButton`), not as a third closure.
- `background(_:)` defaults to `ignoresSafeAreaEdges: .all`, so a full-bleed backdrop also paints the inset the
  floating tab bar sits in — bottom on iPhone, top on iPad. That bar is glass and renders whatever it finds there, so
  it turns dark on that one tab, a frame behind the switch. Neither viewport paints a backdrop any more: the 3D scene
  and the camera's letterbox both take the system background, so the chrome over them stays legible in both
  appearances. **Do not pin a colour under adaptive chrome** — every such backdrop drags a pinned foreground along
  with it, and then neither half can be removed alone. The Live tab's `Color.black` forced
  `toolbarColorScheme(.dark)` to keep the title readable (drop one and the title goes white-on-white or
  black-on-black); the camera's forced a white `Connecting…` for the same reason. `RTCMTLVideoView` clears its own
  unfilled area, so the video never needed the SwiftUI backdrop — that one only ever painted the safe-area insets.
- **A representable wrapping a renderer owes SwiftUI a `sizeThatFits`, and the reference images cannot tell you it is
  missing.** `RTCMTLVideoView` reports the _stream's_ frame size as its intrinsic content size, and without a
  `sizeThatFits` the default forwards that through `systemLayoutSizeFitting` — so `CameraVideoView` sized itself to
  whatever resolution WebRTC happened to be sending, and this file's `.frame(maxWidth: .infinity, maxHeight:
  .infinity)` centred the result. On a landscape iPhone that was a ~140 pt picture in the middle of an 874 pt screen,
  with `CameraViewport`'s bottom `safeAreaInset` stacked under it, so the joystick came up off the bottom edge too.
  **Every `Camera —` reference passed throughout**, and had to: a preview session carries no track, the video frame
  size is zero, and a view with no intrinsic size takes the proposal — the exact case the bug does not occur in. It
  returns the proposal explicitly now, which is why adopting it moved nothing. The rule generalises: a headless
  capture of a renderer certifies the layout around an _empty_ rectangle, never the rectangle.
- **A `safeAreaInset` on a viewport costs a fixed number of points of _height_, and a landscape iPhone has 402 of
  them.** The entry above was fixed and the same complaint came back: a tiny picture in the middle of a landscape
  screen, measured at 145 × 80 pt. `sizeThatFits` was working — `CameraViewport`'s bottom inset was taking
  140 (`JoystickPad`) + 2 × 16 (`.padding()`) = **172 pt**, and the navigation and tab bars the rest, so the camera
  was filling ~86 pt of height perfectly correctly. Nothing about the code says "landscape"; the constant is the same
  in both, and 172 out of 874 is invisible while 172 out of 402 is two thirds of the screen. **The two bugs are
  indistinguishable from a screenshot**, which is why the fix is arithmetic and not inspection: compute the rectangle
  the renderer is handed, then aspect-fit the stream into it and check the number against the image.
  The controls are an `overlay(alignment: .bottomTrailing)` now, and **all 318 snapshot tests passed with the move,
  0 of ~1100 references rewritten** — predicted from the arithmetic before the run and then measured: the pad's own
  rectangle is `bottom − 156 … bottom − 16` in either form, and the two phases that could have disagreed never
  overlap (a `safeAreaInset` whose builder returns `EmptyView` reserves nothing, and `teleopControls` is empty in
  every phase except `.streaming`, which is the one phase `status` is empty in). `LiveTab` still declines
  `ignoresSafeArea`, and the reason survived the change — an overlay is bounded by what it is applied to, so a
  full-bleed viewport would put the pad under the tab bar.
- **Every `.sheet` in this target ends its content with `reachySheet()`, and a new one owes the same line.** On macOS
  a sheet is laid out at its content's ideal size, and every sheet here is a `Form` or a `ScrollView` under a
  `NavigationStack` — none of which has an ideal width — so AppKit picks something cramped and clips. There are nine
  of them; the modifier declares the width and measures the height, and `ReachyDesign/AGENTS.md` carries the
  reasoning along with the two shapes it had before that, both of which shipped. **No snapshot can catch a missing
  one** — the suite runs on an iOS simulator, where the modifier does nothing.
- **Every `Form` in this target names `.formStyle(.grouped)`, and the one that did not was reported as a sheet bug.**
  macOS defaults a `Form` to `.columns`, which puts each label in a right-aligned leading column — and inside a sheet
  that column was laid out past the leading edge, so `HFSignInScreen` rendered "Remote access" as "mote access" with
  its sentence cut off on the other side. It looks exactly like a sheet 100 pt too narrow, and widening the sheet
  hides it without fixing it. **Nothing here could have caught it**: iOS renders a `Form` grouped whether the style is
  named or not, so the references say the same thing either way — expected to move nothing, and not yet confirmed by
  a full run.
- Deployment floor is iOS 18 / macOS 15 (`Package.swift`, `Apps/Project.swift`), set by `RealityView`.
  `ScrollPosition`, `onScrollPhaseChange` and `onScrollGeometryChange` are available; the zero-height sentinel row in
  `LogConsoleScreen` predates the bump and is not a required pattern.

## The joystick's rotation zone

`JoystickMapping` splits the pad with a **vertical line** at `±rotationThreshold`, not with a radius and not with a
sector, and the reason is the handover: that same line is where head yaw saturates, so the head stops moving exactly
as the body starts. A radial zone parts the two — a push into the corner is far from the centre while its sideways
component is not, so the body would begin turning under a head still halfway through its own travel. A sector rule
(`|x| > |y|`) has the opposite problem: crossing its 45° edge at full deflection would drop the rate from most to
nothing, so the taper it would need to be jolt-free leaves a boundary too fuzzy to draw or to tick a haptic on.

- **The threshold was 0.7 and is 0.5, because on a round pad 0.7 sits outside the diagonal.** The rim only reaches
  `|x| = 0.7` within 45.6° of level, so a thumb pushed hard left and slightly up was against the edge of the pad with
  the robot not turning — reported as the zone being "strictly left and right", which is what it was. At 0.5 the
  boundary is 60° off level and the slice covers two thirds of each side of the pad. It costs head-yaw resolution
  (the full ±`headAngle` now arrives at half travel) and, like every constant in the teleop path, it is a guess until
  someone feels it on the robot.
- **`mapping.rotationSide(_:)` is what the pad shades, and it is defined as `bodyYawRate != 0`.** The pad used to
  carry its own copy of the predicate; a lit slice that did not turn, or a turn under an unlit one, is now
  unrepresentable rather than merely untested.
- **The slice is drawn by intersecting the disc with a half-plane, not by sweeping an arc.** `Path.addArc` would have
  to be handed the right winding for a y-down space to keep the near side rather than the far one, and getting that
  backwards renders the complement — a mistake no test catches and only a simulator shows. The intersection is
  correct by construction and cannot drift away from the mapping's boundary.

## Errors

**An error is shown by the screen whose action caused it.** A daemon failure goes into the slot on that screen's
model — `AppStoreModel.lastError`, `MovesModel.lastError`, `AudioSettingsModel.errorMessage`,
`SystemUpdateModel.state`, `WiFiSettingsCard.loadFailure`, `HFAccountSection.linkError`. `RobotSession.robotError`
is **not** a fallback for anything: it holds the robot's connection and power, which are the only failures with no
screen of their own, and `RobotScreen` / `ConnectionScreen` are its only readers. It used to be `lastError` and
every funnel wrote to it, which is how an Apps failure — and before that a _cancelled_ Apps call — ended up printed
on the Robot tab.

- **Fill a slot with `lastError.recordDaemonFailure(error)`** (`DaemonFailure.swift`), never by describing the error
  here. Each of these models used to carry its own `describe` helper, and the moment the session stopped absorbing
  cancellations those eight copies would each have started printing the word "cancelled" on their own tab. The one
  filter is `RobotSession.message(for:)`; `recordDaemonFailure` is the one-liner over it, and it logs on the way past.
- Where the failure lands in a **state enum** rather than an optional (`SystemUpdateModel`, `AppInstallModel`), the
  same rule reads `guard let message = RobotSession.message(for: error) else { return }` — pulled into a private
  `fail(on:)` in both, because two of those guards in one function put `install` over SwiftLint's cyclomatic limit.
- `OnboardingModel` and `HFSignInModel` keep their own `describe`: they report BLE and `ASWebAuthenticationSession`
  failures, neither of which is a daemon call, and the latter already models cancellation as its own error type.
  `YourReachiesModel` maps relay failures to sentences of its own and so guards on `RobotSession.isCancellation`
  at the top of `report(_:)` instead.
- **A crashed app's `error` is a stderr _tail_, not a line, and only one surface may inline it.**
  `RobotAppStatus.error` opens with the daemon's own `Process exited with code 1` and carries the app's last stderr
  lines under it — uvicorn's logging interleaved with a Python traceback. `RunningAppCaption.label` therefore takes
  `Failure`: the dock passes `.inline` because its one caption line is the only place a crash can be read, and
  `AppDetailSheet` passes `.shownSeparately` because `failureRow` prints the whole tail two rows below. It used to
  inline there too, so "State" read `Process exited with code 1 / INFO: connection rejected (403 For…` — the first
  two lines of the very text underneath it, under a heading that promised a state.
  **The references passed over that for as long as it shipped**, because `RobotAppStatus.previewCrashed` was a
  single `ModuleNotFoundError` line, and a one-line tail renders identically whether a surface prints it once or
  twice. It is several lines now, on purpose; do not shorten it back.
- **An error rendered _in place of_ a state has to expire; one in a slot of its own does not.** `lastError` is
  cleared only by a later successful command, which is correct for `AppDetailSheet`, where it is its own red row
  under a state that stays visible. The dock has one caption line, so the same value there hides the state — and a
  refused Restart on an app that goes on running would hide it, and the conversation turn with it, for the rest of
  the session. `RunningAppModel.expireActionFailure(at:)` retires it after `actionFailureWindow`, driven by the poll
  rather than by a `Timer`: the poll is the only clock this model already owns, and while backgrounded there is
  nothing on screen for a stale refusal to be stale on. It must not be shortened to "clear on the next tick" —
  the tick can land milliseconds after the tap, which is the original bug (a refusal shown nowhere) wearing a
  stopwatch.
- **A revalidation nobody asked for may write to neither slot, and that is two rules, not one.** `AppStoreModel` and
  `MovesModel` are seeded in their initialisers from the catalogues `RobotSession.warmCatalogues` read off disk
  during the handshake, so the first frame after a cold start is rows rather than a spinner. Those rows are still
  owed a reading, and the fetch that pays the debt is `silent`: it may not **write** `lastError` — a red line under a
  perfectly usable menu is noise with nothing to act on, and it is the same category as a cancelled call — and it may
  not **clear** it either, or a background read would wipe the refusal from a Start or a Stop somebody is still
  reading. Only `refresh: true` reports, in both directions, because the user asked. A failed silent fetch leaves
  `catalogueIsWarmed` / `warmedDatasets` set, so the next visit tries again rather than settling for the cached list.
  - **Forcing `refresh` on that fetch is load-bearing, not defensive.** The session holds the same list in memory —
    it is what the model was seeded from — so `session.appCatalogue(refresh: false)` answers out of it and the robot
    is never asked at all. `MovesModel` needed a second edit for the same reason: its "already on screen, do not
    re-enter loading" early return swallows the warmed case unless `silent` is excluded from it.
  - **No reference covers any of this, and none can.** A warmed first frame renders pixel for pixel as the rows-on-
    screen state already captured; a silent revalidation draws neither a spinner nor an error; a failed one draws
    the rows without the error section, which is that same frame again. What is new is _when_ the frame appears,
    which is a temporal property. There is deliberately no "showing saved data" footnote of the kind the widget
    carries — the data is replaced within a second, and a badge that lives 800 ms is a flicker.
- **A verdict may only be reached from a reading that arrived.** `refresh` swallows its own failure with `try?`, so
  after an unreachable poll `session.runningApp` still holds the previous status — and timing _that_ as if it were
  fresh is what let a Wi-Fi blip during a stop be reported as a wedged daemon, with `WedgedAppNotice` sending the
  reader to restart the robot's software over Bluetooth. `noteTransition` now runs only on a successful read; a
  verdict already reached stands, and silence concludes nothing new. Anything else this model infers from elapsed
  time owes the same check.

## One page per app

**`AppDetailSheet` is the only page about an app, and both surfaces open it** — a store row and the dock's expand
button. It used to be two views: this one for a catalogue entry (install, update, remove, start-on-wake-up) and
`RunningAppSheet` for the process (state, restart, stop, settings). The split was real but it was about _models_,
not about apps: the store card needs `AppStoreModel` and `AppInstallModel`, which the root did not own. The reader
got one object with two half-pages, and a crashed app had no way back — the running half offered Dismiss and no
Start.

- **The two models live in `ReachyTabShell`, not in `AppStoreScreen`.** The dock is mounted on the `TabView` and
  expands from every tab, so a model built inside the Apps tab would be a second copy: install something from the
  dock's page and the store would go on offering "Install". `AppStoreScreen` adopts them into its own `@State`, the
  way `YourReachiesScreen` adopts the root's.
- **Which sections appear is decided by the app's state, never by which surface asked.** `runningStatus` is read off
  the session and matched against this app by name (`matches(installed:)` covers a Space slug that differs from its
  Python entry point) — not through `model.isRunning(_:)`, which needs the installed list the dock's page may not
  have loaded yet. `loadInstalledIfNeeded` fills that in without the catalogue's Hugging Face round trip.
- **Start is gated on `isBusy`, not on "has a status".** A crashed app keeps its status so its output stays
  readable; hiding Start for it is what left the merged page with no way to try again, and the reference caught it.
- The toolbar button reads "Minimize" while the app holds the robot and "Done" otherwise. Closing the page never
  stops anything — only Stop does.

## An app's own settings

`AppSettingsScreen` is **the only `WKWebView` in this app**, and the only screen that is not built out of the design
system — because there is nothing to build it out of. The daemon carries no route for an app's configuration; it
reports a port (`extra["custom_app_url"]`) and the app serves its own page there. A native screen could only be
written against Conversation App 1.0's `/rpc` and would leave every other app with no settings whatsoever.
(`WebAuthenticationBrowser` is **not** a second web view — that is `ASWebAuthenticationSession`, out of process on
purpose so no Hugging Face credential passes through one of ours.)

- **`AppDetailSheet` decides whether to offer it, not the screen.** `RobotSession.appSettingsURL(for:)` answers nil
  without a declared port and without a LAN address; the page adds `state == .running` and `isReachable`, because
  the process serving the page is the process that crashes. There is no way to reach an app's settings while it is
  down, which is worst precisely when a bad setting is what took it down — say so rather than papering over it.
- **The row was invisible on every real robot for as long as it shipped, and not because of any of that.** The
  daemon builds a running-app status as `AppInfo(name=…, source_kind=INSTALLED)` with an empty `extra`, so
  `customAppPort` was nil for the one app anybody wanted it for. `RobotSession.describedFromInstalled` is the join
  that fixes it; the previews never caught it because their fixtures carry the metadata a real status does not.
  When something on this page is missing on hardware and present in a reference, suspect the status rather than the
  view.
- **`.ready` has no reference and cannot have one.** The web view renders nothing headless and is not even mounted
  under `reachyPreviewMode`, and unlike `CameraViewport.streaming` this phase grows no chrome to capture over it —
  so it is uncapturable in the sense `SceneViewport.ready` is. `.loading` and `.failed` are both covered.
- The Settings row's presence and absence are both already under cover, and by accident of the fixtures rather than
  by design: `previewConversation` declares 7860 so `Running app — conversation` shows the row, and
  `previewInstalled[0]` declares nothing so `Running app — running` shows the page without it. Keep it that way —
  a reference for the offered state alone cannot tell a conditional row from a permanent one. `previewInstalled[0]`
  carrying no metadata at all is not an oversight either: it is what a local app with no Hub card looks like, which
  is the one case `describedFromInstalled` still cannot describe.

## Maintenance, and the guard the robot does not have

`MaintenanceCard` carries the two `/cache/*` actions. Both delete something on the robot, both are irreversible from
here, and both sit behind a `confirmationDialog` — but only one of them needs a rule:

- **`reset-apps` is `shutil.rmtree("/venvs/apps_venv/")` and nothing else.** The daemon does not stop the running app
  first, so its interpreter is deleted underneath it. `MaintenanceModel.blockingApp(_:)` refuses while
  `runningApp.isBusy`, and the card **names the app to stop** rather than only greying the button out — a disabled
  control with no reason attached tells the reader nothing to act on. An unfamiliar process state counts as busy,
  the way `RobotAppStatus.State.isBusy` treats it: refusing to delete an environment that might be in use is the
  safe way to be wrong.
- The description goes **above** the button in both rows, which is how the robot's own dashboard reads it and the
  right way round for something irreversible: what it does before the thing that does it.
- **The dialog's keys deliberately do not echo the buttons'.** `Uninstall all apps` and `Uninstall all apps?` differ
  only in punctuation, and the catalogue derives one Swift symbol per key — that pair is a hard `xcstringstool`
  build error, not a warning. Hence `Remove every app?` and `Clear cached models?`.
- `canPerformMaintenance` gates the whole section, so a Lite robot and a relay session show nothing — the same shape
  as `canConfigureWiFi`. **The gate is only under cover because `PreviewRobotClient` conforms to
  `CacheMaintenanceClient`**, which is why that conformance exists: the gate asks "does this client speak that
  protocol", so without it the section is absent from every `Settings —` reference and `Settings — Lite robot`
  certifies nothing at all. `WiFiConfigClient`, `TeleopClient` and `DaemonLogClient` are on the preview client for
  exactly this reason; a new capability gate needs the same line adding or its screen quietly loses coverage.
  Which reference shows it is decided by scroll position, not by the gate: **`Settings — backend stopped` is the one**,
  because a stopped backend drops the audio section and pulls Maintenance up into the frame. `Settings — wireless
  robot` and `Settings — rename unavailable` pass the gate too and keep the section below the fold, so they did not
  move when it was added — which is the tell, not a bug. Content lives in the five standalone `Maintenance —`
  references.

`WiFiSettingsCard` gained "Forget all" on the same principle: one `/wifi/forget_all` rather than a loop over the
rows, because the per-network route answers 409 while another `nmcli` operation runs and a loop would race itself.
It appears only above one saved network — `Wi-Fi — own hotspot` (one) captures its absence, `Wi-Fi — on a network`
(three) and `Wi-Fi — join failed` (two) its presence. The count is over `known` as the daemon sends it, `Hotspot`
included, so a robot with one real network saved offers the button as well; that matches the rows, which list every
entry the same way and let the robot answer 400 for its own hotspot.

## Strings

Project rule 9 in the root `AGENTS.md` is the whole of it: `.reachy("…")` where SwiftUI takes a
`LocalizedStringResource`, `String(localized: .reachy("…"))` where the value has to stay a `String`. Two things this
target learned doing it:

- **A caption type, not `String(describing:)`.** `DaemonStateCaption` maps the generated
  `Components.Schemas.DaemonState` onto words; `RunningAppCaption` does the same for a process state. Both live here
  rather than in `ReachyKit`, because `ReachyKit` does not link `ReachyDesign` and must not start — a caller maps its
  own domain type onto a presentation value, never the reverse.
- **A sentence is one key.** Prose split across `+` for the sake of the 120-column rule became one literal with
  `// swiftlint:disable:next line_length` above it. Two half-keys cannot be reordered by a translator, and the
  fragments collide as generated symbols with whatever else ends in the same words.

## Previews and snapshots

`Previews/` sits here but is **excluded from the SwiftPM target** (`Package.swift`) and compiled only by the Xcode
targets in `Apps/`. `#Preview` is an external macro implemented by `libPreviewsMacros.dylib`, which ships inside
Xcode's platform SDKs and not in the pinned swift.org toolchain — a `#Preview` anywhere under a SwiftPM target breaks
`mise run build`, `mise run test` and CI with "plugin for module 'PreviewsMacros' not found".

Adding a screen (project rule 8) means: a preview per state in `Previews/<Screen>Previews.swift`, whatever seam and
`#if DEBUG` factory those states need, `mise run test:snapshots:record`, and `git add` on the PNGs.

- Preview files use `@testable import ReachyUI`; that is why `ENABLE_TESTABILITY` is set for the whole Xcode project.
- **Prefire reads previews off the filesystem; Xcode compiles the file list Tuist baked in.** A new file under
  `Previews/` is therefore picked up by the generator but not compiled until `mise run project` runs again — which is
  why the snapshot tasks depend on it. A bare `xcodebuild` skips that and fails with "cannot find … in scope".
  **Deleting** a file needs the same regeneration, and fails less legibly: `Build input file cannot be found`, which
  reads as a broken checkout rather than a stale file list.
- Anything a preview body references must be visible target-wide, because Prefire copies the body into a separate
  generated file. Shared wrappers live in `PreviewScene`; a `private` helper compiles locally and breaks the test.
- **A preview with no `traits:` is captured at full device size.** Prefire defaults the trait list to `.device`
  (`RawPreviewModel.isScreen`), and that device trait is what carries `horizontalSizeClass` — so it is what makes the
  iPad snapshot exercise the regular-width layout. Components opt out with `traits: .sizeThatFitsLayout`.
- **A preview must be final on its first frame.** Prefire captures synchronously and its `.snapshot(delay:)` modifier
  lives in a module this target cannot import without breaking the macOS build. Never rely on a `.task` completing —
  hand the view a model that is already in its end state (`AudioSettingsModel.preview()`, `RobotSession.preview()`).
- Model preview factories live **in the model's own file** under `#if DEBUG`, not in `Previews/`: they write members
  that are `private` to that file, and `@testable` does not reach `private`.
- **One preview body, one model, four captures — so a teardown side effect leaks between them.** Prefire evaluates the
  body once and snapshots the resulting view per device and appearance, mounting and unmounting it each time; the model
  the body built is shared across all four. Anything in `onDisappear` that mutates it therefore corrupts capture two
  onwards while capture one still passes, which is the tell: a single preview failing on three of its four references
  with the first byte-identical is a state-leaking teardown, not a rendering change. Measured on
  `FloatingViewport.onDisappear` adopting a pending `settling`. Put such an effect behind `reachyPreviewMode` — the same
  key `.task` work uses, and for the same reason: a snapshot has to render the state it was handed.
- Screens take their model through an initialiser with a default (`init(session:model:)`), so production call sites
  are unchanged and previews inject a frozen one.
- A defaulted argument whose value is `@MainActor` (`= DeviceCheckModel()`, `= .preview()`) compiles in the SwiftPM targets
  but not in the `Apps/` ones, where it is evaluated nonisolated. Use `nil` and resolve it in the body.
- A model that already takes a factory closure (`OnboardingModel(session:)`, `BLEConsoleModel(link:)`) needs no new
  seam — hand it a `BLELink.preview(…)`, which sits on an inert `PreviewBLETransport` and is assigned its state
  directly. Building the link is not enough on its own: `OnboardingModel.session` is only set by `beginScan()`, which
  is the CoreBluetooth call a preview must not make, so the factory assigns it.
- A screen whose `.task` guards on `model == nil` needs no `reachyPreviewMode` check — injecting the model is what
  makes it inert. Add the guard only where the effect runs unconditionally (`WiFiSettingsCard`, `LogConsoleScreen`).
- **A tab whose content is loaded by a `.task` has no usable root capture, only a standalone one.** The shell builds
  all five tabs at once, and whichever loses that race is caught mid-layout. Settings comes out pure white on iPhone
  while rendering fine on iPad; Moves came out on iPad with its spinner but with the caption under it missing, and
  only a later run — one preview added elsewhere, timings shifted — produced the full frame. The tell is in the
  image: bare tab-bar glyphs instead of labels, or a state missing half of itself. Neither `SettingsScreen` nor
  `MovesTab` can be handed a settled model from `PreviewScene.root`, because the root builds the shell and the shell
  builds the tab — threading a seam through both for a preview is not worth it. So capture those screens standalone
  (`SettingsPreviews`, `MovesScreenPreviews`) and capture _placement_ from a state that needs no `.task` at all
  (`Root — relay moves tab`, which renders `MovesUnavailableView`). A blank or half-drawn reference is worse than a
  missing one: it reads as coverage and passes any change.
- Not covered, deliberately: `SceneViewport` in `.ready` — a bare `RealityView`, which renders nothing meaningful
  headless, so its overlay phases are what get snapshotted.
- **Not covered either, and measured rather than assumed: a `confirmationDialog`.** It presents in a context of its
  own that captures as nothing. Recorded twice for `RobotScreen`'s power-off dialog — once with a running app and
  once without, which change the sentence in it — the two references came out **byte-identical**, and identical to
  the same screen with no dialog at all. Three references for one image, none of which could tell the states apart.
  The rule that leaves behind: a dialog's _copy_ is model logic, and belongs in a model test
  (`RobotPowerOffModelTests` asserts which app gets named); the screen behind it is what a reference is for.
  `MaintenanceCard` never had one of these either, which now reads as the same finding made silently.
- **`CameraViewport` in `.streaming` used to be on that list and is not any more.** The reasoning was that the video
  is a Metal-backed `RTCMTLVideoView` and captures as an empty rectangle — true, and beside the point once the phase
  grew chrome of its own. The joystick and the return-to-neutral button draw over that empty rectangle perfectly
  well, and the button is _conditional_: a reference for the turned state alone cannot tell a conditional control
  from a permanent one, so `Camera — facing forward` exists to capture its **absence**. A black frame with controls
  on it is the intended image. The rule this leaves behind: a phase is uncapturable only while nothing but the
  unrenderable layer is in it.
- One `RobotSceneModel` per preview: `ReachyScene/AGENTS.md` requires exactly one live `RealityView` per model.
- **Navigation chrome does not stay inside a preview card.** SwiftUI hoists `.toolbar` and
  `.searchable` out of the storybook's scaled cards into the app's own bars, even though each
  preview brings its own `NavigationStack` — this is the limitation Prefire records as
  "NavigationView in Preview not supported for Playbook". The storybook hides its root bars to
  absorb it; `LogConsoleScreen`'s search field still floats over the catalogue, which is cosmetic
  and not worth contorting the screen for. Snapshots are unaffected — they capture the title _and_
  the toolbar items, so `RobotScreen`'s Settings gear and `MovesScreen`'s Refresh are covered.
  Only the storybook hoists.
