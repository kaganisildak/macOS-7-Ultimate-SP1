#!/bin/bash
# Extracts Windows 7 artwork, sounds, cursors and fonts from the user's own Windows 7 media into Assets/.
# Usage: import-win7-assets.sh <Win7.iso | dir with sources/install.wim|esd | Windows directory tree>
# Needs 7zz (or 7z) on PATH. Never downloads anything; writes only under Assets/ and a temp directory.
# Environment (for tests): W7_ASSETS_DIR overrides the output folder, W7_ASSET_TOOL the Win7AssetTool binary,
# W7_ASSET_MAP the map file (default scripts/win7-asset-map.txt; its format is described there).
# Icons and cursors: 7-Zip extracts a PE's icon group as .rsrc/GROUP_ICON/<group id> (the bare group directory)
# and its images as .rsrc/ICON/<image id>.ico; `ICON/<id>` in the map is always a group id (or a group's resource
# name), assembled with `Win7AssetTool groupicon` and converted at its largest size (icons/user.png at 48,
# cursors at 32). Contact sheets: Assets/_contact/<dll>-<group id>.png (48 px) for every group of every file an
# ICON line or a CONTACT line names, and Assets/_contact/<dll>.png, a labelled montage of them
# (`Win7AssetTool montage Assets/_contact <out> --prefix <dll>-`).
# Exit: 0 something imported, 1 bad usage/source, 2 7-Zip missing, 3 nothing imported.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
assets="${W7_ASSETS_DIR:-$root/Assets}"
map="${W7_ASSET_MAP:-$root/scripts/win7-asset-map.txt}"

