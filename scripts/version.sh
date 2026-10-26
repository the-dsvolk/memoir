#!/usr/bin/env bash
# memoir's version, from git (DESIGN.md §9.1): the last vX.Y.Z tag, commits since it, the commit and
# whether the tree had uncommitted changes.
#
#   scripts/version.sh                 prints VERSION, AHEAD, COMMIT, MODIFIED, BUILD, DATE as KEY=value
#   scripts/version.sh --plist FILE    also writes them into FILE (an Info.plist; created if missing) —
#                                      the app's build step and scripts/build-cli.sh use this
#
# VERSION is the tag's (0.2.0); AHEAD the commits after it; BUILD the commit count (always grows, for
# CFBundleVersion). Without git or a tag: VERSION=0.0.0.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION=0.0.0 AHEAD=0 COMMIT=unknown MODIFIED=false BUILD=0
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if git rev-parse --git-dir >/dev/null 2>&1; then
  COMMIT="$(git rev-parse --short=7 HEAD)"
  BUILD="$(git rev-list --count HEAD)"
  git diff --quiet HEAD -- 2>/dev/null || MODIFIED=true
  described="$(git describe --tags --long --match 'v[0-9]*' 2>/dev/null || true)"
  if [[ "$described" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)-g[0-9a-f]+$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
    AHEAD="${BASH_REMATCH[2]}"
  else
    AHEAD="$BUILD"  # no release tag yet: everything is "after 0.0.0"
  fi
fi

if [[ "${1:-}" == "--plist" ]]; then
  plist="${2:?--plist needs a file}"
  [[ -f "$plist" ]] || plutil -create xml1 "$plist"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
  plutil -replace CFBundleVersion -string "$BUILD" "$plist"
  plutil -replace MemoirCommitsSinceTag -integer "$AHEAD" "$plist"
  plutil -replace MemoirCommit -string "$COMMIT" "$plist"
  plutil -replace MemoirModified -bool "$MODIFIED" "$plist"
  plutil -replace MemoirBuildDate -string "$DATE" "$plist"
fi

printf 'VERSION=%s\nAHEAD=%s\nCOMMIT=%s\nMODIFIED=%s\nBUILD=%s\nDATE=%s\n' \
  "$VERSION" "$AHEAD" "$COMMIT" "$MODIFIED" "$BUILD" "$DATE"
