#!/bin/bash
# Tests scripts/import-win7-assets.sh with a stub 7zz and synthetic fixtures (scripts/fixtures/).
# No Windows files are used and nothing is downloaded.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fx="$root/scripts/fixtures"
script="$root/scripts/import-win7-assets.sh"

(cd "$root" && swift build --product Win7AssetTool >/dev/null 2>&1) || { echo "FAIL: cannot build Win7AssetTool"; exit 1; }
export W7_ASSET_TOOL="$root/.build/debug/Win7AssetTool"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures+1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# Win7AssetTool icon-names: IconCatalog.all, one per line, sorted and unique (setup's preflight counts against it);
# it contains every chrome name (scripts/chrome-icon-names.txt) and the shell's own ones.
"$W7_ASSET_TOOL" icon-names >"$work/icon-names.txt" 2>/dev/null
check "icon-names: exits 0 with names" "[ -s '$work/icon-names.txt' ]"
check "icon-names: sorted and unique" "LC_ALL=C sort -u '$work/icon-names.txt' | cmp -s - '$work/icon-names.txt'"
check "icon-names: every chrome name" "[ -z \"\$(LC_ALL=C comm -23 '$root/scripts/chrome-icon-names.txt' '$work/icon-names.txt')\" ]"
check "icon-names: shell names too" "grep -qx cp-sync-center '$work/icon-names.txt' && grep -qx tray-wired '$work/icon-names.txt'"
check "icon-names: plain names only" "! grep -qvE '^[A-Za-z0-9][A-Za-z0-9._-]*\$' '$work/icon-names.txt'"

# Stub 7zz. `x <archive> -o<dir> [-y] [paths...]`:
#   archive *.wim/*.esd -> copies "<n>/<path>" from image <n>'s tree into <dir>/<n>/<path>: image 1 is $STUB_TREE,
#                          image 2 $STUB_TREE2 (listed only when set). A path may hold wildcards and name folders
#                          (copied whole), as real 7-Zip allows.
#   other archive (a PE) -> copies $STUB_RSRC/<basename>/ into <dir>
mkdir -p "$work/bin"
cat >"$work/bin/7zz" <<'STUB'
#!/bin/bash
# STUB_SINGLE=1 simulates a single-image WIM: listed and extracted paths have no "1/" folder, and a
# request that still carries "1/" extracts nothing.
cmd="$1"
if [ "$cmd" = l ]; then
    archive="${@: -1}"
    echo "Path = $archive"
    pre="1/"; [ -n "${STUB_SINGLE:-}" ] && pre=""
    echo "Path = ${pre}Windows"
    echo "Path = ${pre}Windows/System32"
    if [ -z "${STUB_SINGLE:-}" ] && [ -n "${STUB_TREE2:-}" ]; then echo "Path = 2/Windows"; fi
    exit 0
fi
[ "$cmd" = x ] || exit 7
archive="$2"; shift 2
out=""; reqs=()
for a in "$@"; do case "$a" in -o*) out="${a#-o}" ;; -y) ;; *) reqs+=("$a") ;; esac; done
echo "$archive ${reqs[*]:-}" >>"$STUB_LOG"
case "$archive" in
    *.wim|*.esd)
        IFS=$'\n'; shopt -s nullglob
        for r in "${reqs[@]}"; do
            if [ -n "${STUB_SINGLE:-}" ]; then
                case "$r" in 1/*) continue ;; esac
                tree="$STUB_TREE"; p="$r"; dest="$out"
            else
                n="${r%%/*}"; p="${r#*/}"; dest="$out/$n"
                case "$n" in 1) tree="$STUB_TREE" ;; 2) tree="${STUB_TREE2:-}" ;; *) tree="" ;; esac
                [ -n "$tree" ] || continue
            fi
            for m in $tree/$p; do
                rel="${m#"$tree"/}"
                mkdir -p "$(dirname "$dest/$rel")"
                if [ -d "$m" ]; then cp -R "$m" "$(dirname "$dest/$rel")/"; else cp "$m" "$dest/$rel"; fi
            done
        done ;;
    *)
        [ -d "$STUB_RSRC/$(basename "$archive")" ] && cp -R "$STUB_RSRC/$(basename "$archive")/." "$out/" ;;
esac
exit 0
STUB
chmod +x "$work/bin/7zz"
export STUB_LOG="$work/7zz.log" STUB_TREE="$work/tree" STUB_RSRC="$work/rsrc"

