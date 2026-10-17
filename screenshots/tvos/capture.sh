#!/bin/bash
# The Apple TV store screenshots, from a tvOS simulator connected to `mise run sim-daemon`.
#
#   mise run sim-daemon          # in another terminal; wait until :8000 answers
#   mise run screenshots:tv      # writes screenshots/tvos/en-US/*.png
#   mise run asc -- screenshots upload --app 6799644194 --version-id <tvOS version id> \
#     --locale en-US --path screenshots/tvos/en-US --device-type APP_APPLE_TV
#
# A session cannot press the Siri Remote, so each screen is reached by a launch argument
# that only a Debug build reads (`Apps/ReachyTV/Sources/TVCaptureStage.swift`), not by
# walking to it. Everything on screen is the real app talking to the real daemon.
#
# The camera shows no picture against a `sim-daemon` on a Mac whose default input is a
# virtual device (the root CLAUDE.md has the measurement), so the drive screen says what
# the camera is waiting for. That is what the app shows there, and it is not replaced.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
OUT="${REACHY_SHOT_DIR:-screenshots/tvos/en-US}"
APP=Apps/DerivedData/Build/Products/Debug-appletvsimulator/ReachyTV.app
BUNDLE=com.alexey1312.ReachyMini
# How long a screen gets before it is photographed: the launch, a handshake over loopback,
# and on the drive screen the camera's first answer. Nothing in the app can be read from
# here to say a screen is ready, so this is a generous wait rather than a condition.
SETTLE="${REACHY_SHOT_SETTLE:-15}"

if ! curl -fsS -m 3 http://127.0.0.1:8000/api/daemon/status >/dev/null; then
  echo "No daemon on 127.0.0.1:8000. Start 'mise run sim-daemon' and wait for it to answer." >&2
  exit 1
fi

if [ -z "${REACHY_SHOT_NO_BUILD:-}" ]; then
  ./bin/mise run build:app:tv
fi

# A simulator of its own, on the newest tvOS runtime installed, so a stored robot address
# or a language somebody left on theirs never reaches the store. Deleted on the way out.
RUNTIME="$(xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
tv = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "tvOS" and r["isAvailable"]]
if not tv:
    sys.exit("No tvOS simulator runtime is installed.")
print(sorted(tv, key=lambda r: [int(p) for p in r["version"].split(".")])[-1]["identifier"])')"
UDID="$(xcrun simctl create "Hey Reachy screenshots" \
  com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K "$RUNTIME")"
cleanup() {
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
# English, as every store capture here is: Scripts/maestro-sim.sh pins the iOS simulator
# the same way.
xcrun simctl spawn "$UDID" defaults write -g AppleLanguages -array en
xcrun simctl spawn "$UDID" defaults write -g AppleLocale -string en_US
xcrun simctl install "$UDID" "$APP"

mkdir -p "$OUT"
RAW="$(mktemp -d)"
# One screen: launch on `stage` (empty for the app as it ships), wait, and keep the
# simulator's 3840x2160 frame at 1920x1080, a size the APP_APPLE_TV slot accepts, with no
# alpha channel (`opaque.swift` says why).
shoot() {
  local name="$1" stage="$2"
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  if [ -n "$stage" ]; then
    xcrun simctl launch "$UDID" "$BUNDLE" --reachy-tv-stage "$stage" >/dev/null
  else
    xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  fi
  sleep "$SETTLE"
  xcrun simctl io "$UDID" screenshot --type=png "$RAW/$name.png" >/dev/null 2>&1
  swift screenshots/tvos/opaque.swift "$RAW/$name.png" "$OUT/$name.png" 1920 1080
  echo "$OUT/$name.png $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" | awk '/pixel/ {print $2}' | paste -sd x -)"
}

# The connect screen first, while the app has never connected: the address field is still
# empty, and the robot is in the list rather than already connected to.
shoot 01-connect connect
shoot 02-robot ""
shoot 03-drive drive
