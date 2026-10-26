#!/bin/bash
# Desktop picture helper, shared by install.sh and `make wallpaper`.
#
#   scripts/set-wallpaper.sh <picture>         sets <picture> on every desktop (System Events)
#   scripts/set-wallpaper.sh --import <image>  imports your own wallpaper (for example img0.jpg from your Windows 7
#                                              media): copies it to Assets/wallpaper.jpg (converting it to JPEG with
#                                              sips if needed), copies that into the installed Assets and sets it
#                                              on every desktop. Before `make install` it only imports: install
#                                              records your current wallpaper first, so uninstall can restore it.
#
# Environment overrides (used by scripts/test_install.sh): W7_ASSETS_SRC  Assets folder (default <repo>/Assets)
set -euo pipefail

# set_picture <path>: the path goes in as an argv item, never inside the script literal.
set_picture() {
    osascript -e 'on run argv' -e 'tell application "System Events" to tell every desktop to set picture to (item 1 of argv)' \
        -e 'end run' -- "$1"
}

import_wallpaper() {
    local src="$1" root assets support dest tmp format
    root="$(cd "$(dirname "$0")/.." && pwd)"
    assets="${W7_ASSETS_SRC:-$root/Assets}"
    support="$HOME/Library/Application Support/Win7Mac"
    dest="$assets/wallpaper.jpg"
    [ -f "$src" ] || { echo "error: $src: no such file. Nothing was changed." >&2; return 1; }

    mkdir -p "$assets"
    tmp="$assets/.wallpaper.jpg.new"
    format="$(sips -g format "$src" 2>/dev/null | awk '/format:/ {print $2}')" || format=""
    if [ "$format" = jpeg ]; then
        cp "$src" "$tmp"
    elif [ -n "$format" ]; then
        sips -s format jpeg -s formatOptions best "$src" --out "$tmp" >/dev/null \
            || { rm -f "$tmp"; echo "error: could not convert $src to JPEG. Nothing was changed." >&2; return 1; }
    else
        echo "error: $src is not an image sips can read. Nothing was changed." >&2
        return 1
    fi
    mv -f "$tmp" "$dest"
    echo "Imported $src as $dest"

    if [ ! -e "$support/restore.env" ]; then
        echo "Win7Mac is not installed yet: run 'make install' to apply it (your current wallpaper is recorded first)."
        return 0
    fi
    mkdir -p "$support/Assets"
    cp "$dest" "$support/Assets/.wallpaper.jpg.new"
    mv -f "$support/Assets/.wallpaper.jpg.new" "$support/Assets/wallpaper.jpg"
    set_picture "$support/Assets/wallpaper.jpg" || { echo "error: could not set the desktop picture" >&2; return 1; }
    echo "Wallpaper set on every desktop."
}

case "${1:-}" in
    --import)
        [ $# -eq 2 ] && [ -n "$2" ] || { echo "usage: $0 --import <image>" >&2; exit 2; }
        import_wallpaper "$2"
        ;;
    ""|-*)
        echo "usage: $0 <picture> | --import <image>" >&2
        exit 2
        ;;
    *)
        [ $# -eq 1 ] || { echo "usage: $0 <picture> | --import <image>" >&2; exit 2; }
        set_picture "$1"
        ;;
esac
