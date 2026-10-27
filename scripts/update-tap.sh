#!/bin/sh
# Manual fallback for the Release workflow's tap step: downloads the release tarball, writes its
# sha256 into Formula/pingski.rb and pushes the formula to lookevink/homebrew-tap.
#
#   scripts/update-tap.sh 0.2.0 [path/to/homebrew-tap]
set -eu
cd "$(dirname "$0")/.."

version="${1:-}"
[ -n "$version" ] || { echo "usage: scripts/update-tap.sh <semver> [tap-checkout]" >&2; exit 64; }
tap_dir="${2:-${TAP_DIR:-../homebrew-tap}}"
tag="v$version"
asset="pingski-$version-macos-universal.tar.gz"
url="https://github.com/looskis/pingski/releases/download/$tag/$asset"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$asset" "$url"
sha="$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)"
echo "sha256 $sha  $url"

sed -i '' \
  -e "s|/releases/download/v[0-9.]*/pingski-[0-9.]*-macos-universal.tar.gz|/releases/download/$tag/$asset|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$sha\"|" Formula/pingski.rb
brew style Formula/pingski.rb

if [ ! -d "$tap_dir/.git" ]; then
  git clone https://github.com/lookevink/homebrew-tap.git "$tap_dir"
fi
mkdir -p "$tap_dir/Formula"
cp Formula/pingski.rb "$tap_dir/Formula/pingski.rb"
(
  cd "$tap_dir"
  git pull --ff-only
  git add Formula/pingski.rb
  git commit -m "pingski $version"
  git push
)

echo
echo "Formula published. Verify with:"
echo "  brew update && brew install lookevink/tap/pingski && brew test pingski"
