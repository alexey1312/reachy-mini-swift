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

# `destination: upload` in the shared plist is what hands the artifact to App Store
# Connect, and it is the only key a dry run has to change. Generating the copy beats
# keeping a second file, which would drift the moment either channel gains an option.
# Takes the value of the caller's own upload flag and echoes the plist to use.
appstore_export_options() {
  if [ "${1:-true}" = true ]; then
    echo Scripts/exportOptions/appstore.plist
    return 0
  fi
  local options
  options="$(mktemp -t reachy-export-options).plist"
  plutil -convert xml1 -o "$options" Scripts/exportOptions/appstore.plist
  plutil -replace destination -string export "$options"
  echo "$options"
}

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

# The build number is the commit count: monotonic, reproducible, and never stored
# in the repository — so releasing needs no version-bump commit for anything but
# MARKETING_VERSION. It has one failure mode and it cost a rejected upload.
# `git rev-list --count HEAD` counts *reachable* commits, so a shallow clone
# answers with its own depth instead: App Store Connect had taken build 143 and
# refused the next one with ITMS-90061 over a CFBundleVersion of 11, archived from
# a truncated history. Nothing in the archive looks wrong — the number is only
# wrong against a number that lives on the server, so neither the build nor the
# export can catch it, and by the time the validator does the whole archive has
# been compiled and signed.
#
# So the history is repaired before it is counted, and the answer is floored.
# Reachable-commit counts only ever go up; the floor is here to catch the
# truncation the unshallow could not fix, not to invent a number.
#
# The floor is the highest build App Store Connect has accepted. It needs raising
# only if a build is ever uploaded with a number the commit count does not reach —
# `mise run asc -- builds list --app 6799644194` is what says otherwise.
BUILD_NUMBER_FLOOR=143

# Echoes the CFBundleVersion to archive with. REACHY_BUILD_NUMBER overrides the
# whole computation, for the recovery case where neither history nor floor is what
# you want. Diagnostics go to stderr — callers capture stdout.
build_number() {
  if [ -n "${REACHY_BUILD_NUMBER:-}" ]; then
    echo "$REACHY_BUILD_NUMBER"
    return 0
  fi

  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "Shallow clone — deepening it, or the build number would be its depth." >&2
    git fetch --unshallow --quiet || true
  fi
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    cat >&2 <<CONF
This clone is shallow and could not be deepened, so the commit count is its depth
and not a build number: archiving from it uploads a CFBundleVersion below the one
App Store Connect already has, and the upload is rejected with ITMS-90061.

  git fetch --unshallow

Release from a full clone, or pass the number yourself:

  REACHY_BUILD_NUMBER=<n> mise run release:ios
CONF
    exit 1
  fi

  local count
  count="$(git rev-list --count HEAD)"
  if [ "$count" -le "$BUILD_NUMBER_FLOOR" ]; then
    cat >&2 <<CONF
The commit count is $count, and build $BUILD_NUMBER_FLOOR has already been
uploaded — App Store Connect would reject this archive with ITMS-90061.

The history is short of what has shipped, which a full clone of main is not: check
that HEAD is on the release branch and that the clone carries every commit.

  git rev-list --count HEAD
  mise run asc -- builds list --app 6799644194

If the number really is meant to jump, pass it and raise BUILD_NUMBER_FLOOR:

  REACHY_BUILD_NUMBER=<n> mise run release:ios
CONF
    exit 1
  fi

  echo "$count"
}
