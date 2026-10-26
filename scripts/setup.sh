#!/bin/bash
# Guided Win7Mac setup (make setup). First a read-only preflight: every prerequisite is a named check with
# PASS / WARN / FAIL and the exact manual fix. Then, after asking, build + test (make) and install (it calls
# scripts/install.sh, which does all the file work), and finally the next manual steps.
#
# It only READS the machine's state. It never runs sudo, never changes SIP (csrutil is only asked for its
# status), never writes NVRAM (nvram is only read), never installs Ammonia and runs no AppleScript: those are
# the user's steps, printed with the exact commands to type.
#
#   scripts/setup.sh              interactive: preflight, then asks before each phase
#   scripts/setup.sh CHECK=1      preflight only; exit 1 if any check FAILs
#   scripts/setup.sh YES=1        no questions: build + test, then install (never creates the signing identity)
#   FORCE=1                       install even when the installed files already match the build
#   SKIP_TESTS=1                  build without running make test
#
# The result goes to build/setup-report.txt ($HOME shown as ~, no user names) for pasting into a help request.
# Any FAIL stops before the build: fix it and run make setup again (re-running is always safe).
#
# Environment overrides (scripts/test_setup.sh): W7_BUILD_DIR, W7_ASSETS_SRC, W7_TWEAK_DIR (as install.sh),
#   W7_SETUP_AMMONIA_DIR    Ammonia's core directory (default /var/ammonia/core)
#   W7_SETUP_AMMONIA_PLIST  Ammonia's LaunchDaemon (default /Library/LaunchDaemons/com.bedtime.ammonia.plist)
#   W7_SETUP_INSTALL        the install script (default scripts/install.sh)
#   W7_SETUP_MAKE           make (default make)
#   W7_ASSET_TOOL           the Win7AssetTool binary (default .build/release, then .build/debug)
#   W7_SETUP_ASSET_MAP      the asset map counted for ICON/? lines (default scripts/win7-asset-map.txt)
# System commands (csrutil, nvram, sysctl, security, launchctl, open, ...) are called by name, so the tests
# put stubs first on PATH.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${W7_BUILD_DIR:-$root/build}"
assets_src="${W7_ASSETS_SRC:-$root/Assets}"
ammonia="${W7_SETUP_AMMONIA_DIR:-/var/ammonia/core}"
tweaks="${W7_TWEAK_DIR:-/var/ammonia/core/tweaks}"
ammonia_plist="${W7_SETUP_AMMONIA_PLIST:-/Library/LaunchDaemons/com.bedtime.ammonia.plist}"
ammonia_label="com.bedtime.ammonia"
install_cmd="${W7_SETUP_INSTALL:-$root/scripts/install.sh}"
make_cmd="${W7_SETUP_MAKE:-make}"
asset_tool="${W7_ASSET_TOOL:-}"
if [ -z "$asset_tool" ]; then
    asset_tool="$root/.build/release/Win7AssetTool"
    [ -x "$asset_tool" ] || asset_tool="$root/.build/debug/Win7AssetTool"
fi
asset_map="${W7_SETUP_ASSET_MAP:-$root/scripts/win7-asset-map.txt}"
support="$HOME/Library/Application Support/Win7Mac"
app_dest="$HOME/Applications/Win7Shell.app"
agent="$HOME/Library/LaunchAgents/com.win7mac.shell.plist"
report="$build/setup-report.txt"
identity="Win7Mac Local Signing"
probe_flag="--w7-permission-probe"
ammonia_url="https://github.com/CoreBedtime/ammonia"
min_free_kb=$((6 * 1024 * 1024))

CHECK=${CHECK:-} YES=${YES:-} FORCE=${FORCE:-} SKIP_TESTS=${SKIP_TESTS:-}
usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }
for arg in "$@"; do
    case "$arg" in
        CHECK=*) CHECK="${arg#*=}" ;;
        YES=*) YES="${arg#*=}" ;;
        FORCE=*) FORCE="${arg#*=}" ;;
        SKIP_TESTS=*) SKIP_TESTS="${arg#*=}" ;;
        --check) CHECK=1 ;;
        --yes) YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "setup: unknown argument '$arg' (see scripts/setup.sh --help)" >&2; exit 2 ;;
    esac