usage() { echo "usage: $0 <Win7.iso | directory with sources/install.wim or install.esd | Windows directory tree>" >&2; exit 1; }
[ $# -eq 1 ] || usage
src="$1"

# Source kind.
kind=""
if [ -f "$src" ] && [[ "$src" == *.[iI][sS][oO] ]]; then kind=iso
elif [ -d "$src" ]; then
    if [ -f "$src/sources/install.wim" ] || [ -f "$src/sources/install.esd" ]; then kind=media
    elif [ -d "$src/Windows/System32" ]; then kind=tree
    fi
fi
[ -n "$kind" ] || usage

# 7-Zip.
sz="$(command -v 7zz || command -v 7z || true)"
if [ -z "$sz" ]; then
    echo "Install 7-Zip for macOS (7zz) from https://www.7-zip.org/download.html, then re-run."
    exit 2
fi

# Win7AssetTool.
tool="${W7_ASSET_TOOL:-}"
if [ -z "$tool" ]; then
    for c in "$root/.build/release/Win7AssetTool" "$root/.build/debug/Win7AssetTool"; do
        [ -x "$c" ] && { tool="$c"; break; }
    done
fi
[ -x "$tool" ] || { echo "Win7AssetTool not built; run 'make import-assets SRC=...' (or swift build --product Win7AssetTool)." >&2; exit 1; }

tmp="$(mktemp -d)"
mounted=""
cleanup() {
    if [ -n "$mounted" ]; then hdiutil detach "$mounted" -quiet >/dev/null 2>&1 || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT
log="$tmp/log"; err="$tmp/err"; : >"$log"

if [ "$kind" = iso ]; then
    mkdir -p "$tmp/iso"
    hdiutil attach -readonly -nobrowse -mountpoint "$tmp/iso" "$src" >/dev/null || { echo "cannot mount $src" >&2; exit 1; }
    mounted="$tmp/iso"
    src="$tmp/iso"
    if [ -f "$src/sources/install.wim" ] || [ -f "$src/sources/install.esd" ]; then kind=media
    elif [ -d "$src/Windows/System32" ]; then kind=tree
    else echo "no sources/install.wim or install.esd in the ISO" >&2; exit 1
    fi
fi

# Parse the map: parallel arrays, and the CONTACT paths. '#' at the start of a line or after a space or tab
# starts a comment (as in IconOverrideNames.stripComment). A spec is TYPE/<digits>, TYPE/<name> ([A-Za-z0-9_],
# matched exactly), TYPE/? (not chosen yet) or TYPE/- (this media has no such resource); a last field that starts
# like a spec but isn't one is kept as "!<field>" and reported.
names=(); paths=(); specs=(); contacts=(); dir_names=(); dir_paths=()
while IFS= read -r line || [ -n "$line" ]; do
    read -r -a f <<<"$line"
    [ "${#f[@]}" -ge 2 ] || continue
    if [ "${f[0]}" = CONTACT ]; then
        contacts+=("$(printf '%s ' "${f[@]:1}" | sed 's/ $//')")
        continue
    fi
    if [ "${f[1]}" = DIR ]; then   # <asset template> DIR <folder pattern>: whole folders (wallpaper themes, gadgets)
        [ "${#f[@]}" -ge 3 ] || continue
        dir_names+=("${f[0]}")
        dir_paths+=("$(printf '%s ' "${f[@]:2}" | sed 's/ $//')")
        continue
    fi
    spec=""
    last="${f[${#f[@]}-1]}"
    n=${#f[@]}
    if [[ "$last" =~ ^[A-Z_]+/([A-Za-z0-9_]+|\?|-)$ ]]; then spec="$last"; n=$((n-1))
    elif [[ "$last" =~ ^(ICON|CURSOR|WAVE|BITMAP|GROUP_ICON|GROUP_CURSOR)/ ]]; then spec="!$last"; n=$((n-1))
    fi
    [ "$n" -ge 2 ] || continue
    names+=("${f[0]}")
    paths+=("$(printf '%s ' "${f[@]:1:$((n-1))}" | sed 's/ $//')")
    specs+=("$spec")
done < <(sed -E $'s/(^|[ \t])#.*$//' "$map")

# Make the mapped files available under $base.
base="$src"
if [ "$kind" = media ]; then
    wim="$src/sources/install.wim"; [ -f "$wim" ] || wim="$src/sources/install.esd"
    base="$tmp/img"
    mkdir -p "$base"
    # 7-Zip shows a "1/" folder per image only when the WIM holds several images; with one image the
    # paths start at "Windows". Detect which, once, from the listing.
    prefix="1/"
    if "$sz" l -slt "$wim" >"$tmp/list" 2>>"$log"; then
        if grep -q '^Path = ' "$tmp/list" && ! grep -Eq '^Path = 1[/\\]' "$tmp/list"; then prefix=""; fi
    fi
    req=()
    for p in "${paths[@]}" ${contacts[@]+"${contacts[@]}"}; do
        dup=0; for r in ${req[@]+"${req[@]}"}; do [ "$r" = "$prefix$p" ] && dup=1; done
        [ $dup -eq 1 ] || req+=("$prefix$p")
    done
    "$sz" x "$wim" "-o$base" -y "${req[@]}" >>"$log" 2>&1 || true
    if [ -n "$prefix" ] && [ -d "$base/1" ]; then base="$base/1"; fi
fi

# DIR lines are looked up in EVERY image of the WIM (Windows 7 media keep the Windows theme in image 1 and
# Landscapes and the regional sets in image 2, for example): each pattern is requested as <n>/<pattern> for every
# image <n> the listing shows (unprefixed for a single-image WIM), and what each image holds is merged.
dir_roots=()
if [ "${#dir_names[@]}" -gt 0 ]; then
    if [ "$kind" = media ]; then
        images=()
        if [ -n "$prefix" ]; then
            while IFS= read -r n; do [ -n "$n" ] && images+=("$n"); done \
                < <(sed -n -E 's#^Path = ([0-9]+)[/\\].*#\1#p' "$tmp/list" 2>/dev/null | sort -un)
            [ "${#images[@]}" -gt 0 ] || images=(1)
        fi
        dreq=()
        if [ "${#images[@]}" -gt 0 ]; then
            for n in "${images[@]}"; do for p in "${dir_paths[@]}"; do dreq+=("$n/$p"); done; done
        else
            dreq=("${dir_paths[@]}")
        fi
        mkdir -p "$tmp/dirs"
        "$sz" x "$wim" "-o$tmp/dirs" -y "${dreq[@]}" >>"$log" 2>&1 || true
        if [ "${#images[@]}" -gt 0 ]; then
            for n in "${images[@]}"; do dir_roots+=("$tmp/dirs/$n"); done
        else
            dir_roots=("$tmp/dirs")
        fi
    else
        dir_roots=("$base")
    fi
fi

mkdir -p "$assets"
imported=0
skip() { echo "skip $1: $2"; if [ -s "$err" ]; then cat "$err" >>"$log"; : >"$err"; fi; }
note() { echo "ok   $1"; imported=$((imported+1)); }

res_dir() {  # extract PE resources of file $1 once; echo the directory
    local f="$1" d="$tmp/res/$(basename "$1")"
    if [ ! -d "$d" ]; then
        mkdir -p "$d"
        "$sz" x "$f" "-o$d" -y >>"$log" 2>&1 || true
    fi
    echo "$d"
}

find_res() {  # find_res <dir> <TYPE> <id> : prints the extracted resource file
    local d="$1" type="$2" id="$3"
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        find "$d" -type f -path "*/.rsrc/$type/*" \
            \( -name "$id" -o -name "$id.*" -o -name "#$id" -o -name "#$id.*" -o -name "${id}_*" \) 2>/dev/null | sort | head -n 1 || true
    else  # a resource name: exactly that file name
        find "$d" -type f -path "*/.rsrc/$type/*" -name "$id" 2>/dev/null | sort | head -n 1 || true
    fi
}

group_file() {  # group_file <GROUP_ICON|GROUP_CURSOR file> <ICON|CURSOR> : assembles it, prints the .ico/.cur
    local g="$1" type="$2" ext=ico
    [ "$type" = CURSOR ] && ext=cur
    local out="$tmp/grp/group.$ext"   # consumed before the next call
    mkdir -p "$tmp/grp"
    "$tool" groupicon "$g" "$(dirname "$(dirname "$g")")/$type" "$out" >/dev/null 2>"$err" || return 1
    echo "$out"
}

is_pe() { case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in *.dll|*.exe|*.cpl|*.ocx|*.mui|*.sys) return 0 ;; esac; return 1; }

has_groups() {  # has_groups <file in the image> : true when it has an icon group (so it gets a contact sheet)
    [ -f "$1" ] && is_pe "$1" || return 1
    [ -n "$(find "$(res_dir "$1")" -type f -path '*/.rsrc/GROUP_ICON/*' 2>/dev/null | head -n 1 || true)" ]
}

# An asset name is a plain file name under one of the asset folders (so a map line can never write outside
# Assets/), or one of the special names.
safe_asset() {
    [[ "$1" =~ ^(icons|cursors|sounds|fonts)/[A-Za-z0-9][A-Za-z0-9._-]*\.(png|wav|ttf)$ ]] && return 0
    case "$1" in wallpaper.jpg|start-orb) return 0 ;; esac
    return 1
}

hotspots=""
for i in "${!names[@]}"; do
    asset="${names[$i]}"; rel="${paths[$i]}"; spec="${specs[$i]}"
    dll="$(basename "$rel")"; dll="${dll%.*}"
    if ! safe_asset "$asset"; then skip "$asset" "unsafe asset name"; continue; fi
    case "$spec" in
        '!'*) skip "$asset" "bad resource spec ${spec#!} (expected TYPE/<id>, TYPE/<name>, TYPE/? or TYPE/-)"; continue ;;
        */'?')
            if has_groups "$base/$rel"; then skip "$asset" "id not chosen — see Assets/_contact/$dll.png"
            else skip "$asset" "id not chosen — see Assets/_contact/"; fi
            continue ;;
        */-) skip "$asset" "no icon on this media (drawn icon stays)"; continue ;;
    esac
    if [ -z "$spec" ] && is_pe "$rel"; then
        case "$asset" in *.png) skip "$asset" "no resource spec after $rel (write ICON/<id>)"; continue ;; esac
    fi
    file="$base/$rel"
    if [ ! -f "$file" ]; then skip "$asset" "$rel not found in the source"; continue; fi
    input="$file"
    if [ -n "$spec" ]; then
        type="${spec%%/*}"; id="${spec##*/}"
        case "$type" in
            ICON|CURSOR)
                # Only the group: an image id is never a group id.
                g="$(find_res "$(res_dir "$file")" "GROUP_$type" "$id")"
                if [ -z "$g" ]; then skip "$asset" "resource $spec not found in $rel"; continue; fi
                if ! input="$(group_file "$g" "$type")"; then skip "$asset" "cannot assemble $spec: $(tail -n 1 "$err")"; continue; fi ;;
            *)
                input="$(find_res "$(res_dir "$file")" "$type" "$id")"
                if [ -z "$input" ]; then skip "$asset" "resource $spec not found in $rel"; continue; fi ;;
        esac
    fi
    out="$assets/$asset"
    mkdir -p "$(dirname "$out")"
    case "$asset" in
        start-orb)
            if "$tool" bmpstrip "$input" "$tmp/orb" --frames 3 2>"$err"; then
                mv "$tmp/orb-0.png" "$assets/start-orb.png"
                mv "$tmp/orb-1.png" "$assets/start-orb-hover.png"
                mv "$tmp/orb-2.png" "$assets/start-orb-pressed.png"
                note "$asset"
            else skip "$asset" "cannot split $spec: $(tail -n 1 "$err")"; fi ;;
        *.png)
            # Icons at their largest representation, except the user tile (48); cursors stay 32.
            case "$asset" in icons/user.png) sizeopt=(--size 48) ;; icons/*) sizeopt=() ;; *) sizeopt=(--size 32) ;; esac
            if outp="$("$tool" ico2png "$input" "$out" ${sizeopt[@]+"${sizeopt[@]}"} 2>"$err")"; then
                case "$asset" in
                    cursors/*)
                        h="$(printf '%s\n' "$outp" | sed -n 's/^hotspot //p')"
                        hotspots="$hotspots$(basename "$asset" .png) ${h:-0 0}"$'\n' ;;
                esac
                note "$asset"
            else skip "$asset" "cannot convert $(basename "$input"): $(tail -n 1 "$err")"; fi ;;
        *)
            cp "$input" "$out" && note "$asset" ;;
    esac
done

if [ -n "$hotspots" ]; then
    printf '%s' "$hotspots" >"$assets/cursors/hotspots.txt"
fi

# DIR lines: `wallpapers/<Name> DIR <folder pattern>` or `gadgets/<Name> DIR <folder pattern>`. The pattern has
# exactly one '*' (in one path component); every folder it matches in any image becomes
# Assets/wallpapers/<what the '*' matched>/, holding that folder's *.jpg (top level only), or
# Assets/gadgets/<what the '*' matched>/, holding the folder's pictures (*.png, *.jpg, *.gif) at its top level, in
# images/ and in images/<folder>/, at the same relative paths (never its html, js, css or xml).
# Windows/Web/Wallpaper/* gives one folder per theme; MCT-*/Wallpaper gives US, GB, ...; Program Files/Windows
# Sidebar/Gadgets/*.Gadget gives Clock, Calendar, CPU, SlideShow, ...
dir_matches() {  # dir_matches <root> <pattern>: the folders the pattern matches under root, one per line
    # Symbolic links are never followed: a match, or any folder on the way to it, that is a link is skipped.
    local root="$1" pat="$2" m p old="$IFS" linked
    IFS=$'\n'
    shopt -s nullglob
    for m in "$root"/$pat; do
        [ -d "$m" ] || continue
        linked=0; p="$m"
        while [ "$p" != "$root" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do
            [ -L "$p" ] && { linked=1; break; }
            p="$(dirname "$p")"
        done
        [ $linked -eq 0 ] && printf '%s\n' "$m"
    done
    shopt -u nullglob
    IFS="$old"
}
safe_file() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]]; }
gadget_pic() {  # gadget_pic <file> <gadget name> <folder under it, or ""> : copies one picture, records it in $got
    local pic="$1" b dest
    [ -f "$pic" ] && [ ! -L "$pic" ] || return 0
    b="$(basename "$pic")"
    case "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" in *.png|*.jpg|*.jpeg|*.gif) ;; *) return 0 ;; esac
    safe_file "$b" || return 0
    dest="$assets/gadgets/$2${3:+/$3}"
    mkdir -p "$dest"
    cp "$pic" "$dest/$b" || return 0
    printf '%s\n' "$got" | grep -qxF "$2/${3:+$3/}$b" || got="$got$2/${3:+$3/}$b"$'\n'
    return 0
}
copy_gadget() {  # copy_gadget <gadget folder> <name>: pictures at its top level, in images/ and images/<folder>/
    local d="$1" name="$2" pic img sub s
    for pic in "$d"/*; do gadget_pic "$pic" "$name" ""; done
    for img in "$d"/*; do
        [ -d "$img" ] && [ ! -L "$img" ] || continue
        [ "$(basename "$img" | tr '[:upper:]' '[:lower:]')" = images ] || continue
        for pic in "$img"/*; do gadget_pic "$pic" "$name" images; done
        for sub in "$img"/*; do
            [ -d "$sub" ] && [ ! -L "$sub" ] || continue
            s="$(basename "$sub")"
            [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
            for pic in "$sub"/*; do gadget_pic "$pic" "$name" "images/$s"; done
        done
    done
    return 0
}
for i in ${dir_names[@]+"${!dir_names[@]}"}; do
    tmpl="${dir_names[$i]}"; pat="${dir_paths[$i]}"
    if [[ "$tmpl" =~ ^wallpapers/\<[A-Za-z]+\>$ ]]; then dkind=wallpapers
    elif [[ "$tmpl" =~ ^gadgets/\<[A-Za-z]+\>$ ]]; then dkind=gadgets
    else skip "$tmpl" "unsafe asset name (a DIR line writes wallpapers/<Name> or gadgets/<Name>)"; continue; fi
    stars="${pat//[^*]/}"
    IFS=/ read -r -a pparts <<<"$pat"
    k=-1; bad=0
    for j in "${!pparts[@]}"; do
        case "${pparts[$j]}" in ''|.|..) bad=1 ;; *'*'*) k=$j ;; esac
    done
    if [ "${#stars}" -ne 1 ] || [ $k -lt 0 ] || [ $bad -eq 1 ] || [[ "$pat" == /* ]]; then
        skip "$tmpl" "bad DIR pattern $pat (one '*' in one folder name, no '..')"; continue
    fi
    pre="${pparts[$k]%%\**}"; suf="${pparts[$k]#*\*}"
    got=""   # "<name>/<file>" lines copied by this line, across images
    for r in ${dir_roots[@]+"${dir_roots[@]}"}; do
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            IFS=/ read -r -a mparts <<<"${d#"$r"/}"
            name="${mparts[$k]#"$pre"}"; name="${name%"$suf"}"
            if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then skip "$tmpl" "unsafe folder name ${mparts[$k]}"; continue; fi
            if [ "$dkind" = gadgets ]; then copy_gadget "$d" "$name"; continue; fi
            for pic in "$d"/*; do
                [ -f "$pic" ] && [ ! -L "$pic" ] || continue
                b="$(basename "$pic")"
                case "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" in *.jpg|*.jpeg) ;; *) continue ;; esac
                [[ "$b" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]] || continue
                mkdir -p "$assets/wallpapers/$name"
                cp "$pic" "$assets/wallpapers/$name/$b" || continue
                printf '%s\n' "$got" | grep -qxF "$name/$b" || got="$got$name/$b"$'\n'
            done
        done < <(dir_matches "$r" "$pat")
    done
    if [ -z "$got" ]; then skip "$tmpl" "$pat not found in the source"; continue; fi
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        count="$(printf '%s' "$got" | awk -F/ -v n="$name" '$1 == n' | wc -l | tr -d ' ')"
        if [ "$dkind" = gadgets ]; then note "gadgets/$name ($count pictures)"; else note "wallpapers/$name ($count pictures)"; fi
    done < <(printf '%s' "$got" | sed 's#/.*##' | sort -u)
done

# Contact sheets, so ids can be chosen and remapped: every icon group of every file an ICON line (chosen or
# `?`) or a CONTACT line names, as _contact/<dll>-<group id>.png, then one labelled montage per file,
# _contact/<dll>.png. A file without icon groups gets no sheet. Each file's old cells and sheet are deleted first,
# so the sheet holds this import's group ids only (not image-id cells an older importer left behind).
sheets=()
for i in "${!names[@]}"; do
    case "${specs[$i]}" in ICON/-) ;; ICON/*) sheets+=("${paths[$i]}") ;; esac
done
sheets+=(${contacts[@]+"${contacts[@]}"})
seen=()
for rel in ${sheets[@]+"${sheets[@]}"}; do
    dup=0; for s in ${seen[@]+"${seen[@]}"}; do [ "$s" = "$rel" ] && dup=1; done
    [ $dup -eq 0 ] || continue
    seen+=("$rel")
    [ -f "$base/$rel" ] || continue
    dll="$(basename "$rel")"; dll="${dll%.*}"
    d="$(res_dir "$base/$rel")"
    rm -f "$assets/_contact/$dll.png"
    for c in "$assets/_contact/$dll-"*.png; do   # only <dll>-<id>.png: never another file's cells
        label="${c##*/}"; label="${label#"$dll-"}"; label="${label%.png}"
        if [[ "$label" =~ ^[A-Za-z0-9_]+$ ]]; then rm -f "$c"; fi
    done
    made=0
    while IFS= read -r g; do
        [ -n "$g" ] || continue
        id="$(basename "$g")"; id="${id%.*}"; id="${id#\#}"
        [[ "$id" =~ ^[A-Za-z0-9_]+$ ]] || continue
        ico="$(group_file "$g" ICON)" || continue
        mkdir -p "$assets/_contact"
        "$tool" ico2png "$ico" "$assets/_contact/$dll-$id.png" --size 48 >/dev/null 2>&1 && made=1
    done < <(find "$d" -type f -path "*/.rsrc/GROUP_ICON/*" 2>/dev/null | sort)
    if [ $made -eq 1 ]; then
        "$tool" montage "$assets/_contact" "$assets/_contact/$dll.png" --prefix "$dll-" >/dev/null 2>>"$log" || true
    fi
done

echo "imported $imported asset(s) into $assets"
if [ "$imported" -le 0 ]; then
    echo "--- last lines of the 7-Zip/tool log:"
    tail -n 20 "$log"
    exit 3
fi
exit 0
