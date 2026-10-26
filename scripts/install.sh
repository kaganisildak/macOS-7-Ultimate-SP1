#!/bin/bash
# Turns the Win7Mac look on. Idempotent: the original settings are recorded once in restore.env and
# a second run never overwrites them. Environment overrides (used by scripts/test_install.sh):
#   W7_TWEAK_DIR   Ammonia tweak directory (default /var/ammonia/core/tweaks)
#   W7_BUILD_DIR   where build/Win7Shell.app and build/Win7Chrome.dylib live (default <repo>/build)
#   W7_ASSETS_SRC  Assets folder to copy (default <repo>/Assets)
#   W7_TERMINAL_DOMAIN  defaults domain for Terminal's preferences (default com.apple.Terminal)
#   W7_LOGIN_SHELL      login shell the Terminal profile is made for (default: the user's, from the user database)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${W7_BUILD_DIR:-$root/build}"
assets_src="${W7_ASSETS_SRC:-$root/Assets}"
tweaks="${W7_TWEAK_DIR:-/var/ammonia/core/tweaks}"
support="$HOME/Library/Application Support/Win7Mac"
restore="$support/restore.env"
agent="$HOME/Library/LaunchAgents/com.win7mac.shell.plist"
app_dest="$HOME/Applications/Win7Shell.app"
term_domain="${W7_TERMINAL_DOMAIN:-com.apple.Terminal}"
term_profile="Win7 Command Prompt"
cmd_dir="$support/cmd-zsh"
term_backup="$support/com.apple.Terminal.before.plist"
UNSET="__unset__"

if [ ! -d "$build/Win7Shell.app" ]; then
    echo "error: $build/Win7Shell.app not found. Run 'make shell' first. Nothing was changed." >&2
    exit 1
fi
warnings=()

mkdir -p "$support"

# --- 1. record the originals (first run only) --------------------------------------------------
# osa_get <script>: prints the answer; "missing value" or a failure gives an empty answer (= unset).
osa_get() {
    local out
    if ! out="$(osascript -e "$1" 2>/dev/null)"; then
        echo "warning: could not read a setting via osascript; it will not be restored" >&2
        return 0
    fi
    [ "$out" = "missing value" ] && out=""
    printf '%s' "$out"
}

rec() { # rec KEY value-or-empty(=unset)
    printf '%s=%q\n' "$1" "${2:-$UNSET}"
}

first_run=0
if [ ! -e "$restore" ]; then
    first_run=1
    {
        rec DOCK_AUTOHIDE "$(defaults read com.apple.dock autohide 2>/dev/null || true)"
        rec DOCK_AUTOHIDE_DELAY "$(defaults read com.apple.dock autohide-delay 2>/dev/null || true)"
        rec BEEP_SOUND "$(defaults read -g com.apple.sound.beep.sound 2>/dev/null || true)"
        rec FINDER_CREATEDESKTOP "$(defaults read com.apple.finder CreateDesktop 2>/dev/null || true)"
        rec MENUBAR_AUTOHIDE "$(osa_get 'tell application "System Events" to get autohide menu bar of dock preferences')"
        rec WALLPAPER "$(osa_get 'tell application "System Events" to get picture of first desktop')"
    } >"$restore.tmp"
    mv -f "$restore.tmp" "$restore"
fi

# Keys added in later versions: each is appended once, on the first run that knows it; keys already recorded
# are never touched. A Terminal key that already names our profile (restore.env lost or edited) counts as unset.
rec_terminal_once() { # rec_terminal_once KEY "<Terminal preference>"
    grep -q "^$1=" "$restore" && return 0
    local value
    value="$(defaults read "$term_domain" "$2" 2>/dev/null || true)"
    [ "$value" = "$term_profile" ] && value=""
    if [ -s "$restore" ] && [ -n "$(tail -c 1 "$restore")" ]; then echo >>"$restore"; fi
    rec "$1" "$value" >>"$restore"
}
rec_terminal_once TERMINAL_DEFAULT_PROFILE "Default Window Settings"
rec_terminal_once TERMINAL_STARTUP_PROFILE "Startup Window Settings"

