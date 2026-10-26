#!/bin/sh
# Renders every Windows 7 component (Win7RenderTool, 2x) and writes build/fidelity/gallery.html, which
# shows each render beside the matching region of the user's reference screenshots in
# Assets/reference/ (git-ignored) when there is one. The references are only displayed, cropped by
# CSS; no pixels are copied out of them.
#
# Usage: scripts/render-gallery.sh   (from the repository root)
set -eu
export LC_ALL=C   # awk prints decimals with a dot

cd "$(dirname "$0")/.."
SWIFT_PLUGINS="$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins/testing"
OUT=build/fidelity
REF=Assets/reference

swift build --product Win7RenderTool -Xswiftc -plugin-path -Xswiftc "$SWIFT_PLUGINS"
BIN="$(swift build --product Win7RenderTool --show-bin-path)/Win7RenderTool"
rm -rf "$OUT/renders"
mkdir -p "$OUT/renders"
"$BIN" "$OUT/renders" >/dev/null

# component | reference file | crop x y w h (reference pixels) | note
CROPS='taskbar-800x40|Windows_7_Taskbar.png|0 0 800 40|
titlebar-active-600x30|Action_Center_on_Windows_7.png|0 0 386 14|the reference window is inactive and scaled to about 50%
titlebar-inactive-600x30|Action_Center_on_Windows_7.png|0 0 386 14|scaled to about 50%
caption-min-normal|Action_Center_on_Windows_7.png|334 3 50 12|inactive, about 50%
caption-max-normal|Action_Center_on_Windows_7.png|334 3 50 12|inactive, about 50%
caption-close-normal|Action_Center_on_Windows_7.png|334 3 50 12|inactive, about 50%
startmenu-400x535|Windows_7_SP1_screenshot.png|0 214 207 246|the screenshot is scaled to 50%
explorer-navbar-800x34|Action_Center_on_Windows_7.png|0 12 386 20|Control Panel window, inactive, about 50%
wallpaper-640x400|Windows_7_SP1_screenshot.png|0 0 640 460|'

esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

{
  cat <<'EOF'
<!doctype html>
<html><head><meta charset="utf-8"><title>Win7Mac fidelity gallery</title>
<style>
body { font: 13px -apple-system, "Segoe UI", sans-serif; background: #e9edf2; color: #1e395b; margin: 16px; }
h1 { font-size: 18px; }
section { background: #fff; border: 1px solid #c5d2e1; border-radius: 6px; padding: 12px; margin: 0 0 14px; }
h2 { font-size: 14px; margin: 0 0 8px; }
.row { display: flex; gap: 24px; align-items: flex-start; flex-wrap: wrap; }
.cell p { margin: 0 0 4px; color: #4c607a; }
.ref { background-repeat: no-repeat; image-rendering: pixelated; border: 1px dashed #99a; }
.none { color: #8a94a3; font-style: italic; }
img { display: block; }
</style></head><body>
<h1>Win7Mac fidelity gallery</h1>
<p>Renders are 2x PNGs shown at 1x (points). References are the user's own screenshots in Assets/reference/, cropped by CSS and scaled to the render's width.</p>
EOF
  for f in "$OUT"/renders/*.png; do
    name=$(basename "$f" .png)
    w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/ {print int($2 / 2)}')
    printf '<section><h2>%s</h2><div class="row"><div class="cell"><p>render</p><img src="renders/%s.png" width="%s"></div>\n' \
      "$(esc "$name")" "$name" "$w"
    line=$(printf '%s\n' "$CROPS" | awk -F'|' -v n="$name" '$1 == n')
    ref=$(printf '%s' "$line" | cut -d'|' -f2)
    if [ -n "$line" ] && [ -f "$REF/$ref" ]; then
      set -- $(printf '%s' "$line" | cut -d'|' -f3)
      note=$(printf '%s' "$line" | cut -d'|' -f4)
      rw=$(sips -g pixelWidth "$REF/$ref" | awk '/pixelWidth/ {print $2}')
      rh=$(sips -g pixelHeight "$REF/$ref" | awk '/pixelHeight/ {print $2}')
      # Scale the crop to the render's width, but at least 40 px high so small crops stay legible.
      css=$(awk -v x="$1" -v y="$2" -v cw="$3" -v ch="$4" -v rw="$rw" -v rh="$rh" -v dw="$w" 'BEGIN {
        s = dw / cw
        if (ch * s < 40) s = 40 / ch
        printf "width:%dpx;height:%dpx;background-position:-%.1fpx -%.1fpx;background-size:%.1fpx %.1fpx", cw * s, ch * s, x * s, y * s, rw * s, rh * s }')
      printf '<div class="cell"><p>reference: %s %s</p><div class="ref" style="background-image:url(../../%s/%s);%s"></div></div>\n' \
        "$(esc "$ref")" "$(esc "${note:+($note)}")" "$REF" "$ref" "$css"
    else
      printf '<div class="cell"><p class="none">no reference crop</p></div>\n'
    fi
    printf '</div></section>\n'
  done
  printf '</body></html>\n'
} > "$OUT/gallery.html"

echo "wrote $OUT/gallery.html"
