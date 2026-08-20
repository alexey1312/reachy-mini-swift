#!/bin/bash
# Xcode Cloud clones a repository with no Xcode project in it — ours is
# generated. This runs right after the clone: install the pinned tools through
# the committed mise bootstrap, run the Prefire playbook + tuist generate
# (that is what `mise run project` is), and the workspace exists by the time
# Xcode Cloud goes looking for it.
#
# The workflow itself lives in App Store Connect, not here — this script and
# ci_post_xcodebuild.sh are the whole of what is reviewable. It archives **iOS
# only**: macOS TestFlight comes from `mise run release:macos`, which archives
# once and exports that archive twice (notarized Developer ID zip *and* Mac App
# Store .pkg). Xcode Cloud can only ever make the second of those — the notary
# needs an App Store Connect key that deliberately never enters CI — so a macOS
# action here duplicates half a local release for 28 minutes of compute. The
# guard below says so out loud if one is ever added back.
#
# Setup quirks, once:
# - Create the workflow from a local Xcode with the generated workspace open
#   (Report navigator → Cloud tab), not from the App Store Connect wizard —
#   the wizard wants to see a project in the repo and there is none.
# - Git LFS is not supported on Xcode Cloud: the snapshot references arrive as
#   pointer stubs. Archiving the app never reads them; do not add the snapshot
#   scheme to an Xcode Cloud workflow.
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

# Delete this block to archive macOS here again, and read the header first: the
# Developer ID zip that always ships cannot be produced on Xcode Cloud, so the
# action can only ever mint a second copy of the App Store artifact
# `release:macos` already made — from a second build-number counter. Folded to
# lower case because the value is Apple's own spelling and only "macOS" is
# documented; a guard that misses on a capital is a guard that is not there.
if [ "$(printf '%s' "${CI_PRODUCT_PLATFORM:-}" | tr '[:upper:]' '[:lower:]')" = macos ]; then
  cat >&2 <<'CONF'
This workflow archived macOS, and this repository does not ship macOS from
Xcode Cloud. Both macOS channels come out of one local archive:

  mise run release:macos

Remove the "Archive - macOS" action from the workflow in App Store Connect.
CONF
  exit 1
fi

# Computed before anything is installed or generated, so a clone this cannot
# count fails in seconds rather than after a tuist generate.
#
# App Store Connect takes a CFBundleVersion strictly above the last one it holds
# for this MARKETING_VERSION *on this platform*, and local releases upload the
# commit count (Scripts/release-env.sh). CI_BUILD_NUMBER is Xcode Cloud's own
# counter and started at 1, so on its own it archives underneath every build a
# local release has already shipped — rejected at "Prepare Build for App Store
# Connect", 28 minutes in, which is how build 24 failed. The sum is above every
# local build by construction and ascending on both axes, so there is no start
# build number to keep in step by hand. The other side of that coin is in
# release-env.sh: these numbers run ahead of the plain commit count, so
# BUILD_NUMBER_FLOOR has to track them before a local iOS release.
#
# build_number() is what deepens the clone first — Xcode Cloud clones shallow,
# and `git rev-list --count` would otherwise answer with the depth — and what
# refuses a count at or below that floor. Two statements rather than one nested
# $(( )), so `set -e` sees the failure instead of an arithmetic syntax error.
# REACHY_BUILD_NUMBER still overrides the whole computation and can be set as an
# Xcode Cloud environment variable if the deepening ever fails.
# shellcheck source=Scripts/release-env.sh
. Scripts/release-env.sh
COMMIT_COUNT="$(build_number)"
BUILD_NUMBER=$((COMMIT_COUNT + ${CI_BUILD_NUMBER:-0}))
echo "Archiving build $BUILD_NUMBER (commit count $COMMIT_COUNT + CI_BUILD_NUMBER ${CI_BUILD_NUMBER:-0})." >&2

# Swift macros and package plugins cannot answer a trust prompt headless.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Apps/Tuist.swift reads this **at generation time** and defaults it to true, so
# it has to be set before `mise run project` and not after — the same ordering
# .github/actions/xcode-workspace/action.yml is built around. The Xcode
# compilation cache answers only through the LaunchAgent `tuist setup cache`
# starts, and there is none here: no tuist.dev session, and bootstrap.sh never
# runs. Generating without this bakes COMPILATION_CACHE_* into the project with
# nothing behind them, and then every compile task waits out a CAS socket
# deadline (ci.yml sets the same variable for the same reason). Build 24 logged
# it as `CAS error: deadlineExceeded(… No such file or directory (errno: 2))`
# beside `swift compiler caching requires explicit module build`, and took 28
# minutes over one Release archive.
export TUIST_CACHE_ENABLED=false

./bin/mise install --yes
./bin/mise run project

# Checked rather than assumed: this rewrites a literal tuist happens to emit, so
# a changed spelling makes the substitution a silent no-op and the archive ships
# CFBundleVersion 1 — rejected at the same step, with nothing in the build
# pointing at the cause.
PBXPROJ=Apps/ReachyMiniApps.xcodeproj/project.pbxproj
/usr/bin/sed -i '' \
  "s/CURRENT_PROJECT_VERSION = 1;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" \
  "$PBXPROJ"
if ! /usr/bin/grep -q "CURRENT_PROJECT_VERSION = $BUILD_NUMBER;" "$PBXPROJ"; then
  cat >&2 <<CONF
Stamping the build number changed nothing in $PBXPROJ: there was no
"CURRENT_PROJECT_VERSION = 1;" to replace, so the archive would carry
CFBundleVersion 1 and App Store Connect would reject it.

Check what tuist now writes for CURRENT_PROJECT_VERSION (Apps/Project.swift sets
it to "1") and update the pattern above.
CONF
  exit 1
fi
