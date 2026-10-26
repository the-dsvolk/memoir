#!/usr/bin/env bash
# Builds the memoir CLI with its version stamped in (`memoir --version`, DESIGN.md §9.1): an Info.plist
# from scripts/version.sh, embedded in the binary's __TEXT,__info_plist section, where Bundle.main reads
# it. A plain `swift build` works too, but its binary says "dev".
#
#   scripts/build-cli.sh            → mac/MemoirKit/.build/release/memoir
#   CONFIGURATION=debug scripts/build-cli.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIGURATION:-release}"
cd "$ROOT/mac/MemoirKit"

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
PLIST="$(dirname "$BIN")/memoir-version.plist"
mkdir -p "$BIN"
rm -f "$PLIST" "$BIN/memoir"  # a fresh plist, and relink even if no source changed (e.g. a new tag)
"$ROOT/scripts/version.sh" --plist "$PLIST" >/dev/null

swift build -c "$CONFIG" --product memoir \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" "$@"
"$BIN/memoir" --version
echo "→ $BIN/memoir"
