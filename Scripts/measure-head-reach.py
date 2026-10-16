#!/usr/bin/env python3
"""Measure the head poses the daemon can drive without a motor past its limit.

Runs the daemon's own default IK (`AnalyticalKinematics`) over a grid of head poses
and checks the six Stewart joints against the URDF limits. The daemon checks no
collision by default and its analytical IK solves poses past those limits, so this
is the measurement behind `HeadphoneMotionMapping`'s reach (Sources/ReachyUI/AGENTS.md).

Run it with the simulator's venv, which holds the daemon's source:

    .venv-sim/bin/python Scripts/measure-head-reach.py

Angles are degrees in the daemon's convention: positive pitch looks down, and the
pose is `create_head_pose(roll, pitch, yaw)`, the same `from_euler("xyz", ...)`
that `ws/set_target` applies to a target.
"""

import logging
import math
import os
import re
import warnings

import numpy as np

import reachy_mini
from reachy_mini.kinematics.analytical_kinematics import AnalyticalKinematics
from reachy_mini.utils import create_head_pose

logging.disable(logging.CRITICAL)
warnings.filterwarnings("ignore")

URDF = os.path.join(os.path.dirname(reachy_mini.__file__), "descriptions/reachy_mini/urdf/robot.urdf")

# The region HeadphoneMotionMapping uses: yaw, pitch up, pitch down, roll, tilt cone.
REGION = (40.0, 30.0, 35.0, 30.0, 35.0)
STEP = 2.5


def stewart_limits():
    text = open(URDF).read()
    limits = []
    for n in range(1, 7):
        block = re.search(rf'<joint name="stewart_{n}".*?<limit [^>]*>', text, re.S).group(0)
        lower = float(re.search(r'lower="([-\d.]+)"', block).group(1))
        upper = float(re.search(r'upper="([-\d.]+)"', block).group(1))
        limits.append((lower, upper))
    return limits


KIN = AnalyticalKinematics()
LIMITS = stewart_limits()


def inside(yaw, pitch, roll):
    """True when the IK solves the pose and every Stewart joint is inside its limit."""
    try:
        joints = KIN.ik(create_head_pose(roll=roll, pitch=pitch, yaw=yaw, degrees=True), body_yaw=0.0)
    except Exception:
        return False
    if joints is None or np.any(np.isnan(joints)):
        return False
    return all(low <= angle <= high for angle, (low, high) in zip(joints[1:], LIMITS))


def frange(low, high, step):
    value = low
    while value <= high + 1e-9:
        yield value
        value += step


def main():
    print("one axis alone, largest angle inside the motor limits:")
    for name, index in (("yaw", 0), ("pitch", 1), ("roll", 2)):
        for sign, label in ((1, "+"), (-1, "-")):
            best = 0
            for angle in range(0, 91):
                pose = [0, 0, 0]
                pose[index] = sign * angle
                if not inside(*pose):
                    break
                best = angle
            print(f"  {name} {label}{best}")

    yaw_reach, pitch_up, pitch_down, roll_reach, cone = REGION
    total, outside = 0, []
    for yaw in frange(-yaw_reach, yaw_reach, STEP):
        for pitch in frange(-pitch_up, pitch_down, STEP):
            for roll in frange(-roll_reach, roll_reach, STEP):
                if math.hypot(pitch, roll) > cone + 1e-9:
                    continue
                total += 1
                if not inside(yaw, pitch, roll):
                    outside.append((yaw, pitch, roll))
    print(f"\nregion yaw ±{yaw_reach}, pitch up {pitch_up} down {pitch_down}, roll ±{roll_reach}, cone {cone}:")
    print(f"  {total} poses on a {STEP}° grid, {len(outside)} outside the limits {outside[:5]}")


if __name__ == "__main__":
    main()
