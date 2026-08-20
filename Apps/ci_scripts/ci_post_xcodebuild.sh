#!/bin/bash
# Assert an Xcode Cloud archive carries its App Intents metadata, before the
# build is handed to TestFlight.
#
# Every other path that produces an artifact already runs this check —
# release-ios.sh and release-macos.sh against the archive, build:app:release and
# build:app:ios:release against the built app. Xcode Cloud was the exception, and
# it is the one that ships to a *public* TestFlight: extraction failing is a
# warning and never a build error, so an archive stays green over an app that
# installs with no actions in the Shortcuts app at all. TestFlight 0.1.1 shipped
# exactly that way.
set -euo pipefail

# The post-xcodebuild script runs whatever the action did and whatever it
# returned, so both are checked: a failed build has no archive to read, and
# reporting a missing one would bury the error that actually stopped it.
[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:-0}" = "0" ] || exit 0

cd "$CI_PRIMARY_REPOSITORY_PATH"

if [ -z "${CI_ARCHIVE_PATH:-}" ]; then
  echo "The archive action left no CI_ARCHIVE_PATH — nothing to check." >&2
  exit 1
fi

Scripts/check-appintents-metadata.sh "$CI_ARCHIVE_PATH"
