#!/bin/zsh
# Tests install.sh / uninstall.sh with a temp HOME and stubbed commands first on PATH.
# Nothing here touches the real Dock, menu bar, wallpaper, Finder, LaunchAgents or Ammonia.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export W7_STUB_LOG="$tmp/stub.log"
export W7_BUILD_DIR="$tmp/build"
export W7_ASSETS_SRC="$tmp/Assets"
export W7_TWEAK_DIR="$tmp/tweaks"
# Terminal preferences go to a plist under $tmp (defaults accepts a path as the domain), never com.apple.Terminal.
export W7_TERMINAL_DOMAIN="$tmp/prefs/com.apple.Terminal"
export W7_LOGIN_SHELL=/bin/zsh
mkdir -p "$HOME" "$tmp/bin" "$tmp/tweaks" "$W7_BUILD_DIR/Win7Shell.app/Contents/MacOS" \
         "$W7_ASSETS_SRC/fonts" "$W7_ASSETS_SRC/sounds" "$W7_ASSETS_SRC/reference" "$HOME/Library/Fonts" "$tmp/prefs"
: >"$W7_STUB_LOG"

fail() { echo "FAIL: $1"; exit 1; }
log_has() { grep -qF -- "$1" "$W7_STUB_LOG"; }

# --- stubs ---------------------------------------------------------------------------------------
for c in osascript killall launchctl sudo afconvert codesign open; do
    printf '#!/bin/sh\necho "$0 $*" >>"$W7_STUB_LOG"\n' >"$tmp/bin/$c"
done
cat >"$tmp/bin/launchctl" <<'S'
#!/bin/sh
echo "$0 $*" >>"$W7_STUB_LOG"
[ "$1" = bootstrap ] && [ -n "${W7_STUB_FAIL_BOOTSTRAP:-}" ] && exit 5
exit 0
S
# pgrep: Terminal counts as running only when W7_STUB_TERMINAL_RUNNING is set.
cat >"$tmp/bin/pgrep" <<'S'
#!/bin/sh
echo "$0 $*" >>"$W7_STUB_LOG"
[ -n "${W7_STUB_TERMINAL_RUNNING:-}" ]
S
# osascript answers the three "get" queries install.sh records.
cat >"$tmp/bin/osascript" <<'S'
#!/bin/sh
echo "$0 $*" >>"$W7_STUB_LOG"
case "$*" in
  *"get autohide menu bar"*) echo false ;;
  *"get picture of first desktop"*) echo "${W7_STUB_PICTURE:-/Users/me/old.jpg}" ;;
esac
S
# defaults: the sandbox Terminal domain goes to the real tool (a plist under $tmp); the real Terminal domain is
# refused and flagged; everything else is logged and answered below.
cat >"$tmp/bin/defaults" <<'S'
#!/bin/sh
case "$2" in "$W7_TERMINAL_DOMAIN") echo "$0 $*" >>"$W7_STUB_LOG"; exec /usr/bin/defaults "$@" ;; esac
case "$*" in *com.apple.Terminal*) echo "REAL-TERMINAL-DOMAIN $0 $*" >>"$W7_STUB_LOG"; exit 1 ;; esac
echo "$0 $*" >>"$W7_STUB_LOG"
[ "$1" = read ] || exit 0
case "$*" in
  *autohide-delay*) echo 0.5 ;;
  *com.apple.dock\ autohide) exit 1 ;;
  *CreateDesktop*) echo 1 ;;
  *beep.sound*) exit 1 ;;
  *) exit 1 ;;
esac
S
# sips: "-g format" answers from the extension (png, jpg/jpeg; anything else is unreadable); a conversion
# writes "converted <source content>" to the --out file.
cat >"$tmp/bin/sips" <<'S'
#!/bin/sh
echo "$0 $*" >>"$W7_STUB_LOG"
if [ "$1" = -g ]; then
    case "$3" in
      *.png) printf '%s\n  format: png\n' "$3" ;;
      *.jpg|*.jpeg) printf '%s\n  format: jpeg\n' "$3" ;;
      *) echo "Error 13: an unknown error occurred" >&2; exit 13 ;;
    esac
    exit 0
fi
src=""; out=""
while [ $# -gt 0 ]; do
    case "$1" in -s) shift 2 ;; --out) out="$2"; shift 2 ;; *) src="$1"; shift ;; esac
done
echo "converted $(cat "$src")" >"$out"
S
# cp and mv log, then do the real thing, so the atomic-install sequence can be asserted.
for c in cp mv; do
    printf '#!/bin/sh\necho "$0 $*" >>"$W7_STUB_LOG"\nexec /bin/%s "$@"\n' "$c" >"$tmp/bin/$c"
done
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"

# Safety net: refuse to continue unless every system-touching command resolves to a stub.
for c in defaults osascript killall launchctl sudo afconvert codesign open pgrep cp mv sips; do
    [ "$(command -v $c)" = "$tmp/bin/$c" ] || fail "stub for $c is not first on PATH"
done

# --- fixtures ------------------------------------------------------------------------------------
cat >"$W7_BUILD_DIR/Win7Shell.app/Contents/MacOS/Win7Shell" <<'S'
#!/bin/sh
[ "$1" = --write-default-wallpaper ] && { echo png >"$2"; exit 0; }
exit 0
S
chmod +x "$W7_BUILD_DIR/Win7Shell.app/Contents/MacOS/Win7Shell"
echo dylib >"$W7_BUILD_DIR/Win7Chrome.dylib"
echo font1 >"$W7_ASSETS_SRC/fonts/segoeui.ttf"
echo font2 >"$W7_ASSETS_SRC/fonts/segoeuib.ttf"
echo font3 >"$W7_ASSETS_SRC/fonts/Segoe UI Light.ttf"
echo mine >"$HOME/Library/Fonts/segoeuib.ttf"       # already installed by the user: must survive uninstall
echo wav >"$W7_ASSETS_SRC/sounds/alert.wav"
echo shot >"$W7_ASSETS_SRC/reference/shot.png"
echo old >"$tmp/tweaks/Win7Chrome.dylib"
# Terminal before install: default profile Basic, no startup profile, one existing profile.
/usr/bin/defaults write "$W7_TERMINAL_DOMAIN" "Default Window Settings" -string Basic
/usr/bin/defaults write "$W7_TERMINAL_DOMAIN" "Window Settings" -dict Basic '<dict><key>name</key><string>Basic</string></dict>'
mkdir -p "$HOME/.zsh_sessions" "$HOME/.zkbd"

