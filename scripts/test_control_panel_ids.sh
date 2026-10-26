#!/bin/sh
# re-enumerates this Mac's System Settings panes (scripts/control-panel-pane-ids.sh) and fails when
# a pane listed in scripts/fixtures/control-panel-pane-ids.txt is missing or lives in another .appex. The
# Control Panel opens only fixture ids (Win7CoreTests checks that), so a pass means every pane it may open
# exists here. Reads Info.plists only.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$root/scripts/fixtures/control-panel-pane-ids.txt"
fail() { echo "FAIL: $1"; exit 1; }

[ -r "$fixture" ] || fail "no fixture at $fixture"
current=$("$root/scripts/control-panel-pane-ids.sh") || fail "enumeration failed"
[ -n "$current" ] || fail "no Settings extensions found"

missing=0
listed=0
tab=$(printf '\t')
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    listed=$((listed + 1))
    if ! printf '%s\n' "$current" | grep -qxF "$line"; then
        echo "missing on this Mac: ${line%%"$tab"*} (${line#*"$tab"})"
        missing=$((missing + 1))
    fi
done <"$fixture"

[ "$listed" -gt 0 ] || fail "the fixture lists no panes"
[ "$missing" -eq 0 ] || fail "$missing of $listed listed panes are missing"
echo "ok: all $listed Control Panel pane ids exist on this Mac"
