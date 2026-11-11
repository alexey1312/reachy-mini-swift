#!/bin/bash
# =============================================================================
# The client of the app's introspection tree
# =============================================================================
# Usage: mise run introspect -- ls
#        mise run introspect -- do setAddress '{"text":"127.0.0.1"}'
#
# The app must be a Debug build started with `--reachy-introspect <port>`.
# The first run compiles the tool; a later run starts in under a second.
set -euo pipefail
cd "$(dirname "$0")/.."
. Scripts/swiftpm-env.sh
# The build log goes to stderr, so stdout holds the one line of JSON and nothing else.
swift build --product ReachyIntrospect >&2
exec "$(swift build --show-bin-path)/ReachyIntrospect" "$@"
