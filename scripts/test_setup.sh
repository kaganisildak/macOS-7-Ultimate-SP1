#!/bin/zsh
# Tests scripts/setup.sh with a temp HOME, a fake Ammonia, a fake build and stubbed system commands first
# on PATH (csrutil, nvram, sysctl, security, launchctl, open, ...). install.sh and make are replaced by stubs
# that record their calls. Nothing here reads or changes the real SIP, NVRAM, Ammonia, keychain or install.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
setup="$root/scripts/setup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The icon preflight runs `Win7AssetTool icon-names` (IconCatalog.all): the real tool, built with the real HOME and
# PATH before both are replaced below (as scripts/test_import.sh builds it).
(cd "$root" && swift build --product Win7AssetTool >/dev/null 2>&1) || { echo "FAIL: cannot build Win7AssetTool"; exit 1; }
real_tool="$root/.build/debug/Win7AssetTool"
"$real_tool" icon-names >"$tmp/icon-names.txt" 2>/dev/null && [ -s "$tmp/icon-names.txt" ] \
    || { echo "FAIL: Win7AssetTool icon-names printed nothing"; exit 1; }
icon_total=$(wc -l <"$tmp/icon-names.txt" | tr -d ' ')

# A `make setup YES=1` that runs `make test` exports its command-line variables: never let them leak in.
unset CHECK YES FORCE SKIP_TESTS MAKEFLAGS MAKELEVEL
export W7_ASSET_TOOL="$real_tool"
unset W7_SETUP_ASSET_MAP
export HOME="$tmp/home"
export W7_STUB_LOG="$tmp/stub.log"
export W7_BUILD_DIR="$tmp/build"
export W7_ASSETS_SRC="$tmp/Assets"
export W7_SETUP_AMMONIA_DIR="$HOME/ammonia/core"       # under HOME so the report's ~ scrubbing shows
export W7_TWEAK_DIR="$W7_SETUP_AMMONIA_DIR/tweaks"
export W7_SETUP_AMMONIA_PLIST="$tmp/LaunchDaemons/com.bedtime.ammonia.plist"
export W7_SETUP_INSTALL="$tmp/fake-install.sh"
export W7_STUB_CLT_DIR="$tmp/clt"
export W7_STUB_ROOT="$root"
unset W7_SETUP_MAKE
report="$W7_BUILD_DIR/setup-report.txt"

fail() { echo "FAIL: $1"; exit 1; }
log_has() { grep -qF -- "$1" "$W7_STUB_LOG"; }
has() { grep -qF -- "$2" <<<"$1"; }

# --- stubs ---------------------------------------------------------------------------------------
# Every stub logs its call. A call setup.sh must never make is logged as "BAD ..." (checked after each run).
mkdir -p "$tmp/bin"
stub() { { echo '#!/bin/sh'; echo 'echo "$(basename "$0") $*" >>"$W7_STUB_LOG"'; cat; } >"$tmp/bin/$1"; chmod +x "$tmp/bin/$1"; }
stub csrutil <<'S'
[ "$*" = status ] || { echo "BAD csrutil $*" >>"$W7_STUB_LOG"; exit 1; }
echo "System Integrity Protection status: ${W7_STUB_SIP:-disabled}."
S
stub nvram <<'S'
[ "$*" = boot-args ] || { echo "BAD nvram $*" >>"$W7_STUB_LOG"; exit 1; }
[ -n "${W7_STUB_NVRAM-}" ] || { echo "nvram: Error getting variable - 'boot-args': (iokit/common) data was not found" >&2; exit 1; }
printf 'boot-args\t%s\n' "$W7_STUB_NVRAM"
S
stub sysctl <<'S'
case "$*" in
  "-n kern.bootargs") echo "${W7_STUB_ACTIVE-${W7_STUB_NVRAM-}}" ;;
  "-n hw.optional.arm64") echo 1 ;;
  *) echo "BAD sysctl $*" >>"$W7_STUB_LOG"; exit 1 ;;
esac
S
stub sw_vers <<'S'
echo "${W7_STUB_MACOS:-27.0.1}"
S
stub uname <<'S'
echo "${W7_STUB_ARCH:-arm64}"
S
stub xcode-select <<'S'
[ "$*" = -p ] || { echo "BAD xcode-select $*" >>"$W7_STUB_LOG"; exit 1; }
[ -z "${W7_STUB_NO_CLT-}" ] || { echo "xcode-select: error: unable to get active developer directory" >&2; exit 2; }
echo "$W7_STUB_CLT_DIR"
S
stub swift <<'S'
[ "$*" = --version ] || { echo "BAD swift $*" >>"$W7_STUB_LOG"; exit 1; }
echo "swift-driver version: 1.0 Apple Swift version ${W7_STUB_SWIFT:-6.4} (swiftlang-6.4)"
S
stub df <<'S'
echo "Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on"
echo "/dev/disk3s5 128462848 95453332 ${W7_STUB_FREE_KB:-20000000} 94% 1 1 1% /System/Volumes/Data"
S
stub security <<'S'
case "$1" in
  find-identity)
    printf '\nPolicy: Code Signing\n  Matching identities\n'
    [ -z "${W7_STUB_NO_IDENTITY-}" ] && echo '  1) FFAFB232513B94517B1F29384E5485C87F6EF902 "Win7Mac Local Signing" (CSSMERR_TP_NOT_TRUSTED)'
    exit 0 ;;
  *) echo "BAD security $*" >>"$W7_STUB_LOG"; exit 1 ;;
