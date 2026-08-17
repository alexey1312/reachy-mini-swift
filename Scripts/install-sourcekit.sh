#!/bin/sh
# =============================================================================
# Install the one library SwiftLint needs on Linux
# =============================================================================
# SwiftLint cannot lint a single file without `libsourcekitdInProc.so`, which ships
# only in the swift.org toolchain — see Scripts/sourcekit-env.sh for the failure it
# produces without one. This fetches that library and the runtime it links, and
# nothing else: the full toolchain unpacks to 3.3 GB, of which ~375 MB is load
# bearing here. There is no Swift compiler afterwards and there is not meant to be —
# `swift build` is out of reach on Linux regardless, because the targets import
# SwiftUI and CoreBluetooth.
#
# Run by ./bootstrap.sh on Linux; idempotent, and safe to run by hand. It writes
# outside the worktree ($XDG_CACHE_HOME/reachy-mini/sourcekit) so that several
# worktrees share one copy and `mise run clean` cannot take it.
#
# Skip it with REACHY_SKIP_SOURCEKIT=1 — a Linux checkout is still good for the
# catalogue check, dprint, actionlint and swiftformat without it.
# =============================================================================
set -eu
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Linux" ]; then
    echo "install-sourcekit.sh: not Linux — Xcode already supplies SourceKit here."
    exit 0
fi

if [ "${REACHY_SKIP_SOURCEKIT:-0}" = "1" ]; then
    echo "install-sourcekit.sh: REACHY_SKIP_SOURCEKIT=1, skipping."
    exit 0
fi

DEST="${XDG_CACHE_HOME:-$HOME/.cache}/reachy-mini/sourcekit"
SWIFT_VERSION="$(tr -d '[:space:]' <.swift-version)"

# swift.org drops a trailing `.0`: 6.3.0 is published as swift-6.3-RELEASE, while
# 6.1.2 is published as swift-6.1.2-RELEASE.
URL_VERSION="$(printf '%s' "$SWIFT_VERSION" | sed 's/\.0$//')"
STAMP="$DEST/.swift-version"

if [ -f "$DEST/usr/lib/libsourcekitdInProc.so" ] &&
    [ "$(cat "$STAMP" 2>/dev/null || true)" = "$SWIFT_VERSION" ]; then
    echo "==> SourceKit already installed for Swift $SWIFT_VERSION ($DEST)"
    exit 0
fi

# The tarball is named after the distribution it was built on, and there is no
# generic Linux build to fall back to.
. /etc/os-release
case "${ID:-}${VERSION_ID:-}" in
ubuntu*) ;;
*)
    echo "install-sourcekit.sh: ${PRETTY_NAME:-this distribution} has no swift.org build here." >&2
    echo "  Unpack a toolchain by hand and point REACHY_SOURCEKIT_LIB at its usr/lib." >&2
    exit 1
    ;;
esac
PLATFORM="ubuntu$VERSION_ID"                              # ubuntu24.04
PLATFORM_DIR="$(printf '%s' "$PLATFORM" | tr -d '.')"     # ubuntu2404
case "$(uname -m)" in
x86_64) SUFFIX="" ;;
aarch64 | arm64) SUFFIX="-aarch64" ;;
*)
    echo "install-sourcekit.sh: no swift.org build for $(uname -m)." >&2
    exit 1
    ;;
esac

BASE="swift-$URL_VERSION-RELEASE-$PLATFORM$SUFFIX"
URL="https://download.swift.org/swift-$URL_VERSION-release/$PLATFORM_DIR$SUFFIX/swift-$URL_VERSION-RELEASE/$BASE.tar.gz"

echo "==> Fetching SourceKit for Swift $SWIFT_VERSION"
echo "    $URL"
# Extracted from the stream rather than from a downloaded file: the whole gzip has to
# be read either way, and this way the 1 GB never lands on disk. --wildcards is GNU
# tar's, which is what Linux has.
mkdir -p "$DEST"
rm -f "$STAMP"
curl -fsSL "$URL" | tar xz -C "$DEST" --strip-components=1 --wildcards \
    "$BASE/usr/lib/libsourcekitdInProc.so" \
    "$BASE/usr/lib/swift/linux/*.so" \
    "$BASE/usr/lib/swift/host/compiler/lib_CompilerSwift*.so"

if [ ! -f "$DEST/usr/lib/libsourcekitdInProc.so" ]; then
    echo "install-sourcekit.sh: the archive carried no libsourcekitdInProc.so." >&2
    exit 1
fi
printf '%s\n' "$SWIFT_VERSION" >"$STAMP"

echo "==> Installed $(du -sh "$DEST" | cut -f1) to $DEST"
echo "    The lint tasks find it through Scripts/sourcekit-env.sh; nothing to export."
