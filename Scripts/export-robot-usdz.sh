#!/bin/bash
# Writes the USD scene an object tracker is trained from (#77).
#
# Three tools, and the split between them is forced rather than chosen:
#
#   ReachyGeometryExport  the app's own URDF parser and STL decoder, so the file
#                         cannot drift from the robot the app draws
#   usdcat                Model I/O writes no `metersPerUnit`, and USD's default
#                         when it is unauthored is 0.01 — a 0.25 m robot would be
#                         read as 0.25 cm. The metadata is layer text, so the file
#                         is round-tripped through .usda to author it.
#   usdzip --arkitAsset   Apple's own packager. `MDLAsset.canExportFileExtension`
#                         answers false for "usdz" (usdc, usda and obj answer
#                         true), and --arkitAsset is the mode that flattens
#                         composition arcs and adjusts the data to RealityKit's
#                         requirements — which is the shape a reference object is
#                         trained from. Hand-rolling the archive would be a second
#                         answer to "what is a usdz".
#
# usdcat and usdzip are macOS's own (`Apple USD Tools`, /usr/bin), the way
# release-macos.sh uses lipo and the icon step uses iconutil. Nothing here is
# pinned by mise because nothing here is installable by it.
#
# The output is a *training input* and is gitignored. What ships is the
# `.referenceobject` Create ML produces from it.
set -euo pipefail

OUT_DIR=".build/geometry"
EXPORT_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir)
      shift
      [ $# -gt 0 ] || { echo "--output-dir needs a path" >&2; exit 2; }
      OUT_DIR="$1"
      ;;
    --with-antennas)
      EXPORT_ARGS+=("--with-antennas")
      ;;
    *)
      echo "usage: $0 [--output-dir <dir>] [--with-antennas]" >&2
      exit 2
      ;;
  esac
  shift
done

for tool in /usr/bin/usdcat /usr/bin/usdzip; do
  [ -x "$tool" ] || { echo "$tool is missing — it ships with macOS's USD tools." >&2; exit 1; }
done

BASE="$OUT_DIR/reachy-mini"
mkdir -p "$OUT_DIR"

. Scripts/swiftpm-env.sh
# `${a[@]+"${a[@]}"}` rather than `"${a[@]}"`: /bin/bash on macOS is 3.2, where an
# empty array expanded under `set -u` is an unbound variable rather than nothing.
swift run ReachyGeometryExport --output "$BASE.usdc" ${EXPORT_ARGS[@]+"${EXPORT_ARGS[@]}"}

/usr/bin/usdcat --flatten -o "$BASE.usda" "$BASE.usdc"

# Authored with python rather than sed because the insert has to land inside the
# layer's metadata block and nowhere else, and because a no-op substitution here
# ships a hundredfold scale error with every tool downstream reporting success —
# the same failure shape ci_post_clone.sh's build-number sed guards against. The
# assertion is the point; the edit is one line.
python3 - "$BASE.usda" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
header = "#usda 1.0\n(\n"
if not text.startswith(header):
    raise SystemExit(f"{path}: not a .usda layer — cannot author metersPerUnit")
if "metersPerUnit" in text.split(")", 1)[0]:
    raise SystemExit(f"{path}: already carries metersPerUnit, refusing to author a second")
path.write_text(text.replace(header, header + "    metersPerUnit = 1\n", 1))
PY

\rm -f "$BASE.usdz"
/usr/bin/usdzip "$BASE.usdz" --arkitAsset "$BASE.usda"

# The package is what gets trained against, so the check is on the package rather
# than on the layer that went into it: --arkitAsset flattens and rewrites, and a
# metadatum surviving the export is not the same claim as one surviving that.
# Process substitution rather than a pipe, and that is not style: `grep -q` exits
# on the first match, usdcat takes SIGPIPE writing the remaining ~160 MB, and
# `set -o pipefail` then reports the pipeline as failed — which reads exactly like
# the metadatum having been lost. Here grep's own status is the answer.
if ! grep -qm1 "metersPerUnit = 1" <(/usr/bin/usdcat --flatten "$BASE.usdz" 2>/dev/null); then
  echo "$BASE.usdz lost metersPerUnit — it would be read as centimetres." >&2
  exit 1
fi

# Only now, because a failure above is the one time these are worth reading. The
# .usda is the flattened layer metersPerUnit was authored into and the .usdc is
# what Model I/O wrote before that round trip; usdzip has taken what it needed
# from the first and nothing reads the second at all. The .usda alone is ~150 MB,
# in a directory nothing prunes.
\rm -f "$BASE.usda" "$BASE.usdc"

echo
echo "Packaged $BASE.usdz ($(du -h "$BASE.usdz" | cut -f1))"
echo "Train it in Create ML → Object Tracking. Where the .referenceobject it"
echo "writes belongs is not settled: at around 12 MB it is above the 9.5 MB"
echo "ReachySimulator precedent, so it likely goes in the app target rather than"
echo "in ReachyScene — see #77."
