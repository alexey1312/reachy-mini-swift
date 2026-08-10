#!/bin/bash
# Run the App Store Connect CLI against the release credentials.
#
#   mise run asc -- apps list
#   mise run asc -- builds list --app 6799644194
#
# The three values asc wants are the three release.env already carries, under
# other names — so nothing is stored twice and no keychain profile is created.
# asc resolves a stored profile first and falls back to the environment, which
# means a hand-made `asc auth login` keeps winning over this wrapper.
set -euo pipefail

# shellcheck source=Scripts/release-env.sh
. "$(dirname "$0")/release-env.sh"
require_asc_key

export ASC_KEY_ID="$REACHY_ASC_KEY_ID"
export ASC_ISSUER_ID="$REACHY_ASC_ISSUER_ID"
export ASC_PRIVATE_KEY_PATH="$REACHY_ASC_KEY_PATH"
# Piped output is JSON either way; this only decides what a terminal shows.
export ASC_DEFAULT_OUTPUT="${ASC_DEFAULT_OUTPUT:-table}"

exec asc "$@"
