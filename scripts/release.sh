#!/bin/sh
# Cuts a release: bumps the version everywhere, runs the tests, commits, tags and pushes.
# The Release workflow then builds, publishes the GitHub release and updates the tap.
#
#   scripts/release.sh 0.2.0
set -eu
cd "$(dirname "$0")/.."

version="${1:-}"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: scripts/release.sh <semver>  (e.g. 0.2.0)" >&2; exit 64 ;;
esac
tag="v$version"

[ "$(git branch --show-current)" = "main" ] || { echo "release from main (currently on $(git branch --show-current))" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree is not clean" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "tag $tag already exists" >&2; exit 1; }
grep -q "^## \[$version\]" CHANGELOG.md || { echo "CHANGELOG.md has no '## [$version]' section" >&2; exit 1; }

# Bump the version in every place that carries it.
sed -i '' "s/pingskiVersion = \".*\"/pingskiVersion = \"$version\"/" Sources/pingski/Version.swift
python3 -I - "$version" <<'PY'
import re, sys
path = "openapi/openapi.json"
text = open(path).read()
new, n = re.subn(r'("info"\s*:\s*\{[^}]*?"version"\s*:\s*")[^"]*(")', r"\g<1>" + sys.argv[1] + r"\2", text, count=1, flags=re.S)
assert n == 1, "could not find info.version in openapi.json"
open(path, "w").write(new)
PY
scripts/embed-openapi.sh
sed -i '' "s|/releases/download/v[0-9.]*/pingski-[0-9.]*-macos-universal.tar.gz|/releases/download/$tag/pingski-$version-macos-universal.tar.gz|" Formula/pingski.rb

make test
make build
./build/Pingski.app/Contents/MacOS/pingski --version | grep -q "$version"
brew style Formula/pingski.rb

git add -A
git diff --cached --quiet || git commit -m "Release $tag"
git tag -a "$tag" -m "Pingski $version"
git push origin main "$tag"

echo
echo "Pushed $tag. The Release workflow is now building:"
echo "  https://github.com/lookevink/pingski/actions"
echo "When it finishes the GitHub release carries the universal archives, SHA256SUMS and pingski.rb."
echo "If the TAP_DEPLOY_KEY secret is not configured, publish the formula with:"
echo "  scripts/update-tap.sh $version"
