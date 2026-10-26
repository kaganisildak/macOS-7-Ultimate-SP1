# Win7Mac — Manual

Makes macOS look and behave like Windows 7: Aero window frames and a Win7 menu strip inside every GUI app
(`Win7Chrome.dylib`, injected by the Ammonia loader), plus a background app (`Win7Shell`) that draws the taskbar,
Start menu, desktop, Alt+Tab switcher, Aero Peek and window snapping.

## What this changes

`make install` (scripts/install.sh) does all of this, and `make uninstall` puts it back:

- Hides the Dock (autohide with a 1000 s delay) and the menu bar (autohide).
- Turns off Finder's own desktop icons (`CreateDesktop = false`) because the shell draws its own desktop.
- Sets the wallpaper (imported `wallpaper.jpg`, or a generated Windows 7 style default; see [Wallpaper](#wallpaper)) and the alert sound (`Win7Alert.aiff`).
- Copies `Assets/` (never `Assets/reference/`) to `~/Library/Application Support/Win7Mac/Assets/`.
- Copies Segoe UI fonts from `Assets/fonts/*.ttf`, if you imported them, to `~/Library/Fonts/` (skipping files already there).
- Installs `Win7Shell.app` to `~/Applications/` and a LaunchAgent (`com.win7mac.shell`) that starts it at login and plays the startup sound.
- Installs `Win7Chrome.dylib` and its blacklist into Ammonia's tweak directory.
- Adds a "Win7 Command Prompt" Terminal profile and makes it Terminal's default and startup profile (see below).

The original settings are recorded once in `~/Library/Application Support/Win7Mac/restore.env`. Running install again never
overwrites them; a setting added in a later version is appended the first time that version runs.

## Terminal looks like the Command Prompt

Terminal gets a profile, not injected code. `scripts/make-terminal-profile.swift` writes
`Assets/terminal/Win7 Command Prompt.terminal` on each install: the Windows 7 console colours (black background, grey
`#C0C0C0` text, the 16 legacy console colours), Lucida Console 12 if it is installed (`make import-assets` copies
`lucon.ttf` from your Windows media) or Menlo 12, an 80×25 window titled "Command Prompt", and a blinking underline cursor.
install.sh adds it to Terminal's preferences through `defaults export`/`import`, so no Terminal window opens and the
preferences file is never edited directly. The first install saves a copy of Terminal's preferences as they were
to `~/Library/Application Support/Win7Mac/com.apple.Terminal.before.plist`. Later installs never overwrite it, and
uninstall keeps it (restore it by hand with `defaults import com.apple.Terminal <file>` if ever needed).

- New Terminal windows use the profile. Windows that are already open keep theirs. If Terminal is running during install or
  uninstall, you get a warning: it may only notice the change after it restarts, so check Terminal ▸ Settings ▸ Profiles.
- If your login shell is zsh, the profile starts zsh with `ZDOTDIR=~/Library/Application Support/Win7Mac/cmd-zsh`. The
  files there run your own `~/.zshenv`, `~/.zprofile`, `~/.zshrc` and `~/.zlogin` (or the ones under the `ZDOTDIR` your
  `~/.zshenv` sets), in zsh's usual order, then set a `C:\Users\you\folder>` prompt. History stays in your own
  `.zsh_history`, and Terminal's session state and zkbd key definitions stay in `~/.zsh_sessions` and `~/.zkbd`. Your
  dotfiles are not edited. With another login shell the profile only changes the look. If the `cmd-zsh` folder is
  missing, the profile opens your normal zsh.
- In Command Prompt windows only, the prompt replaces your own prompt and right prompt, and the zsh options
  `prompt_subst` and `prompt_bang` are switched off (`no_prompt_subst no_prompt_bang`), so a folder name is never
  expanded or run. A prompt theme that needs `prompt_subst` still works in your other Terminal windows.
- The shell lists Terminal as **Command Prompt** (Start menu, taskbar, switcher; "cmd" finds it in the Start menu's
  search). Choosing it in the Start menu, or starting it from a taskbar pin or its jump list while Terminal is not
  running, opens `Assets/terminal/Win7 Command Prompt.terminal` with Terminal (NSWorkspace, no AppleScript): a new
  window with the profile. Without that file it starts Terminal as it is. The profile runs its start command with
  "Run inside shell" off: with it on, Terminal splits the command at blanks and drops the quotes (sh then fails on
  `'[`). The Command Prompt's `.zshrc` clears the screen before your own `.zshrc` runs, so the window opens on the
  prompt, without Terminal's "Last login" line and its echo of the start command.
- To use another profile in one window: Shell ▸ Use Profile ▸ (name). To make another profile the default again: select it in
  Terminal ▸ Settings ▸ Profiles and click Default (or Shell ▸ Use Settings as Default in a window that uses it).
- `make uninstall` removes the profile and the `cmd-zsh` folder and puts back your default and startup profiles, unless you
  have already chosen a different one yourself.

## Security impact

SIP off and the arm64e preview ABI weaken system protections, and injecting a library into every app is invasive.
This may violate MDM or company policy. Use it on a machine you own.

## Setup

Read [Security impact](#security-impact) first. `make setup` checks everything, tells you what is missing and how to
fix it, and only then builds, tests and installs. It never does the system steps below for you: no `sudo`, no
`csrutil` change, no NVRAM write, nothing in Recovery, no Ammonia install. It only reads their state.

### 1. Before `make setup` (by hand, in this order)

1. **Back up**: make a current Time Machine (or other full) backup.
2. **Turn SIP off** in Recovery: shut down, hold the power button until "Loading startup options" appears, choose
   Options ▸ Continue, pick your user and enter its password, choose Utilities ▸ Terminal, run `csrutil disable`
   (answer `y`, enter your password), then `reboot`.
3. **Set the boot-arg** in Terminal: `sudo nvram boot-args="-arm64e_preview_abi"`. If `nvram boot-args` already shows
   other boot-args, keep them: `sudo nvram boot-args="<current boot-args> -arm64e_preview_abi"` (`make setup CHECK=1`
   prints the exact line for your Mac).
4. **Install Ammonia** (1.5 was verified) from https://github.com/CoreBedtime/ammonia as its README says, then
   **reboot** (this reboot also activates the boot-arg). Its tweak directory is `/var/ammonia/core/tweaks/` (plural)
   and is world-writable, so nothing here uses `sudo`. If the directory is missing, `make install` prints "Ammonia not
   found — skipping Win7Chrome" and installs the rest; `make setup` stops with a FAIL instead.
5. **Command Line Tools**: `xcode-select --install` (Swift 6 or later; the full Xcode is not needed).
6. Optional: **your own Windows 7 assets** ([Your own assets](#your-own-assets)): `make import-assets
   SRC=/path/to/Win7.iso`, `make wallpaper SRC=/path/to/img0.jpg`, `make import-icons SRC=/path/to/icons.zip`. Also
   optional: `make signing-identity` once, so the permission grants survive rebuilds
   ([Stable signing](#stable-signing-permissions-survive-reinstalls)); setup offers it too.

### 2. `make setup`

```
make setup            # checks, then asks before each step
make setup CHECK=1    # checks only (read-only); exit status 1 if anything FAILs
make setup YES=1      # checks, then builds, tests and installs without asking
```

The preflight prints one line per check, PASS / WARN / FAIL (INFO for plain facts):

- macOS 15 or later; Apple silicon (`arm64`, not under Rosetta); the Command Line Tools with Swift 6 (`swift` is only
  run when `xcode-select -p` finds them, so no installer pops up); about 6 GB free disk (WARN).
- SIP disabled (`csrutil status`); `-arm64e_preview_abi` in `nvram boot-args` and active since the last boot
  (`sysctl kern.bootargs`; WARN "reboot" when it is set but not active yet).
- Ammonia: the tweak directory exists and you can write to it; its loader (the `com.bedtime.ammonia` LaunchDaemon and
  `/var/ammonia/core/ammonia`) is installed and ran at boot (`launchctl print`).
- The previous install: upgrade or fresh (`restore.env`), the installed shell and dylib against this build, and
  whether the shell is running.
- The "Win7Mac Local Signing" identity (WARN without it: ad-hoc signing loses the grants on every rebuild).
- Accessibility and Screen Recording for Win7Shell, read without prompting. Setup launches the installed Win7Shell
  once in a headless mode (`--w7-permission-probe`) that prints both states and exits. It goes through `open`, so macOS
  answers for Win7Shell and not for the Terminal running setup. Before the first install both show WARN (a shell can
  only be granted after it has run once).
- Your assets (Segoe UI, wallpaper, icons, Start orb; WARN only) and a policy line (WARN when the Mac is enrolled in
  MDM).

Every WARN and FAIL is followed by the exact fix. A FAIL stops setup before it builds anything: fix it and run
`make setup` again. After the checks setup asks (`YES=1` answers yes, except where noted):

1. to create the signing identity when it is missing (default no; `YES=1` never creates it);
2. to build and test: `make test chrome shell` (`SKIP_TESTS=1` builds without the tests);
3. to install: `scripts/install.sh` does all the file work (see [What this changes](#what-this-changes)). When the
   installed app, dylib, blacklist, LaunchAgent, assets and fonts already match the build, this step is skipped
   (interactive: asked, default no). `FORCE=1` installs anyway, for example to reapply the Terminal profile or the
   wallpaper. If you declined the build, setup offers to install the existing `build/` instead, default no, since it
   may be stale.

Re-running is always safe. Setup ends with a summary table and your next steps, and writes `build/setup-report.txt`
(`$HOME` shown as `~`, no user names or keys) to paste when asking for help.

### 3. After `make setup`

1. Reboot if setup says the boot-arg or Ammonia is not active yet.
2. Log out and back in (or `killall Finder` and relaunch your open apps), so every app loads Win7Chrome.
3. Grant Win7Shell Accessibility and Screen Recording: System Settings ▸ Privacy & Security ▸ Accessibility, and
   ▸ Screen & System Audio Recording, enable Win7Shell. Allow the other [Permissions](#permissions) when macOS asks.
   `make setup CHECK=1` shows whether the grants took.
4. Go through the first-run checks below and report anything that is off.

### First-run checks

1. Apps launch normally after install (no instant crashes). If they do crash, see the atomic install rule below and reinstall the dylib.
2. The taskbar is visible, the Dock and menu bar are hidden, the wallpaper is applied, and the startup sound plays (if you imported one).
3. Windows in a normal app, for example TextEdit, show an Aero title bar with caption buttons and a Win7 menu strip.
4. Aero Peek: hovering Show Desktop reveals the desktop and also reaches windows of background apps, not only the frontmost one.
5. The Show Desktop button behaves in slow-launching apps (it ignores activations for about one second).
6. Alt+Tab, window snapping (drag to an edge, and the hotkeys), taskbar thumbnails and the Start menu all respond; the Shut-down popup stays inside the Start menu.
7. Start menu uses your user picture tile and changes it when you hover a place; the Accessibility values read for window titles look right.
8. Menu strip: while a menu is open, mouse-hover and modifier-key events are swallowed by design; tell us if that feels wrong.
9. Finder: macOS may ask for Automation consent the first time Finder windows are restyled. Check that hiding the Finder toolbar does not hide the sidebar or stick in a folder's view settings, and that Finder windows look like Explorer.
10. Desktop: icons, dragging, rubber-band selection and right-click menus work.
11. Log messages from the chrome (subsystem `com.win7mac.chrome`) may not appear in `log show`; if you need them, tell us.

## Build & install

`make setup` runs these after its checks. By hand:

```
make test chrome shell && make install
```

`make install-chrome` installs only the dylib. Log out and back in afterwards.

### The atomic install rule

The dylib is always installed by copying to a temp name in the same directory (`.Win7Chrome.dylib.new`) and then `mv -f` onto
`Win7Chrome.dylib`. Never `cp` over it in place. Overwriting a loaded dylib in place invalidates its code signature, and then
every newly launched app, Finder included, is killed with SIGKILL. `install.sh` and `make install-chrome` both follow this rule;
uninstall uses `rm -f`.

## Permissions

Grant these to Win7Shell when macOS asks (System Settings -> Privacy & Security):

- Accessibility (taskbar, snapping, Alt+Tab).
- Screen Recording (Aero Peek and taskbar thumbnails).
- Desktop folder access (the shell draws your Desktop items).
- Automation -> Finder (Explorer-style Finder windows).

### Stable signing (permissions survive reinstalls)

macOS ties these grants to the app's code signature. With ad-hoc signing (`-`) every rebuild changes the code hash, so the
grants stop matching after each `make shell install` and must be given again. Run this once:

```
make signing-identity
```

It creates a self-signed code-signing certificate "Win7Mac Local Signing" in your login keychain (`security` and `openssl`
from the base system; no sudo, nothing in the System keychain, no trust settings changed) and does nothing if it already
exists. From then on `make shell` signs with it whenever `security find-identity -p codesigning` lists it, and prints which
identity it used; otherwise it falls back to ad-hoc. The identity shows as `CSSMERR_TP_NOT_TRUSTED` and not under "valid
identities only": that is expected, codesign still signs with it, and the app's designated requirement pins this
certificate, so it stays the same across rebuilds. Grant the permissions once more after the first build signed this way.

When signing with this identity, every `make shell` shows a keychain prompt asking to let codesign use the key: choose
**"Allow"**, not "Always Allow" (the Makefile prints a reminder). With "Always Allow", any process running as you could
sign its own bundle as com.win7mac.shell and inherit the shell's Accessibility and Screen Recording grants. The script
puts no application on the key's access list, so every signing asks. It also requests a non-exportable key
(`security import -x`), but macOS may not enforce that for PKCS#12 imports. To undo this, run
`security delete-identity -c "Win7Mac Local Signing"`, rebuild (`make shell` falls back to ad-hoc) and grant the
permissions again.
`make shell CODESIGN_IDENTITY="My Local Cert"` still picks another identity, and `CODESIGN_IDENTITY=-` forces ad-hoc.

## Keyboard shortcuts

A Mac keyboard has no Windows key, and Command or Option shortcuts collide with every app, so **Win is Control+Option**
(the table lives in `Sources/Win7Core/Shortcuts.swift`). "AX" marks shortcuts that need Accessibility; without it they
show the Accessibility balloon once per session and do nothing else.

| Windows 7 | On the Mac | Does |
|---|---|---|
| Win / Ctrl+Esc | Ctrl+Esc | Opens or closes the Start menu |
| Win+D | Ctrl+Option+D | Show desktop; press again to bring the windows back |
| Win+M | Ctrl+Option+M | Minimizes every window (AX). Without Accessibility it hides every app instead; Win+D does not bring those back, Win+Shift+M does |
| Win+Shift+M | Ctrl+Option+Shift+M | Restores what Win+M minimized or hid; the window that was active comes back on top |
| Win+E | Ctrl+Option+E | Opens a Finder window at your home folder |
| Win+L | Ctrl+Option+L | Locks the screen (the Start menu's Lock) once Control and Option are released |
| Win+R | Ctrl+Option+R | Opens the Run dialog |
| Win+Home | Ctrl+Option+Home (fn+Left may work, depending on keyboard) | Minimizes every window except the active one; press again to restore them (AX) |
| Win+Space | Ctrl+Option+Space | Aero Peek at the desktop while Space is held |
| Win+1…9 | Ctrl+Option+1…9 | Clicks the Nth taskbar button (launch, switch to, or list its windows) |
| Win+T | Ctrl+Option+T | Highlights the first taskbar button and shows its preview; each press moves to the next. Esc, or 5 s without a press, ends it |
| Win+←/→/↑/↓ | Ctrl+Option+arrows | Snap left / right, maximize, restore or minimize (AX) |
| Win+Shift+↑ | Ctrl+Option+Shift+Up | Vertical maximize: full height, same left edge and width (AX) |
| Win+Shift+←/→ | Ctrl+Option+Shift+Left/Right | Moves the window to the previous/next display, same relative place and size (AX) |
| Alt+Tab | Option+Tab, Option+Shift+Tab | Window switcher (AX) |

**Aero Shake:** grab a window's title bar and shake it left and right quickly (three turns within 0.6 s, each swing at
least 40 pt, staying within 120 pt of where the drag began): every other window on that display is minimized. Shake
again to bring them back. Needs Accessibility.

Notes:

- macOS's own "Select next source in Input menu" shortcut is Control+Option+Space. While it is on (System Settings ->
  Keyboard -> Keyboard Shortcuts -> Input Sources), it wins and Win+Space does nothing; turn it off to use Peek.
- While Win+T's taskbar focus lasts (up to 5 s after the last Win+T), it captures Esc from every app.
- With VoiceOver on, Control+Option is its VO modifier and these shortcuts take over VO commands with the same keys.
- Windows 7 maximizes a window's height when you double-click its top or bottom border. macOS reports no such event to
  other apps, so this is not available; use Win+Shift+Up.

## Your own assets

Nothing from Windows is shipped. To use your own media: `make import-assets SRC=/path/to/Win7.iso`. This needs 7-Zip for macOS
(`7zz`) on your PATH, from https://www.7-zip.org/download.html. It is never downloaded for you. See `Assets/README.md`
for the layout and for fixing a wrong icon. Anything missing falls back to a built-in default.

Every icon comes from that one import. Then run `make install` (or copy the files in `Assets/icons` into
`~/Library/Application Support/Win7Mac/Assets/icons`), and `make chrome` and `make install-chrome` so the dylib embeds
the icons for sandboxed apps (Safari, TextEdit, Calculator, Preview). The shell reads the icons when it starts, Finder
and Safari when they launch. `make setup CHECK=1` reports how many icon names you have and how many map lines are
still `ICON/?`. Such a line's id is chosen on `Assets/_contact/<dll>.png` (see `Assets/README.md`). An `ICON/-` line
names an icon Windows 7 media do not have, so the drawn or macOS picture stays: IE's ✚ Add to Favorites, the battery
tray icons, Notes and Mobility Center.

### Wallpaper

Without an imported wallpaper, install generates a blue default in the spirit of the Windows 7 desktop (light ribbons
over deep blue, no logo), drawn at your largest display's resolution. Re-running `make install` refreshes that default
only while it is still your desktop picture; a picture you chose since is left alone.

To use the real Windows 7 wallpaper ("Harmony", `img0.jpg`), take it from your own Windows 7 install or disc. It is
Microsoft artwork, so it is never downloaded or included here:

- From an installed Windows 7: copy `C:\Windows\Web\Wallpaper\Windows\img0.jpg`.
- From your Windows 7 ISO or disc: `make import-assets SRC=/path/to/Win7.iso` extracts it as `Assets/wallpaper.jpg`
  (together with the other assets); then run `make install` or the command below to apply it.

Then, in one step:

```
make wallpaper SRC=/path/to/img0.jpg
```

This copies the picture to `Assets/wallpaper.jpg` (any image `sips` can read is converted to JPEG), copies it into
`~/Library/Application Support/Win7Mac/Assets/` and sets it on every desktop (`scripts/set-wallpaper.sh`, the same
step install uses). Before the first `make install` it only imports the file: install records your current wallpaper
first, so `make uninstall` can put it back.

### Gadgets

The desktop gadgets (Clock, Calendar, CPU Meter, Slide Show) use the gadgets' own artwork from your media when it
is there. The map line `gadgets/<Name> DIR Program Files/Windows Sidebar/Gadgets/*.Gadget` copies each gadget's
pictures (`*.png`, `*.jpg`, `*.gif` at the gadget folder's top level, in `images/` and in `images/<folder>/`) to
`Assets/gadgets/<Name>/` at the same relative paths, for example `Assets/gadgets/Clock/images/trad.png`. No HTML,
script or style file is copied. `make install` copies them to Application Support with the other assets.

| Gadget | Files in `images/` | What they draw |
|---|---|---|
| Clock | `<style>.png`, `<style>_h.png`, `<style>_m.png`, `<style>_s.png`, `<style>_dot.png`, `<style>_settings.png`, `settings_*.png` | The face and hands of the chosen style (`trad` by default; `system`, `cronometer`, `diner`, `flower`, `modern`, `square`, `novelty`). Options, from the gadget's toolbar or its right-click menu, picks the style and "Show the second hand" (off by default). |
| Calendar | `calendar_single.png`, `calendar_single_orange.png`, `calendar_ring_docked.png`, `curl.png`, `curl-hot.png`, `bPrev*.png`, `bNext*.png`, `month.png` | Today's page (orange) or another day's page (white, with the curl back to today). A click on the page opens the month view, its title the year view. |
| CPU Meter | `back.png`, `dial.png`, `dial_sml.png`, `dialdot.png`, `glass.png` | The CPU dial (left) and the memory dial with their readouts. The larger size (`*_lrg.png`) is not offered. |
| Slide Show | `in_sidebar/slideshow_glass_frame.png` (or `on_desktop/slideshow_glass_frame.png`), `in_sidebar/bg_sidebar.png`, `prev_*`, `play_*`, `pause_*`, `next_*`, `reveal_*` | The glass frame around the pictures from `~/Pictures` (when there are none, the imported wallpapers stand in), and the control bar while the pointer is over it. Reveal opens the picture in Preview. |

The sizes and positions follow the gadgets' own layout: Clock 130×130, Calendar 130×141, CPU Meter 130×101 and Slide
Show 130×100 points. A gadget whose files are missing keeps its drawn look, and the shell logs one line naming the
missing files.

### Segoe UI (dialogs and app text)

Segoe UI is a Microsoft font. It is never downloaded or included here. Take it from your own Windows install:

- From an installed Windows 7: copy `C:\Windows\Fonts\segoeui.ttf` (Regular) and `C:\Windows\Fonts\segoeuib.ttf` (Bold)
  into `Assets/fonts/`.
- From your Windows 7 ISO or disc: `make import-assets SRC=/path/to/Win7.iso` extracts both into `Assets/fonts/`.

Then run `make install`. It copies `Assets/` (and so `fonts/`) to `~/Library/Application Support/Win7Mac/Assets/fonts/`.
Each decorated app registers the two files from there when the chrome starts, for that app's process only
(`CTFontManagerRegisterFontsForURL`, process scope). Nothing is registered system-wide by this step. Sandboxed apps
can't read Application Support. For them the chrome uses the copies install.sh also puts in `~/Library/Fonts` (see
"What this changes"), which macOS makes available to every app.

With `segoeui.ttf` in place, the system font in decorated apps becomes Segoe UI at the same size: Regular, or Bold
for semibold and heavier weights (with no `segoeuib.ttf`, bold text keeps the system bold font). This covers
`+[NSFont systemFontOfSize:]`, `systemFontOfSize:weight:`, `boldSystemFontOfSize:`, and the message, menu, title bar,
label and control content fonts. Some text keeps the system font:

- Monospaced fonts (`monospacedSystemFont`, `monospacedDigitSystemFont`), so digits stay aligned.
- Sizes under 9 pt.
- Dark appearance.

If `segoeui.ttf` is missing, nothing is installed. Each app then logs one line,
`font substitution off: segoeui.ttf not imported`.

### Icon packs

If you have Windows 7 icons as `.ico` files (an `imageres-#N.ico` export of `imageres.dll`, or named icons such as
`explorer.ico`), zipped or in a folder:

```
make import-icons SRC=/path/to/imageres-icons.zip
```

Each icon is converted at its largest size into `Assets/icons/` (and the installed copy) under the name
`scripts/win7-icon-map.txt` gives it. The desktop then draws `folder.png` for folders and `file*.png` by file type, and
`app-<bundle id>.png` replaces an application's icon in the taskbar, Start menu, switcher and jump list. A file you put
in `Assets/icons/` yourself is never replaced unless you add `FORCE=1`. The shell reads the icons when it starts. See
`Assets/README.md` for the details.

### Finder (Explorer) icons

Finder's browser views (icon, list, column and gallery; not the desktop, which the shell draws) show the Windows 7
icons from the same `icons/` folder, relaunching Finder after an import:

- Folders: `folder.png`, and `folder-user`, `folder-desktop`, `folder-documents`, `folder-downloads`, `folder-music`,
  `folder-pictures`, `folder-videos` for your home and its special folders; a drawn Windows 7 folder when the PNG is
  missing.
- Files, by the type their extension names (the file is never read): `file-image.png`, `file-video.png`,
  `file-audio.png`, `file-text.png`, else `file.png`. A file whose type PNG is missing keeps Finder's icon; there is
  no drawn stand-in for files. As in Windows 7, which shows thumbnails from Medium icons up, pictures, videos, audio
  and other files (`file-image`, `file-video`, `file-audio`, `file`) get the type icon only below 48 pt (list,
  column and small icon sizes); at 48 pt and more Finder's own image stays, so its picture and video thumbnails,
  album art and PDF pages show. Text files (`file-text`) get the type icon at every size.
- Finder's own icon always stays for applications and other packages, aliases, symlinks, items with a pasted icon or
  a macOS folder customization, locked or unreadable items, volumes, and items showing copy or download progress.
- The address bar shows the same picture for the current folder (`drive-system.png` for `/`, `drive.png` for another
  volume, Finder's icon when it has none), its drop-down rows show the Windows 7 folder (`drive-system.png` for `/`
  and `drive.png` for another volume when present; the macOS folder for an application or other package), the
  details pane shows the folder or file icon, the command bar's Help button shows `help.png`, the navigation
  pane's Favorites header shows `favorites.png` (each keeps its drawn or macOS picture when the PNG is missing), and
  its Recents and Shared rows show `recent-places.png` and `shared.png` (Finder's icon when the PNG is missing).

To keep Finder's own folder and file icons: `defaults write -g W7FolderIconsDisabled -bool YES` (or
`defaults write com.apple.finder W7FolderIconsDisabled -bool YES`), then relaunch Finder.

### Message box and application icons

In every decorated app (relaunch it after an import; sandboxed apps such as Safari, TextEdit, Calculator and Preview
read the copies `make chrome` embeds, so run `make install-chrome` first):

- **The app's own icon** (its title bar, its alerts and its Dock tile while it runs) is `app-<bundle id>.png` when you
  have it, for example `app-com.apple.TextEdit.png`; apps without one (Notes has no icon on Windows 7 media) keep
  their macOS icon. Never the shell. One log line per launch: `app icon: app-<bundle id> applied / absent / disabled`.
- **Message boxes** that still show the application icon get `msgbox-warning.png` (critical alerts) or
  `msgbox-info.png` (informational ones); other alerts, and these when the PNG is missing, show the app's own icon from
  above. An icon the app chose itself is never replaced, and Safari's alerts are left alone. On a critical alert
  AppKit draws `msgbox-warning.png` as the main picture with the application's icon as its small badge. If the app
  sets an icon of its own while it runs (Activity Monitor's Dock graph), its alerts keep AppKit's icon.

To keep macOS's icons: `defaults write -g W7AppIconDisabled -bool YES` (the app's own icon) and
`defaults write -g W7MessageBoxIconsDisabled -bool YES` (message boxes), or per app with
`defaults write <bundle-id> …`, then relaunch the apps.

## Stopping a crash loop

If the shell keeps crashing and respawning, stop it with `launchctl bootout gui/$(id -u)/com.win7mac.shell`. The startup sound plays at most once per login session, so a respawn does not replay it.

## Kill switch & denylist

- Turn the chrome off everywhere: `defaults write -g W7ChromeDisabled -bool YES` (relaunch apps). Remove with `defaults delete -g W7ChromeDisabled`.
- Skip single apps: `defaults write -g W7ChromeDenylist -array "com.apple.Safari" "com.example.App"` (bundle IDs).
- System processes are always excluded by the blacklist in [scripts/blacklist.txt](scripts/blacklist.txt) (one process name per line; used by both `make install-chrome` and install.sh).
- Turn off the 8 pt Aero glass frame round decorated windows (left, right and bottom; a separate, click-through window that follows each window): `defaults write -g W7FrameBorderDisabled -bool YES`, or `defaults write <bundle-id> W7FrameBorderDisabled -bool YES` for one app (relaunch apps).
- Leave macOS's own window corner radius alone (the glass frame then paints over the rounded corners instead of giving the window 6 pt top and square bottom corners): `defaults write -g W7CornerRadiusHookDisabled -bool YES`, or per app as above (relaunch apps).
- Turn off the Windows 7 message box look of alerts (white message area, grey button strip, glass caption): `defaults write -g W7MessageBoxDisabled -bool YES`, or per app as above (relaunch apps).
- Leave dialog panels (About, Preferences, Get Info: the Aero caption with only a close button, the white body and the grey button strip) native: `defaults write -g W7DialogPanelDisabled -bool YES`, or per app as above (relaunch apps).
- Leave push buttons, check boxes, radio buttons and scroll bars native (no Windows 7 controls, no always-visible scroll bars): `defaults write -g W7ControlsDisabled -bool YES`, or per app as above (relaunch apps). In dark appearance these controls keep macOS's classic cell look.
- Turn off the Segoe UI substitution: `defaults write -g W7FontSubstitutionDisabled -bool YES`, or per app as above (relaunch apps).
- Keep Finder's own folder and file icons in its browser views: `defaults write -g W7FolderIconsDisabled -bool YES` (relaunch Finder). See [Finder (Explorer) icons](#finder-explorer-icons).
- Keep each app's own macOS icon (no `app-<bundle id>.png` in its title bar, alerts and Dock tile): `defaults write -g W7AppIconDisabled -bool YES`, or per app as above (relaunch apps).
- Keep macOS's alert icons (no `msgbox-warning.png` / `msgbox-info.png`): `defaults write -g W7MessageBoxIconsDisabled -bool YES`, or per app as above (relaunch apps). See [Message box and application icons](#message-box-and-application-icons).
- Stop apps from handling the taskbar's Close window / Close all windows themselves (the shell then presses the close buttons with Accessibility, or asks before quitting): `defaults write -g W7CloseChannelDisabled -bool YES`, or per app as above (relaunch apps).
- Keep macOS's own context menus (right-click menus and other pop-up menus in apps, and the shell's desktop, taskbar, tray and Start menu menus): `defaults write -g W7ContextMenusDisabled -bool YES`, or per app as above (relaunch apps and the shell). A menu the Windows 7 menu cannot draw (one with a custom view, or shown during a modal dialog) is always macOS's.
- Messages framed like Windows Live Messenger (chrome only): in Messages' main window the toolbar's band under the Aero caption becomes Messenger's pale blue header (`#DFEFFC→#C4DDF5`) with your picture (`Assets/icons/user.png`, else a drawn silhouette), your name, a green "Available ▾" status orb and the Messenger toolbar row ("Send an instant message", "Send a file", "Video call", "Add a contact", drawn disabled: Messages' own toolbar does the work). It is drawn in the free space between Messages' toolbar items and under them, so no item is covered, moved or hidden; a 64 pt band when the toolbar band is that tall, else a 32 pt compact one (name and status on one line). Messages is a UIKit app on macOS 27, so its conversation list, transcript and composer keep the macOS look, and nothing is read from the window (contacts, message text and titles never reach the band). Turn it off with `defaults write -g W7MessagesLookDisabled -bool YES` (relaunch Messages).
- Keep macOS's own toolbar look in apps (Notes, Help Viewer, Mail and others; Safari and Finder have their own Internet Explorer and Explorer bars): `defaults write -g W7ToolbarLookDisabled -bool YES`, or per app as above (relaunch apps). The look paints the Windows 7 command bar behind the toolbar, tints the glass of every toolbar item to the bar's colour (the search field's white) and covers the Liquid Glass pill with an opaque slice of the bar under the item (a white box under the search field), puts those glass settings back when macOS resets them, and gives plain buttons the flat Windows 7 hover and pressed face; items, their order, labels, search fields, pop-ups and segmented controls themselves are never changed, and dark appearance keeps the native toolbar. `defaults write -g W7ToolbarVerboseLog -bool YES` logs each toolbar window's view classes and frames once (no titles).
- Keep Finder's own Computer location (Go ▸ Computer) instead of the Windows 7 Computer view ("Hard Disk Drives", "Devices with Removable Storage" and "Network Location" groups of drive tiles with capacity bars, red under 10 % free, and the Computer command bar: System properties, Uninstall or change a program, Map network drive, Open Control Panel): `defaults write -g W7ComputerViewDisabled -bool YES` (relaunch Finder). The view lies over Finder's own (which stays underneath, untouched) and goes away the moment the window navigates; drive facts come from the file system's volume values, and no path or name is logged. Click selects (the details pane shows the drive), double-click opens the drive in Finder, right-click offers Open, Eject and Properties; clicking the navigation pane's Locations header goes to Computer.
- Keep apps running after Close window / Close all windows closes their last window (Finder always stays): `defaults write -g W7CloseKeepAlive -array com.apple.Music com.apple.mail` (takes effect at the next close).
- Stop the shell from moving app windows out of the taskbar band (a window that settles with its bottom under the bar is moved up, or clamped to the visible height; fullscreen windows, sheets, panels and the shell's own windows are never moved, and nothing moves while the mouse button is down): `defaults write com.win7mac.shell W7WorkAreaDisabled -bool YES` (takes effect within 5 s).
- Stop the shell from quitting and reopening apps that started before Ammonia injected (at login), and from offering it in a tray balloon (later): `defaults write com.win7mac.shell W7RelaunchDisabled -bool YES` (read 8 s after the shell starts).
- Put the taskbar back at the status-bar window level (above the screenshot thumbnail and Dock-level system UI, as before): `defaults write com.win7mac.shell W7TaskbarLevelLegacy -bool YES` (restart the shell).

## System Settings

On macOS 27 the sidebar's rows are SwiftUI cell hosts (measured with `W7SettingsVerboseLog`: 39 `CellHostingView` rows, no AppKit image or text cells), so their icons and fonts cannot be changed with public API; the Windows 7 face of settings is the shell's Control Panel and its own windows.

- On macOS 26 and later the System Settings sidebar is Liquid Glass, and public APIs can't restyle it. Nothing drawn under or inside the glass shows, and there is no public setting that turns the glass off. So in System Settings the Windows 7 look is limited to a white window background; the Windows 7 Control Panel is the shell's own window (see [Control Panel](#control-panel)). The sidebar, its selection, and each pane's content stay as macOS draws them, including fonts, switches and accent colour. Each pane's content is drawn by a separate process and is never touched.
- The white background applies only while the visible pane isn't a security pane. These stay fully native, window included, for as long as one of them is showing:
  - Privacy & Security
  - Home privacy settings
  - Security improvements
  - Touch ID & Password
  - Users & Groups
  - Lock Screen
  - Passwords
- If the visible pane can't be identified (while panes switch, for example), the window also stays native. Nothing of win7mac loads into the security panes' own processes: they are listed both in [scripts/blacklist.txt](scripts/blacklist.txt) and in the dylib's built-in denylist.
- Light appearance only. In Dark Mode the window stays native.
- To turn it off: `defaults write com.apple.systempreferences W7SettingsPanelDisabled -bool YES`, then relaunch System Settings. Remove with `defaults delete com.apple.systempreferences W7SettingsPanelDisabled`.
- Diagnostics: `log stream --predicate 'subsystem == "com.win7mac.chrome" AND eventMessage BEGINSWITH "settings panel"'`.
  - A summary line on each pane change shows the detected pane ids and whether the window is styled.
  - Each switch between styled and native logs one `settings panel transition` line per changed property, as `name: original → current`. After a switch back to native, the two values in each line should match.
  - To also log the window's view tree on every change, run `defaults write com.apple.systempreferences W7SettingsPanelVerboseLog -bool YES` and relaunch System Settings (the flag is read once per launch).
- Sidebar diagnostics: `defaults write -g W7SettingsVerboseLog -bool YES` (relaunch System Settings) logs `settings sidebar diagnostics` once per main window: the sidebar's view tree only (classes, frames, the list kind with its row, cell, image view and text field classes and counts, SwiftUI hosts, glass containers). Names and numbers only, never row titles; nothing is drawn, and the pane content is never walked. `defaults write -g W7SettingsSidebarDisabled -bool YES` turns even the dump off.

## Control Panel

System Settings itself can't be restyled (see above), so the Windows 7 Control Panel is a window of the shell's own.
Open it from the Start menu's **Control Panel**. It has a taskbar button while it is open (click it to minimize or restore it, right-click it to close
it).

- The home page shows Windows 7's eight categories with their links. **View by** switches to Large or Small icons, a
  flat list of every item; the choice is remembered (`controlPanelViewMode` in `com.win7mac.shell`).
- A category opens its page of items. Back and forward work like Explorer's (also Option+Left / Option+Right), and the
  address bar's crumbs are clickable. "Search Control Panel" filters items as you type, by name, task or macOS name
  ("FileVault" finds BitLocker Drive Encryption).
- Esc (clearing a search first), Option+F4 (Alt+F4), Control+Option+F4 or Command+W closes it. Its size and position are
  remembered.
- Nothing in it changes a setting. Every item only opens something: the real System Settings pane, as macOS draws it
  (`x-apple.systempreferences:<pane id>`), a macOS app (System Information, Disk Utility, Font Book, Safari for
  Internet Options...), a Finder folder (Programs and Features opens Applications), or a short page of its own (how to
  import a wallpaper or icon pack, the taskbar's settings keys, Desktop Gadgets, Folder Options).

| Windows 7 | Opens |
| --- | --- |
| Action Center | Notifications; its tasks open Privacy & Security, Disk Utility, Time Machine |
| Windows Firewall | Network (the firewall lives there since macOS 15) |
| System, Device Manager | General > About; System Information; the shell's Device Manager (below) |
| Windows Update | Software Update |
| Power Options | Battery (Energy on a desktop Mac), Lock Screen |
| Backup and Restore, Recovery | Time Machine settings; the Time Machine app |
| BitLocker Drive Encryption | Privacy & Security (FileVault) |
| Administrative Tools | the Utilities folder; Storage, Disk Utility, Console |
| User Accounts, Parental Controls | Users & Groups, Touch ID & Password; Screen Time |
| Credential Manager | Passwords |
| Network and Sharing Center, HomeGroup | Network, Wi-Fi; Sharing |
| Personalization, Display | the shell's Personalization and Desktop Background (below); Appearance, Wallpaper, Sound; Displays |
| Taskbar and Start Menu | the shell's own page listing its defaults keys |
| Notification Area Icons, Windows Mobility Center | Control Center, Notifications |
| Folder Options, Fonts | a Finder window (and how to reach Finder's settings); Font Book |
| Devices and Printers, AutoPlay | the shell's Devices and Printers (below), Printers & Scanners, Bluetooth, Mouse; CDs & DVDs (hidden if absent) |
| Sound, Mouse, Keyboard | Sound, Audio MIDI Setup; Mouse, Trackpad; Keyboard |
| Date and Time, Region and Language | Date & Time, the Clock app; Language & Region, Keyboard |
| Programs and Features, Default Programs | the Applications folder; Desktop & Dock (default web browser) |
| Calculator | the shell's Windows 7 Calculator (below) |
| Ease of Access Center, Speech Recognition | Accessibility; Siri, Keyboard (Dictation), Sound |
| Indexing Options, Color Management, Performance, Sync Center | Spotlight, ColorSync Utility, Activity Monitor, Apple Account |

The pane ids were read from the Settings extensions installed on macOS 27.0.1
(`scripts/control-panel-pane-ids.sh`, committed as `scripts/fixtures/control-panel-pane-ids.txt`); `make test` checks
that each still exists on this Mac. When a pane or app a link needs is missing, the window hides that item or link (it
checks once, when it first opens). Icons are your imported `cp-<name>.png` files (names in
`scripts/win7-icon-map.txt`), else older shared names such as `network.png` and `devices.png`, else drawn ones.

### Device Manager and Devices and Printers

Two read-only windows of the shell, framed like the Control Panel and with a taskbar button each. **Device Manager**
opens from System's and Devices and Printers' "Device Manager" links: the computer's name, then Windows 7's device
categories (Audio inputs and outputs, Batteries, Bluetooth, Cameras, Computer, Disk drives, Display adapters, Keyboards,
Mice and other pointing devices, Monitors, Network adapters, Print queues, Processors, Storage controllers, Universal
Serial Bus controllers; empty ones are hidden). Double-click a device, or use the toolbar's Properties, for its
General tab (device type, manufacturer, location, status). **Devices and Printers** opens from the Start menu, the
Control Panel item and Hardware and Sound's "View devices and printers": this Mac, its keyboards, mice, monitors and
connected Bluetooth devices, and the printers; "Add a device" and "Add a printer" open the Bluetooth and Printers &
Scanners panes.

Each time one of them opens, the shell runs `/usr/sbin/system_profiler -json -detailLevel mini` once for the device data
types (off the main thread, at most 20 s and 8 MB of output) and keeps only names, categories, manufacturers and a
coarse location — no serial numbers, network addresses or paths, and only counts go to the log. Nothing in either
window installs, updates, disables or removes anything. Icons are `dev-<name>.png` (see `Assets/README.md`).

### Screen Resolution

The desktop's "Screen resolution" and Control Panel ▸ Display ▸ "Adjust resolution" open the shell's Screen Resolution
window. It only picks among the modes macOS offers, through the public CoreGraphics display configuration API; nothing
is written to firmware or `nvram`. A new mode is first applied for the shell only (`.forAppOnly`): if the shell quits,
crashes or is killed during the 15 s "Keep changes?" countdown, macOS puts the old mode back on its own, and a normal
quit reverts it at once. Only **Keep changes** stores it (`.permanently`); Revert, Esc, closing the dialog or letting
the countdown run out restores the previous mode. If a kept mode does not survive quitting and relaunching the shell
(macOS ignoring the re-commit of the current mode), the fallback is to apply the trial mode `.forSession` instead in
`CoreGraphicsDisplays.setMode`: it then reverts at logout or restart rather than when the shell exits.

### Windows Help and Support and the Start menu's right column

The Start menu's **Help and Support** opens the shell's own Help window (no Help Viewer, nothing online): the Help
toolbar (Back/Forward, Home, Print, Browse Help, Ask, Options with Text Size), "Search Help", and topics written for
win7mac — the taskbar, the Start menu, Explorer, Control Panel, importing your Windows 7 assets, the switches and
removing it. Its links open other topics, Control Panel items and Device Manager; "More on the Windows website" opens
this README (copied into the app by `make shell`). **Computer** opens Finder's own Computer helper
(`Finder.app/Contents/Applications/Computer.app`, the same place as Go > Computer), shown as the Windows 7 Computer
view; **Default Programs** does what the Control Panel item does.

The Start menu pins Finder, Safari, Calculator, Notes, Terminal and Preview on first run only; saved pins (`startPins`)
are never changed or reordered. Its recent programs include programs started from the Dock, Finder or Spotlight. A
pinned or recent program with recent documents shows a ▸ when highlighted: point at it (or click it, or press Right)
for the taskbar jump list's Recent rows (Finder: Frequent folders).

### Windows names and the Calculator

Wherever the shell names a program (the Start menu's left pane, All Programs and search results, taskbar tooltips and
jump lists, the switcher), these get their Windows 7 names; every other program keeps its macOS name, and search still
finds a renamed one by its macOS name:

| macOS | Shown as |
| --- | --- |
| Finder, Safari, Terminal | Windows Explorer, Internet Explorer, Command Prompt |
| Notes, TextEdit, Activity Monitor | Sticky Notes, Notepad, Task Manager |
| Music, Preview, Calculator, System Settings | Windows Media Player, Windows Photo Viewer, Calculator, Control Panel |
| Mail, Messages, Photos | Windows Live Mail, Windows Live Messenger, Windows Live Photo Gallery |

macOS Calculator's buttons are SwiftUI content the injected code cannot restyle, so **Calculator** is a window of the
shell's own, framed like the Control Panel: Windows 7's Standard mode (MC MR MS M+ M−, ←, CE, C, ±, √, %, 1/x and the
four operations), with Windows' arithmetic — operations run as typed (`2 + 3 × 4 =` is 20), `=` again repeats the last
operation, `50 + 10 %` is 5, and 16 significant digits in decimal, so `0.1 + 0.2` is 0.3. The keyboard works as in
Windows (digits, operators, Enter, Esc = C, Delete = CE, Backspace, `@` = √ however your layout types it, Option+Q
included, `R` = 1/x, F9 = ±, Control+L/R/M/P/Q = MC/MR/MS/M+/M−); Edit ▸ Copy and Paste (Command+C / Command+V)
exchange the display's number (Paste takes only a whole number, such as `-1,234.5`; up to 16 digits it can be edited
with Backspace). The numbers reach about 3.4e165 (round ones such as 1e128 overflow sooner), where Windows 7 goes
to 1e10000: beyond that the display shows Overflow. View ▸ Digit grouping is remembered
(`calculatorDigitGrouping`). The Start menu's Calculator (pinned, recent or found by search) and Programs ▸ Calculator
open it; All Programs still lists the macOS Calculator app, which opens as itself.

### Personalization and Desktop Background

The desktop's right-click **Personalize**, the Personalization item and Appearance and Personalization's "Change the
theme" open the shell's **Personalization** window: one tile per Windows 7 theme you imported (Aero Themes; the
regional sets such as United States under Installed Themes). Clicking a theme sets its pictures as a slideshow (Fill, a
new picture every 30 minutes, shuffled). The row under the list opens **Desktop Background**, the Window Color note,
the Sound pane and the Screen Saver (Wallpaper) pane.

**Desktop Background** ("Change desktop background") offers Windows Desktop Backgrounds (the imported themes), Pictures
Library (the top level of `~/Pictures`), Solid Colors and Browse... for any folder. Click a picture to use it alone,
tick more check boxes (or Select all) for a slideshow, then choose Picture position (Fill, Fit, Stretch, Center; Tile
shows as Fill, macOS cannot tile), "Change picture every" (10 seconds to 1 day) and Shuffle. A click shows on the
desktop at once; Cancel or closing the window puts the previous picture back, Save changes keeps the choice
(`W7WallpaperSettings` in `com.win7mac.shell`; a slideshow goes on after the shell restarts).

The shell's desktop is transparent, so the choice is the macOS desktop picture, set on every screen with
`NSWorkspace.setDesktopImageURL` (a solid colour as a small picture in
`~/Library/Application Support/Win7Mac/Wallpaper/`). Another Space gets the current picture when you switch to it,
unless its picture was changed elsewhere. The themes come from your own disc: `make import-assets SRC=/path/to/Win7.iso`
copies every folder of `Windows\Web\Wallpaper` and the regional `Windows\Globalization\MCT\MCT-*\Wallpaper` sets from
every image of `install.wim` into `Assets/wallpapers/<Theme>/`; copy that folder into the installed Assets (or run
`make install`) for the shell to list them.

## Safari looks like Internet Explorer 7

In Safari's **Separate** tab layout (Settings > Tabs), ordinary browsing windows get the look of Internet Explorer 8 on
Windows 7:
- the caption and the navigation row on the Aero glass, the favourites and tab rows on IE8's pale band;
- IE8 tabs drawn by win7mac over Safari's own (invisible) tabs, and the round back/forward orbs;
- a 22 pt status bar at the bottom: the link under the pointer or "Done", and a progress bar while a page loads. It never
  shows a security zone.

What is never changed, in any state: the address field and everything in it, the lock and privacy indicators, AutoFill
and completion lists, password and authentication sheets, the downloads and privacy report buttons, Lockdown Mode, and
web extension buttons and popovers. **Private windows, popups, full-screen windows and the Compact layout get none of the
IE chrome**: they keep Safari's own toolbar, tabs and backgrounds, under the Aero title bar every decorated window gets.

### The rows
- **Navigation row:**
  - Back/forward orbs first, then the address field, then Safari's other buttons together at the right, where IE has
    its search box. Flexible spaces are left out and nothing is centred.
  - Only Safari's toolbar items are reordered, through the public toolbar API; the address field itself is never touched.
  - Windows of one profile share their toolbar, so all of them show this order while any of them is themed. Full-screen
    windows are included.
  - Safari's own order and centring come back exactly when the last themed window sharing the toolbar is un-themed or
    closed.
  - Autosave is off on every window with that toolbar meanwhile (new windows too), so Safari's saved toolbar never
    changes. If the order cannot be fully restored, autosave stays off for the session rather than save a partial
    order.
  - Items added or removed while themed join the saved order.
- **Menu strip:** directly under the navigation row. If Safari puts its tab bar above the strip (it can after a
  relaunch), the strip is moved back to the top.
- **Tab row:**
  - "★ Favorites" at the left: IE's Favorites Center, which here is Safari's Bookmarks sidebar (View ▸ Show Bookmarks
    Sidebar, performed through Safari's own menu item). A right-click, or a press held half a second, opens a small
    menu of Safari's own items: Bookmarks sidebar, Reading List sidebar, Show Bookmarks, Show All History, Show
    Favorites Bar.
  - "✚" next to it: Safari's Add Bookmark…. It follows Safari's own validation of that item: on the Start Page or an
    empty tab it is greyed, a click does nothing and its tooltip says "Open a page first". It is checked again when a
    tab is selected, when a page starts or finishes loading, when the window becomes key and when the row is laid
    out, at most four times a second per window and only for the key window (another window keeps its last state);
    a click always asks Safari afresh, so a stale state never swallows one.
  - The tabs.
  - A blank new-tab stub (Safari's New Tab button, else its menu item).
  - At the right, the command bar: Home (History ▸ Home) and Print (File ▸ Print…) icons, then Page ▾ (Zoom In / Zoom
    Out / Actual Size, Save As…, Export as PDF…, Text Encoding ▸, Show Reader; Show Page Source only when Safari's
    Develop menu is on), Safety ▾ (New Private Window, Clear History…, Privacy Report…, the certificate), Tools ▾
    (Downloads, Extensions…, Settings… — Safari's own title, Show Status Bar, Enter Full Screen) and Help ▾ (Safari's
    Help menu).
  - Every command is one of Safari's own menu items, found by its action selector in Safari's main menu (the names
    Safari uses today, with older names as fallbacks). They run only when Safari's own validation enables them, and
    each menu is rebuilt from copies of Safari's items when it opens, so titles, shortcuts and validation are Safari's.
  - A command Safari has no item for is hidden. Feeds and Mail are not shown.
  - Each click logs one line: the control, the selector, whether Safari enabled it and whether it was sent. Never a
    page title or URL, never a bookmark.

### Tab layout
Safari hides the tab bar while a window has a single tab, so the tab row shows only with two or more tabs, or with
View > Always Show Tab Bar turned on.

The tabs are laid out the way IE does it:
- left-aligned after the ★/✚ group, 2 pt apart, instead of Safari's equal widths filling the row;
- each sized to its whole title, between 120 and 220 pt;
- a title that fits under the cap is never cut off: when Safari's own layout truncates it, the tab grows until it shows;
- pinned tabs stay where Safari puts them, and the IE tabs start after them.

When there are more tabs than room between the Favorites group and the command bar:
- every tab shrinks in proportion, as IE8 does, down to 100 pt;
- if they do not fit even then, Safari's own layout and scrolling take over, inside that room;
- nothing of ours is ever drawn over a tab: a control that would cross one is hidden.

While a tab is dragged, Safari's layout is left as it is. If Safari keeps undoing ours (more than 30 times a second at
one width), the IE layout backs off for that window and tries again 10 s later or when the window is resized.
At launch the titles are not there yet: a pass that finds every title unsized keeps Safari's widths instead of
freezing every tab at the floor, and the row is laid out again (once, coalesced to one pass per 100 ms per tab bar)
whenever a tab's title arrives or changes width. Safari's tab separators are kept invisible wherever Safari keeps
them: its separator table, any separator-named ivar of the tab bar or a tab button (a view or a collection of them),
and the tab container and tab scroll view themselves. Safari's own separator fade only dims a short sliver inside the
separator, so the separator view itself is set to alpha 0 as well; only views whose class name contains "Separator"
are touched, and they get their alphas back when the window is un-themed.

### Tab look
The tabs are drawn by win7mac. Safari's Liquid Glass always renders a pill with its own sheen, so tinting it
can never give IE's flat tabs. Instead:
- Safari's tab buttons stay exactly where they are and do everything they always did: click, drag, close, the context
  menu, hover. Only their faces (the glass, the backgrounds and the content holding the title, icon and close button)
  are made invisible: alpha 0, never hidden, so hit testing and layout keep working. Every alpha is saved first and
  put back when the window is un-themed or closed, with the kill switch, or whenever a tab stops being styled.
- Over each one, win7mac draws an IE8 tab at the button's exact frame (so it follows Safari's layout, the IE tab row,
  scrolling and drags on its own). It never takes a click.
  - Colours sampled from the IE8 screenshot. Every tab has a 1 px `#A3A7AC` outline with a white line
    just inside it and 2 pt top corners.
  - **Unselected tabs:** just that outline on the row's `#E3EEFB`, square bottom, 2 pt shorter, standing on the row's
    `#8B919F` line. A little lighter (`#F7FAFE→#E9F1FB`) under the pointer.
  - **The selected tab:** `#C3DDFB→#F0F4FB`, full height, no bottom line, so it runs into the `#F2F6FB` strip above the
    page.
  - The favicon (16 pt) and the title (12 pt, black, shortened in the middle with "…") are read from Safari's tab for
    drawing only. They are never logged or kept.
  - A grey × (red under the pointer) at Safari's close button, whenever Safari shows it. The × is at the right end of
    the tab as in IE8: Safari's own close button is moved there while the tab is styled (not replaced; it is put back
    exactly when the styling comes off). Safari's own layout puts it back at the left when it shows the × under the
    pointer; its frame is watched while the tab is styled, so it is put at the right the same instant and the ×
    follows Safari's hover without a jump; if Safari keeps moving it back many times a second at one size it is left
    where Safari puts it for 10 s, until the tab is resized or until the pointer enters that tab. Safari's own
    animations (closing a tab widens the others frame by frame) do not count as such a fight. The title stays and the
    × no longer sits over the favicon. A tab whose icon is one of Safari's symbol placeholders (the Start Page star)
    gets IE's generic page icon (your `ie-page.png` when you imported it, see [Icons](#icons)). Websites' favicons
    are always their own.
  - A glyph at each of Safari's other visible controls inside the tab (a speaker for the audio button, a small ring
    for anything else), so nothing that still takes a click is invisible.
  - A tab is redrawn only when its state, title, favicon or close button changes.
  - Which tab is hovered (its × and highlight) follows the tabs as they are on screen. Safari works it out from its own
    layout model, which still holds Safari's widths after the IE layout, so the × used to appear on the tab whose
    Safari frame was under the pointer. While the IE layout is in force, Safari's own lookup answers from the tabs'
    real frames instead (nothing between tabs or over the ★ group); during a drag, a back-off or with the IE layout
    off it is Safari's own again, and after every pass that moves tabs Safari re-resolves the highlight once.
- The new-tab stub is a small blank unselected tab (28 pt): the outline on the row. "★ Favorites", "✚" and the command bar are text and icons on
  the row, with a flat 1 px `#A0B4CC` frame only under the pointer.

What still comes from Safari: every tab's behaviour and position, its title and favicon (drawn by us), the tab bar's
scrolling and overflow, drag images, and pinned tabs (drawn as icon-only IE tabs).

The rows: the caption and navigation row are Aero glass (`#6A8FC6` over white,
with a white highlight line under a `#151C27` outer line). The favourites and tab rows are an opaque pale band: a white
top line, `#F2F7FD→#E3EEFB` over 12 pt, then `#E3EEFB`, with the `#8B919F` line along the tabs' bottom edge and the
`#F2F6FB` strip under it.

Toolbar buttons are tinted through the glass's public settings:
- Back/forward sits on a pale blue IE capsule.
- The sidebar, tab group, new tab, tab overview, share, reload, home and other Safari buttons get the light IE button
  face.
- The address field, downloads, privacy report, Lockdown Mode and web extension buttons keep Safari's glass.

In dark appearance the toolbar buttons are not tinted.

### Icons
The command bar's pictures are the Windows 7 ones from your `icons/` folder (see [Icon packs](#icon-packs)):
`favorites.png` for ★ Favorites, `ie-add-favorite.png` for ✚, `ie-home.png` for Home, `ie-print.png` for Print and
`ie-help.png` for Help ▾ (✚ greyed at 40 % while Safari disables it), and `ie-page.png` is the page icon of a tab
showing one of Safari's placeholders. Each keeps its drawn IE glyph when the PNG is missing (Windows 7 media have no
Add to Favorites icon, so ✚ stays drawn). Safari is sandboxed and cannot read `~/Library/Application Support`: it
uses the copies `make chrome` embeds in `Win7Chrome.dylib` (at most 128 px each), so run `make install-chrome` after
an import and relaunch Safari. Safari's alerts keep their icons (download and permission dialogs are never changed);
Safari's own icon is replaced by `app-com.apple.Safari.png` as in every app (see
[Message box and application icons](#message-box-and-application-icons)).

### Switches
Relaunch Safari after any of these.
- Turn everything off: `defaults write -g W7SafariChromeDisabled -bool YES`. Safari's own icon is separate: keep it with
  `defaults write com.apple.Safari W7AppIconDisabled -bool YES`.
- Drop every hook into Safari's own classes: `defaults write -g W7SafariHooksDisabled -bool YES`. This also drops the
  drawn tabs, the glass tint, the IE tab layout, the ★/✚ group, the new-tab stub and the command bar. Only the
  public-API layers stay: the status bar, the rows' band, the orbs drawn over the control, and the toolbar order.
- Keep Safari's own tabs (its glass, untinted): `defaults write -g W7SafariFacsimileTabsDisabled -bool YES`.
- Leave the toolbar buttons' glass as Safari draws it: `defaults write -g W7SafariGlassTintDisabled -bool YES`.
- Keep Safari's own tab widths and positions: `defaults write -g W7SafariIETabLayoutDisabled -bool YES`. The ★/✚ group,
  the stub and the command bar go with it, because that pass places them.
- Keep Safari's toolbar order: `defaults write -g W7SafariToolbarOrderDisabled -bool YES`.
- Drop only the ★/✚ group, the new-tab stub and the command bar: `defaults write -g W7SafariCommandBarDisabled -bool YES`.

### Diagnostics
No page titles or URLs are logged. Watch with
`log stream --predicate 'subsystem == "com.win7mac.chrome"' | grep -E "Safari (chrome|glass|tabs|toolbar|command|facsimile)"`.
- **Window state:** logged a second after a window is themed, and again when its tab bar first appears or its title bar
  accessories change. At most 3 times per window. It includes the drawn tabs: `facsimile tabs: N drawn by win7mac;
  Safari's faces at alpha 0: k of m found …; _closeButton found on n`, `facsimile close buttons: moved to the right end
  n, left where Safari puts them (backed off) n, not found n; template tab icons … n`, and, for the selected tab, where
  it is hosted, whether its drawing shows in the window's layer tree, and its bottom edge against the tab scroll view's.
- **Glass:** one `Safari glass:` line per glass view per window: styled, with its old → new style, tint and radius, or
  skipped and why. At most 40 per window.
- **Tab row:**
  - `Safari tabs: IE7 layout applied to N tabs …` (`, shrunk to fit` when shrunk);
  - `Safari tabs: N tabs do not fit at the 100 pt floor: Safari's layout inside the reserved room …`;
  - `… backed off …` when Safari keeps undoing the layout;
  - `Safari tabs: IE7 layout left to Safari for this pass: titles not sized yet (titles unsized: N of N) …` once per
    tab bar at launch; the window diagnostics add `IE7 tab layout: N passes applied, N left to Safari (titles unsized),
    N re-layouts requested by title changes (N coalesced passes run), …, hover: _tabBarButtonAtPoint: hooked (N answered
    by frames, N passed to Safari)` (or `not hooked`), and the hook report carries `UnifiedTabBar -_tabBarButtonAtPoint:
    hooked (hovered tab from our frames)` or why it was left alone.
- **Tab styling:** `Safari tabs: tab (x,y w×h) (selected) in <view>: <reason>`, once per tab per reason, for example
  `facsimile drawn (glass …, content in …, _closeButton moved to the right end, shown, in NSStackView, …, icon image)`, window not themed,
  `_unifiedField` set or facsimile tabs off. At most 80 lines per Safari process, always on. `Safari tabs: close button
  left where Safari puts it …` once per window when Safari kept moving a close button back.
- **Navigation row:** `Safari toolbar: IE7 order applied: … → …`, with the address item's width before and a second
  after; `Safari toolbar: Safari's order restored …` on restore.
- **Command bar:** `Safari command bar: …` lists, once per tab bar build (again after a restore), which of Safari's menu actions ★, ✚, the stub,
  Home, Print and each ▾ menu resolved to (or that one is hidden). Then one line per click: `Safari command bar:
  Favorites → toggleBookmarksSidebar: (enabled yes, sent yes)`, or `… Page ▾ opened with N of Safari's items`.
- **Verbose:** `defaults write -g W7SafariVerboseLog -bool YES` adds investigation detail: the title bar z-order, up
  to 10 tab bar lines per window, and once per Safari process a `tab bar dump`: the tab bar's view subtree (14 deep,
  120 views at most: class, frame, alpha, hidden, layer background/border, and for a separator which ivar or table
  holds it), the separator/divider/line ivars of the tab bar and tab button classes (name, type, value class), the
  tab bar's and tab button's own method names about hover, highlight, mouse, point, track, closeButton, visible,
  under, location and hit (one line per class, at most 200 names), the tab bar's geometry ivars (frame, rect, layout,
  hover, highlight, track, mouse, point, button: name and type encoding) and the tracking areas of the tab bar, its
  scroll view and document view, and each visible tab (rect, options, owner class). Class and method names and
  frames only, never text.
- **Messages:** `defaults write -g W7MessagesVerboseLog -bool YES` (relaunch Messages) logs `Messages diagnostics` once per main window: its view tree (classes, frames, SwiftUI hosts, split view panes, table/outline/collection views with counts), the toolbar's item identifiers and the contentLayoutRect. Names and numbers only, never contact names or message text. `W7MessagesLookDisabled` turns the dump off too.

## Title bar blur and performance logging

- The Aero title bars are a static glass drawing by default: no behind-window blur, so WindowServer does not re-blur what is behind every decorated window as it moves. To bring the blur back: `defaults write -g W7TitlebarBlur -bool YES` (every app), or `defaults write <bundle-id> W7TitlebarBlur -bool YES` for one app, then relaunch the apps. Remove with `defaults delete -g W7TitlebarBlur`.
- Slow-path log: `defaults write -g W7PerfLog -bool YES` (relaunch the shell and apps) logs every main-thread interval over 16 ms. Watch it with `log stream --predicate 'subsystem BEGINSWITH "com.win7mac" AND category == "perf"'`. The same intervals are always available as signposts (category `perf`) in Instruments' os_signpost track. Remove with `defaults delete -g W7PerfLog`.

## Known gaps

- Apps that macOS reopens at login (Terminal, Safari, Notes, ...) can start before Ammonia injects and keep the macOS frame. The shell checks 8 s after it starts, once Finder shows that injection works. Within the first minute after login it quits and reopens the apps that started with the login itself, one at a time (an app with unsaved work asks first; if you confirm within 2 min it is reopened then, otherwise it stays open). Any other app without the frame, and every app when the shell starts later or the Mac sleeps meanwhile, is offered from a tray balloon instead: a click restarts them, its × hides it until the shell restarts. Intel apps under Rosetta can never get the frame and are left alone. `defaults write com.win7mac.shell W7RelaunchDisabled -bool YES` turns both off.
- Context menus in some views stay native (v1 hooks only +[NSMenu popUpContextMenu:...]).
- Finder keeps its own icon for applications, packages, aliases, symlinks, items with a pasted icon, locked or unreadable items and volumes, and for every file whose type icon you have not imported (see [Finder (Explorer) icons](#finder-explorer-icons)). Badges Finder composes into a replaced icon (shared, for example) are lost.
- Push buttons and checkboxes inside apps stay macOS. So do text and search fields, pop-up buttons, tabs, progress bars, sliders and group boxes.
- Window frames: decorated windows get Windows 7 corners (6 pt round at the top, square at the bottom, square when maximized). On macOS 27 the window itself is given those corners through a private AppKit call, checked when it is made. If that call is missing or AppKit puts its own radius back, or `W7CornerRadiusHookDisabled` is set, the window keeps macOS's 16 pt corners and the glass frame paints over them instead. The log says which, once per window: `log stream --predicate 'subsystem == "com.win7mac.chrome"' | grep "frame corners"`. With the window's own Windows 7 corners, only the few points outside each 6 pt top corner let clicks through to what is behind. In the fallback:
  - the corners look right, but a click in the outer ≈ 16 × 16 pt of each corner goes through the window to whatever is behind it. The glass frame never takes clicks, so that part of the window is transparent to the mouse;
  - the window's content keeps its rounded 16 pt bottom corners inside the square glass;
  - the close button loses the very top-right corner under the glass;
  - a maximized window keeps rounded bottom corners above the taskbar.
- While you resize a window live, the glass frame can trail the window edge by one frame.
- Message boxes keep macOS's alert layout (stacked buttons). Their glass caption uses the alert's existing top margin, so it is 18 pt tall rather than a full Windows 7 caption.
- Dialog panels keep their own layout and controls. The grey button strip is drawn only when the bottom 48 pt of the panel holds nothing but push buttons. SwiftUI panels get no strip, and neither do floating, utility and HUD panels or AppKit's own panels (Colors, Fonts, Open/Save, Print), which stay macOS.
- The Segoe UI substitution starts with the chrome, after the app has finished launching. Windows built earlier, and text whose font comes from a nib or from SwiftUI, keep the system font. Labels with a fixed size can clip, because Segoe UI's metrics differ from the system font's.
- The Segoe UI substitution is decided when a font is created. Text whose font was made in light appearance keeps Segoe UI after a switch to dark mode, until the app is relaunched. Fonts created after the switch are the system font.

## Full revert

```
make uninstall
```

`make uninstall` restores the Dock, menu bar, Finder desktop, wallpaper, alert sound and Terminal profiles from
`restore.env`, removes the LaunchAgent, the app, the installed dylib, the "Win7 Command Prompt" Terminal profile and the
fonts it added. The system steps are yours to undo, by hand, in this order (neither make target touches them):

1. Uninstall Ammonia as its README describes (https://github.com/CoreBedtime/ammonia). It installed
   `/Library/LaunchDaemons/com.bedtime.ammonia.plist` and `/var/ammonia/`; check both are gone afterwards.
2. Remove the boot-arg: `sudo nvram -d boot-args`. This removes ALL boot-args, not just `-arm64e_preview_abi`. If you
   had other boot-args before, set them again with `sudo nvram boot-args="..."`.
3. Reboot into Recovery (as in [Setup](#setup), step 2) -> Utilities ▸ Terminal -> `csrutil enable`, then restart.

If you ran `make signing-identity`, remove its certificate and key from the login keychain with
`security delete-identity -c "Win7Mac Local Signing"` (or delete "Win7Mac Local Signing" in Keychain Access).
