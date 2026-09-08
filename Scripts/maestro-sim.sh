#!/bin/bash
# Prepares a simulator for a Maestro run and prints its UDID on stdout.
#
# Everything else this script says goes to stderr, so a caller can capture the
# UDID with `$(…)` while still watching the build scroll past.
#
# Usage: Scripts/maestro-sim.sh [--no-build]
#   REACHY_SMOKE_SIM   simulator name (default: iPhone 17 Pro)
#   REACHY_XCB_EXTRA   extra xcodebuild settings, as every other task honours
set -euo pipefail
exec 3>&1 1>&2

# Phase timings. The whole task reads as one opaque number on CI otherwise — a
# 14-minute step whose build, simulator boot and driver startup are indivisible.
_t_start=$(date +%s)
_t_last=$_t_start
phase() {
    local now
    now=$(date +%s)
    printf 'timing  %-24s %5ds\n' "$1" "$((now - _t_last))"
    _t_last=$now
}

BUILD=1
[ "${1:-}" = "--no-build" ] && BUILD=0

SIM="${REACHY_SMOKE_SIM:-iPhone 17 Pro}"
APP="Apps/DerivedData/Build/Products/Debug-iphonesimulator/ReachyMini.app"

# `maestro --device` takes a UDID, and a simulator booted by name is the one thing
# simctl will not hand back by name. python3 is the pinned 3.12 from [tools].
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
groups = json.load(sys.stdin)["devices"]
matches = [d for g in groups.values() for d in g if d["name"] == sys.argv[1]]
if not matches:
    sys.exit(f"no available simulator named {sys.argv[1]!r}")
print(matches[0]["udid"])
' "$SIM")"

phase "resolve udid"

# Started and deliberately NOT waited on: the build below takes minutes and the
# boot takes about ninety seconds, so waiting here spends that ninety seconds
# rather than hiding it under work that has to happen anyway. Measured on CI —
# `bootstatus` cost 95 s and the language pin another 87 s, because `simctl spawn`
# against a still-booting simulator is slow in a way it never is locally. Three
# minutes, on a step whose only other content is a six-minute compile.
xcrun simctl boot "$UDID" 2>/dev/null || true
phase "boot (async)"

if [ "$BUILD" = "1" ]; then
    # A concrete destination rather than `generic/platform=iOS Simulator`, which
    # would build arm64 and x86_64 both and double a compile that already dominates
    # this task.
    xcodebuild build -workspace Apps/ReachyMiniApps.xcworkspace -scheme ReachyMini \
        -destination "platform=iOS Simulator,name=${SIM}" \
        -derivedDataPath Apps/DerivedData \
        CODE_SIGNING_ALLOWED=NO \
        -skipPackagePluginValidation -skipMacroValidation \
        ${REACHY_XCB_EXTRA:-} \
        2>&1 | xcsift
    phase "xcodebuild build"
fi

# Now collect the boot the build was running alongside. On CI this is where the
# 95 s went; after a six-minute compile it should be near zero.
xcrun simctl bootstatus "$UDID" -b
phase "await boot"

# This is what replaces `-testLanguage en -testRegion US` on the xcodebuild test
# line the XCUITest smoke used. Maestro has no equivalent flag for a device it did
# not start itself, and the failure is not subtle once you see it and invisible
# until you do: every selector in Apps/Maestro is visible English text, so a
# simulator left in another language misses all of them and reports the assertion
# as false rather than as untranslated. Measured on a simulator sitting at
# `ru-KZ`, which is where this was found.
xcrun simctl spawn "$UDID" defaults write -g AppleLanguages -array en
xcrun simctl spawn "$UDID" defaults write -g AppleLocale -string en_US
phase "pin language"

[ -d "$APP" ] || {
    echo "$APP is missing — run without --no-build first." >&2
    exit 1
}
xcrun simctl install "$UDID" "$APP"
phase "simctl install"
printf 'timing  %-24s %5ds\n' "prep total" "$(($(date +%s) - _t_start))"

echo "$UDID" >&3