env_file="$HOME/Library/Application Support/Win7Mac/restore.env"
cmd_dir="$HOME/Library/Application Support/Win7Mac/cmd-zsh"
cmd_profile="Win7 Command Prompt"
term_get() { /usr/bin/defaults read "$W7_TERMINAL_DOMAIN" "$1" 2>/dev/null; }
# profile_desc: the installed profile as key=value lines, colours as #RRGGBB@alpha (empty when it is missing).
profile_desc() {
    /usr/bin/defaults export "$W7_TERMINAL_DOMAIN" "$tmp/term-export.plist"
    swift "$root/scripts/make-terminal-profile.swift" --describe "$tmp/term-export.plist" "$cmd_profile" 2>/dev/null
}
# profile_absent: the export works and has no Command Prompt entry under "Window Settings".
profile_absent() {
    /usr/bin/defaults export "$W7_TERMINAL_DOMAIN" "$tmp/term-export.plist" || return 1
    /usr/libexec/PlistBuddy -c "Print ':Window Settings'" "$tmp/term-export.plist" >/dev/null 2>&1 || return 1
    ! /usr/libexec/PlistBuddy -c "Print ':Window Settings:$cmd_profile'" "$tmp/term-export.plist" >/dev/null 2>&1
}
term_backup="$HOME/Library/Application Support/Win7Mac/com.apple.Terminal.before.plist"
running_note="Terminal is running"

# --- install -------------------------------------------------------------------------------------
"$root/scripts/install.sh" >"$tmp/out1" 2>&1 || { cat "$tmp/out1"; fail "install.sh exits 0"; }

log_has "defaults write com.apple.dock autohide-delay -float 1000" || fail "dock autohide-delay write"
log_has "tell dock preferences to set autohide menu bar to true" || fail "menu bar autohide"
log_has "defaults write com.apple.finder CreateDesktop -bool false" || fail "finder CreateDesktop false"
log_has "killall Finder" || fail "killall Finder"
log_has "killall Dock" || fail "killall Dock"
log_has "launchctl bootstrap" || fail "launchctl bootstrap"
grep -q "^DOCK_AUTOHIDE_DELAY=0.5$" "$env_file" || fail "restore.env DOCK_AUTOHIDE_DELAY"
grep -q "^DOCK_AUTOHIDE=__unset__$" "$env_file" || fail "restore.env DOCK_AUTOHIDE unset"
grep -q "^FINDER_CREATEDESKTOP=1$" "$env_file" || fail "restore.env FINDER_CREATEDESKTOP"
[ "$(sort "$HOME/Library/Application Support/Win7Mac/fonts.list")" = "$(printf 'Segoe UI Light.ttf\nsegoeui.ttf')" ] || fail "fonts.list lists only the copied fonts"
[ -f "$HOME/Library/Fonts/Segoe UI Light.ttf" ] || fail "font with space copied"
[ -f "$HOME/Library/Fonts/segoeui.ttf" ] || fail "font copied"
[ "$(cat "$HOME/Library/Fonts/segoeuib.ttf")" = mine ] || fail "pre-existing font not overwritten"
[ -d "$HOME/Library/Application Support/Win7Mac/Assets/sounds" ] || fail "assets copied"
[ ! -e "$HOME/Library/Application Support/Win7Mac/Assets/reference" ] || fail "Assets/reference must not be copied"
[ -f "$HOME/Library/Application Support/Win7Mac/wallpaper.png" ] || fail "default wallpaper generated"
grep -q "W7_LOGIN" "$HOME/Library/LaunchAgents/com.win7mac.shell.plist" || fail "launch agent written"
grep -q "$HOME/Applications/Win7Shell.app/Contents/MacOS/Win7Shell" "$HOME/Library/LaunchAgents/com.win7mac.shell.plist" || fail "launch agent path expanded"

# Atomic dylib install: temp name then mv -f, never a direct cp onto the final name; no sudo.
log_has "cp $W7_BUILD_DIR/Win7Chrome.dylib $W7_TWEAK_DIR/.Win7Chrome.dylib.new" || fail "dylib copied to temp name"
log_has "mv -f $W7_TWEAK_DIR/.Win7Chrome.dylib.new $W7_TWEAK_DIR/Win7Chrome.dylib" || fail "dylib mv -f onto final name"
grep -E "/cp .*Win7Chrome\.dylib( |$)" "$W7_STUB_LOG" | grep -v "\.new" | grep -q "$W7_TWEAK_DIR/Win7Chrome.dylib\$" && fail "direct cp onto final dylib name"
log_has "sudo" && fail "no sudo anywhere"
[ "$(cat "$tmp/tweaks/Win7Chrome.dylib")" = dylib ] || fail "dylib content installed"
[ "$(cat "$tmp/tweaks/Win7Chrome.dylib.blacklist")" = "$(printf '%s\n' loginwindow Dock WindowManager ControlCenter SystemUIServer NotificationCenter Spotlight SecurityAgent Win7Shell osascript SecurityPrivacyExtension HomePrivacySettingsExtension SecurityImprovementsExtension "Touch ID & Password" UsersGroups LockScreen PasswordsSettingsExtension)" ] || fail "blacklist content"
ls -A "$tmp/tweaks" | grep -q '\.new' && fail "temp files left behind"

# Terminal: the Command Prompt profile, imported through defaults (cfprefsd), never the real domain.
log_has "REAL-TERMINAL-DOMAIN" && fail "the real com.apple.Terminal domain was used"
log_has "defaults import $W7_TERMINAL_DOMAIN -" || fail "profile imported via defaults import"
[ -f "$W7_ASSETS_SRC/terminal/$cmd_profile.terminal" ] || fail "profile file generated in Assets/terminal"
desc="$(profile_desc)"
for line in "BackgroundColor=#000000@1" "TextColor=#C0C0C0@1" "TextBoldColor=#FFFFFF@1" "SelectionColor=#C0C0C0@0.5" \
            "CursorColor=#C0C0C0@1" "CursorType=1" "CursorBlink=true" "columnCount=80" "rowCount=25" \
            "ANSIBlackColor=#000000@1" "ANSIRedColor=#800000@1" "ANSIGreenColor=#008000@1" "ANSIYellowColor=#808000@1" \
            "ANSIBlueColor=#000080@1" "ANSIMagentaColor=#800080@1" "ANSICyanColor=#008080@1" "ANSIWhiteColor=#C0C0C0@1" \
            "ANSIBrightBlackColor=#808080@1" "ANSIBrightRedColor=#FF0000@1" "ANSIBrightGreenColor=#00FF00@1" \
            "ANSIBrightYellowColor=#FFFF00@1" "ANSIBrightBlueColor=#0000FF@1" "ANSIBrightMagentaColor=#FF00FF@1" \
            "ANSIBrightCyanColor=#00FFFF@1" "ANSIBrightWhiteColor=#FFFFFF@1" "WindowTitle=Command Prompt" \
            "ShowWindowSettingsNameInTitle=false" "ShowActiveProcessInTitle=false" "ShowRepresentedURLInTitle=false" \
            "ShowRepresentedURLPathInTitle=false" "ShowShellCommandInTitle=false" "ShowDimensionsInTitle=false" \
            "FontAntialias=true" "name=$cmd_profile" "type=Window Settings" "RunCommandAsShell=false" \
            "noWarnProcesses=[ProcessName=login, ProcessName=sh, ProcessName=-sh, ProcessName=zsh, ProcessName=-zsh, ProcessName=bash, ProcessName=-bash, ProcessName=screen, ProcessName=tmux]"; do
    print -r -- "$desc" | grep -qxF -- "$line" || fail "profile has $line"
