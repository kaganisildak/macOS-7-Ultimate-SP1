#!/bin/sh
# Lists the System Settings panes installed on this Mac: every ExtensionKit extension under
# /System/Library/ExtensionKit/Extensions whose extension point is com.apple.Settings.extension.ui and that
# allows the x-apple.systempreferences: URL scheme, one per line as "<bundle id><TAB><appex name>", sorted.
# The Control Panel opens panes with `open "x-apple.systempreferences:<bundle id>"`; the ids it may use are
# committed in Tests/Win7CoreTests/Fixtures/control-panel-pane-ids.txt (regenerate with this script;
# scripts/test_control_panel_ids.sh checks the fixture against this Mac). Reads Info.plists only.
#
# Usage: scripts/control-panel-pane-ids.sh [--fixture] [extensions directory]
#   --fixture  start with the fixture's comment header (regenerate the fixture with
#              scripts/control-panel-pane-ids.sh --fixture > scripts/fixtures/control-panel-pane-ids.txt)
set -u
if [ "${1:-}" = "--fixture" ]; then
    shift
    echo "# System Settings panes on macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), from scripts/control-panel-pane-ids.sh:"
    echo "# Settings extensions (com.apple.Settings.extension.ui) that allow the x-apple.systempreferences: URL scheme."
    echo "# Format: <bundle id><TAB><appex name in /System/Library/ExtensionKit/Extensions>. The Control Panel may only"
    echo "# open ids listed here (Win7CoreTests); scripts/test_control_panel_ids.sh fails when one is missing on this Mac."
fi
dir=${1:-/System/Library/ExtensionKit/Extensions}
[ -d "$dir" ] || { echo "control-panel-pane-ids: no directory $dir" >&2; exit 2; }

for appex in "$dir"/*.appex; do
    plist="$appex/Contents/Info.plist"
    [ -r "$plist" ] || continue
    point=$(plutil -extract EXAppExtensionAttributes.EXExtensionPointIdentifier raw -o - "$plist" 2>/dev/null) || continue
    [ "$point" = "com.apple.Settings.extension.ui" ] || continue
    url=$(plutil -extract EXAppExtensionAttributes.SettingsExtensionAttributes.allowsXAppleSystemPreferencesURLScheme \
        raw -o - "$plist" 2>/dev/null) || continue
    [ "$url" = "true" ] || continue
    id=$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null) || continue
    printf '%s\t%s\n' "$id" "$(basename "$appex")"
done | LC_ALL=C sort
