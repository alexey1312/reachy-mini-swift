#!/bin/bash
# Xcode Cloud clones a repository with no Xcode project in it — ours is
# generated. This runs right after the clone: install the pinned tools through
# the committed mise bootstrap, run the Prefire playbook + tuist generate
# (that is what `mise run project` is), and the workspace exists by the time
# Xcode Cloud goes looking for it.
#
# The workflow itself lives in App Store Connect, not here — this script and
# ci_post_xcodebuild.sh are the whole of what is reviewable. It archives iOS
# (scheme `ReachyMini`), visionOS (scheme `ReachyVision`), tvOS (scheme
# `ReachyTV`) and macOS (scheme `ReachyMini`), all with the same bundle ID.
#
# **macOS here is the Mac App Store half of a release, and only that half.** The
# notarized Developer ID zip needs an App Store Connect key that deliberately
# never enters CI, so it stays local: `mise run release:macos`, which now makes
# that channel alone unless told otherwise. The Mac App Store build used to be
# local too, and that tied every macOS release to an Apple ID session in Xcode on
# one Mac, which lapsed between releases twice.
#
# Xcode Cloud numbers every build itself, and that is the number every upload
# carries — the block below the SDK check says what that asks of a Mac build.
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

# shellcheck source=Scripts/release-env.sh
. Scripts/release-env.sh
# First, so a workflow left on Xcode 27.0 fails in seconds rather than archiving
# an app that iPhone Duo boxes beside the status bar.
require_duo_sdk

# **Xcode Cloud numbers the build, and nothing in this repository can.** App Store
# Connect gives every upload the cloud's own build number (Apple, "Setting the next
# build number for Xcode Cloud builds"), so a CFBundleVersion stamped into the
# project is overwritten. This script stamped the commit count plus
# CI_BUILD_NUMBER for months while the uploads read 90, 121, 125 and 128 — the run
# numbers — so the stamp is gone.
#
# A Mac build must carry a number above every Mac build before it, even across
# versions; the other platforms only need a version and number pair nobody used.
# The last Mac build, uploaded from a Mac, was 268, so the cloud's counter was
# raised to 300 in App Store Connect → Xcode Cloud → Settings → Build Number, which
# no API sets. That is also why build 24 died at "Prepare Build for App Store
# Connect". This check fails in seconds instead, if the counter ever reads low
# again — a new Xcode Cloud product starts at 1.
MAC_BUILD_FLOOR=268
if [ "$(printf '%s' "${CI_PRODUCT_PLATFORM:-}" | tr '[:upper:]' '[:lower:]')" = macos ] &&
  [ "${CI_BUILD_NUMBER:-0}" -le "$MAC_BUILD_FLOOR" ]; then
  cat >&2 <<CONF
This Mac build is numbered ${CI_BUILD_NUMBER:-?}, and App Store Connect already holds
Mac build $MAC_BUILD_FLOOR. A Mac build must be numbered above every Mac build
before it, so this one would be turned away after the whole archive.

Raise the next build number above $MAC_BUILD_FLOOR in App Store Connect:
Hey Reachy → Xcode Cloud → Settings → Build Number → Next Build Number.
CONF
  exit 1
fi

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
