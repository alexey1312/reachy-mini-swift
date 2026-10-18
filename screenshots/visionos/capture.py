"""Relaunch Hey Reachy on the Apple Vision Pro simulator at one screen and capture it.

    python3 screenshots/visionos/capture.py <screen> <name> [seconds]

<screen> is a value for `REACHY_SHOT`, which only `navigate.py`'s temporary edits
read (robot, live, controller, moves, apps, discover, settings), or "smoke" for a
launch with `--reachy-smoke`, which shows the connect screen with no sweep and no
sheet over it. The capture is the simulator's own frame, 3840 x 2160, which is the
one size App Store Connect takes for APP_APPLE_VISION_PRO. It goes to
screenshots/raw/visionos-<name>.png (gitignored); `flatten.swift` then drops the
alpha channel. [seconds] is how long to wait after the launch, 25 by default:
long enough to connect to sim-daemon and draw.
"""

import json
import os
import subprocess
import sys
import time

DEVICE_NAME = os.environ.get("REACHY_VISION_SIM", "Apple Vision Pro")
BUNDLE = "com.alexey1312.ReachyMini"
OUT = os.path.join("screenshots", "raw")


def booted_vision_pro():
    listing = json.loads(subprocess.run(
        ["xcrun", "simctl", "list", "devices", "booted", "-j"],
        check=True, capture_output=True, text=True,
    ).stdout)
    for runtime, devices in listing["devices"].items():
        if "xrOS" not in runtime:
            continue
        for device in devices:
            if device["name"] == DEVICE_NAME:
                return device["udid"]
    sys.exit(f"capture: no booted visionOS simulator named {DEVICE_NAME!r}")


screen, name = sys.argv[1], sys.argv[2]
wait = float(sys.argv[3]) if len(sys.argv) > 3 else 25
udid = booted_vision_pro()

subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], capture_output=True)
env = dict(os.environ)
launch = ["xcrun", "simctl", "launch", udid, BUNDLE]
if screen == "smoke":
    launch.append("--reachy-smoke")
else:
    # `SIMCTL_CHILD_` is stripped and the rest reaches the app's environment.
    env["SIMCTL_CHILD_REACHY_SHOT"] = screen
subprocess.run(launch, env=env, check=True, capture_output=True)
time.sleep(wait)

os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, f"visionos-{name}.png")
subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", path], check=True, capture_output=True)
print(path)
