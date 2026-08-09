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

echo "==> Installing pinned tools (swiftformat, swiftlint, hk, dprint, tuist, ...)"
./bin/mise install

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
echo "==> Setting up the Tuist Xcode cache service (LaunchAgent)"
TUIST="$(./bin/mise where tuist)/tuist"
(cd Apps && env -u TOOLCHAINS "$TUIST" setup cache) || {
  echo "WARNING: tuist setup cache failed — no tuist.dev session?"
  echo "         Run './bin/mise x -- tuist auth login' and re-run bootstrap,"
  echo "         or generate with TUIST_CACHE_ENABLED=false to build uncached."
}

echo "==> Done"
./bin/mise run setup
echo ""
echo "Next steps:"
echo "  ./bin/mise run build   # build the Swift package"
echo "  ./bin/mise run test    # run tests"
echo "  ./bin/mise tasks       # list all tasks"
