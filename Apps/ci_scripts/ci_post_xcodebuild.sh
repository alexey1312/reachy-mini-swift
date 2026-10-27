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

# What ships on macOS is arm64 alone, and in Xcode Cloud only Apps/Project.swift's
# Release setting says so: the cloud passes no `ARCHS=arm64` on a command line the
# way release-macos.sh does. Drop that setting and the archive goes back to a
# universal binary with the build still green, so the artifact is what is read.
if [ "$(printf '%s' "${CI_PRODUCT_PLATFORM:-}" | tr '[:upper:]' '[:lower:]')" = macos ]; then
  BINARY="$CI_ARCHIVE_PATH/Products/Applications/ReachyMini.app/Contents/MacOS/ReachyMini"
  SLICES=$(lipo -archs "$BINARY")
  if [ "$SLICES" != "arm64" ]; then
    echo "Expected an arm64-only macOS binary, got '$SLICES'." >&2
    exit 1
  fi
fi
