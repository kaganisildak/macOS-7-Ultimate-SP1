#!/bin/bash
# Installs a prebuilt release of macOS 7 Ultimate SP1 (the tarball from GitHub Releases) without compiling
# anything: build/Win7Shell.app and build/Win7Chrome.dylib come ready in the bundle. Run it from the
# unpacked folder:
#
#   ./install-release.sh                          # the shell, and the dylib when Ammonia is installed
#   ./install-release.sh SRC=/path/to/Win7.iso    # also imports wallpaper, sounds, cursors, fonts and icons
#                                                 # from your own Windows 7 media (needs 7zz on your PATH)
#
# Nothing is downloaded and nothing needs sudo. The release bundle holds no Microsoft files: the assets are
# extracted on this Mac from media you own. With SRC the icons are also embedded into the dylib, which
# needs the Command Line Tools' clang; without clang the prebuilt dylib is installed as it is and the
# icons still come from the imported folder where apps can read them.
#
# Environment overrides are the ones scripts/install.sh takes (W7_BUILD_DIR, W7_TWEAK_DIR, ...).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$here/Makefile" ]; then root="$here"; else root="$(cd "$here/.." && pwd)"; fi
build="${W7_BUILD_DIR:-$root/build}"
tweaks="${W7_TWEAK_DIR:-/var/ammonia/core/tweaks}"

src=""
for arg in "$@"; do
    case "$arg" in
        SRC=*) src="${arg#SRC=}" ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg (usage: $0 [SRC=/path/to/Win7.iso])" >&2; exit 2 ;;
    esac
done

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || fail "this release is built for Apple silicon (arm64); this Mac is $(uname -m)"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "${major:-0}" -ge 15 ] || fail "macOS 15 or later is needed; this is $(sw_vers -productVersion)"
[ -d "$build/Win7Shell.app" ] || fail "$build/Win7Shell.app is missing: run this from the unpacked release folder"
[ -f "$build/Win7Chrome.dylib" ] || fail "$build/Win7Chrome.dylib is missing: run this from the unpacked release folder"

# A browser download carries the quarantine flag, which Gatekeeper would turn into "cannot be opened"
# for an app that is not notarized. The bundle is signed ad hoc; clear the flag on it.
xattr -dr com.apple.quarantine "$root" 2>/dev/null || true

echo "==> Preflight (read-only)"
if ! "$root/scripts/setup.sh" CHECK=1; then
    echo
    echo "Some checks did not pass (see above). The shell installs anyway; the injected title bars and menus"
    echo "need Ammonia with SIP off, and the Windows 7 assets need an import (SRC=...)."
    echo
fi

if [ -n "$src" ]; then
    echo "==> Importing the Windows 7 assets from $src"
    command -v 7zz >/dev/null 2>&1 || fail "7zz (7-Zip for macOS) is not on your PATH; it is needed to read the media"
    "$root/scripts/import-win7-assets.sh" "$src"
    if command -v clang >/dev/null 2>&1 && [ -f "$root/Makefile" ]; then
        echo "==> Embedding the imported icons and cursors into the dylib"
        (cd "$root" && make chrome)
    else
        echo "clang is not available: the prebuilt dylib is installed without embedded icons."
    fi
fi

echo "==> Installing"
"$root/scripts/install.sh"

echo
echo "Done. Grant the Accessibility and Screen Recording permissions when the shell asks for them."
if [ ! -d "$tweaks" ]; then
    echo "Ammonia is not installed ($tweaks is missing), so only the shell is in place. Install Ammonia with SIP off"
    echo "and run this script again for the Windows 7 title bars, menus, Explorer bars and the IE look (see README)."
fi
if [ -z "$src" ] && [ ! -f "$root/Assets/wallpaper.jpg" ]; then
    echo "No Windows 7 assets yet: run  ./install-release.sh SRC=/path/to/Win7.iso  to import them from your own media."
fi
