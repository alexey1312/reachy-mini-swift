#!/bin/sh
# =============================================================================
# ReachyMini development environment bootstrap
# =============================================================================
# The single entry point for setting up this repo after cloning. Idempotent.
# Installs all pinned tools via the self-contained ./bin/mise and wires git
# hooks. No global mise, brew, or manual tool installs required.
#
# Swift itself is managed by swiftly (https://www.swift.org/swiftly/) via the
# .swift-version file — install swiftly separately if `swift --version`
# doesn't match .swift-version.
# =============================================================================
set -eu
cd "$(dirname "$0")"

echo "==> Trusting mise config"
./bin/mise trust --yes mise.toml

# A Linux checkout is a lint-and-review checkout: xcodebuild, the simulators and the
# snapshot suite are all out of reach, and four of the pinned tools ship as macOS
# binaries only (tuist, xcsift, Prefire, asc) — `mise install` fails outright on them,
# and with `set -e` that used to end bootstrap before the git hooks were wired. Turning
# them off in the gitignored local config is what leaves the rest of mise usable, and it
# has to be a file rather than an exported variable so that a later `mise run lint` in a
# fresh shell still works.
if [ "$(uname -s)" = "Linux" ]; then
    echo "==> Linux: disabling the macOS-only tools in mise.local.toml"
    cat >mise.local.toml <<'EOF'
# Written by ./bootstrap.sh on Linux; gitignored. These four ship as macOS binaries
# only, and nothing a Linux checkout can run needs them.
[settings]
disable_tools = [
  "tuist",
  "xcsift",
  "github:BarredEwe/Prefire",
  "github:rorkai/App-Store-Connect-CLI",
]
EOF
    ./bin/mise trust --yes mise.local.toml
fi

echo "==> Installing pinned tools (swiftformat, swiftlint, hk, dprint, tuist, ...)"
./bin/mise install

# SwiftLint cannot lint one file without SourceKit, and on Linux nothing supplies it.
# Skippable, because it is a ~1 GB download for ~325 MB of libraries.
if [ "$(uname -s)" = "Linux" ]; then
    ./Scripts/install-sourcekit.sh || {
        echo "WARNING: SourceKit not installed — 'mise run lint' will skip swiftlint."
        echo "         Everything else (catalogue, swiftformat, dprint, actionlint) still runs."
    }
fi

echo "==> Wiring git hooks (.githooks via core.hooksPath)"
git config core.hooksPath .githooks
chmod +x .githooks/*

# Snapshot reference images are LFS pointers; without the filter they check out as text stubs
# and every snapshot test fails with an unreadable-image error.
echo "==> Enabling Git LFS for this clone"
# LFS hooks are tracked in .githooks and combined with hk where necessary.
# Install only the local filters so git-lfs does not reject those existing hooks.
./bin/mise x -- git lfs install --local --skip-repo

# Apps/Tuist.swift enables the Xcode compilation cache by default, and the cache
# only answers through this per-user LaunchAgent — without it every compile task
# waits out a CAS socket deadline. Needs a tuist.dev session, hence best-effort.
# There is no Xcode to cache for on Linux, and tuist is not installed there.
if [ "$(uname -s)" = "Darwin" ]; then
  echo "==> Setting up the Tuist Xcode cache service (LaunchAgent)"
  TUIST="$(./bin/mise where tuist)/tuist"
  (cd Apps && env -u TOOLCHAINS "$TUIST" setup cache) || {
    echo "WARNING: tuist setup cache failed — no tuist.dev session?"
    echo "         Run './bin/mise x -- tuist auth login' and re-run bootstrap,"
    echo "         or generate with TUIST_CACHE_ENABLED=false to build uncached."
  }
fi

echo "==> Done"
./bin/mise run setup
echo ""
echo "Next steps:"
if [ "$(uname -s)" = "Linux" ]; then
  # Deliberately not offering build or test: both targets import SwiftUI, so they do not
  # compile here at all. What a Linux checkout is good for is exactly these two.
  echo "  ./bin/mise run lint          # SwiftLint --strict, catalogue, actionlint"
  echo "  ./bin/mise run format-check  # what CI checks"
  echo "  ./bin/mise tasks             # list all tasks (the xcodebuild ones need a Mac)"
else
  echo "  ./bin/mise run build   # build the Swift package"
  echo "  ./bin/mise run test    # run tests"
  echo "  ./bin/mise tasks       # list all tasks"
fi
