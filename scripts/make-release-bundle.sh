#!/bin/bash
# Builds the prebuilt release bundle for GitHub Releases from a clean checkout:
#
#   scripts/make-release-bundle.sh <version>        e.g. 1.0.0  ->  dist/macOS-7-Ultimate-SP1-v1.0.0-arm64.tar.gz
#
# The bundle is the tracked source tree plus build/Win7Shell.app (signed ad hoc), build/Win7Chrome.dylib with its
# blacklist, the Win7AssetTool binary (so the importer runs without compiling) and install-release.sh at the top.
# It refuses to run while Assets/ holds anything but its README: a dylib built then would embed the Windows
# icons and cursors, and nothing from Windows media may be redistributed. A SHA-256 file is written next to it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "usage: $0 <version>   (e.g. 1.0.0)" >&2; exit 2 ;;
esac
name="macOS-7-Ultimate-SP1-v$version-arm64"
dist="$root/dist"
stage="$dist/$name"

cd "$root"
stray="$(find Assets -type f ! -name README.md ! -name .gitkeep 2>/dev/null | head -3)"
if [ -n "$stray" ]; then
    echo "error: Assets/ holds files; a release must be built from a checkout without any imported media:" >&2
    echo "$stray" >&2
    exit 1
fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: not a git checkout" >&2; exit 1; }
plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[ "$plist_version" = "$version" ] || { echo "error: Resources/Info.plist says $plist_version, not $version" >&2; exit 1; }

echo "==> Building the shell (ad-hoc signature), the dylib and the asset tool"
make shell CODESIGN_IDENTITY=-
make chrome
swift build -c release --product Win7AssetTool -Xswiftc -plugin-path -Xswiftc "$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins/testing"
tool="$(swift build -c release --product Win7AssetTool --show-bin-path)/Win7AssetTool"
[ -x "$tool" ] || { echo "error: Win7AssetTool was not built" >&2; exit 1; }

# Nothing from Windows: the dylib has no icon or cursor section, and the staged Assets hold only the README.
if otool -l build/Win7Chrome.dylib | grep -qE 'sectname __w7(icons|cursors)'; then
    echo "error: build/Win7Chrome.dylib embeds icons or cursors; refusing to bundle it" >&2; exit 1
fi
codesign --verify --strict build/Win7Shell.app
codesign --verify build/Win7Chrome.dylib
lipo -info build/Win7Chrome.dylib | grep -q arm64

echo "==> Staging $stage"
rm -rf "$stage"
mkdir -p "$stage"
git ls-files -z | while IFS= read -r -d '' f; do
    mkdir -p "$stage/$(dirname "$f")"
    cp "$f" "$stage/$f"
done
for d in icons cursors sounds fonts _contact; do mkdir -p "$stage/Assets/$d"; done
mkdir -p "$stage/build" "$stage/.build/release"
cp -R build/Win7Shell.app "$stage/build/Win7Shell.app"
cp build/Win7Chrome.dylib "$stage/build/Win7Chrome.dylib"
cp scripts/blacklist.txt "$stage/build/Win7Chrome.dylib.blacklist"
cp "$tool" "$stage/.build/release/Win7AssetTool"
cp scripts/install-release.sh "$stage/install-release.sh"
chmod +x "$stage/install-release.sh" "$stage"/scripts/*.sh
stray="$(find "$stage/Assets" -type f ! -name README.md ! -name .gitkeep | head -3)"
[ -z "$stray" ] || { echo "error: asset files in the stage: $stray" >&2; exit 1; }

echo "==> Packing"
rm -f "$dist/$name.tar.gz" "$dist/$name.tar.gz.sha256"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$dist/$name.tar.gz" -C "$dist" "$name"
(cd "$dist" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256")
rm -rf "$stage"
ls -la "$dist/$name.tar.gz"
cat "$dist/$name.tar.gz.sha256"