# Fonts: one name per line in fonts.list, appended BEFORE each copy so an interrupted install cannot
# leave an unrecorded font. Fonts already in ~/Library/Fonts (the user's own, or ones a previous run
# added) are skipped; later runs add only fonts that are new.
if [ -d "$assets_src/fonts" ]; then
    mkdir -p "$HOME/Library/Fonts"
    for f in "$assets_src"/fonts/*.ttf; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        [ -e "$HOME/Library/Fonts/$name" ] && continue
        printf '%s\n' "$name" >>"$support/fonts.list"
        cp "$f" "$HOME/Library/Fonts/$name"
    done
fi

# --- 2. stop the shell, copy assets and the app -------------------------------------------------
launchctl bootout "gui/$UID/com.win7mac.shell" 2>/dev/null || true

mkdir -p "$support/Assets"
if [ -d "$assets_src" ]; then
    for entry in "$assets_src"/*; do
        [ -e "$entry" ] || continue
        [ "$(basename "$entry")" = reference ] && continue   # downloaded reference screenshots: never shipped
        cp -R "$entry" "$support/Assets/"
    done
fi

mkdir -p "$HOME/Applications"
rm -rf "$app_dest"
cp -R "$build/Win7Shell.app" "$app_dest"

# --- 3. hide the Dock, the menu bar and Finder's desktop icons ----------------------------------
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock 2>/dev/null || true
osascript -e 'tell application "System Events" to tell dock preferences to set autohide menu bar to true' || true
defaults write com.apple.finder CreateDesktop -bool false
killall Finder 2>/dev/null || true

# --- 4. alert sound -----------------------------------------------------------------------------
if [ -f "$assets_src/sounds/alert.wav" ]; then
    mkdir -p "$HOME/Library/Sounds"
    afconvert -f AIFF -d BEI16 "$assets_src/sounds/alert.wav" "$HOME/Library/Sounds/Win7Alert.aiff"
    defaults write -g com.apple.sound.beep.sound "$HOME/Library/Sounds/Win7Alert.aiff"
fi

# --- 5. wallpaper -------------------------------------------------------------------------------
# An imported wallpaper.jpg is always applied. Otherwise the generated default is: on the first run, and on a
# re-run only while the desktop still shows our previous default (so an improved default reaches existing
# installs), never over a picture the user chose since.
wall=""
if [ -f "$assets_src/wallpaper.jpg" ]; then
    wall="$support/Assets/wallpaper.jpg"
elif [ "$first_run" = 1 ] || [ "$(osa_get 'tell application "System Events" to get picture of first desktop')" = "$support/wallpaper.png" ]; then
    wall="$support/wallpaper.png"
    "$app_dest/Contents/MacOS/Win7Shell" --write-default-wallpaper "$wall"
else
    echo "Wallpaper: keeping the current desktop picture (not the Win7Mac default)."
fi
[ -z "$wall" ] || "$root/scripts/set-wallpaper.sh" "$wall" || true

# --- 6. LaunchAgent -----------------------------------------------------------------------------
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "$root/Resources/com.win7mac.shell.plist" >"$agent"
launchctl bootstrap "gui/$UID" "$agent" || warnings+=("launchctl bootstrap failed: the shell will start at next login (or run: launchctl bootstrap gui/$UID \"$agent\")")

# --- 7. Terminal: the "Win7 Command Prompt" profile ---------------------------------------------
# The profile is added to Terminal's preferences through cfprefsd (export, edit the copy, import), never by
# editing the plist file, and no Terminal window is opened. The user's dotfiles are not touched: zsh is started
# with ZDOTDIR=cmd-zsh, whose startup files source the user's own and then set the prompt.
install_terminal() {
    local f work profile_file="$assets_src/terminal/$term_profile.terminal"
    local pb=/usr/libexec/PlistBuddy entry=":Window Settings:$term_profile"
    mkdir -p "$cmd_dir" || return 1
    for f in zshenv zprofile zshrc zlogin; do
        cp "$root/scripts/cmd-zsh/$f" "$cmd_dir/.$f" || return 1
    done
    cp "$root/scripts/cmd-zsh/win7-cmd.zsh" "$cmd_dir/win7-cmd.zsh" || return 1
    # The system startup files look in ${ZDOTDIR:-$HOME} for Terminal's per-window session state (.zsh_sessions,
    # /etc/zshrc_Apple_Terminal) and zkbd key definitions (.zkbd, /etc/zshrc): keep using the user's.
    for f in .zsh_sessions .zkbd; do
        if [ -d "$HOME/$f" ] && [ ! -e "$cmd_dir/$f" ] && [ ! -L "$cmd_dir/$f" ]; then
            ln -s "$HOME/$f" "$cmd_dir/$f" || return 1
        fi
    done
    swift "$root/scripts/make-terminal-profile.swift" "$profile_file" "$cmd_dir" || return 1

    work="$(mktemp -d)" || return 1
    defaults export "$term_domain" "$work/prefs.plist" || { rm -rf "$work"; return 1; }
    # One-time backup of Terminal's preferences as they were before the first change; never overwritten.
    if [ ! -e "$term_backup" ]; then
        cp "$work/prefs.plist" "$term_backup" || { rm -rf "$work"; return 1; }
    fi
    "$pb" -c "Delete '$entry'" "$work/prefs.plist" >/dev/null 2>&1 || true
    "$pb" -c "Print ':Window Settings'" "$work/prefs.plist" >/dev/null 2>&1 \
        || "$pb" -c "Add ':Window Settings' dict" "$work/prefs.plist" || { rm -rf "$work"; return 1; }
    for f in "Default Window Settings" "Startup Window Settings"; do
        "$pb" -c "Delete ':$f'" "$work/prefs.plist" >/dev/null 2>&1 || true
        "$pb" -c "Add ':$f' string '$term_profile'" "$work/prefs.plist" || { rm -rf "$work"; return 1; }
    done
    "$pb" -c "Add '$entry' dict" -c "Merge '$profile_file' '$entry'" "$work/prefs.plist" >/dev/null \
        && defaults import "$term_domain" - <"$work/prefs.plist"
    local rc=$?
    rm -rf "$work"
    return $rc
}
if install_terminal; then
    echo "Terminal: new windows use the \"$term_profile\" profile. Existing Terminal windows keep their profile."
    if pgrep -xq Terminal; then
        warnings+=("Terminal is running: it may pick up the \"$term_profile\" profile only after it restarts, or undo the change when it quits. Check Terminal ▸ Settings ▸ Profiles afterwards (re-run make install if the profile is missing).")
    fi
else
    warnings+=("could not install the \"$term_profile\" Terminal profile; Terminal was not changed")
fi

# --- 8. Win7Chrome.dylib into Ammonia -----------------------------------------------------------
# The tweak directory is world-writable, so no sudo. The dylib is installed atomically: copying over
# a loaded dylib in place invalidates its code signature and every app launched afterwards is killed.
# Copy to a temp name in the same directory, then rename over the final name.
if [ -d "$tweaks" ]; then
    if [ -f "$build/Win7Chrome.dylib" ]; then
        cp "$build/Win7Chrome.dylib" "$tweaks/.Win7Chrome.dylib.new"
        mv -f "$tweaks/.Win7Chrome.dylib.new" "$tweaks/Win7Chrome.dylib"
        cp "$root/scripts/blacklist.txt" "$tweaks/.Win7Chrome.dylib.blacklist.new"
        mv -f "$tweaks/.Win7Chrome.dylib.blacklist.new" "$tweaks/Win7Chrome.dylib.blacklist"
    else
        echo "warning: $build/Win7Chrome.dylib not found (run make chrome first), skipping Win7Chrome" >&2
    fi
else
    echo "Ammonia not found — skipping Win7Chrome"
fi

for ((i = 0; i < ${#warnings[@]}; i++)); do echo "warning: ${warnings[$i]}" >&2; done
echo "Win7Mac installed. Log out and back in for the full effect."