done
print -r -- "$desc" | grep -qxE "Font=(LucidaConsole|Menlo-Regular) 12" || fail "profile font Lucida Console or Menlo 12"
print -r -- "$desc" | grep -qxF "CommandString=/usr/bin/env /bin/sh -c '[ -r \"\$1/.zshenv\" ] && export ZDOTDIR=\"\$1\"; exec \"\$2\" -l' sh '$cmd_dir' '/bin/zsh'" || fail "CommandString starts zsh with the cmd-zsh ZDOTDIR"
# One-time backup of Terminal's preferences, taken before the first change.
[ "$(/usr/libexec/PlistBuddy -c "Print ':Default Window Settings'" "$term_backup")" = Basic ] || fail "Terminal preferences backed up before the change"
/usr/libexec/PlistBuddy -c "Print ':Window Settings:$cmd_profile'" "$term_backup" >/dev/null 2>&1 && fail "backup is from before the install"
cp -p "$term_backup" "$tmp/term-backup.first"
log_has "pgrep -xq Terminal" || fail "install checks whether Terminal is running"
grep -qF "$running_note" "$tmp/out1" && fail "no Terminal warning while Terminal is not running"
[ "$(readlink "$cmd_dir/.zkbd")" = "$HOME/.zkbd" ] || fail "zkbd key definitions stay in ~/.zkbd"
[ "$(term_get "Default Window Settings")" = "$cmd_profile" ] || fail "Terminal default profile set"
[ "$(term_get "Startup Window Settings")" = "$cmd_profile" ] || fail "Terminal startup profile set"
/usr/bin/defaults read "$W7_TERMINAL_DOMAIN" "Window Settings" | grep -q "Basic" || fail "existing Terminal profiles kept"
grep -q "^TERMINAL_DEFAULT_PROFILE=Basic$" "$env_file" || fail "restore.env TERMINAL_DEFAULT_PROFILE"
grep -q "^TERMINAL_STARTUP_PROFILE=__unset__$" "$env_file" || fail "restore.env TERMINAL_STARTUP_PROFILE unset"
grep -qF "Existing Terminal windows keep their profile" "$tmp/out1" || fail "note about existing Terminal windows"
for f in .zshenv .zprofile .zshrc .zlogin win7-cmd.zsh; do
    [ -f "$cmd_dir/$f" ] || fail "cmd-zsh $f installed"
done
[ "$(readlink "$cmd_dir/.zsh_sessions")" = "$HOME/.zsh_sessions" ] || fail "Terminal session state stays in ~/.zsh_sessions"
log_has "/open " && fail "install must not open Terminal"

# --- idempotence ---------------------------------------------------------------------------------
cp -p "$env_file" "$tmp/restore.before"
"$root/scripts/install.sh" >/dev/null 2>&1 || fail "second install exits 0"
cmp -s "$env_file" "$tmp/restore.before" || fail "second install leaves restore.env byte-identical"

# restore.env from an older install has no Terminal keys: the next run appends them, recorded keys untouched.
grep -v '^TERMINAL_' "$tmp/restore.before" >"$env_file"
cp -p "$env_file" "$tmp/restore.old"
/usr/bin/defaults write "$W7_TERMINAL_DOMAIN" "Default Window Settings" -string Basic
/usr/bin/defaults write "$W7_TERMINAL_DOMAIN" "Startup Window Settings" -string Pro
"$root/scripts/install.sh" >/dev/null 2>&1 || fail "install with an old restore.env exits 0"
[ "$(head -n "$(wc -l <"$tmp/restore.old")" "$env_file")" = "$(cat "$tmp/restore.old")" ] || fail "recorded keys untouched"
grep -q "^TERMINAL_DEFAULT_PROFILE=Basic$" "$env_file" || fail "TERMINAL_DEFAULT_PROFILE appended"
grep -q "^TERMINAL_STARTUP_PROFILE=Pro$" "$env_file" || fail "TERMINAL_STARTUP_PROFILE appended"
[ "$(grep -c '^TERMINAL_' "$env_file")" -eq 2 ] || fail "Terminal keys appended once"
# A key missing while Terminal already uses the profile (restore.env edited by hand) is recorded as unset.
grep -v '^TERMINAL_STARTUP_PROFILE=' "$env_file" >"$tmp/restore.edit"; cat "$tmp/restore.edit" >"$env_file"
"$root/scripts/install.sh" >/dev/null 2>&1 || fail "install with a missing key exits 0"
grep -q "^TERMINAL_STARTUP_PROFILE=__unset__$" "$env_file" || fail "own profile never recorded as the original"
grep -q "^TERMINAL_DEFAULT_PROFILE=Basic$" "$env_file" || fail "other Terminal key kept"
# Back to the state of the first install for the uninstall checks.
cp -p "$tmp/restore.before" "$env_file"

