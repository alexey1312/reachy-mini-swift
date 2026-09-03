# ReachyUI

Shared SwiftUI views for all platforms (macOS/iPadOS/iOS). Depends on ReachyKit and ReachyMedia (WebRTC camera).

- Adaptive layouts, not per-platform copies; `#if os(iOS)` only for platform-exclusive APIs (Settings deep link etc.).
- `horizontalSizeClass` is unavailable on macOS — guard size-class branching with `#if os(macOS)` (always regular there).
  The root used to build a two-column `HStack` for a regular width and hide the Live tab on a compact one;
  `.tabViewStyle(.sidebarAdaptable)` does that adaptation itself, and it is iOS 18 / macOS 15, not an iOS 26 API.
  Reaching for the size class to fork a _layout_ is still a sign the layout is being forked rather than adapted.
- **There is exactly one size-class branch, in `FloatingViewportModifier`, and it is not a layout fork.** The
  viewport asks a different question: not "how wide is this" but **"does the shell draw a tab bar or a sidebar"**.
  `.sidebarAdaptable` makes that decision on the size class and offers no way to ask what it decided, so the modifier
  reads the same input and writes `FloatingViewportModel.hasTabBar`. This entry used to say nothing in the target
  branched on the size class; do not "restore" it by deleting the branch.
  - **What the flag decides has changed, and the old answer is written down here because it reads as the safe one.**
    It used to mean "is there a second place for the viewport at all": false collapsed `placement` to `.inline`
    everywhere, on the reasoning that a sidebar keeps the Live tab beside every other destination so there is nothing
    to float out of it. That is true of a **window** and false of the **viewport**. A sidebar layout still hides the
    Live tab's _content_ behind a selection, so iPad and macOS had no way to watch the robot and do anything else at
    once — while having the one thing an iPhone does not, which is width to spare. The flag now picks **which** second
    place: a tab bar gets the floating window, a sidebar gets a trailing column. Only `isEnabled` collapses everything
    to `.inline` now, and that is still the pre-window shape, `viewportIsOnScreen` included.
  - **`placement` has four cases and three hosts, so `!isInline` is no longer the overlay's condition.** `isWindowed`
    is — `.floating` or `.docked` — and the two mount points (`FloatingViewportModifier`, `FloatingViewport.body`)
    both read it. Left asking `!isInline` they draw the window **over** the column, because a column is not inline
    either. `drawn` guards on the same predicate, which is what keeps `drawnSize` and `drawnEdge` window arithmetic
    instead of switches carrying a meaningless fourth answer: a column has no corner, no edge, and a width the
    inspector owns.
  - **The column is `.inspector`, and the three things that made it viable were measured on a booted iPad, not read.**
    A ~100-line probe by the recipe below, on an iPad Pro 11 (M5) / iOS 26.4 at 834 × 1210: the inspector applied to
    the `TabView` renders as a trailing column at `hClass == .regular`, the content comes out **554 × 1099 against the
    column's 280 × 1210** — the 111 pt being the tab bar the content is inset by and the column is not, which is the
    "full height of the trailing column" a modifier outside a navigation structure gets — and a synthetic drag on the
    divider moved it **280 → 320** with the content at 514, so the sum stays 834 and the divider is live.
    - **`inspectorColumnWidth(min:ideal:max:)` is what makes it resizable at all**, which its name does not say:
      "inspectors can collapse by default, they aren't resizable by default" (WWDC23, _Inspectors in SwiftUI_). Drop
      the line and the column is fixed. The same session is why nothing here stores a width — the system persists
      what the reader drags to, and `ideal` is the first launch only.
    - **It goes on the `TabView`, never inside a tab.** Inside one it is rebuilt on every tab change, which tears
      down and remounts the `RealityView`; and only outside a navigation structure does it get the full height above.
    - **The `isPresented` binding is `.constant`, deliberately.** SwiftUI writes back through a two-way binding when
      it collapses the inspector itself, and it collapses on a width-class change — an iPad Split View resize away.
      That write would reach `setEnabled(false)` and persist "do not offer it" because a window was made narrower.
    - **The builder returns `Color.clear` unless `placement == .column`.** Neither the reference documentation nor
      that session says whether an inspector's content is evaluated while dismissed, and the cost of guessing wrong
      is the second `RealityView` this whole design exists to prevent. The guard makes the question moot rather than
      answered; it is the same shape `LiveTab` already uses.
    - **An iPad narrowed into Split View turns the column back into the window on its own**, because both forms read
      the one flag. Nothing implements that and nothing should: `.inspector` on a compact width adapts to a _sheet_,
      which is what the collapse to `rest` avoids.
    - **Applying `.inspector` collapses the iPad's large navigation titles to inline, presented or not — and that is
      accepted, not a bug to chase.** It is the modifier's mere presence: measured on `Root — viewport switched off`,
      which is the one root capture where `isEnabled` is false and the column therefore never appears at all. Its
      iPad reference still moved **28.1 % of pixels at maxDelta 255**, bounding box `x 600…2347 of 2388` — the whole
      content column shifted up by the height of a large title, with the sidebar to its left untouched. The iPhone
      reference of the same preview came back **byte-identical**, which is the control that makes the rest of that
      reading safe and the reason nothing here reaches a phone.
      This is what explains the four root captures that moved with **no viewport source at all**
      (`Root — apps need the local network`, `— dock on the apps tab`, `— no live view`, `— relay moves tab`): they
      have no column and never could, but they do have a navigation title. Predicting the column's captures and
      finding those four as well is exactly the "anything beyond the prediction is a second finding" case — do not
      re-record a wide sweep here without checking the titles first.
  - **A sidebar reads `isLiveTabSelected` nowhere, and that is a bug fix rather than a simplification.** It did at
    first, on the symmetry with the window: selecting Live handed the viewport back to the tab. A window has to do
    that because it _covers_ the Live tab's own content; a column sits beside it and never needs to — and paying the
    symmetry cost meant one `RealityView` with two mount points, which `ReachyScene/AGENTS.md` forbids outright.
    Reported as "3D does not always render after a tab switch", and instrumenting `RobotSceneView` on a booted iPad is
    what settled it. Four switches produced **four `make`s and four teardowns**, with `container.parent != nil` at two
    of the `make`s — the entity really was being reparented between scenes — one scene made and torn down **4 ms
    later**, and a running `made − gone` that reached **−1**. After the fix the same four switches produce **one**
    `make` and nothing else.
    - **That −1 is the part worth keeping.** `onDisappear` fires for a subtree whose `RealityView` `make` never ran,
      so it is not a teardown signal — which kills the obvious alternative fix of sequencing the two hosts on it. Do
      not reach for a "blank for one runloop turn" hand-over here; there is nothing reliable to key it on.
    - **Two hosts still exist behind the switch, and this is the known remainder.** Turning the column off on a
      sidebar sends the viewport back to the Live tab, which is a crossing of exactly the kind above. It is one
      deliberate action instead of every tab switch, and it animates nothing, so it has not been seen to fail — but
      it is the place to look if the symptom ever comes back.
    - **The Live tab therefore draws the controls on a sidebar**, not the picture: `ControllerScreen` inline, or
      `ControlsUnavailableView` where `canTeleoperate` is false (the relay carries no `ws/set_target`). Its
      `Controller` toolbar link is hidden there — pushing it would put a second `TeleopDriver` over the first. This is
      also the one arrangement in the app where the controls and the live view are on screen together: pushed as a
      screen, that `Form` covers a stream that goes on running behind it, which it did on every platform for as long
      as it shipped.
  - **`dockBleed(in:)` in the same file is the second branch on how the device is held, and it passes the same test.**
    It reads `UIInterfaceOrientation` — through `scene.effectiveGeometry`, because the scene's own
    `interfaceOrientation` is deprecated in the 27 SDK and the compiler names that replacement — and it asks neither
    "how wide" nor "how tall" but **"which end of this screen has no cutout in it"** — because that is the one thing no amount of geometry will say. iOS reports the landscape
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
      - **On an iPad the plist needs `UIRequiresFullScreen` as well, and the symptom is the same lie in new
        clothes.** iPadOS 26 runs an app in a resizable window by default, so the first run of the inspector probe
        measured **280 × 834 inside a window** and reported it as the screen — plausible numbers, wrong question.
        The tell is a resize grab handle in the bottom-trailing corner of the screenshot. With the key set the same
        probe reported 834 × 1210, which is the figure every conclusion here rests on. `UILaunchScreen` does not
        cover this: they are two different ways to be given a viewport that is not the device's.
        - **That escape hatch is gone in 27.** The same probe, rebuilt against the 27 SDK on an iPad Pro 11 running
          27.0, reported the same 417 pt window with and without the key — traffic lights, resize handle and all.
          So an iPad measurement there is a window measurement, and the only way to read the display is
          `scene.screen`, which the windowed run gave as 834 × 1210 against the window's 417 × 1158.
      - **The resized window costs `dockBleed` nothing, and that is measured rather than argued** (#114). Ask the
        scene for landscape with `requestGeometryUpdate` and iPadOS 27 rotates the interface inside a window whose
        shape on the display does not change — orientation as a preference, in one screenshot. The probe read
        1210 × 397 with **`l0 r0`**, so the bleed is zero at either end. The horizontal inset only exists where a
        cutout does, and that is a full-screen iPhone, where the window _is_ the display. The two orientation
        readings, deprecated and `effectiveGeometry`, agreed in every configuration reachable here.
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
- **`Navigation/SpotlightIndex.swift` is a third system again, and it publishes _destinations_ rather than
  commands.** App Shortcuts put actions in Spotlight; the icon's menu is UIKit's; this files `CSSearchableItem` rows
  the index can match against words the app's **name** does not contain. It exists because Spotlight matches an
  installed app on its display name alone, and this app's name is two words one of which is "Hey" — a token so
  common in mail, messages and contacts that the app ranks under all of them. Searching "Reachy" always found it and
  searching "Hey" did not.
  - **It widens what is findable; it cannot change how iOS _matches_.** Query length, tokenization and ranking are
    the system's, and no key here overrides any of them — iOS 17/18 has been reported to ignore `keywords` for
    content items entirely ([FB17330079](https://developer.apple.com/forums/thread/781872)), which is why
    `alternateNames` carries the same list. Never write this up as the fix for a particular query; a device is the
    only thing that can say what a given query returns.
  - **The app's name is read, never written down.** `appName` reads `CFBundleDisplayName` off the running bundle, so
    the one spelling stays in `Apps/Project.swift` — the same drift `ThemeIconNameTests` guards for the icon names.
    The keyword list is that name, plus each word of it separately (which is what puts "Hey" in the index as a term
    of its own), plus one comma-separated catalogue string a translator replaces wholesale rather than translating
    word for word.
  - **A row's `uniqueIdentifier` _is_ its deep link**, so a tap goes back through the same `ReachyDeepLink` parsing
    `onOpenURL` uses and there is no second table mapping identifiers to places. `RootLifecycle.follow(_:)` is the
    one arrival path for both.
  - **`expirationDate` is set, and the default is one month.** An item left to expire takes the app back out of
    every search these words reach — silently, and long after anybody would connect it to this file.
  - `indexIfNeeded` is `@MainActor` and `index(appName:)` is not, which is deliberate: `UserDefaults` is not
    `Sendable` (`KnownRobots.defaults` needs `nonisolated(unsafe)`) and neither is `CSSearchableItem`, so the
    stamp stays on the caller's actor and the items are built and spent inside one `nonisolated` function. Only a
    `String` crosses.
  - **Nothing here is under test cover on a device, and no reference image can be.** The index cannot be read back
    through any API, so `SpotlightIndexTests` asserts the half that decides what gets written and where a tap
    lands. What a query actually returns is a device check: install, search, and search again after a language
    change, which is the other thing the stamp keys on.
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
    which is the complaint the switch exists to answer. It is a menu rather than a bare glyph because what a reader
    finds is a word.
    - **The menu is no longer behind `floating.hasTabBar`, and that flag now only picks the word inside it.** It was
      hidden under a sidebar on the reasoning that there was nothing there to switch off; once there is a column,
      that left iPad and macOS with a placement and no way to refuse it. One stored key
      (`floatingViewport.isEnabled`) covers both forms on purpose — a device draws a tab bar or a sidebar, never
      both, so it only ever has one second place to have an opinion about — and `secondPlaceName` picks between
      "Mini window" and "Side column" off the model, which keeps the target's one size-class branch its only one.
- **A move belongs to the robot, not to the Moves screen, and `onDisappear` no longer stops one.** It used to:
  leaving the tab killed the dance. That was indefensible next to restoring a move across a relaunch — force-quit the
  app and the dance survived, glance at the camera and it did not. `MoveActivityBar` is the strip that replaced the
  bare Stop button, because two of the four phases have no control at all: an adopted move (`/api/move/running` names
  nothing, so it says "A move is running on the robot" with no row highlighted) and the second of parking, which
  offers no Stop because there is nothing left to stop. Showing the parking phase is not decoration — it holds the
  daemon's one move slot, so a screen silent about it would claim an idle robot while it was still travelling.
  `MovesModel.rowsAreEnabled(_:)` owns the tap gate rather than the view: every phase in it is a phase where
  `_try_start_move` would drop the play without a word.
- **The soundboard is two libraries on one screen, and every row says which one it is in.** `Sounds/` holds
  `SoundboardScreen` and `SoundboardModel`, pushed from the Moves tab rather than given a tab of its own — the five are
  unconditional, and "things the robot does when you ask" is the tab this already belongs to. The row is gated on
  `session.canManageSounds`, so a relayed session never offers a screen that could only report that it cannot ask.
  - **A play sends the file first when the robot is not known to have it, and that ordering is the feature.** Uploads
    live in the daemon's `/tmp`, so a restart empties them, and `play_sound` answers `{"status": "ok"}` for a name that
    matches nothing — so without the send a tap reports success into silence. `SoundboardModelTests.sendsBeforePlaying`
    asserts the order rather than the outcome, because both orders "work".
  - **`Presence.unknown` is not a fourth shade of absent.** It is what a row says when the _robot_ has not answered, and
    it exists so a failed listing never claims the robot is missing a sound. A failed load therefore keeps the device's
    library on screen as `unknown` with the reason in the error section, rather than relabelling everything
    `deviceOnly`.
  - **The rows are gated on the backend and never on `isAwake`.** A speaker is not a motor: a parked robot plays
    perfectly well, and only `play_sound`/`stop_sound` sit behind `get_backend`. Listing, sending and deleting work on a
    robot whose motors were never enabled, which is why `AsleepBanner` appears here off `!isBackendRunning` rather than
    off `!isAwake` as it does on the Moves screen.
  - **Nothing on this screen claims a sound is playing**, because no route reports it. The caption says a sound _was_
    played, and Stop is a row with a word on it rather than a toolbar glyph — a control that can never show a result
    should at least say what it does. It is gated on `isBackendRunning` like the taps above it, `stop_sound` sitting
    behind `get_backend` with nothing but a 503 to answer without one.
  - **The wobbling switch is on two screens and shares one model.** `MoveWhileSpeakingToggle` is drawn here and in
    `TelepresenceSheet`, and the `PresenceModel` behind it comes down from `ReachyTabShell` through `MovesTab` and
    `MovesScreen` as a plain `let`. Nothing reads the state back from the robot, so a second instance would disagree
    with the first forever — this is the same reason the shell owns it in the first place. The footer here is the
    sheet's own sentence, reused rather than reworded.
  - **Refresh is `.refreshable`, not a toolbar item.** The button it replaced could not show its own work: after the
    first listing `isContentLoading` is false by definition, and a LAN round trip takes tens of milliseconds, so a tap
    drew no frame at all. The system's pull gesture at least has a spinner. macOS has no such gesture, so
    `reachyRefreshToolbar` puts a ⌘R item there and nowhere else — every catalogue screen has exactly one way to ask
    again on each platform, and the two Refresh buttons the Apps and Moves screens carried on iOS went the same way.
  - **Three things here are deliberately uncovered by any reference**, each for a reason already written up elsewhere in
    this file: the `fileImporter` sheet and the delete `confirmationDialog` both capture as nothing, and the two
    `ControlWidget`s are WidgetKit, which the snapshot suite never exercises. The confirmation _copy_ is model-adjacent
    and is asserted in the screen's own tests instead; the controls are a built-metadata check plus a device install.
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
- **The gate has three segments and it had four; the typed address is not one of them.** `Local`, `HF`, `Simulator` —
  short because four segments of prose truncate on an iPhone, and a segment nobody can read is a segment nobody
  opens. What went was `Manual`, into the foot of `Local`, and the argument is that it was never a fourth _way_ to
  reach a robot: it answers the same question the sweep does, and the reader who needs it is the one watching that
  list stay empty — which is the worst possible moment to send someone hunting through tabs.
  `NetworkRobotsSection`'s own footer had been saying "or enter its address below" the whole time it was a segment
  away. Consequences worth knowing before touching either: `ManualAddressSection` keeps its name and its `disabled`,
  the three `Connection — manual address` previews are now captures of the **default** segment, and
  `SmokeTests.testColdLaunchShowsConnectGate` queries these labels by name in English.
- Leaves stay injectable rather than reading the router: `ConnectionScreen.showRemoteRobots` is optional because its
  absence is what hides `YourReachiesSection` in previews. The router is the shell's business.
- All robot interaction goes through `RobotSession` / `RobotBrowser` from ReachyKit — no direct URLSession here.
- Screen logic belongs in a `@MainActor @Observable` model beside the view (`MovesModel`, `LogConsoleModel`), covered
  by `Tests/ReachyUITests`; the view stays thin. `@Observable` does honour `didSet`, so derived caches can live there.
- **The threshold is a second step, not a second line.** A view earns a model when it coordinates a call that reads
  something back (`WiFiSettingsModel.forget` re-reads the list), when it reports a failure to the user, or when it
  derives text from what the robot said. Pure display state stays in the view's `@State`: which sheet is up, which
  dialog is confirming, which disclosure is open — `WiFiSettingsCard` keeps `confirmingForgetAll` and `joining` and
  nothing else. A model that only copies session properties buys nothing, which is why the many views reading
  `session.snapshot` directly are right as they are.
- **The seam is a closure with a default, not a protocol.** `WiFiJoinModel`, `WiFiSettingsModel` and
  `RobotHFLinkModel` take `typealias Forget = @MainActor (RobotSession, String) async throws -> Void`, defaulted to
  the session call. A test then drives the model with no stub client, and previews seed it through
  `#if DEBUG static func preview(…)`. That costs less than a protocol and adds no conformance to `RobotSession`.
  It also catches what a recorded image cannot: the second call, the `defer`, and the branch that must _not_ run —
  `RobotHFLinkModelTests.doesNotRereadASkippedRelay`.
- **A model reaches its view as an optional argument the init defaults.** `model: WiFiSettingsModel? = nil` with
  `_model = State(initialValue: model ?? WiFiSettingsModel())`, and the init is `@MainActor`: a defaulted argument
  whose value is main-actor-isolated compiles in the SwiftPM targets and not in the `Apps/` ones (`MaintenanceCard`
  carries the same note). Adopting the argument into `@State` is also what makes the `.sheet` rule below survivable.
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
  `TeleopPadCluster` owns the shared driver lifecycle; camera and scene provide only their visibility gate and
  factory. `ViewportContent` forwards the factory to the scene only for simulated sources, where the model is the
  robot being driven rather than a mirror of a LAN robot.
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
- **`ASWebAuthenticationSession` has two main-actor traps, and only one is visible in the source.**
  `presentationAnchor(for:)` is `nonisolated` and AuthenticationServices calls it from a queue of its own, so
  `MainActor.assumeIsolated` there is an assertion rather than a hop and takes the process with it — decide the
  anchor on the main actor before `start()` and hand it back. The second has nothing to grep for: the completion
  handler is written inside a `@MainActor` method and the ObjC block parameter is not `@Sendable`, so Swift 6 infers
  the enclosing isolation and wraps it in the same `dispatch_assert_queue` **even though its body touches nothing
  isolated** — which is why removing the explicit `assumeIsolated` fixed nothing and the crash came back unchanged.
  `@Sendable` on the closure is the fix; hopping is not available (the requirement is synchronous) and a
  `@preconcurrency` conformance only inserts the same check. The root `AGENTS.md` has how to find either one in the
  log, because neither leaves an exception.
- **A modifier around a `Button` or a `Menu` sets neither its appearance nor its click target** — both belong to the
  control. Wrapped around one it draws the disc in the right place while macOS draws the button's own rectangle
  around the glyph inside, and only that rectangle answers a click. A `Button` takes a `ButtonStyle`, whose body
  _is_ the button; `ViewportControlButtonStyle` is the worked example and `viewportControlLabelStyle()` is named for
  where it may go. **State the size and the shape, never derive them from the glyph**: `Circle` insets to the
  shorter side, so anything wider than it is tall overhangs the disc drawn around it — at `.title3`
  `slider.horizontal.3` is 35 × 31 against `ellipsis.circle`'s 33 × 33 and `mic.slash`'s 31 × 34, which is three
  diameters and two overhangs, reported as a stray line across one button. The same mistake has a toolbar spelling:
  a toolbar sizes its chrome around a **15 × 15** symbol, so a 26 pt avatar deformed the item's glass into a shape
  neither round nor a capsule, and two attempts at the _shape_ moved it without settling it.
  - **A `Menu` is measured, not guessed.** Painting a background straight onto the menu makes the rectangle drawn
    the control itself, and therefore its hit area: `.borderlessButton` discards the label's layout entirely,
    `.menuStyle(.button)` imposes **39 × 17** of its own, and only the default style plus `.buttonStyle(.plain)`
    honours the label's **36 × 36**. So "just use the same `ButtonStyle` as the buttons" cannot work for a menu.
  - **`ImageRenderer` measures SwiftUI layout and lies about anything AppKit-backed.** It reported 36 × 36 for a
    `Menu` spelling that was visibly smaller in the app, which sent one fix in the wrong direction. The macOS twin
    of the iOS probe above is the answer: a borderless `NSWindow` holding an `NSHostingView`, positioned at
    `screen.frame.maxY - height - inset`, then `screencapture -R x,y,w,h`. **AppKit's origin is bottom-left and
    `screencapture`'s is top-left**, which is what makes the first capture come back showing the desktop; key the
    background to a colour nothing else uses and read the bounding box. `screencapture` needs Screen Recording
    permission, and the window of an app under Stage Manager cannot be captured at all while it is in another stage.
- Deployment floor is iOS 18 / macOS 15 (`Package.swift`, `Apps/Project.swift`), set by `RealityView`.
  `ScrollPosition`, `onScrollPhaseChange` and `onScrollGeometryChange` are available; the zero-height sentinel row in
  `LogConsoleScreen` predates the bump and is not a required pattern.
- **A `@State` property assigned in `init` is declared without a default, and that convention is what made TN3211 a
  non-event here.** Xcode 27 initialises `@State` lazily — back-deployed to iOS 17 — so a default expression runs at
  the property's first _access_ rather than at the view's construction, and the shape it breaks is a property that
  has both a default **and** an `init` assignment. The audit found **none**: all 58 `_x = State(initialValue:)`
  assignments in `Sources/` and `Apps/` belong to properties declared bare. Do not "tidy" a type annotation into a
  default on one of them; that is the bug, and it is silent.
  - **What the audit did change is one default that read mutable global state**: `ConnectionScreen`'s
    `awaitedHardwareID`, which reads `KnownRobots.pendingProvisionedHardwareID` — a value `RobotSession` clears on the
    handshake, so a deferred read is a banner that never appears. It is assigned in `init` now, beside `manualInput`,
    which reads `KnownRobots.lastAddress` from the same position. **The rule generalises past `@State`**: a default
    that reads global state is a default whose evaluation time is part of its meaning.
  - **The other two computed defaults were checked and deliberately left alone.** `ReachyTabShell.presence`
    (`PresenceModel()`) and `RobotScreen.powerOff` (`RobotPowerOffModel()`) construct a fresh model and read nothing,
    so lazy construction is strictly cheaper and observably identical.
  - **Nothing pins any of this, and no test could.** `@State` initialisation order is not reachable from a unit test,
    and the banner has no reference image. This entry is the cover.
- **The UIScene launch requirement is declared in `Apps/Project.swift` and belongs to `QuickActionSceneDelegate`.**
  SwiftUI's `App` has always been scene-based, but adoption is an Info.plist key and Tuist's `.extendingDefault` does
  not supply one. The manifest carries `UIApplicationSupportsMultipleScenes: false` and **no** `UISceneConfigurations`
  — the app builds its own configuration in `application(_:configurationForConnecting:)` to name the delegate, and a
  listed configuration would disagree with it. The widget extension is an appex, not an app, and the requirement does
  not reach it.

## The joystick's rotation zone

`JoystickMapping` splits the pad with a **vertical line** at `±rotationThreshold`, not with a radius and not with a
sector, and the reason is the handover: that same line is where head yaw reaches its full lead, so the head stops
moving out exactly as the body starts. A radial zone parts the two — a push into the corner is far from the centre
while its sideways component is not, so the body would begin turning under a head still halfway through its own
travel. A sector rule (`|x| > |y|`) has the opposite problem: crossing its 45° edge at full deflection would drop the
rate from most to nothing, so the taper it would need to be jolt-free leaves a boundary too fuzzy to draw or to tick a
haptic on.

- **The daemon measures the head from the base, not from the torso, and `TeleopDriver` is the one place the two are
  composed.** The Stewart platform is handed `yaw − body_yaw` — proven by running the shipped IK rather than read off
  a doc: `(head 30°, body 30°)` comes out bit-identical to neutral, and `(head 0°, body 30°)` identical to
  `(head −30°, body 0°)`. So a head sent at a fixed angle while the body turns holds its **absolute** direction and
  visually unwinds from the torso: the camera stopped panning at the exact moment the robot started turning, which is
  what this shipped for five releases. Every angle in `JoystickMapping` is therefore body-relative — the only frame a
  pad centred on the torso can mean — and `TeleopDriver.target.yaw` is that plus `target.bodyYaw`, written in one
  place (`worldYaw`). `target` is `private(set)` to keep it one place: `@Bindable` would otherwise hand
  `$driver.target.bodyYaw` to the next slider, which is the same bug in a second place. The composition is exact
  (`rpy` is `Rz·Ry·Rx`, so the body's yaw factors out on the left) and stays exact only while `x` and `y` are zero —
  they are world-frame too, and driving them needs `Rz(bodyYaw)` applied to the pair.
- **The second half of that bug was invisible, and it was a limit.** The daemon also clamps body yaw so
  `|head − body| ≤ 65°` (`max_relative_yaw`), so a head pinned at −40° forever meant the body stopped near ±105°
  rather than the ±180° the client was integrating toward. Composed, that difference never exceeds `headAngle`, the
  clamp goes inert, and the whole of `TeleopDriver.bodyYawLimit` — the URDF's own ±160°, mirrored here because the
  head's world yaw is computed from it — becomes reachable. `staysInsideTheRelativeLimit` is what holds it.
- **`headRecentring` decides where the head sits during the turn, and it is a feel constant.** At 1 the head gives its
  whole lead back across the zone, so a held deflection leaves the camera looking straight down the torso; at 0 it
  keeps the lead for the whole turn. The cost of 1 is that world head yaw is a tent in thumb travel — crossing the
  boundary hands 40° back before the body has moved, so the camera swings against the push and the body needs
  `headAngle / maxBodyYawRate` to repay it. Only the robot settles that; the knob is one number.

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
`SystemUpdateModel.state`, `WiFiSettingsModel.loadFailure`, `RobotHFLinkModel.linkError`. `RobotSession.robotError`
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

## The store's scope and sort

`AppStoreFilters.swift` holds `AppStoreModel.Scope` and `.Sort`; `visibleApps` composes them as section →
scope → search → order. A file of its own because `AppStoreModel.swift` is within a few dozen lines of both
SwiftLint's file and type limits, and `--strict` turns that warning into a build failure.

- **`.recommended` is the default because the daemon's order _is_ the curation.** `list_all_available_apps`
  concatenates the curated `app-list.json` entries ahead of every other Space, and
  `hf_space._build_app_info` stamps **`source_kind = hf_space` on both lists** — so curation survives only as
  position in the array, and a default sort of anything else silently throws away the one editorial signal the
  store has. `keepsDaemonOrdering` in `AppStoreModelTests` predates the sort and is what said so.
- **Scopes are questions, not buckets.** `.community` is the complement of `.official`, so a private community
  Space answers both it and `.privateSpaces`. Partitioning them would hide such a Space from a reader who asked
  for community apps, which is the more surprising of the two ways to be wrong. And **official can only ever
  mean the author** — there is no verified flag on a Space, and the curated list is indistinguishable on the
  wire.
- **The two dates were already on the robot, undecoded.** `extra.createdAt` / `extra.lastModified`, folded onto
  that one spelling by the daemon's `_normalize_space_data`, and present in **both** its catalogue paths
  (checked against the live Hub API, not inferred). `JSONCodec.daemon` already reads ISO 8601 with fractional
  seconds and `Card`'s `value(_:_:)` already swallows a field of the wrong type, so decoding them cost two
  properties and no new parsing.
- **`sorted(by:)` is not stable**, so every sort ends in a tie-break on title and then `id`. Without it two apps
  by the same author swap places between redraws of a list nobody touched — invisible in a snapshot, which
  captures one frame.
- **A toolbar item moves every reference of its screen and none of any other.** The filter menu moved 8
  previews × 4 references and left the `App detail —` sheets alone, because the toolbar is on the screen and not
  on the sheet. Predict that count before recording; anything beyond it is a second finding.
  - **It renders at `maxDelta 13`, and that is not evidence it is missing.** The glyph is thin, light and on
    glass, which `ReachyDesign/AGENTS.md` records as rendering faint headless. A pixel-diff summary alone would
    read as "the bar resized"; cropping the reference and looking at it is what confirmed the button.
- **`record` overwrote a good reference with an unstable one, and the run after it caught that.**
  `Moves — dances loading` moved with the other 32 for no reason belonging to this change, and its
  freshly recorded copy then failed against itself while the copy at `HEAD` passed — an indeterminate
  `ProgressView` captured at an unlucky phase, the churn the previews section describes. So a re-record is not
  the end of the job: run `test:snapshots` again afterwards, and `git checkout HEAD --` anything that moved for
  a reason you cannot name.

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
- **Start depends on the robot's power now, and the two power conditions are shown differently on purpose.** A
  sleeping robot keeps its Start — `RobotSession.startApp` wakes it — and only the footer says so, because a Wake up
  button beside a button that wakes is a step the reader does not have to take. A _stopped backend_ gets
  `AsleepBanner` instead and Start goes out, because the way back is a 90 s job and that is a decision, not something
  to meet inside a tap. Both follow `MaintenanceCard`'s rule: a disabled control with no reason attached tells the
  reader nothing to act on. `PowerTransitionRow` covers the seconds in between; it is shared with `RobotScreen`
  rather than copied, and it is what keeps Start from reading as a button that did nothing.
  **The three states are captured** (`App detail — robot asleep`, `— robot backend stopped`, `— waking up to
  start`), and they had to be pointed at `RobotApp.previewConversation`: `previewCatalogue[0]` and
  `previewInstalled[0]` carry different `spaceID`s, so `matches(installed:)` never joins them and every existing
  `App detail — installed` reference is in fact a picture of the _not_ installed state, Start included. Fixing that
  fixture would move references belonging to other screens; use an app that is installed in its own right instead.

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

## The robot's state screen

`Health/` — a screen pushed from the Robot tab, fed by two sources that fail independently and are never presented
as one. The **two sections are named after their sources** (`Control loop`, `System`) rather than merged, because
where a number comes from decides whether to trust it when the other half is missing.

- **A screen and not a section on the tab, and the lifecycle is what earns that.** As a section it held an SSH
  connection open for as long as the app was connected to the robot, and carried a password sheet and a failure row
  inline on the tab the app opens on. The reading now starts on `.task` and stops on `.onDisappear`.
- **The daemon's half is free and works everywhere.** `control_loop_stats` rides the status `RobotSession` already
  polls every three seconds. `RobotScreen` — not the screen — records it through `.onChange(of:initial:)`, so the
  series is already a line when the screen opens instead of taking three minutes to become one, and a second timer
  over a three-second poll would sample the same value twice as often as it changes.
- **The operating system's half is SSH, and it is LAN-only by construction.** `session.address == nil` builds the
  model with no file system at all, which settles it in `.unavailable` — the same gate `filesLink` uses, and the
  reason is the same (ADR 0003: the relay carries WebRTC, not a tunnel). The footer says so instead of offering a
  sign-in that could not connect. The **link** on the Robot tab is hidden only when _both_ halves are gone.
- **It never prompts.** An absent credential settles in `.needsPassword` and waits for a row to be tapped. A health
  panel that raises a password field on open has turned a passive reading into a demand.
- **Sampling is gated on `scenePhase == .active`** as well, the same gate `RunningAppDock` puts on its poll.
  `stop()` keeps `phase` at `.sampling` on purpose, so the readings stay on screen through the gap and `start()`
  reconnects on the way back; a panel that blanks itself whenever the app is put away is a panel nobody trusts.
- **`HealthFormat` exists because two screens spell the same number.** The Robot tab shows the loop rate beside the
  link and the screen shows it again at the top; two formatters is two answers to "how fast is the loop" that can
  disagree by a decimal place.
- **`SSHPasswordForm` takes bindings, not a model**, because two screens now sign in to the same robot. Typing it to
  either model would mean a second copy of the field, the footer and the shipping-default password warning — and the
  warning is the part that must not be allowed to drift. `HostKeyConfirmation` was already model-free.
  - **Its `error` slot is not optional decoration, and both models owe it a `lastError`.** A refused password is the
    one failure that does not land in a phase anybody can read: it goes back to `.needsPassword`, which is a row
    offering the sheet again, while the sheet stays up over it with the field cleared underneath. Passing `nil`
    there — as this screen did first — makes the entire answer to a mistyped password a text field emptying itself.
    The key is shared with `RobotFilesModel`, so the two paths say the same sentence.
- **The sparklines are Swift Charts**, which ships with the OS well below this app's floor. Their y-domains are
  **fixed** (`HealthMetric`), never fitted to the data: a sparkline that scales to its own extremes turns a 0.3%
  wobble in memory into a mountain range and a processor pinned at 100% into a flat line. Each is
  `accessibilityHidden` — the row above states the value in words, and voicing sixty points is that fact sixty times.
- **The thresholds are hardware facts and live in `HealthLevel`, tested.** 80 °C is where the Raspberry Pi 5 begins
  soft-throttling, so `elevated` arrives before it rather than after. No reference image can tell a wrong threshold
  from a right one, which is why they are not inline in the view.
- **A preview injects fixed series.** Live samples would redraw differently on every capture. `RobotHealthModel.preview`
  fills the daemon's series always and the other three only while `.sampling`, which is exactly what the screen shows
  when SSH drops: the loop keeps drawing and the operating system's rows go.

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
- **The iPhone references render at `.medium`, one step below a device's default text size; the iPad ones at
  `.large`.** `ViewImageConfig`'s iPhone traits set `preferredContentSizeCategory: .medium` and the iPad traits set
  nothing, so a `@ScaledMetric` comes out at about 94 % of its constant in every iPhone reference and at the constant
  on iPad — adopting one moves the iPhone pair of every preview it reaches and nothing else, measured at 38 previews
  for five sites (the joystick knob, the theme tiles, the remote-robot artwork, the reset screen's bullets, the
  floating switcher). That is the expected shape of adopting one, not a regression: the constant it replaced only
  stayed put because it did not scale, which is the whole point. And **a labelled `Slider` draws a tick per step on
  iOS 26** — the `label:` initialiser, not the bare one — so a slider's name goes on as `accessibilityLabel`;
  `AudioSettingsSection` carries the note.
- **Every capture runs in `reachyPreviewMode`, set by the stencil and not by the preview.** `.preview()` still sets
  it for the screens that need their `.task` inert, but the glass gate in `reachyButton` cannot be left to that:
  the ReachyDesign gallery and the asleep banner never called it, met `.glassProminent`, and came back as blank
  references — which pass any change. `PreviewTests.stencil` wraps every body in `.reachyPreviewMode(true)`.
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
- **`SceneViewport.ready` is captured only with the simulator joystick.** RealityKit itself is blank headless; the
  image covers the controls, while `ViewportModelTests.onlyTheSimulatorDrivesItsScene` covers the source gate.
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

## Entities in Spotlight, beside the three systems above

`Navigation/EntityIndex.swift` is the **fourth** system next to App Shortcuts, `ReachyQuickAction` and
`ReachySpotlightIndex`. Its neighbour files _destinations_ — two rows that open two tabs, because Spotlight matches
an installed app on its display name alone. This files the robot's own apps and moves as **entities**, and an
indexed `AppEntity` carries its type with it, so Spotlight can pair the row with the intents that take that type:
searching for a dance offers to play it. The conformances live in `ReachyWidgetUI` beside the entities themselves.

- **Never the network.** Both lists come out of the caches the entity queries already read — `RobotAppsCacheStore`
  and `MoveEntityQuery`, the latter documented as reading only. `RobotAppQuery.suggestedEntities()` is deliberately
  _not_ used: it carries a 2 s live refresh this has no use for, and it **writes** the cache.
- **Never `deleteAllSearchableItems()`.** `ReachySpotlightIndex` files its two destination rows into the same default
  index, and a blanket delete takes them with it — silently, and long after anybody would connect the two files.
  Deletion is `deleteAppEntities(ofType:)`, which is also what retires an app removed from the robot.
- **The stamp is over the content and it is SHA-256, not `hashValue`.** Unlike the two destination rows, this list
  changes while the app is installed: every install, removal and `reset-apps` moves it. And Swift seeds `Hasher` per
  process, so a stored `hashValue` compares unequal on the very next launch — the index would be rewritten on every
  cold start, and the only symptom would be battery. `EntityIndexTests` pins the digest as a pure function of the
  content; nothing in one process can catch the `hashValue` version.
- The trigger is one `.task(id:)` in `RootLifecycle`, keyed on the robot **and** the scene phase. Connect-only would
  miss the ordinary case: the widget and Shortcuts both start and install apps with this process not running.
- Only _installed_ apps are indexed. The catalogue holds hundreds nobody has, and a row offering to start one of
  those cannot do what it promises — the same reason `ReachySpotlightIndex` leaves `.runningApp` out.

## Where the robot heard you

`DirectionOfArrivalModel` + `DirectionOfArrivalIndicator`, mounted in `ViewportView`'s chrome row and owned by
`ViewportModel`.

- **It opens a socket of its own rather than reading `RobotSceneModel`'s.** That one already receives every field of
  every frame and could publish this for a line — but it streams only while the 3D model is on screen, so the badge
  would go dead the moment somebody switched to the camera. That is exactly the view where "somebody spoke, off to
  your left" is worth having, because the robot's own picture cannot show them. `StateStreamOptions.hearing` keeps
  the second socket cheap, and **its three `false`s are the whole point**: the daemon defaults `with_head_pose`,
  `with_body_yaw` and `with_antenna_positions` to _true_, so a preset that merely added `with_doa` would carry a full
  pose five times a second for a two-field reading.
- **An axis, never a compass.** The daemon reports one angle along the robot's left–right line — 0 = left,
  π/2 = front/back, π = right (`.claude/rules/daemon-api.md`) — so **π/2 is a genuine degeneracy**: a two-microphone
  array measures a delay along one axis and cannot tell in front from behind. A dial would have to invent the missing
  half and would be wrong about it half the time with nothing on screen admitting it. `Side.frontOrBehind` is that
  case, and it has a preview of its own so the wording cannot quietly be "improved" into a claim.
- **The directions are the robot's, so they are `left`/`right` and the symbols do not mirror.** Same exception
  `JoystickPad` takes, and the same reason: a right-to-left language flipping these would reverse a fact about the
  world. The caption says _its_ left out loud, because looking through the camera and looking at the 3D model put the
  robot's left on opposite sides of the screen — the only unambiguous thing to draw is a word.
- **`isSupported` is what keeps the badge off a robot that cannot answer.** `doa` is nullable and `sim-daemon` sends
  `null` for ever, as does any unit with no array; a badge mounted on hope would sit blank on every simulator run and
  read as broken rather than absent. Quiet and unsupported render identically and are separate properties for exactly
  that reason.
  - **There is a third reason for `null`, and it is the one that looks like a bug in this file.** The array needs
    ReSpeaker firmware **2.1.0 or higher** (`reachy_mini/media/audio_doa.py`, readable in `.venv-sim`), and the
    daemon reports an older one by answering `null` rather than by complaining — so a unit that visibly _has_ the
    array shows no badge and every layer here is behaving correctly. Check the firmware before reading the model.
    The upgrade is Seeed's:
    <https://wiki.seeedstudio.com/respeaker_xvf3800_introduction/#update-firmware>.
- **The hold window is retired by the stream, not by a `Timer`.** Frames arrive at 5 Hz whether or not anybody is
  talking, so the stream is a clock the model already owns — the same argument `RunningAppModel.expireActionFailure`
  makes about its poll. `stop()` keeps the last reading, so a glance at another tab does not blank one still inside
  its window; only `detach()` drops it, because that is a different robot.
- **No existing reference moved.** `ViewportModel.preview` defaults `hearing` to nil, so the badge is absent from
  every capture that predates it; `Viewport — heard a voice` is the one that shows it in the chrome row, and the
  standalone `Direction of arrival —` set covers the badge itself. **None of it can be verified against
  `sim-daemon`** — that sends `doa: null` — so the mapping is a hardware check.

## Driving the Live Activity

`Apps/RunningAppActivityPlan.swift` (+ `Reading`), `RunningAppActivityController.swift` and
`RunningAppActivityDismissal.swift`. The card itself, and why it is shaped as it is, are in
`ReachyWidgetUI/AGENTS.md`; this is the half that decides. Issue #61.

- **A pure reducer, the `CallLifecycle` shape, and the reason is the same one written there.** ActivityKit is
  iOS-only and `mise run test` is SwiftPM on macOS, so a rule inside an `#if os(iOS)` fence is a rule no test can
  hold. `RunningAppActivityPlan` therefore decides everything and touches nothing; `RunningAppActivityController` is
  a thin adapter over five injected `@Sendable` closures whose defaults are the ActivityKit calls.
- **The drive hangs off `RootLifecycle`, not off the dock's own modifier.** That one unmounts when the shell gives
  way to the connect gate — which is exactly the disconnect the card must be torn down on. It is a `.task(id:)` over
  an `Equatable` facts struct, the shape `RobotWidgetFacts` already has and for the reason recorded there.
  `RunningAppModel` is not edited: it is at SwiftLint's length limit and every input already exists on it.
- **`Activity.activities` is the source of truth for "is there one", never a stored handle** — the process that
  renders is not the process that started it. Reconciling against it on every pass is what covers three separate
  hazards at once: the app was killed and relaunched, the eight-hour cap ended the card, and the reader swiped it
  away while nothing was running to be told.
- **A card the reader dismissed must not come back, so the dismissal is durable.** Without it the next foreground
  pass sees a running app and no card and resurrects exactly what was waved away. `RunningAppActivityDismissalStore`
  keys on `robot/app` and **expires on `RobotSnapshotStore.freshness`** — past half an hour nothing else here
  believes the reading it was about either, and an app stopped and restarted while this process was closed would
  otherwise be suppressed for ever. The eight-hour cap records the same thing: re-creating a card starts a fresh
  eight hours, so a conversation app left running all day would reappear every eight hours for ever.
- **A restart is not the app letting go.** `restart-current-app` is stop-then-start behind one request, and a poll
  landing between the halves reads an idle robot — ending there is a false "stopped" and a new card 1.5 s later.
  `RobotSession.isRestartingApp` was made public for this one guard; the in-app dock never needed it because it
  draws what the session holds rather than ending anything on the edge.
- **An unchanged reading still moves the stale date, but not on every tick.** Skipping identical updates lets a
  healthy app polled every ten seconds go grey on screen; pushing every tick spends the update budget on nothing.
  The rule is "rendered content changed, or 60 s since the last push", and `RunningAppActivityContent.rendersSameAs`
  is what excludes `readAt` from the comparison — it moves with every poll by construction, so a plain `==` would
  mean no reading is ever unchanged. That was a real bug, caught by its own test rather than on a device.
- **One alert, on the crash edge, and it rides an `update` because `end` takes no alert configuration.** Not on a
  start (the reader caused it and the card appearing _is_ the notification), not on a clean finish, not on a wedge
  (that is the _absence_ of an event, and alerting on silence is how a Wi-Fi blip becomes a notification), not on a
  refused Stop. The title joins through the installed list and the body is the summary line alone: on a paired Watch
  this is a real alert, and a stack frame is not a sentence.
- **A refused Stop updates and never ends.** Ending on a failed Stop reads as the Stop having worked — the bug
  `RunningAppCaption.description` was written to fix, in a second place.

## Job notifications

`Notifications/JobNotificationPlan.swift`, `JobNotificationCenter.swift`, `JobNotificationSystem.swift`,
`NotificationPermission.swift`, `JobNotificationSettings.swift`, plus `Settings/NotificationsSection.swift`. Issue
#80, and it is sequenced **after** the Live Activity rather than instead of it.

- **A pure reducer again, but the reason is not the Live Activity's and copying that one's doc comment would be
  wrong.** `UserNotifications` ships on both platforms this app targets, so there is no `#if os` fence anywhere here.
  The split earns its place on something harder: `UNUserNotificationCenter.current()` **traps** in a process with no
  bundle identifier, which is exactly what `mise run test` is. A rule that calls it is a rule that crashes the whole
  suite rather than failing one case. Hence the discipline the boundary file states outright — the singleton appears
  only inside a `@Sendable` closure _body_, never in an initialiser, a computed property read at construction, or
  file scope.
- **The centre is a `shared` singleton, and the Live Activity's `@State`-on-`RootLifecycle` shape would break this.**
  ActivityKit refuses a request from anywhere but the foreground, so driving the card from SwiftUI costs it nothing.
  A job notification's entire purpose is the moment the app is _not_ on screen, and putting an update pass in the
  delivery path makes delivery contingent on a redraw a backgrounded scene may coalesce. `RootLifecycle` contributes
  one fact — the scene phase — through `sceneChanged()`, which fires on **every** phase and not only on activation.
- **Authorization is cached and refreshed on scene change, not read per event, and that is a race fix.**
  `receive(_:)` must mutate the plan _synchronously_: wrap it in a `Task` and a settle can overtake the start it
  belongs to, whereupon the plan's primary guard silently drops it. Scene activation is also the only moment the
  answer can have changed — coming back from Settings is a phase transition by definition.
- **`running: Set<Key>` is the primary guard, and it is a whole class of bugs rather than one.** A settle whose start
  was never observed belongs to a relaunched process, a stale model, or a `check` that failed before any job existed.
  None of those may notify and none has to be enumerated to be refused. `.started` inserts the key **whether or not
  posting is permitted**, so a reader who grants permission halfway through a ten-minute update is still told — the
  one asymmetry in the file, and it has a test because otherwise it reads as an oversight.
- **No durable store, deliberately, and this is where it differs from `RunningAppActivityDismissalStore`.** That
  exists because a _card persists_ and is reconciled against `Activity.activities` on every foreground pass, so a
  swipe has to be remembered. A notification is an event: once delivered it is over, and the only process that could
  re-emit it is one that never observed the start.
- **The announcement rides `AppJobMonitor.Outcome`, never `AppInstallModel.State`.** `state(for:operation:)` collapses
  `.timedOut` into `.failed`, which is right on a sheet in front of someone who can go and look, and wrong in a
  notification, where "failed" would be a verdict inferred from a timer about a register that never answered. Keeping
  the two mappings separate is the point; unifying them is the one refactor that breaks this silently, and
  `AppInstallModelTests` has the assertion that goes red when it happens.
- **`SystemUpdateModel` announces off a `didSet` and `AppInstallModel` off explicit calls, and the asymmetry is
  deliberate.** `state` reaches a terminal value from six places in the update model, so a `didSet` is what makes a
  missed announcement impossible — and it inherits three existing rules for free, because a cancelled call, a job
  still running, and a failed `check` all work by _not assigning_. The install model cannot use one, for the reason
  in the bullet above.
- **Nothing survives the app being unloaded, and the copy says so.** Both hook points are polls that die with the
  process; `UIBackgroundModes` is `["audio","voip"]` and neither covers one. The deliverable is "announced while the
  app is still running in the background", and the footer key is written to prevent the over-promise. Keep that
  clause through review.
- **Zero capability changes.** No usage string, no background mode, no `aps-environment`, no `.timeSensitive` (which
  would need its own entitlement and a review justification for a finished install). `Apps/Project.swift`'s comment
  about declaring no push entitlement stays true, and a reviewer will look for exactly that.
- **No `UNUserNotificationCenterDelegate`, and it is not an omission.** Three layers already say the same thing: the
  plan refuses while `isForeground`; both platforms suppress foreground alerts by default when no delegate implements
  `willPresent`; and a delegate written only to `return []` would cost an `NSApplicationDelegateAdaptor` on macOS,
  which this app does not have. A pleasant consequence worth writing down because it reads as an accident: on macOS a
  visible-but-not-key window reports `.inactive`, so a reader with the app open behind Xcode **does** get told.
  Routing a _tap_ is what a delegate would be for, and that is a follow-up rather than this issue.
- **The fourth `PermissionKind` is not a device permission**, and the enum's doc comment says why at length — it
  gates no hardware and blocks nothing, and exists only so the Settings toggle cannot silently do nothing. It is also
  the one row with no matching usage string in `Apps/Project.swift`: the system writes that prompt's text.
  `PermissionState.restricted` is unreachable for it, and `.ephemeral` is deliberately not named — it is
  `API_UNAVAILABLE(macos)`, so spelling it fails the one CI job that compiles every SwiftPM target.
- **Notifications is not a Privacy anchor on macOS.** It is a pane of its own, so `PrivacySettingsLink.macOSURL`
  became a switch over whole URLs rather than over anchors. A wrong pane id still has **no runtime signal** —
  `NSWorkspace.open` returns `true` and shows whatever it found — so it is clicked by hand before merge.
