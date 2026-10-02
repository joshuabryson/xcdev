#!/bin/sh
# Builds the universal (arm64 + x86_64) release of xcd and the Homebrew formula for it.
#   scripts/release.sh <version>      e.g. scripts/release.sh 0.1.0
# Writes dist/xcdev-<version>-macos.tar.gz (xcd, LICENSE, README.md) and dist/xcdev.rb.
# GITHUB_REPOSITORY (owner/repo, set by GitHub Actions) goes into the formula's URLs.
set -eu
version=${1:?usage: scripts/release.sh <version>}
repo=${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY=<owner>/<repo>}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

declared=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/XcdevKit/Version.swift)
if [ "$declared" != "$version" ]; then
    echo "error: Sources/XcdevKit/Version.swift says $declared, not $version; update it first" >&2
    exit 1
fi

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
archs=$(lipo -archs "$bin/xcd")
case "$archs" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "error: $bin/xcd is not universal (archs: $archs)" >&2; exit 1 ;;
esac

dist="$root/dist"
stage="$dist/xcdev-$version"
rm -rf "$stage"
mkdir -p "$stage"
cp "$bin/xcd" LICENSE README.md "$stage/"
tarball="$dist/xcdev-$version-macos.tar.gz"
COPYFILE_DISABLE=1 tar --no-mac-metadata --uid 0 --gid 0 -czf "$tarball" -C "$stage" xcd LICENSE README.md
sha=$(shasum -a 256 "$tarball" | cut -d ' ' -f 1)
sed -e "s|@VERSION@|$version|g" -e "s|@SHA256@|$sha|g" -e "s|@REPOSITORY@|$repo|g" \
    packaging/homebrew/xcdev.rb.template > "$dist/xcdev.rb"
rm -rf "$stage"
echo "built $tarball ($archs)"
echo "sha256 $sha"
echo "formula $dist/xcdev.rb"
