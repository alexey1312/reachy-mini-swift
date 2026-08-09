#!/bin/bash
# Sourced by release-ios.sh and release-macos.sh: loads and checks the release
# credentials. Like the device signing team, they live outside every worktree in
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

release_env_missing=""
for var in REACHY_DEVELOPMENT_TEAM REACHY_ASC_KEY_ID REACHY_ASC_ISSUER_ID REACHY_ASC_KEY_PATH; do
  [ -n "${!var:-}" ] || release_env_missing="$release_env_missing $var"
done

if [ -n "$release_env_missing" ]; then
  cat >&2 <<EOF
Missing release credentials:$release_env_missing

Releases are signed and uploaded with an App Store Connect API key
(App Store Connect → Users and Access → Integrations → App Store Connect API,
role App Manager). Write the four values once:

  mkdir -p "$(dirname "$RELEASE_CONFIG")"
  cat > "$RELEASE_CONFIG" <<'CONF'
REACHY_DEVELOPMENT_TEAM=XXXXXXXXXX
REACHY_ASC_KEY_ID=XXXXXXXXXX
REACHY_ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
REACHY_ASC_KEY_PATH=$HOME/.config/reachy-mini/AuthKey_XXXXXXXXXX.p8
CONF

The one-time App Store Connect setup is documented in docs/release.md.
EOF
  exit 1
fi

if [ ! -f "$REACHY_ASC_KEY_PATH" ]; then
  echo "REACHY_ASC_KEY_PATH points at $REACHY_ASC_KEY_PATH, which does not exist." >&2
  exit 1
fi
