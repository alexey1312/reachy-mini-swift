#!/bin/bash
# Sourced by release-ios.sh, release-macos.sh and asc.sh: loads and checks the
# release credentials. Like the device signing team, they live outside every worktree in
# ~/.config/reachy-mini/, so nothing is copied when a workspace is created and
# nothing account-specific ever lands in the repository.
#
# Exported variables win over the file, so a CI machine can inject its own.

RELEASE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/reachy-mini/release.env"
DEVICE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/reachy-mini/device.env"

# The signing team is the same one device builds already use; read it first so
# release.env only has to add the App Store Connect key.
if [ -z "${REACHY_DEVELOPMENT_TEAM:-}" ] && [ -f "$DEVICE_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$DEVICE_CONFIG"
fi
if [ -f "$RELEASE_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$RELEASE_CONFIG"
fi

# Demanded by the two scripts that archive; asc.sh sources this file for the API key
# alone and never signs anything, so the check cannot run on load.
require_development_team() {
  [ -n "${REACHY_DEVELOPMENT_TEAM:-}" ] && return 0
  cat >&2 <<EOF
No signing team. Write it once, the way device builds already expect:

  mkdir -p "$(dirname "$DEVICE_CONFIG")"
  echo 'REACHY_DEVELOPMENT_TEAM=XXXXXXXXXX' > "$DEVICE_CONFIG"

The id is in Xcode → Settings → Accounts, next to the team that owns com.alexey1312.*.
EOF
  exit 1
}

# The API key is optional, and deliberately unused for signing. xcodebuild takes
# `-authenticationKey*` as "do everything through cloud signing", and a key below
# the Admin role cannot manage profiles — the export then fails with "Cloud
# signing permission error" and "No profiles were found" even though the
# certificate is right there in the keychain. A key's role cannot be changed
# after it is created. Without the flags xcodebuild uses the Xcode account, which
# has the rights, so signing is left to it and the key is kept for the two things
# that only need to read and submit: notarization, and CI.
REACHY_HAS_ASC=""
if [ -n "${REACHY_ASC_KEY_ID:-}" ] && [ -n "${REACHY_ASC_ISSUER_ID:-}" ] && [ -n "${REACHY_ASC_KEY_PATH:-}" ]; then
  if [ ! -f "$REACHY_ASC_KEY_PATH" ]; then
    echo "REACHY_ASC_KEY_PATH points at $REACHY_ASC_KEY_PATH, which does not exist." >&2
    exit 1
  fi
  REACHY_HAS_ASC=1
fi

# Called by the macOS script, where notarytool has no other way in, and by asc.sh,
# which is nothing but the key.
require_asc_key() {
  [ -n "$REACHY_HAS_ASC" ] && return 0
  cat >&2 <<EOF
This needs an App Store Connect API key (App Store Connect → Users and Access →
Integrations → App Store Connect API). Write the three values once:

  cat >> "$RELEASE_CONFIG" <<'CONF'
REACHY_ASC_KEY_ID=XXXXXXXXXX
REACHY_ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
REACHY_ASC_KEY_PATH=$HOME/.config/reachy-mini/AuthKey_XXXXXXXXXX.p8
CONF

The one-time App Store Connect setup is documented in docs/release.md.
EOF
  exit 1
}