done
on() { case "${1:-}" in ""|0|no|NO|false) return 1 ;; *) return 0 ;; esac; }
# make exports its command-line variables (make setup FORCE=1 ...) and MAKEFLAGS: keep them out of the
# nested make and install.sh (import-icons.sh, run by make test, reads FORCE).
export -n CHECK YES FORCE SKIP_TESTS
unset MAKEFLAGS MFLAGS MAKELEVEL

tilde='~'
scrub() { local s="$1"; printf '%s' "${s//"$HOME"/$tilde}"; }

# --- results ------------------------------------------------------------------------------------
# Parallel arrays (bash 3.2 has no associative arrays). Fix text may hold several lines.
names=() states=() details=() fixes=()
fail_count=0 warn_count=0
result() { # result PASS|WARN|FAIL|INFO "name" "detail" ["fix line" ...]
    local st="$1" name="$2" detail="$3" fix="" line
    shift 3
    for line in "$@"; do fix="${fix:+$fix
}$line"; done
    names+=("$name"); states+=("$st"); details+=("$detail"); fixes+=("$fix")
    case "$st" in FAIL) fail_count=$((fail_count + 1)) ;; WARN) warn_count=$((warn_count + 1)) ;; esac
    render_check $((${#names[@]} - 1))
}
render_check() { # render_check <index>
    local i=$1 line
    printf '[%s] %-20s %s\n' "${states[$i]}" "${names[$i]}" "$(scrub "${details[$i]}")"
    if [ -n "${fixes[$i]}" ]; then
        while IFS= read -r line; do printf '       %s\n' "$(scrub "$line")"; done <<<"${fixes[$i]}"
    fi
}
status_of() { # status_of "name": prints the state of that check
    local i
    for ((i = 0; i < ${#names[@]}; i++)); do
        [ "${names[$i]}" = "$1" ] && { printf '%s' "${states[$i]}"; return 0; }
    done
    return 0
}
phase_names=() phase_results=()
phase() { phase_names+=("$1"); phase_results+=("$2"); echo "==> $1: $2"; }

# --- helpers ------------------------------------------------------------------------------------
# cdhash <code>: the code directory hash (stable when a bundle is re-signed with an identity, whose
# signature blob carries a signing time); empty when unsigned.
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1 || true; }
# same_code <a> <b>: identical bytes, or the same code directory hash.
same_code() {
    [ -e "$1" ] && [ -e "$2" ] || return 1
    [ -f "$1" ] && [ -f "$2" ] && cmp -s "$1" "$2" && return 0
    local a b
    a="$(cdhash "$1")"; b="$(cdhash "$2")"
    [ -n "$a" ] && [ "$a" = "$b" ]
}
app_same() { # the built and the installed Win7Shell.app match
    local a="$build/Win7Shell.app" b="$app_dest"
    [ -d "$a" ] && [ -d "$b" ] || return 1
    if cmp -s "$a/Contents/MacOS/Win7Shell" "$b/Contents/MacOS/Win7Shell" \
        && cmp -s "$a/Contents/Info.plist" "$b/Contents/Info.plist"; then
        return 0
    fi
    same_code "$a" "$b"
}
# install_diff: prints one line per thing scripts/install.sh would change (nothing = already installed and
# current). Read-only; the Terminal profile, wallpaper and alert sound are not compared (FORCE=1 reapplies them).
install_diff() {
    [ -f "$support/restore.env" ] || echo "not installed yet (no restore.env)"
    if [ ! -f "$agent" ]; then
        echo "LaunchAgent missing"
    elif [ "$(sed "s|__HOME__|$HOME|g" "$root/Resources/com.win7mac.shell.plist")" != "$(cat "$agent")" ]; then
        echo "LaunchAgent differs from Resources/com.win7mac.shell.plist"
    fi
    app_same || echo "Win7Shell.app differs from the build"
    if [ -d "$tweaks" ] && [ -f "$build/Win7Chrome.dylib" ]; then
        same_code "$build/Win7Chrome.dylib" "$tweaks/Win7Chrome.dylib" || echo "Win7Chrome.dylib differs from the build"
        cmp -s "$root/scripts/blacklist.txt" "$tweaks/Win7Chrome.dylib.blacklist" || echo "Win7Chrome.dylib.blacklist differs"
    fi
    if [ -d "$assets_src" ]; then
        local f rel changed=0
        while IFS= read -r f; do
            rel="${f#"$assets_src"/}"
            cmp -s "$f" "$support/Assets/$rel" || { changed=1; break; }
        done < <(find "$assets_src" -type f ! -path "$assets_src/reference/*" 2>/dev/null)
        [ "$changed" = 0 ] || echo "Assets/ has files the installed copy lacks or differ"
        for f in "$assets_src"/fonts/*.ttf; do
            [ -f "$f" ] || continue
            [ -e "$HOME/Library/Fonts/$(basename "$f")" ] || { echo "fonts not yet in ~/Library/Fonts"; break; }
        done
    fi
    return 0
}
# ask "question" y|n: 0 for yes. YES=1 answers yes; end of input answers no (never installs by accident).
ask() {
    local prompt="[y/N]" ans
    [ "$2" = y ] && prompt="[Y/n]"
    if on "$YES"; then echo "$1 -> yes (YES=1)"; return 0; fi
    printf '%s %s ' "$1" "$prompt"
    if ! IFS= read -r ans; then echo; return 1; fi
    case "$ans" in
        "") [ "$2" = y ] ;;
        [yY]*) return 0 ;;
        *) return 1 ;;
    esac
}

recovery_steps=(
    "Turn SIP off yourself in Recovery (setup never does):"
    "  1. Shut down. Hold the power button until \"Loading startup options\" appears, choose Options ▸ Continue."
    "  2. Pick your user and enter its password, then choose Utilities ▸ Terminal in the menu bar."
    "  3. Run: csrutil disable   (answer y, enter your password), then  reboot"
)
ammonia_steps=(
    "Install Ammonia yourself (1.5 was verified): $ammonia_url - follow its README."
    "It needs SIP off and the -arm64e_preview_abi boot-arg first, and a reboot after installing."
)

# --- 1. preflight (read-only) ---------------------------------------------------------------------
echo "Win7Mac setup: preflight (read-only; nothing is changed)"
echo

# System
ver="$(sw_vers -productVersion 2>/dev/null || true)"
if [ -z "$ver" ]; then
    result FAIL "macOS version" "unknown (sw_vers failed)" "Win7Mac needs macOS 15 or later."
elif [ "${ver%%.*}" -ge 15 ] 2>/dev/null; then
    result PASS "macOS version" "macOS $ver"
else
    result FAIL "macOS version" "macOS $ver" "Win7Mac needs macOS 15 (Sequoia) or later: update macOS first (System Settings ▸ General ▸ Software Update)."
fi

arch="$(uname -m 2>/dev/null || true)"
if [ "$arch" = arm64 ]; then
    result PASS "Architecture" "arm64 (Apple silicon)"
elif [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
    result FAIL "Architecture" "$arch under Rosetta" "This Terminal runs under Rosetta: quit it, untick Get Info ▸ \"Open using Rosetta\" and run make setup again."
else
    result FAIL "Architecture" "${arch:-unknown}" "Win7Mac needs an Apple silicon Mac (the arm64e preview ABI and Ammonia are arm64 only)."
fi

# Never run swift unless the developer directory exists: without the tools /usr/bin/swift pops up an installer.
devdir="$(xcode-select -p 2>/dev/null || true)"
if [ -n "$devdir" ] && [ -d "$devdir" ]; then
    swift_ver="$(LC_ALL=C swift --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1 || true)"
    if [ -z "$swift_ver" ]; then
        result FAIL "Command Line Tools" "$devdir, but swift --version fails" \
            "Reinstall the Command Line Tools: run  xcode-select --install  yourself (or Software Update)."
    elif [ "${swift_ver%%.*}" -ge 6 ] 2>/dev/null; then
        result PASS "Command Line Tools" "$devdir, Swift $swift_ver"
    else
        result FAIL "Command Line Tools" "Swift $swift_ver" "Swift 6 or later is needed: update the Command Line Tools (Software Update)."
    fi
else
    result FAIL "Command Line Tools" "not installed" "Run  xcode-select --install  yourself, accept the dialog, then run make setup again."
fi

free_kb="$(LC_ALL=C df -k "$root" 2>/dev/null | LC_ALL=C awk 'NR > 1 { v = $4 } END { print v + 0 }' || true)"
free_gb="$(LC_ALL=C awk -v k="${free_kb:-0}" 'BEGIN { printf "%.1f", k / 1048576 }')"
if [ "${free_kb:-0}" -ge "$min_free_kb" ] 2>/dev/null; then
    result PASS "Free disk" "$free_gb GB free"
else
    result WARN "Free disk" "$free_gb GB free" "The build (.build/) needs about 6 GB: free some space before building."
fi

# SIP: status only.
sip="$(LC_ALL=C csrutil status 2>&1 || true)"
case "$sip" in
    *"status: disabled"*) result PASS "SIP" "disabled" ;;
    *"Custom Configuration"*|*"status: unknown"*)
        result WARN "SIP" "custom configuration" "Ammonia expects SIP fully off. If Win7Chrome does not load:" "${recovery_steps[@]}" ;;
    *"status: enabled"*) result FAIL "SIP" "enabled" "${recovery_steps[@]}" ;;
    *) result WARN "SIP" "could not read csrutil status" "Run  csrutil status  yourself; it must say disabled." ;;
esac

# boot-args: NVRAM read only; kern.bootargs is what the running system booted with.
bootargs="$(nvram boot-args 2>/dev/null | sed -n 's/^boot-args[[:space:]]*//p' || true)"
active_args="$(sysctl -n kern.bootargs 2>/dev/null || true)"
has_flag() { case " $1 " in *" -arm64e_preview_abi "*) return 0 ;; *) return 1 ;; esac; }
reboot_needed=0
if has_flag "$bootargs"; then
    if has_flag "$active_args"; then
        result PASS "boot-args" "-arm64e_preview_abi (active)"
    else
        reboot_needed=1
        result WARN "boot-args" "-arm64e_preview_abi set, not active until you reboot" "Reboot (after setup is fine), then check again with make setup CHECK=1."
    fi
else
    newargs="-arm64e_preview_abi"
    keep=""
    if [ -n "$bootargs" ]; then newargs="$bootargs -arm64e_preview_abi"; keep="  (keeps your current boot-args)"; fi
    result FAIL "boot-args" "${bootargs:-not set}, -arm64e_preview_abi missing" \
        "Run this yourself in Terminal (after SIP is off), then reboot:" \
        "  sudo nvram boot-args=\"$newargs\"$keep"
fi

# Ammonia: detected, never installed.
if [ ! -d "$tweaks" ]; then
    result FAIL "Ammonia tweaks dir" "$tweaks missing" "${ammonia_steps[@]}"
elif [ ! -w "$tweaks" ]; then
    result FAIL "Ammonia tweaks dir" "$tweaks not writable by you" \
        "Ammonia makes it world-writable (drwxrwxrwx); reinstall Ammonia ($ammonia_url). Setup never uses sudo."
else
    result PASS "Ammonia tweaks dir" "$tweaks (writable)"
fi
if [ ! -f "$ammonia_plist" ] || [ ! -x "$ammonia/ammonia" ]; then
    result FAIL "Ammonia loader" "not installed ($ammonia_plist / $ammonia/ammonia missing)" "${ammonia_steps[@]}"
elif ! job="$(launchctl print "system/$ammonia_label" 2>/dev/null)"; then
    reboot_needed=1
    result WARN "Ammonia loader" "installed, launchd job $ammonia_label not loaded" "Reboot so launchd loads Ammonia, then check again with make setup CHECK=1."
else
    runs="$(sed -n 's/^[[:space:]]*runs = \([0-9][0-9]*\).*/\1/p' <<<"$job" | head -1)"
    code="$(sed -n 's/^[[:space:]]*last exit code = \(.*\)$/\1/p' <<<"$job" | head -1)"
    if [ "${runs:-0}" = 0 ]; then
        reboot_needed=1
        result WARN "Ammonia loader" "loaded, has not run since boot" "Reboot so Ammonia starts, then check again with make setup CHECK=1."
    elif [ -n "$code" ] && [ "$code" != 0 ] && [ "$code" != "(never exited)" ]; then   # never exited: still on its first run
        result WARN "Ammonia loader" "last run exited with: $code" "See Ammonia's README ($ammonia_url); a reboot usually restarts it."
    else
        result PASS "Ammonia loader" "$ammonia_label ran at boot (runs = ${runs})"
    fi
fi

# Previous Win7Mac state.
if [ -f "$support/restore.env" ]; then
    result INFO "Previous install" "found (upgrade): restore.env keeps your original settings"
else
    result INFO "Previous install" "none (fresh install)"
fi
if [ -d "$app_dest" ]; then
    app_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dest/Contents/Info.plist" 2>/dev/null || echo "?")"
    if [ ! -d "$build/Win7Shell.app" ]; then app_state="not built yet"
    elif app_same; then app_state="matches the build"
    else app_state="differs from the build (install updates it)"; fi
    result INFO "Installed shell" "Win7Shell $app_ver, $app_state"
else
    result INFO "Installed shell" "not installed"
fi
if [ -f "$tweaks/Win7Chrome.dylib" ]; then
    if [ ! -f "$build/Win7Chrome.dylib" ]; then dylib_state="installed; not built yet"
    elif same_code "$build/Win7Chrome.dylib" "$tweaks/Win7Chrome.dylib"; then dylib_state="installed, matches the build"
    else dylib_state="installed, differs from the build (install updates it)"; fi
    result INFO "Installed dylib" "$dylib_state"
else
    result INFO "Installed dylib" "not installed"
fi
if pgrep -xq Win7Shell; then
    result INFO "Shell running" "yes"
else
    result INFO "Shell running" "no"
fi

# Signing identity: presence only, no hashes in the report.
# Output captured first: `cmd | grep -q` can report a false miss under pipefail (SIGPIPE to cmd).
identities="$(security find-identity -p codesigning 2>/dev/null || true)"
if grep -qF "\"$identity\"" <<<"$identities"; then
    result PASS "Signing identity" "\"$identity\" in your keychain"
else
    result WARN "Signing identity" "\"$identity\" missing: the shell is ad-hoc signed" \
        "Ad-hoc signing loses the Accessibility and Screen Recording grants on every rebuild." \
        "Run  make signing-identity  once (interactive setup offers it). At each make shell keychain prompt" \
        "answer \"Allow\", never \"Always Allow\" (README, Stable signing)."
fi

# Permissions, read without prompting by the installed shell itself (--w7-permission-probe). It is launched
# through LaunchServices so TCC answers for Win7Shell, not for this Terminal. An installed shell that
# predates the probe would start a second full shell, so it is only launched when it knows the flag.
probe_permissions() { # prints accessibility=0|1 and screen-recording=0|1, or a reason on failure (exit 1)
    local exe="$app_dest/Contents/MacOS/Win7Shell" out i=0 text
    [ -x "$exe" ] || { echo "Win7Shell is not installed yet"; return 1; }
    grep -aqF -- "$probe_flag" "$exe" || { echo "the installed Win7Shell predates this check"; return 1; }
    out="$(mktemp -t w7-permission-probe)"
    if ! open -n -g --stdout "$out" "$app_dest" --args "$probe_flag" >/dev/null 2>&1; then
        rm -f "$out"; echo "could not launch the probe"; return 1
    fi
    while [ $i -lt 100 ] && ! grep -q '^screen-recording=' "$out" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
    text="$(cat "$out")"
    rm -f "$out"
    if ! grep -q '^screen-recording=' <<<"$text"; then
        pkill -f -- "Win7Shell $probe_flag" >/dev/null 2>&1 || true   # never leave a hung probe behind
        echo "the probe did not answer"; return 1
    fi
    printf '%s\n' "$text"
}
ax_fix="System Settings ▸ Privacy & Security ▸ Accessibility ▸ enable Win7Shell."
sr_fix="System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording ▸ enable Win7Shell."
if perms="$(probe_permissions)"; then
    if grep -q '^accessibility=1' <<<"$perms"; then
        result PASS "Accessibility" "granted to Win7Shell"
    else
        result WARN "Accessibility" "not granted to Win7Shell" "$ax_fix"
    fi
    if grep -q '^screen-recording=1' <<<"$perms"; then
        result PASS "Screen Recording" "granted to Win7Shell"
    else
        result WARN "Screen Recording" "not granted to Win7Shell" "$sr_fix"
    fi
else
    result WARN "Accessibility" "unknown: $perms" "After the shell's first launch: $ax_fix"
    result WARN "Screen Recording" "unknown: $perms" "After the shell's first launch: $sr_fix"
fi

# Your own assets (optional; anything missing falls back to a built-in default).
if [ -f "$assets_src/fonts/segoeui.ttf" ] && [ -f "$assets_src/fonts/segoeuib.ttf" ]; then
    result PASS "Segoe UI fonts" "Assets/fonts/segoeui.ttf, segoeuib.ttf"
elif [ -e "$HOME/Library/Fonts/segoeui.ttf" ] && [ -e "$HOME/Library/Fonts/segoeuib.ttf" ]; then
    result PASS "Segoe UI fonts" "in ~/Library/Fonts"
else
    result WARN "Segoe UI fonts" "not imported (optional; apps keep the system font)" \
        "make import-assets SRC=/path/to/Win7.iso  (or copy segoeui.ttf and segoeuib.ttf from C:\\Windows\\Fonts into Assets/fonts/)"
fi
if [ -f "$assets_src/wallpaper.jpg" ]; then
    result PASS "Wallpaper" "Assets/wallpaper.jpg"
else
    result WARN "Wallpaper" "not imported (optional; a generated default is used)" "make wallpaper SRC=/path/to/img0.jpg"
fi
# Icon coverage: how many of the catalogue's names (Win7AssetTool icon-names, IconCatalog.all) have a regular
# <asset root>/icons/<name>.png, and how many map lines still wait for an id (ICON/?; ICON/- lines can never resolve
# on Windows 7 media and are not work). Never a FAIL: every missing icon keeps its drawn or macOS picture.
icon_names=""
if [ -x "$asset_tool" ]; then icon_names="$("$asset_tool" icon-names 2>/dev/null)" || icon_names=""; fi
if [ -z "$icon_names" ]; then
    result WARN "Icons" "icons: (Win7AssetTool not built; run make import-assets first)" \
        "make import-assets SRC=/path/to/Win7.iso  (or make import-icons SRC=/path/to/icons.zip)"
else
    icons_total=0 icons_present=0
    while IFS= read -r n; do
        case "$n" in ""|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue ;; esac   # plain names only, as the shell reads them
        icons_total=$((icons_total + 1))
        f="$assets_src/icons/$n.png"
        if [ -f "$f" ] && [ ! -L "$f" ]; then icons_present=$((icons_present + 1)); fi
    done <<<"$icon_names"
    # '#' at the start of a line or after a space or tab starts a comment; the spec is a line's last field.
    icons_unchosen="$(sed -e 's/^#.*//' -e 's/[[:space:]]#.*//' "$asset_map" 2>/dev/null \
        | LC_ALL=C awk 'NF >= 3 && $NF == "ICON/?" { n++ } END { print n + 0 }' || true)"
    icons_line="icons: $icons_present of $icons_total names present in $assets_src; ${icons_unchosen:-0} map lines still ICON/? (see Assets/_contact/)"
    if [ "$icons_present" -lt "$icons_total" ]; then
        result WARN "Icons" "$icons_line" \
            "make import-assets SRC=/path/to/Win7.iso  (or make import-icons SRC=/path/to/icons.zip); then make install," \
            "make chrome and make install-chrome. An ICON/? line's id is chosen on Assets/_contact/<dll>.png (Assets/README.md)."
    else
        result PASS "Icons" "$icons_line"
    fi
fi
if [ -f "$assets_src/start-orb.png" ] || [ -f "$support/Assets/start-orb.png" ]; then
    result PASS "Start orb" "start-orb.png"
else
    result WARN "Start orb" "not imported (optional; a drawn orb is used)" "make import-assets SRC=/path/to/Win7.iso"
fi

# Policy (README, Security impact).
enrollment="$(LC_ALL=C profiles status -type enrollment 2>/dev/null || true)"
if grep -qi 'MDM enrollment: Yes' <<<"$enrollment"; then
    result WARN "Policy" "this Mac is enrolled in MDM (managed)" \
        "SIP off, the arm64e preview ABI and injecting into every app may violate your organisation's policy: ask before installing."
else
    result INFO "Policy" "SIP off and injection weaken system protections; may violate MDM or company policy. Use a Mac you own."
fi

# --- report and summary --------------------------------------------------------------------------
write_report() {
    local i
    mkdir -p "$build"
    {
        echo "Win7Mac setup report"
        echo "date: $(date '+%Y-%m-%d %H:%M')"
        echo "mode: $(if on "$CHECK"; then echo check; elif on "$YES"; then echo yes; else echo interactive; fi)"
        echo "result: $fail_count FAIL, $warn_count WARN"
        echo
        for ((i = 0; i < ${#names[@]}; i++)); do render_check "$i"; done
        if [ ${#phase_names[@]} -gt 0 ]; then
            echo
            for ((i = 0; i < ${#phase_names[@]}; i++)); do printf 'phase  %-20s %s\n' "${phase_names[$i]}" "${phase_results[$i]}"; done
        fi
    } >"$report.tmp"
    mv -f "$report.tmp" "$report"
}
installed_now=0 identity_created=0
summary() {
    local i n=1
    echo
    echo "Summary"
    for ((i = 0; i < ${#names[@]}; i++)); do printf '  %-4s  %-20s %s\n' "${states[$i]}" "${names[$i]}" "$(scrub "${details[$i]}")"; done
    for ((i = 0; i < ${#phase_names[@]}; i++)); do printf '  %-4s  %-20s %s\n' "-->" "${phase_names[$i]}" "${phase_results[$i]}"; done
    echo
    echo "Next steps (by hand):"
    if [ "$fail_count" -gt 0 ]; then
        echo "  $n. Fix every FAIL above (the indented lines say how), then run make setup again."; n=$((n + 1))
    fi
    if [ "$reboot_needed" = 1 ]; then
        echo "  $n. Reboot: the boot-arg or Ammonia is not active yet."; n=$((n + 1))
    fi
    if [ "$installed_now" = 1 ]; then
        echo "  $n. Log out and back in (or run  killall Finder  and relaunch your open apps) so every app loads Win7Chrome."; n=$((n + 1))
    fi
    # A fresh ad-hoc build, or the first build signed with a new identity, no longer matches earlier grants.
    if [ "$(status_of Accessibility)" != PASS ] || [ "$(status_of "Screen Recording")" != PASS ] \
        || [ "$identity_created" = 1 ] || { [ "$installed_now" = 1 ] && [ "$(status_of "Signing identity")" != PASS ]; }; then
        echo "  $n. Grant Win7Shell Accessibility and Screen Recording (System Settings ▸ Privacy & Security); if macOS"
        echo "     asks to quit and reopen Win7Shell, do so. Check again with make setup CHECK=1."; n=$((n + 1))
    fi
    if [ "$(status_of "Signing identity")" != PASS ] && [ "$identity_created" = 0 ]; then
        echo "  $n. Optional: make signing-identity, then make setup again, so the grants survive rebuilds."; n=$((n + 1))
    fi
    echo "  $n. Go through README ▸ Setup ▸ First-run checks."
    echo
    echo "Report: $(scrub "$report") (paste it when asking for help)."
}
finish() { write_report; summary; exit "$1"; }

echo
if on "$CHECK"; then
    if [ "$fail_count" -gt 0 ]; then finish 1; fi
    finish 0
fi
if [ "$fail_count" -gt 0 ]; then
    echo "Setup stops here: $fail_count check(s) FAILed. Nothing was built or installed."
    finish 1
fi

# --- 2. signing identity (asked, never automatic) -------------------------------------------------
if [ "$(status_of "Signing identity")" != PASS ]; then
    if on "$YES"; then
        phase "Signing identity" "skipped (YES=1 never creates it; run make signing-identity yourself)"
    elif ask "Create the \"$identity\" signing identity now (make signing-identity)?" n; then
        if "$make_cmd" -C "$root" signing-identity; then
            identity_created=1
            phase "Signing identity" "created"
        else
            phase "Signing identity" "FAILED (the build signs ad-hoc)"
        fi
    else
        phase "Signing identity" "skipped"
    fi
fi

# --- 3. build + test ------------------------------------------------------------------------------
targets="test chrome shell"
on "$SKIP_TESTS" && targets="chrome shell"
built=0
# shellcheck disable=SC2086
if ask "Build and test now (make $targets; the tests take several minutes)?" y; then
    if "$make_cmd" -C "$root" $targets; then
        built=1
        phase "Build + test" "done (make $targets)"
    else
        phase "Build + test" "FAILED (make $targets): nothing was installed"
        finish 1
    fi
else
    phase "Build + test" "skipped"
fi

# --- 4. install (scripts/install.sh does the work; it is idempotent) -----------------------------
if [ ! -d "$build/Win7Shell.app" ]; then
    phase "Install" "skipped: no build/Win7Shell.app (build first)"
else
    diff_lines="$(install_diff)"
    if [ -z "$diff_lines" ] && ! on "$FORCE"; then
        if on "$YES" || ! ask "Win7Mac is installed and matches this build. Reinstall anyway?" n; then
            phase "Install" "up to date, skipped (FORCE=1 reinstalls)"
            finish 0
        fi
    else
        [ -z "$diff_lines" ] || { echo "To install or update:"; while IFS= read -r l; do echo "  - $l"; done <<<"$diff_lines"; }
        # Without a fresh build, build/ may be stale: say so and default to no.
        what="Install now" default=y
        if [ "$built" = 0 ]; then what="Install the existing build/ (not rebuilt now; it may be stale)"; default=n; fi
        if ! ask "$what (scripts/install.sh: hides the Dock and menu bar, restarts Dock and Finder, starts Win7Shell)?" "$default"; then
            phase "Install" "skipped"
            finish 0
        fi
    fi
    if "$install_cmd"; then
        installed_now=1
        phase "Install" "done (scripts/install.sh)"
    else
        phase "Install" "FAILED (scripts/install.sh); see its messages above"
        finish 1
    fi
fi
finish 0
