# ReachySimulator — target notes

A robot that is not there. The daemon's own `--mockup-sim` is the parity target, and this target is
the half of it a client can carry: the robot's shape, and later the arithmetic that moves it.

## The assets are vendored, and where they came from matters

`Resources/robot.urdf` and the 41 `*.stl` beside it are copied **unmodified** from
`pollen-robotics/reachy_mini`, `src/reachy_mini/descriptions/reachy_mini/urdf`, which is Apache-2.0.
`Resources/reachy_mini-LICENSE.txt` is that licence, and it ships inside the bundle rather than
sitting beside it in the repository, because clause 4(a) is about what reaches a _recipient_ of the
work — an App Store build is a distribution.

This is not a breach of project rule 1. That rule forbids porting upstream's **code**; the robot's
geometry is the one thing a client cannot derive, measure or re-invent, and copying it is the only
way to draw the robot at all. Nothing executable came across.

Two facts that decided the contents, both read off the code rather than assumed:

- **Only `<visual>` meshes are here.** `URDFParser` skips the entire `<collision>` subtree
  (`URDFParser.swift:97`) and `RobotGeometryProvider` downloads `document.visualMeshFilenames`. As it
  happens the two sets are identical in this description — 41 files either way — so nothing was saved
  by filtering, but the rule is what to apply the next time upstream's meshes change.
- **`robot.urdf`, not `robot_no_collision.urdf`.** Which one a real daemon answers with is up to its
  backend (`kinematics.py` returns `backend.get_urdf()`), and it cannot change what is drawn, for the
  reason above. The unabridged file is the one that matches its source byte for byte.

Upstream stores the meshes in **Git LFS**, so `raw.githubusercontent.com` serves 131-byte pointers
for them. The bytes come from `media.githubusercontent.com/media/…`. A pointer that slipped through
would decode as a 131-byte STL and fail; `BundledRobotGeometryTests` parses every mesh for that
reason, among others.

They are **not** in this repository's LFS. Its `.gitattributes` tracks the snapshot references, which
are re-recorded constantly and would otherwise bloat the history. These are written once and never
touched, which is the case LFS buys nothing for — and a checkout that skipped LFS would hand the
scene 131-byte pointer files with no error anywhere.

## The size, and the lever if it ever matters

9.30 MiB across 41 meshes, plus 124 KB of description. Measured, not estimated: the sizes come from
the `size` field of upstream's LFS pointers.

2.91 MiB of that — 15 files — is fasteners and dummies: `phs_1_7x20_5_dc10*` screws, `bts2_m2_6x8`,
the `dc15_a01_*` servo-case dummies, bearings and rod balls. None of it is visible at the scale the
viewport draws, so that is the 31% to drop if `mise run inspect:bundle` ever says the app cannot
afford this. Dropping them means the description names meshes the bundle lacks, so
`BundledRobotGeometry.Failure.missingAsset` would have to become a rendering decision rather than a
packaging error — do not start there.
