#!/bin/bash
# Cuts a release of the version in VERSION: builds, verifies, checks reproducibility, zips,
# tags v<VERSION> and publishes a GitHub release with the zip and its SHA-256.
# Run from a clean checkout of main whose VERSION has not been released yet.
set -euo pipefail
cd "$(dirname "$0")"
version="$(cat VERSION)"
tag="v$version"
fail() { echo "release: $*" >&2; exit 1; }

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "working tree not clean"
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not in sync with origin/main"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then fail "$tag already exists: bump VERSION"; fi

# Build into dist/ so a release never replaces the app you're running.
export APP=dist/Eavesdropper.app
mkdir -p dist
./verify-reproducible.sh
./build-app.sh
./verify.sh

zip="dist/Eavesdropper-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent --norsrc "$APP" "$zip"
sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
echo "$sha  $(basename "$zip")" > "$zip.sha256"

git tag -a "$tag" -m "Eavesdropper $version"
git push -q origin "$tag"
gh release create "$tag" "$zip" "$zip.sha256" --title "Eavesdropper $version" --notes "Build $(git rev-list --count HEAD), commit $(git rev-parse --short=12 HEAD).

SHA-256: \`$sha\`

Rebuild and compare: check out \`$tag\`, run \`./build-app.sh\`; \`./verify-reproducible.sh\` shows builds are byte-identical."
echo "released $tag: $zip ($sha)"