# Fixture Windows tree: some mapped assets present, others deliberately missing.
t="$work/tree"
mkdir -p "$t/Windows/Web/Wallpaper/Windows" "$t/Windows/Media" "$t/Windows/Cursors" "$t/Windows/Fonts" \
         "$t/Windows/System32" "$t/ProgramData/Microsoft/User Account Pictures/Default Pictures"
echo jpg >"$t/Windows/Web/Wallpaper/Windows/img0.jpg"
mkdir -p "$t/Windows/Web/Wallpaper/Nature"; echo jpg >"$t/Windows/Web/Wallpaper/Nature/img1.jpg"
# Symbolic links pointing outside the matched folders: a linked theme folder and a linked picture (never followed).
mkdir -p "$work/outside"; echo jpg >"$work/outside/secret.jpg"
ln -s "$work/outside" "$t/Windows/Web/Wallpaper/Linked"
ln -s "$work/outside/secret.jpg" "$t/Windows/Web/Wallpaper/Nature/link.jpg"
# Gadgets (gadgets/<Name> DIR Program Files/Windows Sidebar/Gadgets/*.Gadget): pictures at the top, in images/ and in
# images/<folder>/ are copied at their relative paths; html/js/css, language folders, deeper folders, linked
# folders and pictures, and unsafe folder names are not.
g="$t/Program Files/Windows Sidebar/Gadgets"
mkdir -p "$g/X.Gadget/images/a/c" "$g/X.Gadget/en-US/css" "$g/x y.Gadget/images" "$work/outside-gadget/images"
for f in icon.png images/top.png images/Tulip.jpg images/a/b.png en-US/en.png images/a/c/deep.png "x y.Gadget/images/bad.png"; do
    case "$f" in x\ y*) echo png >"$g/$f" ;; *) echo png >"$g/X.Gadget/$f" ;; esac
done
echo html >"$g/X.Gadget/en-US/x.html"; echo css >"$g/X.Gadget/en-US/css/x.css"; echo js >"$g/X.Gadget/images/x.js"
echo png >"$work/outside-gadget/images/s.png"
ln -s "$work/outside-gadget" "$g/Linked.Gadget"
ln -s "$work/outside/secret.jpg" "$g/X.Gadget/images/link.jpg"
mkdir -p "$g/Y.Gadget"; ln -s "$work/outside-gadget/images" "$g/Y.Gadget/images"   # a linked images/ folder
ln -s "$work/outside-gadget/images" "$g/X.Gadget/images/lnk"                         # a linked images/<folder>/
# Image 2 of the WIM (Windows 7 media keep Landscapes and the regional sets there): the Windows theme again,
# Landscapes with a Desktop.ini, two regional sets with their Theme folders, and a folder name that isn't safe.
t2="$work/tree2"
mkdir -p "$t2/Windows/Web/Wallpaper/Windows" "$t2/Windows/Web/Wallpaper/Landscapes" \
         "$t2/Windows/Globalization/MCT/MCT-US/Wallpaper" "$t2/Windows/Globalization/MCT/MCT-US/Theme" \
         "$t2/Windows/Globalization/MCT/MCT-GB/Wallpaper" "$t2/Windows/Globalization/MCT/MCT-x y/Wallpaper"
echo jpg >"$t2/Windows/Web/Wallpaper/Windows/img0.jpg"
for f in img7.jpg img8.JPG Desktop.ini; do echo x >"$t2/Windows/Web/Wallpaper/Landscapes/$f"; done
echo jpg >"$t2/Windows/Globalization/MCT/MCT-US/Wallpaper/US-wp1.jpg"
echo theme >"$t2/Windows/Globalization/MCT/MCT-US/Theme/US.theme"
echo jpg >"$t2/Windows/Globalization/MCT/MCT-GB/Wallpaper/GB-wp1.jpg"
echo jpg >"$t2/Windows/Globalization/MCT/MCT-x y/Wallpaper/bad.jpg"
echo wav >"$t/Windows/Media/Windows Ding.wav"
cp "$fx/synthetic.cur" "$t/Windows/Cursors/aero_arrow.cur"      # aero_link.cur missing
echo ttf >"$t/Windows/Fonts/segoeui.ttf"                         # segoeuib.ttf missing
for pe in imageres.dll user32.dll shell32.dll ieframe.dll cmd.exe batmeter.dll; do   # DeviceCenter.dll missing
    echo pe >"$t/Windows/System32/$pe"
done
echo pe >"$t/Windows/explorer.exe"
cp "$fx/synthetic-user.bmp" "$t/ProgramData/Microsoft/User Account Pictures/Default Pictures/usertile11.bmp"

