# ReachyScene

RealityKit rendering of the robot, driven by the state stream. Depends on ReachyKit. Read-only — nothing here
ever sends the robot a command.

- An `Entity` has one parent, so there must be **exactly one live `RealityView` per `RobotSceneModel`** — a second
  one silently steals the robot from the first. Move the view; never mount two (this rules out zoom transitions and
  `if/else` layout branches, both of which keep source and destination alive at once).
- Going off screen calls `pauseStream()`, not `stop()`: `stop()` clears `geometryTask` and `start()` guards on it
  being nil, so the pair re-downloads the URDF and re-frames the camera.
- **The camera entity is the one thing that must _not_ survive a `RealityView` teardown.** Everything else is
  deliberately reused across the 3D/camera switch — the meshes, the entity tree, the lighting, the angle. But
  "the camera we render from" is a role the _scene_ holds, not a property the entity carries: append the same
  `PerspectiveCamera` to the replacement scene and it is present without being active, so nothing at all is drawn.
  `OrbitCamera.makeEntity()` builds a new one per view and applies the stored angle to it; the controller then
  writes to that instance. The failure is silent and looks like an empty viewport with `phase == .ready`,
  `container.scene` non-nil and the full child count — no property of the entity graph reveals it, because the
  entity graph is fine. Reproducing it needs the real screen: a bare box in a two-branch `ViewBuilder` swap does
  _not_ show it, since a trivial view tree releases the old scene before the new one is made.
- `head_pose` is the head's transform with the daemon's `head_z_offset` subtracted — both engines end `fk` with
  `T_world_head.z -= head_z_offset` — so drawing it is that subtraction undone, and nothing else. The offset is a
  **literal 0.177**, not a robot dimension: the URDF's own rest height is 0.14957, 27 mm lower. `StewartGeometry`
  therefore carries 0.177 rather than deriving it, and `RobotSceneGraph` takes its lift from there so the head and
  the rods `PassiveJointSolver` aims at it cannot end up at two different heights. Either number alone looks
  plausible on screen — one detaches the head from the platform, the other sinks it into the body.
- **A passive wrist is three stacked joints, so its three angles compose `Rx * Ry * Rz` — the reverse of URDF `rpy`**,
  and `PassiveJointSolver` decomposes with `RigidTransform.wristAngles(from:)` for exactly that reason. The pair is
  not interchangeable and the mistake is invisible where it is cheapest to look: the two orders agree to first order,
  so the rest pose and a small nod both draw correctly. But the daemon's neutral head pose already stands the motors
  at ±35.9° (`fk([±0.6266 …])` is identity — the URDF's own zero configuration is the head 27 mm _lower_), so every
  wrist sits 80–110° from its rest orientation across the head's whole working range. Feeding those angles back
  through the joint chain in `rpy` order aimed the rods 9 mm past their mounts at rest and up to **8 cm** during an
  emotion that raises the head — `understanding2`, which holds the head 10–17 mm up and pitches it 21°, drew the head
  hanging free of a linkage pointing somewhere else entirely. `PassiveJointChainTests` pins it on a synthetic
  description, because the property that matters is that the _joint chain_ rebuilds the direction the solver
  extracted: rebuilding with the convention it was extracted with proves nothing and passed throughout.
- **A frame with no `head_joints` is the ordinary case, and the linkage may not fall back to zero.** The daemon
  defaults `with_head_joints` to false; `StateStreamOptions.visualization` asks for them, but a stream that did not
  — or a frame the daemon dropped them from — used to leave all six cranks at their zero configuration while
  `applyHeadPose` went on placing the head from `head_pose`, which is 27 mm above that configuration before any
  rotation is added. The head is then drawn hanging off a robot standing somewhere else. `RobotJointState.resolve`
  now takes a `StewartIK` and recovers the angles from the pose, which is exactly what the daemon would have sent;
  `RobotSceneModel` builds it from the same `StewartGeometry` the passive solver gets, so the rods, the cranks and
  the head cannot disagree about what they were derived from.
