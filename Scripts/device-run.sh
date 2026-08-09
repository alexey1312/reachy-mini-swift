#!/bin/bash
# Build ReachyMini for a physical iPhone, install it and launch it.
#
# The signing team is the only thing that cannot be discovered: several teams exist on a
# typical machine and only one owns com.alexey1312.*. It lives outside every worktree, in
# ~/.config/reachy-mini/device.env, so nothing has to be copied when a workspace is created.
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/reachy-mini/device.env"
DERIVED=Apps/DerivedData
PRODUCT="$DERIVED/Build/Products/Debug-iphoneos/ReachyMini.app"

launch=true
install=true
device_udid="${REACHY_DEVICE_UDID:-}"

while [ $# -gt 0 ]; do
  case "$1" in
  --no-launch) launch=false ;;
  --build-only)
    launch=false
    install=false
    ;;
  --device)
    device_udid="${2:-}"
    shift
    ;;
  *)
    echo "usage: device-run.sh [--no-launch] [--build-only] [--device <udid>]" >&2
    exit 2
    ;;
  esac
  shift
done

# An exported variable wins, so a second machine overrides without editing the file.
if [ -z "${REACHY_DEVELOPMENT_TEAM:-}" ] && [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
fi
if [ -z "${REACHY_DEVELOPMENT_TEAM:-}" ]; then
  cat >&2 <<EOF
No signing team. Device builds cannot be signed without one, and guessing between the
teams in your keychain would pick the wrong one. Write it once:

  mkdir -p "$(dirname "$CONFIG")"
  echo 'REACHY_DEVELOPMENT_TEAM=XXXXXXXXXX' > "$CONFIG"

The id is in Xcode → Settings → Accounts, next to the team that owns com.alexey1312.*.
EOF
  exit 1
fi

# devicectl reports both identifiers for one phone: `identifier` is the CoreDevice UUID it
# takes itself, `hardwareProperties.udid` is what xcodebuild -destination wants. They are
# not interchangeable — passing the CoreDevice UUID to xcodebuild times out waiting for
# destinations. Read them together so they cannot drift apart.
devices_json="$(mktemp -t reachy-devices)"
trap 'rm -f "$devices_json"' EXIT
xcrun devicectl list devices --json-output "$devices_json" >/dev/null 2>&1 || true

selection="$(REACHY_WANTED_UDID="$device_udid" python3 - "$devices_json" <<'PY'
import json, os, sys

wanted = os.environ.get("REACHY_WANTED_UDID") or None
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except (OSError, ValueError, KeyError):
    devices = []

candidates = []
for d in devices:
    hardware, connection = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hardware.get("platform") != "iOS":
        continue
    if connection.get("pairingState") != "paired" or connection.get("tunnelState") == "unavailable":
        continue
    candidates.append((d["deviceProperties"].get("name", "?"), hardware.get("udid"), d["identifier"]))

if wanted:
    candidates = [c for c in candidates if c[1] == wanted]

if len(candidates) == 1:
    print("\t".join(candidates[0][1:]))
else:
    if candidates:
        print("Paired iPhones:", file=sys.stderr)
        for name, udid, _ in candidates:
            print(f"  {name}  {udid}", file=sys.stderr)
    sys.exit(1)
PY
)" || {
  if [ -n "$device_udid" ]; then
    echo "No paired iPhone with udid $device_udid." >&2
  else
    echo "Expected exactly one paired iPhone (listed above, if any). Connect one, or pick with --device <udid>." >&2
  fi
  exit 1
}

udid="${selection%%$'\t'*}"
core_id="${selection##*$'\t'}"

set -o pipefail
xcodebuild -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyMini \
  -destination "id=$udid" -configuration Debug \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$REACHY_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  -skipPackagePluginValidation -skipMacroValidation \
  build 2>&1 | xcsift

[ "$install" = true ] || exit 0

# devicectl prints "Failed to load provisioning paramter list … No provider was found." on
# every invocation and succeeds anyway, so its stderr says nothing about the outcome.
xcrun devicectl device install app --device "$core_id" "$PRODUCT"

[ "$launch" = true ] || exit 0

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PRODUCT/Info.plist")"

# A locked phone refuses the launch and nothing else: the new build is already installed,
# so the whole run is one home-screen tap from done. Say that instead of the CoreDevice
# wall of text, and still exit non-zero — the app is not running.
launch_log="$(mktemp -t reachy-launch)"
trap 'rm -f "$devices_json" "$launch_log"' EXIT
if ! xcrun devicectl device process launch --device "$core_id" "$bundle_id" 2>&1 | tee "$launch_log"; then
  if grep -q "could not be, unlocked" "$launch_log"; then
    echo "" >&2
    echo "$bundle_id is installed; the phone was locked, so it could not be started." >&2
    echo "Unlock it and rerun, or just tap the icon." >&2
  fi
  exit 3
fi
