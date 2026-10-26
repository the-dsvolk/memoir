#!/usr/bin/env bash
# Releases memoir X.Y.Z (DESIGN.md §9.1): tags the current main as vX.Y.Z, pushes the tag and creates the
# GitHub Release with that version's CHANGELOG.md section as its notes.
#
#   scripts/release.sh 0.3.0
#
# Run on main, clean and in sync with origin, after the PR that adds a "## 0.3.0" section to
# CHANGELOG.md was merged. Nothing is committed here — so nothing is pushed to main.
set -euo pipefail
die() { echo "release: $*" >&2; exit 1; }

V="${1:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh X.Y.Z"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "not on main"
git diff --quiet HEAD -- || die "uncommitted changes"
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main isn't the same as origin/main — pull first"
! git rev-parse -q --verify "refs/tags/v$V" >/dev/null || die "v$V already exists"
last="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0)"
[[ "$(printf '%s\n%s\n' "${last#v}" "$V" | sort -V | tail -1)" == "$V" && "${last#v}" != "$V" ]] \
  || die "$V isn't newer than ${last#v}"

notes="$(awk -v v="$V" '$0 ~ "^## " v "( |$)" {on = 1; next} /^## / {on = 0} on' CHANGELOG.md)"
[[ -n "${notes//[[:space:]]/}" ]] || die "CHANGELOG.md has no \"## $V\" section — add it in a PR first"

git tag -a "v$V" -m "memoir $V"
git push origin "v$V"
gh release create "v$V" -R github.com/the-dsvolk/memoir --title "memoir $V" --notes "$notes"
echo "released v$V — rebuild the app (Xcode) and the CLI (scripts/build-cli.sh); on the Spark: git pull, restart memoir-asr"