esac
S
stub launchctl <<'S'
[ "$*" = "print system/com.bedtime.ammonia" ] || { echo "BAD launchctl $*" >>"$W7_STUB_LOG"; exit 1; }
[ "${W7_STUB_AMMONIA_JOB:-loaded}" = loaded ] || { echo "Could not find service" >&2; exit 113; }
printf 'system/com.bedtime.ammonia = {\n\truns = %s\n\tlast exit code = %s\n}\n' "${W7_STUB_AMMONIA_RUNS:-1}" "${W7_STUB_AMMONIA_EXIT:-0}"
S
stub pgrep <<'S'
[ "$*" = "-xq Win7Shell" ] || { echo "BAD pgrep $*" >>"$W7_STUB_LOG"; exit 1; }
[ -n "${W7_STUB_RUNNING-}" ]
S
# open: only the headless probe launch is allowed; it answers through the --stdout file like the real shell.
stub open <<'S'
out=""; app=""; probe=0
while [ $# -gt 0 ]; do
  case "$1" in --stdout) out="$2"; shift 2 ;; --args) shift; [ "${1-}" = --w7-permission-probe ] && probe=1; shift $# ;; -*) shift ;; *) app="$1"; shift ;; esac
done
[ "$probe" = 1 ] && [ -n "$out" ] && [ "$app" = "$HOME/Applications/Win7Shell.app" ] || { echo "BAD open (not the probe)" >>"$W7_STUB_LOG"; exit 1; }
[ -n "${W7_STUB_PROBE_SILENT-}" ] && exit 0   # a probe that never answers
printf 'accessibility=%s\nscreen-recording=%s\n' "${W7_STUB_AX:-1}" "${W7_STUB_SR:-1}" >"$out"
S
# pkill: only to clean up a probe that did not answer.
stub pkill <<'S'
[ "$*" = "-f -- Win7Shell --w7-permission-probe" ] || { echo "BAD pkill $*" >>"$W7_STUB_LOG"; exit 1; }
exit 1
S
stub profiles <<'S'
printf 'Enrolled via DEP: No\nMDM enrollment: %s\n' "${W7_STUB_MDM:-No}"
S
stub codesign <<'S'
case "$1" in -d*) echo "$2: code object is not signed at all" >&2; exit 1 ;; esac
echo "BAD codesign $*" >>"$W7_STUB_LOG"; exit 1
S
# make: setup's own variables and make's must never reach the nested make (FORCE=1 breaks import-icons in make test).
stub make <<'S'
[ -z "${FORCE-}${YES-}${CHECK-}${SKIP_TESTS-}${MAKEFLAGS-}${MFLAGS-}${MAKELEVEL-}" ] || echo "BAD make environment leak: FORCE=${FORCE-} YES=${YES-} MAKEFLAGS=${MAKEFLAGS-}" >>"$W7_STUB_LOG"
exit "${W7_STUB_MAKE_EXIT:-0}"
S
for c in sudo osascript killall defaults curl; do
    stub "$c" <<'S'
echo "BAD $(basename "$0") called" >>"$W7_STUB_LOG"; exit 1
S
done
export PATH="$tmp/bin:$PATH"

# Safety net: refuse to continue unless every system-touching command resolves to a stub.
for c in csrutil nvram sysctl sw_vers uname xcode-select swift df security launchctl pgrep pkill open profiles codesign make \
         sudo osascript killall defaults; do
    [ "$(command -v $c)" = "$tmp/bin/$c" ] || fail "stub for $c is not first on PATH"
done