# --- uninstall -----------------------------------------------------------------------------------
: >"$W7_STUB_LOG"
"$root/scripts/uninstall.sh" >"$tmp/out2" 2>&1 || { cat "$tmp/out2"; fail "uninstall.sh exits 0"; }
log_has "defaults write com.apple.dock autohide-delay -float 0.5" || fail "restore autohide-delay"
log_has "defaults delete com.apple.dock autohide" || fail "delete autohide"
log_has "defaults write com.apple.finder CreateDesktop -bool true" || fail "restore CreateDesktop"
log_has "defaults delete -g com.apple.sound.beep.sound" || fail "delete beep sound"
log_has "set autohide menu bar to false" || fail "restore menu bar"
log_has "-- /Users/me/old.jpg" || fail "restore wallpaper"
log_has "killall Finder" || fail "uninstall killall Finder"
log_has "sudo" && fail "no sudo in uninstall"
[ ! -e "$env_file" ] || fail "restore.env removed"
[ ! -e "$HOME/Library/Fonts/segoeui.ttf" ] || fail "installed font removed"
[ ! -e "$HOME/Library/Fonts/Segoe UI Light.ttf" ] || fail "installed font with space removed"
[ -f "$HOME/Library/Fonts/segoeuib.ttf" ] || fail "pre-existing font kept"
[ ! -e "$tmp/tweaks/Win7Chrome.dylib" ] || fail "dylib removed"
[ ! -e "$HOME/Library/LaunchAgents/com.win7mac.shell.plist" ] || fail "launch agent removed"
[ ! -e "$HOME/Applications/Win7Shell.app" ] || fail "app removed"
log_has "REAL-TERMINAL-DOMAIN" && fail "uninstall used the real com.apple.Terminal domain"
[ "$(term_get "Default Window Settings")" = Basic ] || fail "Terminal default profile restored"
term_get "Startup Window Settings" >/dev/null && fail "Terminal startup profile deleted (was unset)"
profile_absent || fail "Command Prompt profile removed"
cmp -s "$term_backup" "$tmp/term-backup.first" || fail "Terminal backup never overwritten, and kept by uninstall"
/usr/bin/defaults read "$W7_TERMINAL_DOMAIN" "Window Settings" | grep -q "Basic" || fail "other Terminal profiles kept"
[ ! -e "$cmd_dir" ] || fail "cmd-zsh removed"
[ -d "$HOME/.zsh_sessions" ] || fail "~/.zsh_sessions kept"

# --- no Ammonia ----------------------------------------------------------------------------------
export W7_TWEAK_DIR="$tmp/none"
out="$("$root/scripts/install.sh" 2>&1)"; rc=$?
[ $rc -eq 0 ] || fail "install without Ammonia exits 0"
echo "$out" | grep -qF "Ammonia not found — skipping Win7Chrome" || fail "Ammonia-missing message"
[ ! -e "$tmp/none" ] || fail "tweak dir must not be created"

