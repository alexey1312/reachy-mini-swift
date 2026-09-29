#!/bin/bash
# Slim the simulator this project runs on — apply, check or undo one of the two profiles
# committed in Scripts/simslim/.
#
# A slim simulator is state that lives in the simulator's own launchd database, not in this
# repository: it survives reboots, and it resets to stock — silently, with nothing failing —
# whenever the device is erased, deleted and recreated, or replaced by one from a new
# runtime. That is the whole reason this is a script rather than a note: `apply` is a cheap
# no-op when the state already matches — 3.3 s, against 93 s to slim a stock device cold —
# so it is safe to run from bootstrap.sh and from CI on every job rather than once by hand.
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE_DIR=Scripts/simslim

# The simulator the snapshot tasks, the smoke flows and Scripts/maestro-sim.sh all pin —
# one variable across all four, so overriding REACHY_SNAPSHOT_SIM for a run slims the
# machine that run will actually use. It has to stay one: a second name with the same
# default reads as working right up until somebody overrides it, and then this slims one
# simulator while the flows run on another.
device_name="${REACHY_SNAPSHOT_SIM:-iPhone 17 Pro}"
device_os="${REACHY_SNAPSHOT_OS:-27.0}"
device_udid=""
# One default for every machine, deliberately — including a runner. The only CI that slims a
# simulator here is a self-hosted one, which is somebody's Mac, and flipping the same device
# between profiles between jobs would take the widgets and App Intents they hand-test out
# from under them. ci.json is for a simulator nothing else uses: REACHY_SIMSLIM_PROFILE=ci.
profile="${REACHY_SIMSLIM_PROFILE:-dev}"
action=apply

while [ $# -gt 0 ]; do
  case "$1" in
  apply | check | off) action="$1" ;;
  --profile)
    profile="${2:-}"
    shift
    ;;
  --device)
    device_name="${2:-}"
    shift
    ;;
  --os)
    device_os="${2:-}"
    shift
    ;;
  --udid)
    device_udid="${2:-}"
    shift
    ;;
  *)
    echo "usage: simslim.sh [apply|check|off] [--profile dev|ci|<path>] [--device <name>] [--os <version>] [--udid <udid>]" >&2
    exit 2
    ;;
  esac
  shift
done

case "$profile" in
dev | ci) profile_path="$PROFILE_DIR/$profile.json" ;;
*) profile_path="$profile" ;;
esac
if [ ! -f "$profile_path" ]; then
  echo "simslim.sh: no such profile: $profile_path" >&2
  exit 2
fi

# The pinned copy first: a brew-installed simslim on PATH is whatever version that machine
# happens to carry, and a profile file is validated against the version reading it.
SIMSLIM="$(./bin/mise where 'github:MobAI-App/simslim' 2>/dev/null || true)/simslim"
if [ ! -x "$SIMSLIM" ]; then
  SIMSLIM="$(command -v simslim || true)"
fi
if [ -z "$SIMSLIM" ] || [ ! -x "$SIMSLIM" ]; then
  cat >&2 <<EOF
simslim is not installed. It is pinned in mise.toml — run ./bootstrap.sh, or:

  ./bin/mise install
EOF
  exit 1
fi

# A laptop gets --preserve-boot-state, so a setup run leaves no simulator running behind it.
# A runner does not: the smoke task boots the same device seconds later, and shutting it
# down here only to boot it again there is a boot spent for nothing.
preserve_boot="--preserve-boot-state"
if [ -n "${CI:-}" ]; then
  preserve_boot=""
  # A shared runner is slower and less predictable than a laptop, and blowing the default
  # 10-minute deadline mid-reconfigure is what `context deadline exceeded` reads as.
  export SIMSLIM_BOOT_TIMEOUT="${SIMSLIM_BOOT_TIMEOUT:-15m}"
  export SIMSLIM_SPAWN_TIMEOUT="${SIMSLIM_SPAWN_TIMEOUT:-5m}"
fi

if [ -z "$device_udid" ]; then
  device_udid="$("$SIMSLIM" list --json | python3 -c '
import json, sys

name, os_version = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)
for device in devices:
    if device["name"] == name and device["osVersion"] == os_version:
        print(device["udid"])
        break
else:
    have = ", ".join(sorted({d["name"] + " iOS " + d["osVersion"] for d in devices})) or "none"
    sys.exit("simslim.sh: no simulator named " + name + " on iOS " + os_version + ". Have: " + have)
' "$device_name" "$device_os")"
fi

echo "==> $action $(basename "$profile_path" .json): $device_name (iOS $device_os) $device_udid"

case "$action" in
apply)
  # shellcheck disable=SC2086 # deliberately unquoted: empty means "pass no flag"
  "$SIMSLIM" on "$device_udid" --profile "$profile_path" $preserve_boot
  ;;
off)
  # shellcheck disable=SC2086
  "$SIMSLIM" off "$device_udid" $preserve_boot
  ;;
check)
  # verify answers "is this simulator in the state the profile describes"; doctor answers
  # "do the features this project still hand-tests on it work". Both need it booted.
  "$SIMSLIM" boot "$device_udid" >/dev/null
  "$SIMSLIM" verify "$device_udid" --profile "$profile_path"
  if [ "$(basename "$profile_path" .json)" = "dev" ]; then
    "$SIMSLIM" doctor "$device_udid" --requires widgets,siri
  fi
  "$SIMSLIM" measure "$device_udid"
  ;;
esac