# PE resources in 7-Zip's real layout: .rsrc/GROUP_ICON/<group> is a bare group directory naming image ids, and
# .rsrc/ICON/<image id>.ico holds one image each (likewise GROUP_CURSOR + CURSOR). An image id is never a group id.
# grp <file> <type: 1 icon, 2 cursor> <size>:<image id>... writes a hand-made group directory (6-byte header,
# 14-byte entries ending in the image id).
le16() { printf "\\x$(printf %02x $(($1 & 255)))\\x$(printf %02x $((($1 >> 8) & 255)))"; }
grp() {
    local f="$1" type="$2" e size id; shift 2
    mkdir -p "$(dirname "$f")"
    {
        le16 0; le16 "$type"; le16 $#
        for e in "$@"; do
            size="${e%%:*}"; id="${e##*:}"
            if [ "$type" = 1 ]; then printf "\\x$(printf %02x $((size & 255)))\\x$(printf %02x $((size & 255)))\\x00\\x00"
            else le16 "$size"; le16 $((size * 2)); fi
            le16 1; le16 32; le16 0; le16 0; le16 "$id"
        done
    } >"$f"
}
le32() { le16 $(($1 & 65535)); le16 $((($1 >> 16) & 65535)); }
# dib <width> <bpp>: a square BITMAPINFOHEADER DIB, palette and pixels zeroed (black), empty AND mask.
dib() {
    local w="$1" bpp="$2" pal=0
    [ "$bpp" -le 8 ] && pal=$(( (1 << bpp) * 4 ))
    le32 40; le32 "$w"; le32 $((w * 2)); le16 1; le16 "$bpp"; le32 0; le32 0; le32 0; le32 0; le32 0; le32 0
    head -c $(( pal + (w * bpp + 31) / 32 * 4 * w + (w + 31) / 32 * 4 * w )) /dev/zero
}
# icowrap <width> <bpp> <payload file>: 7-Zip's single-image .ico wrapper around a payload.
icowrap() {
    local n; n=$(wc -c <"$3" | tr -d ' ')
    le16 0; le16 1; le16 1; printf "\\x$(printf %02x $(($1 & 255)))\\x$(printf %02x $(($1 & 255)))\\x00\\x00"
    le16 1; le16 "$2"; le32 "$n"; le32 22; cat "$3"
}
r="$work/rsrc"
mkdir -p "$r/imageres.dll/.rsrc/ICON" "$r/imageres.dll/.rsrc/WAVE" "$r/explorer.exe/.rsrc/BITMAP" "$r/explorer.exe/.rsrc/ICON" \
         "$r/user32.dll/.rsrc/ICON" "$r/user32.dll/.rsrc/CURSOR" "$r/shell32.dll/.rsrc/ICON" "$r/ieframe.dll/.rsrc/ICON" \
         "$r/cmd.exe/.rsrc/ICON" "$r/batmeter.dll/.rsrc/BITMAP"
grp "$r/imageres.dll/.rsrc/GROUP_ICON/112" 1 32:7001 64:7002          # Documents: a 32 px and a 64 px image
cp "$fx/icon-7001.ico" "$r/imageres.dll/.rsrc/ICON/7001.ico"
cp "$fx/icon-7002.ico" "$r/imageres.dll/.rsrc/ICON/7002.ico"
cp "$fx/synthetic.ico" "$r/imageres.dll/.rsrc/ICON/112.ico"     # an image whose id equals the group id: never used
cp "$fx/synthetic.ico" "$r/imageres.dll/.rsrc/ICON/1120.ico"    # must not match id 112
grp "$r/imageres.dll/.rsrc/GROUP_ICON/113" 1 32:7001            # 108, 109, 27 missing
echo riff >"$r/imageres.dll/.rsrc/WAVE/5080.wav"
grp "$r/user32.dll/.rsrc/GROUP_ICON/103" 1 32:7101              # msgbox-error
cp "$fx/icon-7001.ico" "$r/user32.dll/.rsrc/ICON/7101.ico"
grp "$r/user32.dll/.rsrc/GROUP_CURSOR/101" 2 16:7302            # the I-beam, as real media has it: a bare
{ le16 5; le16 1; tail -c +23 "$fx/synthetic.cur"; } >"$r/user32.dll/.rsrc/CURSOR/7302"   # CURSOR/<id>, hotspot + DIB
grp "$r/user32.dll/.rsrc/GROUP_CURSOR/73" 2 16:7301             # a .cur wrapper (1b map)
cp "$fx/synthetic.cur" "$r/user32.dll/.rsrc/CURSOR/7301.cur"
grp "$r/user32.dll/.rsrc/GROUP_CURSOR/120" 2 32:7310 64:7311    # 32 px 1 bpp vs 64 px 32 bpp (1b map)
{ le16 8; le16 8; dib 32 1; } >"$r/user32.dll/.rsrc/CURSOR/7310"
{ le16 20; le16 20; dib 64 32; } >"$r/user32.dll/.rsrc/CURSOR/7311"
grp "$r/shell32.dll/.rsrc/GROUP_ICON/25" 1 32:7201              # run
cp "$fx/icon-7001.ico" "$r/shell32.dll/.rsrc/ICON/7201.ico"
grp "$r/shell32.dll/.rsrc/GROUP_ICON/40" 1 48:7202 32:7201      # cp-taskbar-start-menu: 48 px 4 bpp, 32 px 32 bpp
dib 48 4 >"$work/dib4"; icowrap 48 4 "$work/dib4" >"$r/shell32.dll/.rsrc/ICON/7202.ico"
grp "$r/ieframe.dll/.rsrc/GROUP_ICON/1" 1 32:7401               # no line maps ieframe 1
cp "$fx/icon-7001.ico" "$r/ieframe.dll/.rsrc/ICON/7401.ico"
grp "$r/cmd.exe/.rsrc/GROUP_ICON/IDI_APPICON" 1 32:7601         # a group 7-Zip names by resource name
cp "$fx/icon-7001.ico" "$r/cmd.exe/.rsrc/ICON/7601.ico"
cp "$fx/synthetic-strip.bmp" "$r/explorer.exe/.rsrc/BITMAP/6801.bmp"
grp "$r/explorer.exe/.rsrc/GROUP_ICON/1" 1 32:7501              # explorer.exe: only a CONTACT line
cp "$fx/icon-7001.ico" "$r/explorer.exe/.rsrc/ICON/7501.ico"
cp "$fx/synthetic-strip.bmp" "$r/batmeter.dll/.rsrc/BITMAP/1.bmp"   # batmeter: no icon resource at all

width() { sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ {print $2}'; }

# 1. Windows tree source. Assets/_contact holds stale cells from an earlier import (image ids, an old sheet).
a="$work/assets1"
mkdir -p "$a/_contact"
for stale in imageres-9999.png imageres-7001.png imageres.png pack-x.png imageres-notes.txt; do echo stale >"$a/_contact/$stale"; done
out="$(W7_ASSETS_DIR="$a" PATH="$work/bin:$PATH" "$script" "$t" 2>&1)"; code=$?
check "tree: exit 0" "[ $code -eq 0 ]"
check "tree: wallpaper" "[ -f '$a/wallpaper.jpg' ]"
check "tree: startup.wav from WAVE/5080" "[ -f '$a/sounds/startup.wav' ] && grep -q riff '$a/sounds/startup.wav'"
check "tree: alert.wav (path with space)" "[ -f '$a/sounds/alert.wav' ]"
check "tree: arrow cursor png" "[ -f '$a/cursors/arrow.png' ] && [ \"\$(width '$a/cursors/arrow.png')\" = 32 ]"
check "tree: hotspots.txt" "grep -qx 'arrow 6 4' '$a/cursors/hotspots.txt'"
check "tree: segoeui.ttf" "[ -f '$a/fonts/segoeui.ttf' ]"
check "tree: start orb frames" "[ -f '$a/start-orb.png' ] && [ -f '$a/start-orb-hover.png' ] && [ -f '$a/start-orb-pressed.png' ]"
check "tree: icon assembled from its GROUP_ICON at the largest size" "[ \"\$(width '$a/icons/documents.png')\" = 64 ]"
check "tree: pictures icon" "[ -f '$a/icons/pictures.png' ]"
check "tree: user tile stays 48" "[ \"\$(width '$a/icons/user.png')\" = 48 ]"
check "tree: cursor stays 32" "[ \"\$(width '$a/cursors/arrow.png')\" = 32 ] && [ \"\$(width '$a/cursors/ibeam.png')\" = 32 ]"
check "tree: ibeam from cursor group 101, a bare CURSOR image, with its hotspot" "[ -f '$a/cursors/ibeam.png' ] && grep -qx 'ibeam 10 2' '$a/cursors/hotspots.txt'"
check "tree: colour depth before size (32 px 32 bpp over 48 px 4 bpp)" "[ \"\$(width '$a/icons/cp-taskbar-start-menu.png')\" = 32 ]"
check "tree: stale cells of a dll are removed" "[ ! -e '$a/_contact/imageres-9999.png' ] && [ ! -e '$a/_contact/imageres-7001.png' ]"
check "tree: the dll's sheet is rebuilt" "[ \"\$(width '$a/_contact/imageres.png')\" -ge 48 ]"
check "tree: other files in _contact stay" "[ -f '$a/_contact/pack-x.png' ] && [ -f '$a/_contact/imageres-notes.txt' ]"
check "tree: contact sheet named by group id" "[ -f '$a/_contact/imageres-112.png' ] && [ -f '$a/_contact/imageres-113.png' ] && [ ! -e '$a/_contact/imageres-7001.png' ]"
check "tree: contact sheet cells are 48" "[ \"\$(width '$a/_contact/imageres-112.png')\" = 48 ]"
check "tree: ICON/? is skipped with a generic hint when the file has no sheet" "printf '%s\n' \"\$out\" | grep -qx 'skip icons/cp-location-sensors.png: id not chosen — see Assets/_contact/'"
check "tree: ICON/- is skipped as absent from this media" "printf '%s\n' \"\$out\" | grep -qx 'skip icons/ie-add-favorite.png: no icon on this media (drawn icon stays)' && printf '%s\n' \"\$out\" | grep -qx 'skip icons/tray-battery-0.png: no icon on this media (drawn icon stays)'"
check "tree: CONTACT sheet without a mapped icon" "[ -f '$a/_contact/explorer-1.png' ] && [ -f '$a/_contact/explorer.png' ]"
check "tree: unmapped group of a mapped dll on its sheet" "[ -f '$a/_contact/ieframe-1.png' ] && [ -f '$a/_contact/ieframe.png' ]"
check "tree: montage per dll" "[ -f '$a/_contact/user32.png' ] && [ \"\$(width '$a/_contact/user32.png')\" -ge 48 ]"
check "tree: no montage for a dll without icons" "[ ! -e '$a/_contact/batmeter.png' ]"
check "tree: second dll icon" "[ -f '$a/icons/msgbox-error.png' ] && [ -f '$a/icons/run.png' ]"
check "tree: group named by resource name" "[ -f '$a/icons/app-com.apple.Terminal.png' ] && [ -f '$a/_contact/cmd-IDI_APPICON.png' ]"
check "tree: the repo map has a resource spec on every PE line" "! printf '%s\n' \"\$out\" | grep -q 'no resource spec\|bad resource spec'"
for s in "cursors/hand.png" "fonts/segoeuib.ttf" "icons/music.png" "icons/devices.png" "icons/control-panel.png"; do
    check "tree: skip line for $s" "printf '%s\n' \"\$out\" | grep -q '^skip $s: '"
done
check "tree: DIR themes from the tree" "[ -f '$a/wallpapers/Windows/img0.jpg' ] && [ -f '$a/wallpapers/Nature/img1.jpg' ]"
check "tree: DIR does not follow a linked folder" "[ ! -e '$a/wallpapers/Linked' ]"
check "tree: DIR does not follow a linked picture" "[ ! -e '$a/wallpapers/Nature/link.jpg' ] && [ ! -e '$a/wallpapers/Nature/secret.jpg' ]"
check "tree: gadgets DIR keeps the pictures' relative paths" "[ -f '$a/gadgets/X/icon.png' ] && [ -f '$a/gadgets/X/images/top.png' ] && [ -f '$a/gadgets/X/images/Tulip.jpg' ] && [ -f '$a/gadgets/X/images/a/b.png' ]"
check "tree: gadgets DIR copies no html, js, css or language folder" "[ ! -e '$a/gadgets/X/en-US' ] && [ -z \"\$(find '$a/gadgets' -name '*.html' -o -name '*.css' -o -name '*.js')\" ]"
check "tree: gadgets DIR stops at images/<folder>/" "[ ! -e '$a/gadgets/X/images/a/c' ]"
check "tree: gadgets DIR does not follow a linked folder or picture" "[ ! -e '$a/gadgets/Linked' ] && [ ! -e '$a/gadgets/X/images/link.jpg' ]"
check "tree: gadgets DIR does not follow a linked images/ or images/<folder>/" "[ ! -e '$a/gadgets/Y' ] && [ ! -e '$a/gadgets/X/images/lnk' ]"
check "tree: gadgets DIR skips an unsafe folder name" "printf '%s\n' \"\$out\" | grep -qx 'skip gadgets/<Name>: unsafe folder name x y.Gadget' && [ ! -e '$a/gadgets/x y' ]"
check "tree: gadgets DIR counts the pictures" "printf '%s\n' \"\$out\" | grep -qx 'ok   gadgets/X (4 pictures)'"
check "tree: DIR line without a match is skipped" "printf '%s\n' \"\$out\" | grep -qx 'skip wallpapers/<CC>: Windows/Globalization/MCT/MCT-\\*/Wallpaper not found in the source'"
check "tree: no skip for present assets" "! printf '%s\n' \"\$out\" | grep -q '^skip \(wallpaper.jpg\|icons/documents.png\|cursors/ibeam.png\|icons/msgbox-error.png\)'"

# 1b. Map grammar (W7_ASSET_MAP): trailing comments, named ids, ICON/?, CONTACT, and malformed lines.
cat >"$work/map.txt" <<'MAP'
# a comment line
icons/folder.png   Windows/System32/imageres.dll ICON/112   # trailing comment, K
icons/named.png    Windows/System32/cmd.exe ICON/IDI_APPICON	# chosen 2026-10-17 (after a tab)
icons/q.png        Windows/System32/imageres.dll ICON/?      # C
icons/nospec.png   Windows/System32/imageres.dll             # a PE without a resource spec
icons/badspec.png  Windows/System32/imageres.dll ICON/1-2    # not a resource spec
icons/badname.png  Windows/System32/imageres.dll ICON/IDI_APP
icons/q2.png       Windows/System32/batmeter.dll ICON/?      # a file without icon groups
icons/gone.png     Windows/System32/batmeter.dll ICON/-      # no icon on this media
icons/../x.png     Windows/System32/imageres.dll ICON/112
../y.png           Windows/System32/imageres.dll ICON/112
cursors/wrapped.png Windows/System32/user32.dll CURSOR/73
cursors/depth.png  Windows/System32/user32.dll CURSOR/120
CONTACT Windows/explorer.exe   # sheet only
CONTACT Windows/explorer.exe
wallpapers/<Theme>  DIR Windows/Web/Wallpaper/*   # a theme per folder
wallpapers/../<X>   DIR Windows/Web/Wallpaper/*
wallpapers/<Two>    DIR Windows/*/Wallpaper/*
wallpapers/<Up>     DIR Windows/../Web/Wallpaper/*
wallpapers/<None>   DIR Windows/Web/Wallpaper/Windows
gadgets/<G>         DIR Program Files/Windows Sidebar/Gadgets/*.Gadget   # gadgets
gadgets/../<Y>      DIR Program Files/Windows Sidebar/Gadgets/*.Gadget
pictures/<Z>        DIR Program Files/Windows Sidebar/Gadgets/*.Gadget
MAP
a="$work/assets1b"
out="$(W7_ASSET_MAP="$work/map.txt" W7_ASSETS_DIR="$a" PATH="$work/bin:$PATH" "$script" "$t" 2>&1)"; code=$?
check "map: exit 0" "[ $code -eq 0 ]"
check "map: spec read before a trailing comment" "[ \"\$(width '$a/icons/folder.png')\" = 64 ]"
check "map: named id after a tab comment" "[ -f '$a/icons/named.png' ]"
check "map: ICON/? skipped with a hint" "printf '%s\n' \"\$out\" | grep -q '^skip icons/q.png: id not chosen — see Assets/_contact/imageres.png'"
check "map: PE line without a spec rejected" "printf '%s\n' \"\$out\" | grep -q '^skip icons/nospec.png: no resource spec' && [ ! -e '$a/icons/nospec.png' ]"
check "map: malformed spec rejected" "printf '%s\n' \"\$out\" | grep -q '^skip icons/badspec.png: bad resource spec ICON/1-2'"
check "map: a name matches exactly" "printf '%s\n' \"\$out\" | grep -q '^skip icons/badname.png: resource ICON/IDI_APP not found'"
check "map: CONTACT sheet" "[ -f '$a/_contact/explorer-1.png' ] && [ -f '$a/_contact/explorer.png' ]"
check "map: ICON/? of a file without icon groups names no sheet" "printf '%s\n' \"\$out\" | grep -qx 'skip icons/q2.png: id not chosen — see Assets/_contact/'"
check "map: ICON/- skipped" "printf '%s\n' \"\$out\" | grep -qx 'skip icons/gone.png: no icon on this media (drawn icon stays)'"
check "map: unsafe asset names rejected" "printf '%s\n' \"\$out\" | grep -qx 'skip icons/../x.png: unsafe asset name' && printf '%s\n' \"\$out\" | grep -qx 'skip ../y.png: unsafe asset name' && [ ! -e '$a/x.png' ] && [ ! -e '$work/y.png' ]"
check "map: cursor from a .cur wrapper keeps its hotspot" "grep -qx 'wrapped 6 4' '$a/cursors/hotspots.txt'"
check "map: --size path prefers colour depth (64 px 32 bpp over 32 px 1 bpp)" "grep -qx 'depth 10 10' '$a/cursors/hotspots.txt'"
check "map: DIR line" "[ -f '$a/wallpapers/Nature/img1.jpg' ] && printf '%s\n' \"\$out\" | grep -qx 'ok   wallpapers/Nature (1 pictures)'"
check "map: DIR template must be wallpapers/<Name>" "printf '%s\n' \"\$out\" | grep -q '^skip wallpapers/../<X>: unsafe asset name' && [ ! -e '$a/X' ]"
check "map: gadgets DIR line" "[ -f '$a/gadgets/X/images/a/b.png' ] && printf '%s\n' \"\$out\" | grep -qx 'ok   gadgets/X (4 pictures)'"
check "map: DIR template must be gadgets/<Name> or wallpapers/<Name>" "printf '%s\n' \"\$out\" | grep -q '^skip gadgets/../<Y>: unsafe asset name' && printf '%s\n' \"\$out\" | grep -q '^skip pictures/<Z>: unsafe asset name' && [ ! -e '$a/Y' ] && [ ! -e '$a/pictures' ]"
for bad in Two Up None; do
    check "map: bad DIR pattern ($bad)" "printf '%s\n' \"\$out\" | grep -q '^skip wallpapers/<$bad>: bad DIR pattern'"
done
check "map: sheets only for files the map names" "[ -f '$a/_contact/cmd.png' ] && [ ! -e '$a/_contact/user32.png' ]"

# 1c. Win7AssetTool groupicon measures the file a symlink points to (a group directory is at most 4 KB).
grp "$work/grp-small" 1 32:7001
{ cat "$work/grp-small"; head -c 5000 /dev/zero; } >"$work/grp-big"
ln -s "$work/grp-big" "$work/grp-link-big"; ln -s "$work/grp-small" "$work/grp-link-small"
check "groupicon: symlink to a small group works" "'$W7_ASSET_TOOL' groupicon '$work/grp-link-small' '$r/imageres.dll/.rsrc/ICON' '$work/g1.ico' >/dev/null 2>&1"
check "groupicon: a large file is refused" "! '$W7_ASSET_TOOL' groupicon '$work/grp-big' '$r/imageres.dll/.rsrc/ICON' '$work/g2.ico' >/dev/null 2>&1"
check "groupicon: a symlink to a large file is refused" "! '$W7_ASSET_TOOL' groupicon '$work/grp-link-big' '$r/imageres.dll/.rsrc/ICON' '$work/g3.ico' >/dev/null 2>&1"

# 2. install.wim source: only mapped paths are requested from image 1.
mkdir -p "$work/media/sources"; echo wim >"$work/media/sources/install.wim"
: >"$STUB_LOG"
a="$work/assets2"
out="$(STUB_TREE2="$t2" W7_ASSETS_DIR="$a" PATH="$work/bin:$PATH" "$script" "$work/media" 2>&1)"; code=$?
check "wim: exit 0" "[ $code -eq 0 ]"
check "wim: DIR patterns requested from every image" "grep -qF '1/Windows/Web/Wallpaper/*' '$STUB_LOG' && grep -qF '2/Windows/Web/Wallpaper/*' '$STUB_LOG' && grep -qF '2/Windows/Globalization/MCT/MCT-*/Wallpaper' '$STUB_LOG'"
check "wim: gadgets pattern requested and copied" "grep -qF '1/Program Files/Windows Sidebar/Gadgets/*.Gadget' '$STUB_LOG' && [ -f '$a/gadgets/X/images/a/b.png' ] && [ ! -e '$a/gadgets/X/en-US' ]"
check "wim: themes merged across images" "[ -f '$a/wallpapers/Windows/img0.jpg' ] && [ -f '$a/wallpapers/Nature/img1.jpg' ] && [ -f '$a/wallpapers/Landscapes/img7.jpg' ] && [ -f '$a/wallpapers/Landscapes/img8.JPG' ]"
check "wim: only pictures are copied" "[ ! -e '$a/wallpapers/Landscapes/Desktop.ini' ] && [ ! -e '$a/wallpapers/US/US.theme' ]"
check "wim: regional sets named by country code" "[ -f '$a/wallpapers/US/US-wp1.jpg' ] && [ -f '$a/wallpapers/GB/GB-wp1.jpg' ] && [ ! -e '$a/wallpapers/MCT-US' ]"
check "wim: an unsafe folder name is skipped" "printf '%s\n' \"\$out\" | grep -q '^skip wallpapers/<CC>: unsafe folder name MCT-x y' && ! ls '$a/wallpapers' | grep -q ' '"
check "wim: a theme in both images counts its pictures once" "printf '%s\n' \"\$out\" | grep -qx 'ok   wallpapers/Windows (1 pictures)' && printf '%s\n' \"\$out\" | grep -qx 'ok   wallpapers/Landscapes (2 pictures)'"
check "wim: requested image 1 paths" "grep -q '1/Windows/Web/Wallpaper/Windows/img0.jpg' '$STUB_LOG' && grep -q '1/Windows/Media/Windows Ding.wav' '$STUB_LOG'"
check "wim: wallpaper + icon + cursor" "[ -f '$a/wallpaper.jpg' ] && [ -f '$a/icons/documents.png' ] && [ -f '$a/cursors/arrow.png' ]"

# 2b. Single-image WIM: no "1/" folder in the listing, so requests must carry no prefix.
: >"$STUB_LOG"
a="$work/assets2b"
out="$(STUB_SINGLE=1 W7_ASSETS_DIR="$a" PATH="$work/bin:$PATH" "$script" "$work/media" 2>&1)"; code=$?
check "single-image wim: exit 0" "[ $code -eq 0 ]"
check "single-image wim: unprefixed request" "grep -q ' Windows/Web/Wallpaper/Windows/img0.jpg' '$STUB_LOG' && ! grep -q ' 1/Windows' '$STUB_LOG'"
check "single-image wim: unprefixed DIR request" "grep -qF ' Windows/Web/Wallpaper/*' '$STUB_LOG' && [ -f '$a/wallpapers/Nature/img1.jpg' ]"
check "single-image wim: wallpaper + icon + cursor" "[ -f '$a/wallpaper.jpg' ] && [ -f '$a/icons/documents.png' ] && [ -f '$a/cursors/arrow.png' ]"

# 3. 7-Zip absent.
a="$work/assets3"
out="$(W7_ASSETS_DIR="$a" PATH="/usr/bin:/bin" "$script" "$t" 2>&1)"; code=$?
check "no 7zz: exit 2" "[ $code -eq 2 ]"
check "no 7zz: install message" "[ \"\$out\" = 'Install 7-Zip for macOS (7zz) from https://www.7-zip.org/download.html, then re-run.' ]"
check "no 7zz: nothing written" "[ ! -e '$a' ]"

# 4. Bogus sources.
mkdir -p "$work/empty"; echo x >"$work/file.txt"
for bogus in "$work/empty" "$work/file.txt" "$work/does-not-exist"; do
    W7_ASSETS_DIR="$work/assets4" PATH="$work/bin:$PATH" "$script" "$bogus" >/dev/null 2>&1; code=$?
    check "bogus source ($(basename "$bogus")): exit 1" "[ $code -eq 1 ]"
done

# 5. Nothing importable: exit 3.
mkdir -p "$work/hollow/Windows/System32"
W7_ASSETS_DIR="$work/assets5" PATH="$work/bin:$PATH" "$script" "$work/hollow" >/dev/null 2>&1; code=$?
check "nothing importable: exit 3" "[ $code -eq 3 ]"
out5="$(W7_ASSETS_DIR="$work/assets5" PATH="$work/bin:$PATH" "$script" "$work/hollow" 2>&1)"
check "nothing importable: prints the log tail" "printf '%s\n' \"\$out5\" | grep -q 'last lines'"
# A corrupt icon: the skip reason carries the parser error.
cp "$work/tree/Windows/Cursors/aero_arrow.cur" "$work/arrow.bak"; printf 'junk' >"$work/tree/Windows/Cursors/aero_arrow.cur"
out7="$(W7_ASSETS_DIR="$work/assets7" PATH="$work/bin:$PATH" "$script" "$t" 2>&1)"
check "corrupt cursor: skip reason has the error" "printf '%s\n' \"\$out7\" | grep -q '^skip cursors/arrow.png: cannot convert .*:.\+'"
cp "$work/arrow.bak" "$work/tree/Windows/Cursors/aero_arrow.cur"

# 6. ISO source (hdiutil is part of macOS).
if hdiutil makehybrid -iso -joliet -o "$work/media.iso" "$work/media" >/dev/null 2>&1; then
    a="$work/assets6"
    W7_ASSETS_DIR="$a" PATH="$work/bin:$PATH" STUB_TREE="$t" "$script" "$work/media.iso" >/dev/null 2>&1; code=$?
    check "iso: exit 0 and wallpaper" "[ $code -eq 0 ] && [ -f '$a/wallpaper.jpg' ]"
    check "iso: detached" "! hdiutil info | grep -q '$work'"
else
    echo "note: hdiutil makehybrid unavailable, ISO case skipped"
fi

[ $failures -eq 0 ] && { echo "test_import: all passed"; exit 0; }
echo "test_import: $failures failure(s)"; exit 1
