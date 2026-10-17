# ReachyTeleop

Driving the robot live, with no view in it:
`JoystickMapping` (the pad's mapping and its rotation zone),
`GamepadMapping` and `GamepadTeleop` (a game controller, and the Siri Remote on tvOS),
`TeleopDriver` (the one writer of the target that goes out on a `TeleopChannel`)
and `HeadAim` (a pose from headphones that track a head).

It is a target of its own so that a surface with no ReachyUI can drive.
The TV app (`Apps/ReachyTV`) links this, ReachyKit and ReachyDesign, and nothing else:
ReachyUI does not compile for tvOS, and its screens are not built for focus.
Safety stays in the daemon (project rule 2):
everything here writes one target, and the daemon clamps it.

- **The design notes stay in `Sources/ReachyUI/AGENTS.md`**,
  under "The joystick's rotation zone", "A game controller (#160)" and "Headphones that track a head".
  Those sections are about how the pad, the controller and the headphones feel on the screens that draw them,
  and the screens are in ReachyUI.
- **Nothing here draws, and nothing here may.** ReachyDesign is linked for `.reachy(_:)` and `reachyPreviewMode`.
  A view that both ReachyUI and the TV app need is a sign that the view belongs in neither shape.
- **`Double.clamped(to:)` is internal here and in ReachyUI**, one copy each, as ReachyKit keeps its own.
  A public extension on `Double` would reach every module that imports this one.
- **The Siri Remote is a pad and nothing more** (`GamepadTeleop`, tvOS only).
  Its touch surface reports absolute positions, so where the thumb rests is the deflection,
  and lifting it is the release that recentres the head, as on the phone's pad.
  Play/Pause resets.
  The most recently used of the remote and a two-stick controller drives:
  `GCControllerDidBecomeCurrent` is what hands over.
  How it feels on a real remote is a device check; the simulator's remote was not driven here.