# ------------------------------------------------------------------------------------
export W7_TWEAK_DIR="$tmp/tweaks"
support="$HOME/Library/Application Support/Win7Mac"
rm -rf "$support" "$HOME/Library/Fonts"/* ; mkdir -p "$HOME/Library/Fonts"

# Missing app: exit 1 before any setting changes.
: >"$W7_STUB_LOG"
W7_BUILD_DIR="$tmp/nobuild" "$root/scripts/install.sh" >"$tmp/out3" 2>&1 && fail "missing app must exit 1"
grep -q "make shell" "$tmp/out3" || fail "missing app message"
log_has "defaults write" && fail "missing app: no defaults written"
[ ! -e "$support/restore.env" ] || fail "missing app: nothing recorded"

# launchctl bootstrap failure: warns, still installs the dylib, exits 0.
rm -f "$tmp/tweaks/Win7Chrome.dylib"
W7_STUB_FAIL_BOOTSTRAP=1 "$root/scripts/install.sh" >"$tmp/out4" 2>&1 || fail "bootstrap failure must not abort"
grep -q "launchctl bootstrap failed" "$tmp/out4" || fail "bootstrap failure warning printed"
[ -f "$tmp/tweaks/Win7Chrome.dylib" ] || fail "dylib installed despite bootstrap failure"

# Wallpaper goes in as an argv item, not inside the script literal; "missing value" is recorded as unset.
log_has "on run argv" || fail "wallpaper via argv"
rm -rf "$support"
W7_STUB_PICTURE="missing value" "$root/scripts/install.sh" >/dev/null 2>&1 || fail "install with missing value"
grep -q "^WALLPAPER=__unset__$" "$support/restore.env" || fail "missing value recorded as unset"

# Later install adds only fonts that are new, and records them.
echo font4 >"$W7_ASSETS_SRC/fonts/New One.ttf"
"$root/scripts/install.sh" >/dev/null 2>&1 || fail "reinstall with a new font"
grep -qxF "New One.ttf" "$support/fonts.list" || fail "new font appended to fonts.list"
[ "$(grep -c . "$support/fonts.list")" -eq 1 ] || fail "fonts.list records only the new font"

# Uninstall with one key missing from restore.env: exits 0, the other keys are still restored.
sed -i '' '/^FINDER_CREATEDESKTOP=/d' "$support/restore.env"
: >"$W7_STUB_LOG"
"$root/scripts/uninstall.sh" >"$tmp/out5" 2>&1 || { cat "$tmp/out5"; fail "uninstall with missing key exits 0"; }
log_has "defaults write com.apple.dock autohide-delay -float 0.5" || fail "other keys still restored"
log_has "defaults delete com.apple.finder CreateDesktop" || fail "missing key treated as unset"
[ ! -e "$HOME/Library/Fonts/New One.ttf" ] || fail "fonts removed"

# Uninstall with an empty restore.env also exits 0.
"$root/scripts/install.sh" >/dev/null 2>&1; : >"$support/restore.env"
"$root/scripts/uninstall.sh" >/dev/null 2>&1 || fail "uninstall with empty restore.env exits 0"

# Uninstall without restore.env: macOS defaults, and fonts.list still processed.
"$root/scripts/install.sh" >/dev/null 2>&1; rm -f "$support/restore.env"
echo x >"$HOME/Library/Fonts/Orphan.ttf"; echo Orphan.ttf >>"$support/fonts.list"
: >"$W7_STUB_LOG"
"$root/scripts/uninstall.sh" >/dev/null 2>&1 || fail "uninstall without restore.env exits 0"
log_has "defaults delete com.apple.dock autohide-delay" || fail "fallback deletes autohide-delay"
log_has "defaults delete com.apple.dock autohide" || fail "fallback deletes autohide"
log_has "defaults delete com.apple.finder CreateDesktop" || fail "fallback deletes CreateDesktop"
log_has "set autohide menu bar to false" || fail "fallback shows menu bar"
log_has "killall Dock" && log_has "killall Finder" || fail "fallback restarts Dock and Finder"
[ ! -e "$HOME/Library/Fonts/Orphan.ttf" ] || fail "fonts.list processed without restore.env"
profile_absent || fail "fallback removes the Command Prompt profile"
term_get "Default Window Settings" >/dev/null && fail "fallback deletes the default profile that pointed at it"
term_get "Startup Window Settings" >/dev/null && fail "fallback deletes the startup profile that pointed at it"
[ ! -e "$cmd_dir" ] || fail "fallback removes cmd-zsh"

# --- Terminal profile ------------------------------------------------------------------------------
# A profile the user picked after install is theirs: uninstall restores only keys still set to ours.
rm -rf "$support"
/usr/bin/defaults write "$W7_TERMINAL_DOMAIN" "Default Window Settings" -string Basic
/usr/bin/defaults write "$W7_TERMINAL_DOMAIN" "Startup Window Settings" -string Basic
"$root/scripts/install.sh" >/dev/null 2>&1 || fail "install for the Terminal checks"
/usr/bin/defaults write "$W7_TERMINAL_DOMAIN" "Startup Window Settings" -string Homebrew
"$root/scripts/uninstall.sh" >/dev/null 2>&1 || fail "uninstall for the Terminal checks"
[ "$(term_get "Default Window Settings")" = Basic ] || fail "default profile restored"
[ "$(term_get "Startup Window Settings")" = Homebrew ] || fail "a profile chosen after install is kept"

# Terminal running: install and uninstall warn, and still never quit or open Terminal.
: >"$W7_STUB_LOG"
W7_STUB_TERMINAL_RUNNING=1 "$root/scripts/install.sh" >"$tmp/out6" 2>&1 || fail "install while Terminal runs exits 0"
grep -qF "$running_note" "$tmp/out6" || fail "install warns that Terminal is running"
grep -qF "Terminal ▸ Settings ▸ Profiles" "$tmp/out6" || fail "install warning says where to check"
W7_STUB_TERMINAL_RUNNING=1 "$root/scripts/uninstall.sh" >"$tmp/out7" 2>&1 || fail "uninstall while Terminal runs exits 0"
grep -qF "$running_note" "$tmp/out7" || fail "uninstall warns that Terminal is running"
grep -E "killall.*Terminal|quit|/open " "$W7_STUB_LOG" | grep -q . && fail "Terminal is never quit or opened"
profile_absent || fail "profile removed while Terminal runs"

# Login shell other than zsh: no CommandString, Terminal runs that shell as usual.
W7_LOGIN_SHELL=/bin/bash "$root/scripts/install.sh" >/dev/null 2>&1 || fail "install with bash"
desc="$(profile_desc)"
print -r -- "$desc" | grep -qxF "columnCount=80" || fail "bash: profile installed"
print -r -- "$desc" | grep -q "^CommandString=" && fail "bash: no CommandString"
print -r -- "$desc" | grep -q "^RunCommandAsShell=" && fail "bash: no RunCommandAsShell"
"$root/scripts/uninstall.sh" >/dev/null 2>&1 || fail "uninstall after bash install"

# CommandString falls back to a plain login shell when cmd-zsh is gone (a profile left behind by a partial
# uninstall). Run through /bin/sh -c, plain and as Terminal's "exec -la", with a fake zsh that reports.
fake="$tmp/fake shell"; cmd_test="$tmp/cmd dir's"; mkdir -p "$fake" "$cmd_test"; : >"$cmd_test/.zshenv"
printf '#!/bin/sh\nprintf "ZDOTDIR=%%s args=%%s\\n" "${ZDOTDIR-unset}" "$*"\n' >"$fake/zsh"; chmod +x "$fake/zsh"
W7_LOGIN_SHELL="$fake/zsh" swift "$root/scripts/make-terminal-profile.swift" "$tmp/cs.terminal" "$cmd_test" || fail "profile for the CommandString checks"
cs="$(swift "$root/scripts/make-terminal-profile.swift" --describe "$tmp/cs.terminal" | sed -n 's/^CommandString=//p')"
[ -n "$cs" ] || fail "CommandString present for a zsh login shell"
[ "$(env -u ZDOTDIR /bin/sh -c "$cs")" = "ZDOTDIR=$cmd_test args=-l" ] || fail "CommandString sets ZDOTDIR when cmd-zsh exists"
[ "$(env -u ZDOTDIR /bin/sh -c "exec -la zsh $cs")" = "ZDOTDIR=$cmd_test args=-l" ] || fail "CommandString works under exec -la"
rm -f "$cmd_test/.zshenv"
[ "$(env -u ZDOTDIR /bin/sh -c "$cs")" = "ZDOTDIR=unset args=-l" ] || fail "CommandString falls back without cmd-zsh"
[ "$(env -u ZDOTDIR /bin/sh -c "exec -la zsh $cs")" = "ZDOTDIR=unset args=-l" ] || fail "CommandString falls back under exec -la"

# Prompt: the path with / -> \ under C:, then >.
prompt_of() { /bin/zsh -f -c 'source "$1/scripts/cmd-zsh/win7-cmd.zsh"; w7_cmd_prompt "$2"' zsh "$root" "$1"; }
[ "$(prompt_of /Users/someone/project)" = 'C:\Users\someone\project>' ] || fail "prompt for /Users/someone/project"
[ "$(prompt_of /)" = 'C:\>' ] || fail "prompt for /"
[ "$(prompt_of /tmp/x)" = 'C:\tmp\x>' ] || fail "prompt for /tmp/x"

# Startup chain, in a sandboxed environment: the user's own files run in zsh's order with ZDOTDIR=$HOME, the
# prompt is the Command Prompt one (a % in a folder name stays literal), and ZDOTDIR is the user's afterwards.
"$root/scripts/install.sh" >/dev/null 2>&1 || fail "install for the startup chain"
u="$tmp/zuser"; mkdir -p "$u/.config/zsh" "$tmp/50%"
for f in .zshenv .zprofile .zshrc .zlogin; do
    printf 'print -r -- "%s ZDOTDIR=$ZDOTDIR" >>"$HOME/order"\n' "$f" >"$u/$f"
done
printf 'PS1="user> "; RPS1=right; typeset w7_test_rc=kept\n' >>"$u/.zshrc"
env -i HOME="$u" PATH=/usr/bin:/bin TERM=dumb ZDOTDIR="$cmd_dir" /bin/zsh -i -l -c \
    'cd "$1"; for f in $precmd_functions; do $f; done; print -r -- "PS1=$PS1|RPS1=$RPS1|ZDOTDIR=${ZDOTDIR-unset}|HISTFILE=$HISTFILE|rc=$w7_test_rc"' \
    zsh "$tmp/50%" >"$tmp/chain" 2>"$tmp/chain.err" || { cat "$tmp/chain.err"; fail "cmd zsh starts"; }
[ "$(cat "$u/order")" = "$(printf '%s ZDOTDIR=%s\n' .zshenv "$u" .zprofile "$u" .zshrc "$u" .zlogin "$u")" ] || fail "user startup files sourced in order with ZDOTDIR=\$HOME"
win_path() { print -r -- "C:$(print -r -- "$1" | tr / '\\')"; }
expect="PS1=$(win_path "$tmp/50%%")>|RPS1=|ZDOTDIR=unset|HISTFILE=$u/.zsh_history|rc=kept"
[ "$(cat "$tmp/chain")" = "$expect" ] || { print -r -- "got:      $(cat "$tmp/chain")"; print -r -- "expected: $expect"; fail "cmd zsh prompt and environment"; }
[ ! -s "$tmp/chain.err" ] || { cat "$tmp/chain.err"; fail "cmd zsh startup is silent"; }

# Inside Terminal (/etc/zshrc_Apple_Terminal, per-session history): the shared history file is the user's, and the
# commands typed reach it on exit; nothing is left in cmd-zsh.
uh="$tmp/zhist"; mkdir -p "$uh"
printf 'print -r -- "HISTFILE=$HISTFILE|SHARED=$SHELL_SESSION_HISTFILE_SHARED" >"$HOME/vars"\n' >"$uh/.zlogin"
print -r -- 'echo w7-history-marker' | env -i HOME="$uh" PATH=/usr/bin:/bin TERM=dumb TERM_PROGRAM=Apple_Terminal \
    TERM_SESSION_ID=test ZDOTDIR="$cmd_dir" /bin/zsh -i -l >/dev/null 2>&1
[ "$(cat "$uh/vars")" = "HISTFILE=$uh/.zsh_history|SHARED=$uh/.zsh_history" ] || { cat "$uh/vars"; fail "Terminal session history uses the user's file"; }
[ ! -e "$cmd_dir/.zsh_history" ] || fail "no history in cmd-zsh"
grep -qx 'echo w7-history-marker' "$uh/.zsh_history" 2>/dev/null || fail "typed command saved to the user's history"

# A user whose ~/.zshenv moves the dotfiles (ZDOTDIR=~/.config/zsh): the rest come from there.
rm -f "$u/order" "$u/.zprofile" "$u/.zshrc" "$u/.zlogin"
printf 'ZDOTDIR="$HOME/.config/zsh"\n' >>"$u/.zshenv"
printf 'print -r -- "config-rc ZDOTDIR=$ZDOTDIR" >>"$HOME/order"\n' >"$u/.config/zsh/.zshrc"
env -i HOME="$u" PATH=/usr/bin:/bin TERM=dumb ZDOTDIR="$cmd_dir" /bin/zsh -i -l -c 'print -r -- "$ZDOTDIR|$PS1"' \
    >"$tmp/chain" 2>"$tmp/chain.err" || fail "cmd zsh with a moved ZDOTDIR starts"
[ "$(cat "$u/order")" = "$(printf '%s\n' ".zshenv ZDOTDIR=$u" "config-rc ZDOTDIR=$u/.config/zsh")" ] || fail "moved ZDOTDIR followed"
[ "$(cat "$tmp/chain")" = "$u/.config/zsh|$(win_path "$(pwd -P)")>" ] || { cat "$tmp/chain"; fail "moved ZDOTDIR kept after startup"; }
"$root/scripts/uninstall.sh" >/dev/null 2>&1 || fail "uninstall after the startup chain"
log_has "REAL-TERMINAL-DOMAIN" && fail "the real com.apple.Terminal domain was used"

# --- wallpaper ---------------------------------------------------------------------------
wp="$support/wallpaper.png"
set_wp() { log_has "set picture to (item 1 of argv)" && log_has "-- $1"; }
rm -rf "$support"
: >"$W7_STUB_LOG"
"$root/scripts/install.sh" >/dev/null 2>&1 || fail "wallpaper: first install"
[ "$(cat "$wp")" = png ] && set_wp "$wp" || fail "first install generates and sets the default wallpaper"

# Re-run while the desktop still shows our previous default: regenerated and set again.
echo stale >"$wp"; : >"$W7_STUB_LOG"
W7_STUB_PICTURE="$wp" "$root/scripts/install.sh" >/dev/null 2>&1 || fail "wallpaper: re-run over our default"
[ "$(cat "$wp")" = png ] || fail "re-run regenerates the default while it is the desktop picture"
set_wp "$wp" || fail "re-run sets the regenerated default"

# Re-run after the user chose another picture: neither regenerated nor set.
echo stale >"$wp"; : >"$W7_STUB_LOG"
W7_STUB_PICTURE=/Users/me/mine.jpg "$root/scripts/install.sh" >"$tmp/out8" 2>&1 || fail "wallpaper: re-run over the user's picture"
[ "$(cat "$wp")" = stale ] || fail "re-run leaves the default alone when the user chose another picture"
log_has "set picture to" && fail "re-run never overrides the user's picture"
grep -qF "keeping the current desktop picture" "$tmp/out8" || fail "re-run says the picture is kept"
grep -q "^WALLPAPER=/Users/me/old.jpg$" "$support/restore.env" || fail "the original wallpaper stays recorded"

# An imported wallpaper.jpg is applied on every run.
echo harmony >"$W7_ASSETS_SRC/wallpaper.jpg"; : >"$W7_STUB_LOG"
W7_STUB_PICTURE=/Users/me/mine.jpg "$root/scripts/install.sh" >/dev/null 2>&1 || fail "wallpaper: install with wallpaper.jpg"
set_wp "$support/Assets/wallpaper.jpg" || fail "imported wallpaper.jpg is set"
rm -f "$W7_ASSETS_SRC/wallpaper.jpg"

# make wallpaper SRC=...: the Makefile target, sandboxed through W7_ASSETS_SRC and HOME.
mkwall() { make -s -C "$root" CODESIGN_IDENTITY=- wallpaper "$@"; }
echo harmony >"$tmp/img0.jpg"; echo pixels >"$tmp/pic.png"; echo text >"$tmp/notes.txt"
mkwall >"$tmp/out9" 2>&1 && fail "make wallpaper without SRC fails"
grep -qF "usage: make wallpaper SRC=<image>" "$tmp/out9" || fail "make wallpaper usage"
mkwall SRC="$tmp/nope.jpg" >/dev/null 2>&1 && fail "make wallpaper with a missing file fails"
[ ! -e "$W7_ASSETS_SRC/wallpaper.jpg" ] || fail "missing file: nothing imported"

: >"$W7_STUB_LOG"
mkwall SRC="$tmp/img0.jpg" >"$tmp/out10" 2>&1 || { cat "$tmp/out10"; fail "make wallpaper with a JPEG"; }
[ "$(cat "$W7_ASSETS_SRC/wallpaper.jpg")" = harmony ] || fail "JPEG copied to Assets/wallpaper.jpg"
[ "$(cat "$support/Assets/wallpaper.jpg")" = harmony ] || fail "JPEG copied into the installed Assets"
set_wp "$support/Assets/wallpaper.jpg" || fail "make wallpaper sets the imported picture"
log_has "sips -s" && fail "a JPEG is copied, not converted"
ls -A "$W7_ASSETS_SRC" "$support/Assets" | grep -q '\.new' && fail "make wallpaper leaves no temp files"

: >"$W7_STUB_LOG"
mkwall SRC="$tmp/pic.png" >/dev/null 2>&1 || fail "make wallpaper with a PNG"
[ "$(cat "$W7_ASSETS_SRC/wallpaper.jpg")" = "converted pixels" ] || fail "PNG converted to JPEG by sips"
[ "$(cat "$support/Assets/wallpaper.jpg")" = "converted pixels" ] || fail "converted picture installed"
log_has "sips -s format jpeg" || fail "conversion through sips"

: >"$W7_STUB_LOG"
mkwall SRC="$tmp/notes.txt" >"$tmp/out11" 2>&1 && fail "make wallpaper with a non-image fails"
[ "$(cat "$W7_ASSETS_SRC/wallpaper.jpg")" = "converted pixels" ] || fail "non-image: Assets/wallpaper.jpg unchanged"
log_has "set picture to" && fail "non-image: desktop picture not changed"

# Not installed yet: only imports; install records the original wallpaper first.
"$root/scripts/uninstall.sh" >/dev/null 2>&1 || fail "uninstall before the not-installed wallpaper check"
rm -rf "$support"; rm -f "$W7_ASSETS_SRC/wallpaper.jpg"; : >"$W7_STUB_LOG"
mkwall SRC="$tmp/img0.jpg" >"$tmp/out12" 2>&1 || fail "make wallpaper before install exits 0"
[ "$(cat "$W7_ASSETS_SRC/wallpaper.jpg")" = harmony ] || fail "not installed: imported into Assets"
log_has "set picture to" && fail "not installed: desktop picture not changed"
[ ! -e "$support/restore.env" ] || fail "not installed: nothing recorded"
grep -qF "make install" "$tmp/out12" || fail "not installed: points to make install"
rm -f "$W7_ASSETS_SRC/wallpaper.jpg"

# set-wallpaper.sh: one picture argument, passed as argv.
"$root/scripts/set-wallpaper.sh" >/dev/null 2>&1 && fail "set-wallpaper.sh without arguments fails"
: >"$W7_STUB_LOG"
"$root/scripts/set-wallpaper.sh" "$tmp/a b.jpg" || fail "set-wallpaper.sh <picture>"
set_wp "$tmp/a b.jpg" || fail "set-wallpaper.sh passes the picture as argv"

# make import-icons: the user's imageres-#N.ico pack, imported in a sandbox (W7_ASSETS_SRC, HOME).
# The .ico fixture is generated here: two 32-bpp images, 1x1 and 2x2, so "largest representation" is checked.
(cd "$root" && swift build --product Win7AssetTool >/dev/null 2>&1) || fail "icons: cannot build Win7AssetTool"
export W7_ASSET_TOOL="$root/.build/debug/Win7AssetTool"
ico="$tmp/icons-fx/fixture.ico"; mkdir -p "$tmp/icons-fx"
{
    echo 000001000200
    echo 0101000001002000 30000000 26000000
    echo 0202000001002000 40000000 56000000
    echo 28000000 01000000 02000000 0100 2000 000000000000000000000000000000000000000000000000 0000ffff 00000000
    echo 28000000 02000000 04000000 0100 2000 000000000000000000000000000000000000000000000000
    echo 00ff00ff00ff00ff00ff00ff00ff00ff 00000000 00000000
} | xxd -r -p >"$ico"
pngw() { [ "$(xxd -l 8 -p "$1" 2>/dev/null)" = 89504e470d0a1a0a ] && printf '%d' "0x$(xxd -s 16 -l 4 -p "$1")"; }
icons() { "$root/scripts/import-icons.sh" "$@"; }
pack="$tmp/icons-src/imageres-pack1"; mkdir -p "$pack/sub"
cp "$ico" "$pack/imageres-#3.ico"; cp "$ico" "$pack/imageres-#2.ico"; cp "$ico" "$pack/sub/imageres-#19.ico"
cp "$ico" "$pack/imageres-#5.ico"                     # not in the map: contact sheet only
echo junk >"$pack/imageres-#21.ico"                   # corrupt: skipped, the rest still imported
echo text >"$pack/readme.txt"                        # not an icon: ignored
cp "$ico" "$pack/shell32-#3.ico"; cp "$ico" "$pack/unknown-#5.ico"  # other DLLs' unlisted ids: contact sheet only
cp "$ico" "$pack/shell32-#25.ico"                     # a <dll>:<id> line of the map (run.png)
cp "$ico" "$pack/photoshop1.ico"                      # neither an id nor named in the map: skipped
cp "$ico" "$pack/explorer.ico"; cp "$ico" "$pack/sub/TaskMgr.ICO"   # mapped by file name (any case)
ln -s /etc/hosts "$pack/imageres-#22.ico"             # symlinks are never followed
(cd "$pack" && /usr/bin/zip -qry "$tmp/icons-src/imageres-pack1.zip" .) || fail "icons: cannot zip the fixture"
A="$W7_ASSETS_SRC"; S="$support/Assets"
rm -rf "$A/icons" "$A/_contact" "$support"; mkdir -p "$S"   # installed
before="$(ls -AR "$tmp/icons-src")"

out="$(icons "$tmp/icons-src/imageres-pack1.zip" 2>&1)" || { print -r -- "$out"; fail "icons: zip import exits 0"; }
for n in folder file file-text app-com.apple.finder app-com.apple.ActivityMonitor run; do
    [ "$(pngw "$A/icons/$n.png")" = 2 ] || { print -r -- "$out"; fail "icons: $n.png is the 2 px (largest) image"; }
    cmp -s "$A/icons/$n.png" "$S/icons/$n.png" || fail "icons: $n.png copied into the installed Assets"
done
[ "$(pngw "$A/_contact/pack1/imageres-5.png")" = 2 ] || fail "icons: unknown id 5 goes to the contact sheet"
[ "$(pngw "$A/_contact/pack1/unknown-5.png")" = 2 ] || fail "icons: another DLL's unknown id goes to the contact sheet"
[ "$(pngw "$A/_contact/pack1.png")" -ge 48 ] || fail "icons: the pack's contact sheet montage"
[ ! -e "$A/icons/imageres-5.png" ] && [ ! -e "$S/_contact" ] || fail "icons: unknown id only in Assets/_contact"
[ "$(ls "$A/icons" | LC_ALL=C sort | tr '\n' ' ')" = "app-com.apple.ActivityMonitor.png app-com.apple.finder.png file-text.png file.png folder.png run.png " ] \
    || { ls "$A/icons"; fail "icons: only mapped names in icons/"; }
print -r -- "$out" | grep -q '^skip photoshop1.ico: not in scripts/win7-icon-map.txt' || fail "icons: unmapped named icon reported"
print -r -- "$out" | grep -q '^contact _contact/pack1/shell32-3.png' || fail "icons: other DLL's unlisted icon reported"
[ "$(ls "$A/_contact/pack1" | tr '\n' ' ')" = 'imageres-5.png shell32-3.png unknown-5.png ' ] || fail "icons: contact sheet holds only the unknown ids"
print -r -- "$out" | grep -q '^skip imageres-#21.ico: ' || fail "icons: corrupt icon reported"
# A link stored in the zip is never followed: its entry holds the link text, which isn't an icon.
print -r -- "$out" | grep -q '^skip imageres-#22.ico: cannot convert' || fail "icons: zipped symlink not followed"
print -r -- "$out" | grep -q 'imageres-#112\|recycle' && fail "icons: ids absent from the pack are silent"
[ "$(ls -AR "$tmp/icons-src")" = "$before" ] || fail "icons: nothing extracted next to the source"

# Idempotent: a second run changes nothing and says so.
touch -t 200001010000 "$A/icons/folder.png"
out="$(icons "$tmp/icons-src/imageres-pack1.zip" 2>&1)" || fail "icons: re-run exits 0"
[ "$(stat -f %Sm -t %Y%m%d%H%M "$A/icons/folder.png")" = 200001010000 ] || fail "icons: re-run leaves same files alone"
print -r -- "$out" | grep -q '^same icons/folder.png' || fail "icons: re-run reports same"

# A file placed by hand is kept unless FORCE=1; the folder source works like the zip.
echo hand >"$A/icons/folder.png"; echo hand >"$S/icons/file.png"
out="$(icons "$pack" 2>&1)" || fail "icons: folder import exits 0"
[ "$(cat "$A/icons/folder.png")" = hand ] && [ "$(cat "$S/icons/file.png")" = hand ] || fail "icons: hand-placed files kept"
print -r -- "$out" | grep -q '^keep icons/folder.png: .*FORCE=1' || fail "icons: kept file reported with FORCE hint"
print -r -- "$out" | grep -q 'imageres-#22' && fail "icons: symlink in a folder source ignored"
[ "$(ls "$A/_contact" | tr '\n' ' ')" = "pack1 pack1.png " ] || fail "icons: folder pack name from the folder"
out="$(FORCE=1 icons "$pack" 2>&1)" || fail "icons: FORCE=1 exits 0"
[ "$(pngw "$A/icons/folder.png")" = 2 ] && [ "$(pngw "$S/icons/file.png")" = 2 ] || fail "icons: FORCE=1 replaces"
ls -A "$A/icons" "$S/icons" | grep -q '\.new' && fail "icons: no temp files left"

# Not installed: only the repo Assets are written. PACK names the contact folder.
rm -rf "$A/icons" "$A/_contact" "$support"
out="$(PACK=part2 icons "$tmp/icons-src/imageres-pack1.zip" 2>&1)" || fail "icons: not installed exits 0"
[ -f "$A/icons/folder.png" ] && [ ! -e "$support" ] || fail "icons: not installed writes only Assets"
[ -f "$A/_contact/part2/imageres-5.png" ] && [ -f "$A/_contact/part2.png" ] || fail "icons: PACK names the contact folder"
print -r -- "$out" | grep -qF "make install" || fail "icons: not installed points to make install"

# Bad sources and the make target (W7_ASSET_TOOL set, so make doesn't build the release tool).
icons >/dev/null 2>&1 && fail "icons: no argument fails"
icons "$tmp/nope.zip" >/dev/null 2>&1 && fail "icons: missing source fails"
mkdir -p "$tmp/icons-empty"; icons "$tmp/icons-empty" >/dev/null 2>&1 && fail "icons: a folder without .ico files fails"
echo notzip >"$tmp/icons-src/bad.zip"; icons "$tmp/icons-src/bad.zip" >/dev/null 2>&1 && fail "icons: a corrupt zip fails"
make -s -C "$root" import-icons >"$tmp/out13" 2>&1 && fail "make import-icons without SRC fails"
grep -qF "usage: make import-icons SRC=" "$tmp/out13" || fail "make import-icons usage"
echo hand >"$A/icons/folder.png"
make -s -C "$root" import-icons SRC="$pack" FORCE=1 >"$tmp/out14" 2>&1 || { cat "$tmp/out14"; fail "make import-icons SRC=..."; }
[ "$(pngw "$A/icons/folder.png")" = 2 ] || fail "make import-icons passes FORCE"
rm -rf "$A/icons" "$A/_contact"
unset W7_ASSET_TOOL

# One blacklist source of truth.
grep -q "scripts/blacklist.txt" "$root/Makefile" || fail "Makefile uses scripts/blacklist.txt"
grep -q "Win7Shell" "$root/scripts/blacklist.txt" || fail "blacklist.txt content"
# the System Settings security panes run in processes of their own; nothing of ours loads in them.
for exe in SecurityPrivacyExtension HomePrivacySettingsExtension SecurityImprovementsExtension "Touch ID & Password" \
           UsersGroups LockScreen PasswordsSettingsExtension; do
    grep -qxF "$exe" "$root/scripts/blacklist.txt" || fail "blacklist.txt lists the security pane $exe"
done

echo "all install tests passed"
