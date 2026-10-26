#!/bin/bash
# Imports the user's own Windows 7 icons (.ico files: <dll>-#N.ico exports such as imageres-#3.ico, or named icons such as
# explorer.ico; for example an icon pack zip) into Assets/icons/ under the names in scripts/win7-icon-map.txt,
# and into the installed copy (~/Library/Application Support/Win7Mac/Assets/icons/) when Win7Mac is installed.
#
# Usage: import-icons.sh <pack.zip | folder of .ico files>      (make import-icons SRC=...)
# Environment:
#   FORCE=1        replace an existing icon that differs (by default a file placed by hand is never overwritten)
#   PACK=<name>    contact-sheet folder name (default: the source's name without "imageres-" and its extension)
#   W7_ASSETS_SRC  Assets folder (default <repo>/Assets), W7_ASSET_TOOL the Win7AssetTool binary (both for tests)
#
# The source is untrusted data: zip entries are read one by one into a fresh temp directory under names this
# script chooses (no paths, links or permissions from the archive), at most 16 MB each, and only parsed by
# Win7AssetTool. Nothing from the source is ever executed. Nothing is downloaded.
# Each icon is converted at its largest representation. Ids not in the map, from any DLL, go to
# Assets/_contact/<pack>/<dll>-<id>.png only, and into one labelled contact sheet, Assets/_contact/<pack>.png
# (Win7AssetTool montage); other files not in the map are skipped. Re-running is safe: identical files are left
# alone.
# Exit: 0 done, 1 bad usage or source, 3 no icon could be converted.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
assets="${W7_ASSETS_SRC:-$root/Assets}"
support="$HOME/Library/Application Support/Win7Mac"
map="$root/scripts/win7-icon-map.txt"
force="${FORCE:-0}"

usage() { echo "usage: $0 <icon pack .zip | folder of .ico files (<dll>-#N.ico or named)>" >&2; exit 1; }
[ $# -eq 1 ] && [ -n "$1" ] || usage
src="$1"

kind=""
if [ -d "$src" ]; then kind=dir
elif [ -f "$src" ] && [[ "$(printf '%s' "$src" | tr '[:upper:]' '[:lower:]')" == *.zip ]]; then kind=zip
fi
[ -n "$kind" ] || { echo "error: $src is not a .zip file or a folder" >&2; usage; }

tool="${W7_ASSET_TOOL:-}"
if [ -z "$tool" ]; then
    for c in "$root/.build/release/Win7AssetTool" "$root/.build/debug/Win7AssetTool"; do
        [ -x "$c" ] && { tool="$c"; break; }
    done
fi
[ -n "$tool" ] && [ -x "$tool" ] || { echo "Win7AssetTool not built; run 'make import-icons SRC=...'." >&2; exit 1; }

pack="${PACK:-}"
if [ -z "$pack" ]; then
    pack="$(basename "$src")"; pack="${pack%.*}"; pack="${pack#imageres-}"; pack="${pack#imageres_}"
fi
pack="$(printf '%s' "$pack" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
case "$pack" in ''|.*) pack="pack" ;; esac
contact="$assets/_contact/$pack"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/in" "$tmp/out"

# Collect the candidate icons as $tmp/in/<n>.ico, with their original names in parallel arrays.
names=(); files=()
n=0
if [ "$kind" = zip ]; then
    unzip -Z1 "$src" >"$tmp/list" 2>/dev/null || { echo "error: cannot read $src as a zip archive" >&2; exit 1; }
    while IFS= read -r entry || [ -n "$entry" ]; do
        base="${entry##*/}"
        case "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" in *.ico) ;; *) continue ;; esac
        # unzip treats these as wildcards; such names are not imageres exports anyway.
        case "$entry" in *'['*|*']'*|*'*'*|*'?'*|*'\'*) echo "skip $base: unusual name"; continue ;; esac
        n=$((n+1))
        { unzip -p "$src" "$entry" 2>/dev/null || true; } | head -c 16777216 >"$tmp/in/$n.ico" || true
        names+=("$base"); files+=("$tmp/in/$n.ico")
    done <"$tmp/list"
else
    while IFS= read -r -d '' f; do
        n=$((n+1))
        names+=("$(basename "$f")"); files+=("$f")
    done < <(find "$src" -type f -iname '*.ico' -size -16384k -print0 2>/dev/null | sort -z)
fi

[ "$n" -gt 0 ] || { echo "error: no .ico files in $src" >&2; exit 1; }

# place <png> <dest> <label>: writes atomically; an existing file that differs is kept unless FORCE=1.
place() {
    local png="$1" dest="$2" label="$3"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        if cmp -s "$png" "$dest"; then echo "same $label"; return 0; fi
        if [ "$force" != 1 ]; then echo "keep $label: already there and different (FORCE=1 replaces it)"; return 0; fi
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$png" "$dest.new"
    mv -f "$dest.new" "$dest"
    echo "ok   $label"
}

installed=0
[ -d "$support/Assets" ] && installed=1
converted=0; seen=" "
for i in "${!files[@]}"; do
    name="${names[$i]}"; file="${files[$i]}"
    line="$("$tool" iconname "$map" "$name" 2>"$tmp/err")" || {
        code=$?
        if [ $code -eq 2 ]; then echo "skip $name: not in scripts/win7-icon-map.txt"; continue; fi
        echo "error: $(cat "$tmp/err")" >&2; exit 1
    }
    key="${line%% *}"; target="${line#* }"
    case "$seen" in *" $key "*) echo "skip $name: $key seen twice in the source"; continue ;; esac
    seen="$seen$key "
    png="$tmp/out/$key.png"
    if ! "$tool" ico2png "$file" "$png" >/dev/null 2>"$tmp/err"; then
        echo "skip $name: cannot convert: $(tail -n 1 "$tmp/err")"; continue
    fi
    converted=$((converted+1))
    if [ "$target" = - ]; then
        mkdir -p "$contact"
        cp "$png" "$contact/$key.png"
        echo "contact _contact/$pack/$key.png (not in scripts/win7-icon-map.txt)"
        continue
    fi
    place "$png" "$assets/icons/$target" "icons/$target"
    if [ $installed -eq 1 ]; then place "$png" "$support/Assets/icons/$target" "installed icons/$target"; fi
done

if [ $converted -eq 0 ]; then
    echo "error: no icon could be converted from $src" >&2
    exit 3
fi
echo "converted $converted icon(s) into $assets/icons"
if [ -d "$contact" ] && "$tool" montage "$contact" "$assets/_contact/$pack.png" >/dev/null 2>&1; then
    echo "contact sheet _contact/$pack.png: the ids not in scripts/win7-icon-map.txt"
fi
if [ $installed -eq 1 ]; then
    echo "Installed copy updated: the shell picks the icons up when it next starts, Finder (folder icons) when it relaunches."
else
    echo "Win7Mac is not installed yet: 'make install' copies the icons into place."
fi
