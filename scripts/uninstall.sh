#!/bin/bash
# Reverses scripts/install.sh using restore.env. Environment overrides: W7_TWEAK_DIR, W7_TERMINAL_DOMAIN.
set -uo pipefail

tweaks="${W7_TWEAK_DIR:-/var/ammonia/core/tweaks}"
support="$HOME/Library/Application Support/Win7Mac"
restore="$support/restore.env"
term_domain="${W7_TERMINAL_DOMAIN:-com.apple.Terminal}"
term_profile="Win7 Command Prompt"
UNSET="__unset__"

# uninstall_terminal <original default profile> <original startup profile>: removes the profile from Terminal's
# preferences (export, edit the copy, import: through cfprefsd), then puts back the default and startup profile,
# deleting them when they were unset. A key the user has since pointed at another profile is left alone.
uninstall_terminal() {
    local pb=/usr/libexec/PlistBuddy entry=":Window Settings:$term_profile" work key original
    work="$(mktemp -d)" || return 1
    if defaults export "$term_domain" "$work/prefs.plist" && "$pb" -c "Print '$entry'" "$work/prefs.plist" >/dev/null 2>&1; then
        "$pb" -c "Delete '$entry'" "$work/prefs.plist" && defaults import "$term_domain" - <"$work/prefs.plist" \
            || echo "warning: could not remove the \"$term_profile\" Terminal profile" >&2
    fi
    rm -rf "$work"
    for key in "Default Window Settings" "Startup Window Settings"; do
        if [ "$key" = "Default Window Settings" ]; then original="$1"; else original="$2"; fi
        [ "$(defaults read "$term_domain" "$key" 2>/dev/null)" = "$term_profile" ] || continue
        if [ "$original" = "$UNSET" ]; then
            defaults delete "$term_domain" "$key" >/dev/null 2>&1 || true
        else
            defaults write "$term_domain" "$key" -string "$original" || echo "warning: could not restore Terminal's $key" >&2
        fi
    done
    rm -rf "$support/cmd-zsh"
    if pgrep -xq Terminal; then
        echo "warning: Terminal is running: it may drop the \"$term_profile\" profile only after it restarts, or bring it back when it quits. Check Terminal ▸ Settings ▸ Profiles afterwards (re-run make uninstall if it is still there)." >&2
    fi
}

launchctl bootout "gui/$UID/com.win7mac.shell" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.win7mac.shell.plist"
rm -rf "$HOME/Applications/Win7Shell.app"
rm -f "$HOME/Library/Sounds/Win7Alert.aiff"
rm -f "$tweaks/Win7Chrome.dylib" "$tweaks/Win7Chrome.dylib.blacklist" \
      "$tweaks/.Win7Chrome.dylib.new" "$tweaks/.Win7Chrome.dylib.blacklist.new"

# restore_default <defaults args...> <type flag> <value>: __unset__ deletes the key. A failure warns and continues.
restore_default() {
    local n=$#
    local value="${!n}" type="${@:$((n-1)):1}"
    local args=("${@:1:$((n-2))}")
    if [ "$value" = "$UNSET" ]; then
        defaults delete "${args[@]}" 2>/dev/null || true
        return 0
    fi
    case "$type" in
        -bool) case "$value" in 1|true|YES|yes) value=true ;; *) value=false ;; esac ;;
    esac
    if [ "$type" = -string ]; then type=; fi
    defaults write "${args[@]}" ${type:+"$type"} "$value" || echo "warning: could not restore ${args[*]}" >&2
}

if [ -f "$restore" ]; then
    # shellcheck disable=SC1090
    . "$restore"
    # Any key missing from an old or hand-edited file counts as "was unset".
    : "${DOCK_AUTOHIDE:=$UNSET}" "${DOCK_AUTOHIDE_DELAY:=$UNSET}" "${BEEP_SOUND:=$UNSET}" \
      "${FINDER_CREATEDESKTOP:=$UNSET}" "${MENUBAR_AUTOHIDE:=$UNSET}" "${WALLPAPER:=$UNSET}" \
      "${TERMINAL_DEFAULT_PROFILE:=$UNSET}" "${TERMINAL_STARTUP_PROFILE:=$UNSET}"

    restore_default com.apple.dock autohide -bool "$DOCK_AUTOHIDE"
    restore_default com.apple.dock autohide-delay -float "$DOCK_AUTOHIDE_DELAY"
    restore_default com.apple.finder CreateDesktop -bool "$FINDER_CREATEDESKTOP"
    restore_default -g com.apple.sound.beep.sound -string "$BEEP_SOUND"
    killall Dock 2>/dev/null || true
    killall Finder 2>/dev/null || true

    if [ "$MENUBAR_AUTOHIDE" != "$UNSET" ]; then
        osascript -e "tell application \"System Events\" to tell dock preferences to set autohide menu bar to $MENUBAR_AUTOHIDE" \
            || echo "warning: could not restore the menu bar setting" >&2
    fi
    if [ "$WALLPAPER" != "$UNSET" ]; then
        osascript -e 'on run argv' -e 'tell application "System Events" to tell every desktop to set picture to (item 1 of argv)' -e 'end run' -- "$WALLPAPER" \
            || echo "warning: could not restore the wallpaper" >&2
    fi
    uninstall_terminal "$TERMINAL_DEFAULT_PROFILE" "$TERMINAL_STARTUP_PROFILE"
else
    # Never strand the user: without a record, fall back to the macOS defaults.
    echo "No restore.env found: restoring the macOS defaults." >&2
    defaults delete com.apple.dock autohide 2>/dev/null || true
    defaults delete com.apple.dock autohide-delay 2>/dev/null || true
    defaults delete com.apple.finder CreateDesktop 2>/dev/null || true
    defaults delete -g com.apple.sound.beep.sound 2>/dev/null || true
    osascript -e 'tell application "System Events" to tell dock preferences to set autohide menu bar to false' || true
    killall Dock 2>/dev/null || true
    killall Finder 2>/dev/null || true
    uninstall_terminal "$UNSET" "$UNSET"
fi

if [ -f "$support/fonts.list" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$HOME/Library/Fonts/$f"
    done <"$support/fonts.list"
fi

rm -rf "$support/Assets" "$support/wallpaper.png"
rm -f "$restore" "$support/fonts.list"
rmdir "$support" 2>/dev/null || true
echo "Win7Mac uninstalled."