# install.sh stand-in: records the call and produces what install.sh would leave behind (restore.env only once).
cat >"$W7_SETUP_INSTALL" <<'S'
#!/bin/sh
set -e
echo "install.sh called" >>"$W7_STUB_LOG"
[ -z "${FORCE-}${YES-}${CHECK-}${SKIP_TESTS-}${MAKEFLAGS-}${MAKELEVEL-}" ] || echo "BAD install.sh environment leak" >>"$W7_STUB_LOG"
support="$HOME/Library/Application Support/Win7Mac"
mkdir -p "$support/Assets" "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Fonts"
[ -e "$support/restore.env" ] || echo "DOCK_AUTOHIDE=__unset__" >"$support/restore.env"
rm -rf "$HOME/Applications/Win7Shell.app"
/bin/cp -R "$W7_BUILD_DIR/Win7Shell.app" "$HOME/Applications/Win7Shell.app"
/bin/cp -R "$W7_ASSETS_SRC/." "$support/Assets/"
for f in "$W7_ASSETS_SRC"/fonts/*.ttf; do [ -f "$f" ] && /bin/cp -n "$f" "$HOME/Library/Fonts/" || true; done
sed "s|__HOME__|$HOME|g" "$W7_STUB_ROOT/Resources/com.win7mac.shell.plist" >"$HOME/Library/LaunchAgents/com.win7mac.shell.plist"
/bin/cp "$W7_BUILD_DIR/Win7Chrome.dylib" "$W7_TWEAK_DIR/Win7Chrome.dylib"
/bin/cp "$W7_STUB_ROOT/scripts/blacklist.txt" "$W7_TWEAK_DIR/Win7Chrome.dylib.blacklist"
S
chmod +x "$W7_SETUP_INSTALL"

# --- fixtures ------------------------------------------------------------------------------------
mkdir -p "$HOME" "$W7_STUB_CLT_DIR" "$W7_TWEAK_DIR" "$tmp/LaunchDaemons" "$W7_BUILD_DIR/Win7Shell.app/Contents/MacOS" \
         "$W7_ASSETS_SRC/fonts" "$W7_ASSETS_SRC/icons"
chmod 777 "$W7_TWEAK_DIR"
printf '#!/bin/sh\nexit 0\n' >"$W7_SETUP_AMMONIA_DIR/ammonia"; chmod +x "$W7_SETUP_AMMONIA_DIR/ammonia"
echo plist >"$W7_SETUP_AMMONIA_PLIST"
# The built shell knows the probe flag (the string is in the executable, as in the real binary).
printf '#!/bin/sh\n# handles --w7-permission-probe\nexit 0\n' >"$W7_BUILD_DIR/Win7Shell.app/Contents/MacOS/Win7Shell"
chmod +x "$W7_BUILD_DIR/Win7Shell.app/Contents/MacOS/Win7Shell"
/usr/bin/plutil -create xml1 "$W7_BUILD_DIR/Win7Shell.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 0.1.0 "$W7_BUILD_DIR/Win7Shell.app/Contents/Info.plist"
echo dylib-v1 >"$W7_BUILD_DIR/Win7Chrome.dylib"
echo f1 >"$W7_ASSETS_SRC/fonts/segoeui.ttf"
echo f2 >"$W7_ASSETS_SRC/fonts/segoeuib.ttf"
echo jpg >"$W7_ASSETS_SRC/wallpaper.jpg"
while IFS= read -r n; do echo png >"$W7_ASSETS_SRC/icons/$n.png"; done <"$tmp/icon-names.txt"   # every catalogue name
echo orb >"$W7_ASSETS_SRC/start-orb.png"

good_env() { # the all-PASS machine; each case changes only what it tests
    unset W7_STUB_SIP W7_STUB_ACTIVE W7_STUB_MACOS W7_STUB_ARCH W7_STUB_NO_CLT W7_STUB_SWIFT W7_STUB_FREE_KB \
          W7_STUB_NO_IDENTITY W7_STUB_AMMONIA_JOB W7_STUB_AMMONIA_RUNS W7_STUB_AMMONIA_EXIT W7_STUB_RUNNING \
          W7_STUB_AX W7_STUB_SR W7_STUB_MDM W7_STUB_MAKE_EXIT W7_STUB_PROBE_SILENT
    export W7_STUB_NVRAM="-arm64e_preview_abi"
}
# run_setup <args...>: runs setup.sh with stdin from $W7_STDIN (default: none), sets $out and $rc,
# and fails the test on any forbidden call.
run_setup() {
    : >"$W7_STUB_LOG"
    printf '%b' "${W7_STDIN-}" >"$tmp/stdin"
    out="$("$setup" "$@" <"$tmp/stdin" 2>&1)"
    rc=$?
    if grep -q '^BAD' "$W7_STUB_LOG"; then fail "forbidden call ($*): $(grep '^BAD' "$W7_STUB_LOG")"; fi
}
installed_tree() { find "$HOME" -print | LC_ALL=C sort; }

# --- static checks -------------------------------------------------------------------------------
[ "$(head -1 "$setup")" = "#!/bin/bash" ] || fail "setup.sh must run on /bin/bash (3.2)"
grep -qx 'set -euo pipefail' "$setup" || fail "setup.sh lacks set -euo pipefail"
# The code with every double-quoted string (messages), comment and single-quoted string removed: what is left
# is what can run. Fixes may mention sudo or csrutil disable only inside messages.
code="$(sed -E -e 's/"([^"\\]|\\.)*"//g' -e 's/(^|[[:space:]])#.*$//' -e "s/'[^']*'//g" "$setup")"
grep -q 'probe_permissions' <<<"$code" || fail "static check stripped the code itself"
bad="$(grep -nE '(^|[^[:alnum:]_-])(sudo|osascript|killall|cfprefsd|curl|wget)([^[:alnum:]_-]|$)|/usr/bin/|/usr/sbin/' <<<"$code")"
[ -z "$bad" ] && bad="$(grep -nE '(^|[^[:alnum:]_-])(defaults|launchctl (bootstrap|bootout|load|unload|kickstart|enable|disable))([^[:alnum:]_-]|$)' <<<"$code")"
[ -z "$bad" ] || fail "setup.sh runs a forbidden command: $bad"
# nvram, csrutil and security may only run as exactly these reads (followed by a redirect, pipe) or the end).
end='[[:space:]]*(2>[^[:space:]|)]*)?[[:space:]]*(\||\)|;|$)'
rest="$(sed -E -e "s/nvram boot-args$end//g" -e "s/csrutil status$end//g" \
                -e "s/security find-identity -p codesigning$end//g" <<<"$code")"
bad="$(grep -nE '(^|[^[:alnum:]_-])(nvram|csrutil|security)([^[:alnum:]_-]|$)' <<<"$rest")"
[ -z "$bad" ] || fail "setup.sh runs nvram/csrutil/security beyond the allowed reads: $bad"

# --- Makefile wiring -----------------------------------------------------------------------------
run_make() { env -u MAKEFLAGS -u MAKELEVEL -u CHECK -u YES /usr/bin/make -n -C "$root" "$@" 2>/dev/null; }
mk="$(run_make setup CHECK=1)"
has "$mk" 'scripts/setup.sh CHECK="1" YES="" FORCE="" SKIP_TESTS=""' || fail "make setup CHECK=1 does not pass CHECK: $mk"
mk="$(run_make setup YES=1)"
has "$mk" 'YES="1"' || fail "make setup YES=1 does not pass YES: $mk"
mk="$(run_make test)"
has "$mk" "scripts/test_setup.sh" || fail "make test does not run scripts/test_setup.sh"
# make shell copies README.md for Help and Support only when it exists (a missing one warns, never stops the build).
grep -q 'if \[ -f README.md \]; then cp README.md ' "$root/Makefile" || fail "make shell does not tolerate a missing README.md"
grep -qE '^[[:space:]]*cp README.md' "$root/Makefile" && fail "make shell copies README.md unconditionally"

run_setup BOGUS=1
[ $rc -eq 2 ] || fail "unknown argument not refused (rc $rc)"

# --- 1. all good, CHECK=1 (read-only) --------------------------------------------------------------
good_env
before="$(installed_tree)"
run_setup CHECK=1
[ $rc -eq 0 ] || fail "all-good check exited $rc: $out"
for line in "[PASS] macOS version        macOS 27.0.1" "[PASS] Architecture" "[PASS] Command Line Tools" "[PASS] Free disk" \
            "[PASS] SIP                  disabled" "[PASS] boot-args            -arm64e_preview_abi (active)" \
            "[PASS] Ammonia tweaks dir" "[PASS] Ammonia loader" "[INFO] Previous install     none (fresh install)" \
            "[PASS] Signing identity" "[PASS] Segoe UI fonts" "[PASS] Wallpaper" "[PASS] Icons" "[PASS] Start orb" \
            "[INFO] Policy"; do
    has "$out" "$line" || fail "all-good: missing '$line': $out"
done
has "$out" "[FAIL]" && fail "all-good: unexpected FAIL: $out"
# Not installed yet: the probe is never launched, permissions are WARN with the System Settings path.
log_has "open " && fail "probe launched with no installed shell"
has "$out" "[WARN] Accessibility        unknown: Win7Shell is not installed yet" || fail "no not-installed permission WARN: $out"
has "$out" "Privacy & Security ▸ Accessibility ▸ enable Win7Shell" || fail "no Accessibility path: $out"
has "$out" "Screen & System Audio Recording ▸ enable Win7Shell" || fail "no Screen Recording path: $out"
log_has "make" && fail "CHECK=1 ran make"
log_has "install.sh called" && fail "CHECK=1 ran install.sh"
log_has "csrutil status" || fail "SIP not read"
log_has "nvram boot-args" || fail "boot-args not read"
[ "$(installed_tree)" = "$before" ] || fail "CHECK=1 changed HOME: $(diff <(echo "$before") <(installed_tree))"
[ -f "$report" ] || fail "no report written"
grep -qF "$HOME" "$report" && fail "report contains the HOME path: $(cat "$report")"
grep -qF "~/ammonia/core/tweaks (writable)" "$report" || fail "report does not show HOME as ~: $(cat "$report")"
grep -qF "mode: check" "$report" || fail "report lacks the mode"
grep -qF "result: 0 FAIL" "$report" || fail "report lacks the result line"
has "$out" "Report: " || fail "report path not printed"

# --- 1b. icon coverage: catalogue names present, map lines still ICON/? (never fails the preflight) ----------------
# All names present (the fixture): PASS. The ? count is the repo map's: today 1 (cp-location-sensors; dev-bluetooth and dev-usb were chosen; as
# IconCatalogTests.repoMapMarksOnlyRealUnknownsWithAQuestionMark keeps it).
has "$out" "[PASS] Icons                icons: $icon_total of $icon_total names present in $W7_ASSETS_SRC; 1 map lines still ICON/? (see Assets/_contact/)" \
    || fail "all icons: no PASS coverage line: $out"
grep -qF "icons: $icon_total of $icon_total names present" "$report" || fail "coverage line not in the report: $(cat "$report")"
# Three names (a symlink, a directory and a stray file do not count): WARN, exit 0, the fix names the importers.
few="$tmp/AssetsFew"
mkdir -p "$few/icons/$(sed -n 4p "$tmp/icon-names.txt").png"
for n in $(sed -n 1,3p "$tmp/icon-names.txt"); do echo png >"$few/icons/$n.png"; done
ln -s "$few/icons/$(sed -n 1p "$tmp/icon-names.txt").png" "$few/icons/$(sed -n 5p "$tmp/icon-names.txt").png"
echo png >"$few/icons/not-a-catalogue-name.png"
W7_ASSETS_SRC="$few" run_setup CHECK=1
[ $rc -eq 0 ] || fail "partial icons failed the preflight (rc $rc): $out"
has "$out" "[WARN] Icons                icons: 3 of $icon_total names present in $few; 1 map lines still ICON/? (see Assets/_contact/)" \
    || fail "3 icons: no WARN coverage line: $out"
has "$out" "make import-assets SRC=" && has "$out" "make import-icons SRC=" || fail "3 icons: no import fix: $out"
# The ? count follows the map: commented lines and ICON/- (no icon on this media) are not work.
cat >"$tmp/map.txt" <<'M'
# ICON/? means "not chosen yet"
icons/a.png  Windows/System32/x.dll ICON/?
icons/b.png  Windows/System32/y.dll   ICON/?    # C (still to choose)
icons/c.png  Windows/System32/z.dll ICON/-      # no icon resource
# icons/d.png Windows/System32/x.dll ICON/?
icons/e.png  Windows/System32/x.dll ICON/12     # was ICON/?
M
W7_SETUP_ASSET_MAP="$tmp/map.txt" run_setup CHECK=1
has "$out" "names present in $W7_ASSETS_SRC; 2 map lines still ICON/? (see Assets/_contact/)" || fail "fake map ? count: $out"
# No tool (a fresh checkout), or one that predates icon-names: WARN, never FAIL.
W7_ASSET_TOOL="$tmp/no-such-tool" run_setup CHECK=1
[ $rc -eq 0 ] && has "$out" "[WARN] Icons                icons: (Win7AssetTool not built; run make import-assets first)" \
    || fail "missing tool: $rc $out"
printf '#!/bin/sh\necho "usage: Win7AssetTool ico2png|bmpstrip ..." >&2\nexit 64\n' >"$tmp/old-tool"; chmod +x "$tmp/old-tool"
W7_ASSET_TOOL="$tmp/old-tool" run_setup CHECK=1
[ $rc -eq 0 ] && has "$out" "icons: (Win7AssetTool not built; run make import-assets first)" || fail "old tool: $rc $out"

# --- 2. FAIL rendering: SIP on, boot-args missing, no Ammonia --------------------------------------
good_env
export W7_STUB_SIP=enabled
unset W7_STUB_NVRAM
mv "$W7_SETUP_AMMONIA_PLIST" "$tmp/plist.away"
run_setup CHECK=1
[ $rc -eq 1 ] || fail "FAIL check exited $rc"
has "$out" "[FAIL] SIP                  enabled" || fail "SIP FAIL missing: $out"
has "$out" "Utilities ▸ Terminal" || fail "Recovery steps missing: $out"
has "$out" "Run: csrutil disable" || fail "csrutil disable step missing: $out"
has "$out" "[FAIL] boot-args            not set, -arm64e_preview_abi missing" || fail "boot-args FAIL missing: $out"
has "$out" 'sudo nvram boot-args="-arm64e_preview_abi"' || fail "exact nvram command missing: $out"
has "$out" "[FAIL] Ammonia loader" || fail "Ammonia FAIL missing: $out"
has "$out" "https://github.com/CoreBedtime/ammonia" || fail "Ammonia link missing: $out"
has "$out" "reboot after installing" || fail "Ammonia reboot requirement missing: $out"
grep -qF "result: 3 FAIL" "$report" || fail "report does not count 3 FAILs: $(cat "$report")"
# Not in check mode: stops before building or installing.
run_setup YES=1
[ $rc -eq 1 ] || fail "YES=1 with FAILs exited $rc"
has "$out" "Nothing was built or installed" || fail "no stop message: $out"
log_has "make" && fail "built despite FAILs"
log_has "install.sh called" && fail "installed despite FAILs"
mv "$tmp/plist.away" "$W7_SETUP_AMMONIA_PLIST"

# Tweaks dir missing and not writable.
good_env
mv "$W7_TWEAK_DIR" "$tmp/tweaks.away"
run_setup CHECK=1
[ $rc -eq 1 ] && has "$out" "[FAIL] Ammonia tweaks dir   ~/ammonia/core/tweaks missing" || fail "missing tweaks dir: $rc $out"
mv "$tmp/tweaks.away" "$W7_TWEAK_DIR"
chmod 555 "$W7_TWEAK_DIR"
run_setup CHECK=1
chmod 777 "$W7_TWEAK_DIR"
[ $rc -eq 1 ] && has "$out" "not writable by you" || fail "read-only tweaks dir: $rc $out"

# --- 3. boot-args details --------------------------------------------------------------------------
good_env
export W7_STUB_NVRAM="debug=0x100"
run_setup CHECK=1
has "$out" 'sudo nvram boot-args="debug=0x100 -arm64e_preview_abi"  (keeps your current boot-args)' \
    || fail "existing boot-args not kept in the fix: $out"
good_env
export W7_STUB_NVRAM="-v -arm64e_preview_abi" W7_STUB_ACTIVE="-v"
run_setup CHECK=1
[ $rc -eq 0 ] || fail "set-but-inactive boot-args exited $rc"
has "$out" "[WARN] boot-args            -arm64e_preview_abi set, not active until you reboot" || fail "inactive boot-args: $out"
has "$out" "Reboot: the boot-arg or Ammonia is not active yet." || fail "reboot step missing: $out"

# --- 4. other preflight branches -------------------------------------------------------------------
good_env; export W7_STUB_AMMONIA_RUNS=0
run_setup CHECK=1
has "$out" "[WARN] Ammonia loader       loaded, has not run since boot" || fail "Ammonia not run: $out"
good_env; export W7_STUB_AMMONIA_JOB=none
run_setup CHECK=1
has "$out" "[WARN] Ammonia loader       installed, launchd job com.bedtime.ammonia not loaded" || fail "Ammonia job not loaded: $out"
good_env; export W7_STUB_SIP="unknown (Custom Configuration)"
run_setup CHECK=1
[ $rc -eq 0 ] && has "$out" "[WARN] SIP                  custom configuration" || fail "custom SIP: $out"
good_env; export W7_STUB_SIP="enabled (Custom Configuration)"
run_setup CHECK=1
[ $rc -eq 0 ] && has "$out" "[WARN] SIP                  custom configuration" || fail "enabled custom SIP: $out"
good_env; export W7_STUB_AMMONIA_EXIT="(never exited)"     # resident: still on its first run
run_setup CHECK=1
has "$out" "[PASS] Ammonia loader" || fail "resident Ammonia not PASS: $out"
good_env; export W7_STUB_AMMONIA_EXIT=9
run_setup CHECK=1
has "$out" "[WARN] Ammonia loader       last run exited with: 9" || fail "failed Ammonia run: $out"
good_env; export W7_STUB_NO_CLT=1
run_setup CHECK=1
[ $rc -eq 1 ] && has "$out" "[FAIL] Command Line Tools   not installed" && has "$out" "xcode-select --install" || fail "no CLT: $out"
log_has "swift " && fail "swift ran without the Command Line Tools (would pop up the installer)"
good_env; export W7_STUB_SWIFT=5.10
run_setup CHECK=1
[ $rc -eq 1 ] && has "$out" "[FAIL] Command Line Tools   Swift 5.10" || fail "old Swift: $out"
good_env; export W7_STUB_MACOS=14.6
run_setup CHECK=1
[ $rc -eq 1 ] && has "$out" "[FAIL] macOS version        macOS 14.6" || fail "old macOS: $out"
good_env; export W7_STUB_ARCH=x86_64
run_setup CHECK=1
[ $rc -eq 1 ] && has "$out" "[FAIL] Architecture         x86_64 under Rosetta" || fail "Rosetta: $out"
good_env; export W7_STUB_FREE_KB=2097152
run_setup CHECK=1
[ $rc -eq 0 ] && has "$out" "[WARN] Free disk            2.0 GB free" || fail "low disk: $out"
good_env; export W7_STUB_MDM=Yes
run_setup CHECK=1
has "$out" "[WARN] Policy               this Mac is enrolled in MDM (managed)" || fail "MDM: $out"

# --- 5. WARN rendering: no identity, no assets ----------------------------------------------------
good_env; export W7_STUB_NO_IDENTITY=1
mv "$W7_ASSETS_SRC" "$tmp/Assets.away"
run_setup CHECK=1
[ $rc -eq 0 ] || fail "WARN-only check exited $rc"
has "$out" '[WARN] Signing identity     "Win7Mac Local Signing" missing' || fail "identity WARN: $out"
has "$out" "make signing-identity" || fail "identity fix: $out"
has "$out" 'never "Always Allow"' || fail "Always Allow warning: $out"
has "$out" "loses the Accessibility and Screen Recording grants on every rebuild" || fail "ad-hoc explanation: $out"
has "$out" "[WARN] Segoe UI fonts" && has "$out" "make import-assets SRC=" || fail "fonts WARN: $out"
has "$out" "[WARN] Wallpaper" && has "$out" "make wallpaper SRC=" || fail "wallpaper WARN: $out"
has "$out" "[WARN] Icons" && has "$out" "make import-icons SRC=" || fail "icons WARN: $out"
has "$out" "[WARN] Start orb" || fail "orb WARN: $out"
has "$out" "Optional: make signing-identity" || fail "identity next step: $out"
mv "$tmp/Assets.away" "$W7_ASSETS_SRC"

# --- 6. YES=1 on a fresh machine: build + test, then install.sh ------------------------------------
good_env; export W7_STUB_NO_IDENTITY=1
run_setup YES=1
[ $rc -eq 0 ] || fail "YES=1 exited $rc: $out"
log_has "make -C $root test chrome shell" || fail "build + test not run: $(cat "$W7_STUB_LOG")"
log_has "make -C $root signing-identity" && fail "YES=1 created the signing identity"
has "$out" "Signing identity: skipped (YES=1 never creates it" || fail "identity skip not reported: $out"
[ "$(grep -c "install.sh called" "$W7_STUB_LOG")" -eq 1 ] || fail "install.sh not called once: $(cat "$W7_STUB_LOG")"
has "$out" "==> Install: done (scripts/install.sh)" || fail "install not reported: $out"
has "$out" "Log out and back in" || fail "logout step missing: $out"
grep -qF "phase  Install              done" "$report" || fail "report lacks the phases: $(cat "$report")"
grep -qF "mode: yes" "$report" || fail "report mode not yes"
restore_before="$(cat "$HOME/Library/Application Support/Win7Mac/restore.env")"

# --- 7. idempotent: a second YES=1 run finds everything current and does not reinstall --------------
good_env; export W7_STUB_RUNNING=1
run_setup YES=1
[ $rc -eq 0 ] || fail "second YES=1 exited $rc: $out"
has "$out" "[INFO] Previous install     found (upgrade)" || fail "upgrade not detected: $out"
has "$out" "[INFO] Installed shell      Win7Shell 0.1.0, matches the build" || fail "installed shell not current: $out"
has "$out" "[INFO] Installed dylib      installed, matches the build" || fail "installed dylib not current: $out"
has "$out" "[INFO] Shell running        yes" || fail "running shell not detected: $out"
log_has "install.sh called" && fail "second run reinstalled although nothing changed: $out"
has "$out" "Install: up to date, skipped (FORCE=1 reinstalls)" || fail "up-to-date skip not reported: $out"
# Now installed, the probe runs through open with the flag and reports the grants.
log_has "open -n -g --stdout" || fail "probe not launched through open: $(cat "$W7_STUB_LOG")"
has "$out" "[PASS] Accessibility        granted to Win7Shell" || fail "AX grant not read: $out"
has "$out" "[PASS] Screen Recording     granted to Win7Shell" || fail "SR grant not read: $out"
[ "$(cat "$HOME/Library/Application Support/Win7Mac/restore.env")" = "$restore_before" ] || fail "restore.env changed"

good_env; export W7_STUB_AX=0 W7_STUB_SR=0
run_setup CHECK=1
has "$out" "[WARN] Accessibility        not granted to Win7Shell" || fail "AX not granted: $out"
has "$out" "[WARN] Screen Recording     not granted to Win7Shell" || fail "SR not granted: $out"
has "$out" "Grant Win7Shell Accessibility and Screen Recording" || fail "permission next step: $out"

good_env
run_setup YES=1 FORCE=1
[ "$(grep -c "install.sh called" "$W7_STUB_LOG")" -eq 1 ] || fail "FORCE=1 did not reinstall"
# As `make setup FORCE=1 YES=1` runs it: the variables also arrive in the environment, with make's own.
# The make and install.sh stubs log BAD (failing run_setup) if any of them leaks through.
export FORCE=1 YES=1 MAKEFLAGS=" -- FORCE=1 YES=1" MFLAGS=-w MAKELEVEL=1
run_setup YES=1 FORCE=1
unset FORCE YES MAKEFLAGS MFLAGS MAKELEVEL
[ $rc -eq 0 ] && log_has "make -C $root test chrome shell" && log_has "install.sh called" || fail "env FORCE=1 run: $rc $out"

# An edited LaunchAgent (or a changed Resources/com.win7mac.shell.plist) makes the next run install again.
echo edited >>"$HOME/Library/LaunchAgents/com.win7mac.shell.plist"
run_setup YES=1
has "$out" "LaunchAgent differs from Resources/com.win7mac.shell.plist" && log_has "install.sh called" \
    || fail "changed LaunchAgent not reinstalled: $out"

# A probe that never answers is cleaned up after the 10 s wait.
good_env; export W7_STUB_PROBE_SILENT=1
run_setup CHECK=1
log_has "pkill -f -- Win7Shell --w7-permission-probe" || fail "silent probe not killed: $(cat "$W7_STUB_LOG")"
has "$out" "[WARN] Accessibility        unknown: the probe did not answer" || fail "silent probe not reported: $out"

# A changed build (or asset) makes the next run install again.
echo dylib-v2 >"$W7_BUILD_DIR/Win7Chrome.dylib"
good_env
run_setup CHECK=1
has "$out" "installed, differs from the build (install updates it)" || fail "changed dylib not detected: $out"
run_setup YES=1
has "$out" "Win7Chrome.dylib differs from the build" || fail "difference not listed: $out"
log_has "install.sh called" || fail "changed build not installed"
echo new >"$W7_ASSETS_SRC/icons/computer.png"
run_setup YES=1
has "$out" "Assets/ has files the installed copy lacks or differ" && log_has "install.sh called" || fail "new asset not installed: $out"

# An installed shell that predates the probe is never launched (it would start a second full shell).
printf '#!/bin/sh\nexit 0\n' >"$HOME/Applications/Win7Shell.app/Contents/MacOS/Win7Shell"
run_setup CHECK=1
log_has "open " && fail "probe launched on a shell without the flag"
has "$out" "unknown: the installed Win7Shell predates this check" || fail "old shell not reported: $out"

# --- 8. interactive -------------------------------------------------------------------------------
good_env
export W7_STDIN='n\nn\n'
run_setup
[ $rc -eq 0 ] || fail "interactive no/no exited $rc: $out"
has "$out" "Build and test now (make test chrome shell" || fail "build question missing: $out"
has "$out" "Install the existing build/ (not rebuilt now; it may be stale) (scripts/install.sh" || fail "install question missing: $out"
has "$out" "starts Win7Shell)? [y/N]" || fail "install of an unrebuilt build/ does not default to no: $out"
log_has "make" && fail "interactive 'n' still built"
log_has "install.sh called" && fail "interactive 'n' still installed"
grep -qF "mode: interactive" "$report" || fail "report mode not interactive"

export W7_STDIN='n\n\n'   # build declined: Enter at the install question means no
run_setup
log_has "install.sh called" && fail "unrebuilt build/ installed by default"
export W7_STDIN='n\ny\n'  # ...but an explicit yes installs the existing build/
run_setup
log_has "make" && fail "declined build still ran make"
log_has "install.sh called" || fail "explicit yes did not install the existing build/"
printf '#!/bin/sh\nexit 0\n' >"$HOME/Applications/Win7Shell.app/Contents/MacOS/Win7Shell"   # differ again for the next cases

export W7_STDIN=''      # end of input answers no
run_setup
log_has "make" && fail "EOF still built"
log_has "install.sh called" && fail "EOF still installed"

export W7_STUB_NO_IDENTITY=1 W7_STDIN='y\n\n\n'   # identity yes, then Enter takes the defaults (yes)
run_setup
log_has "make -C $root signing-identity" || fail "interactive yes did not create the identity: $(cat "$W7_STUB_LOG")"
log_has "make -C $root test chrome shell" || fail "interactive default did not build"
log_has "install.sh called" || fail "interactive default did not install"
has "$out" "Optional: make signing-identity" && fail "identity still suggested after creating it: $out"
has "$out" "Grant Win7Shell Accessibility and Screen Recording" || fail "no re-grant step after a new identity: $out"
unset W7_STDIN

# Already current: interactive asks before reinstalling, default no.
good_env
export W7_STDIN='\n\n'
run_setup
has "$out" "Win7Mac is installed and matches this build. Reinstall anyway? [y/N]" || fail "reinstall question missing: $out"
log_has "install.sh called" && fail "default answer reinstalled"
unset W7_STDIN

# --- 9. SKIP_TESTS and a failing build -------------------------------------------------------------
good_env
run_setup YES=1 SKIP_TESTS=1
log_has "make -C $root chrome shell" || fail "SKIP_TESTS=1 did not build chrome shell"
log_has "test chrome shell" && fail "SKIP_TESTS=1 still ran make test"
good_env; export W7_STUB_MAKE_EXIT=2
run_setup YES=1 FORCE=1
[ $rc -eq 1 ] || fail "failed build exited $rc"
log_has "install.sh called" && fail "installed after a failed build"
has "$out" "Build + test: FAILED" || fail "build failure not reported: $out"

echo "test_setup: all checks passed"
