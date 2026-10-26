# Assets

Optional user-supplied files. This folder is git-ignored except for this README.
Anything missing falls back to a built-in default.

## Importing from your own Windows 7 media

```
make import-assets SRC=/path/to/Win7.iso
```

`SRC` may be an ISO, a folder containing `sources/install.wim` or `install.esd`, or a copied Windows folder tree.
Nothing is downloaded: you supply the media,.

Prerequisite: 7-Zip for macOS (`7zz`) on your PATH, from https://www.7-zip.org/download.html.
Missing items are reported as `skip <asset>: <reason>` and the rest is still imported.

Icons are written at their largest size (Windows 7 ships 256 px for most); `icons/user.png` stays 48 px and the
cursors 32 px. `ICON/<id>` in the map is an icon *group* (what Explorer calls the icon index's resource id): the
importer assembles every image of the group, so an icon is one file with all its sizes, not one picture of it. The
picture taken from a group is the best colour depth first (PNG and 32-bit, then 24, 8, 4 and 1 bit), then the size, so
a 48 px 16-colour image never wins over a 32 px full-colour one. In a black-and-white cursor, pixels that invert the
screen in Windows (the I-beam is drawn only with those) become opaque black.

### Fixing a wrong icon

`scripts/win7-asset-map.txt` has a line for every icon name below. For every file a line takes icons from (and every
file on a `CONTACT <path>` line) the import writes a contact sheet:

- `Assets/_contact/<dll>-<group>.png` - each icon group at 48 px, named by its group id (or its resource name, such as
  `cmd-IDI_APPICON.png`);
- `Assets/_contact/<dll>.png` - all of that file's groups on one labelled sheet, the id under each picture.

Each import deletes a file's old `<dll>-<id>.png` cells and `<dll>.png` sheet before writing new ones, so the sheet only
ever shows group ids.

Find the right picture, then edit the id on the matching line (for example `ICON/112`, or `ICON/IDI_APPICON` for a group
7-Zip names) and re-run the import. No code changes needed. A line whose id says `ICON/?` has not been chosen yet: the
import skips it with `skip <asset>: id not chosen — see Assets/_contact/<dll>.png` (or just `see Assets/_contact/`
when that file has no icon groups to put on a sheet), and the drawn or system icon stays until you write an id there.
A line whose id says `ICON/-` names an icon this media does not have (no icon resource, or the file is not on image 1):
the import skips it with `skip <asset>: no icon on this media (drawn icon stays)`; there is nothing to choose. The
first field of a line must be `icons/`, `cursors/`, `sounds/` or `fonts/` followed by a plain file name (letters,
digits, `.`, `_`, `-`; ending in `.png`, `.wav` or `.ttf`), or `wallpaper.jpg` or `start-orb`; any other name is
skipped as `unsafe asset name`. A `#` after a space starts a comment, so `# chosen 2026-10-17` tags can stay.

## Importing an icon pack

```
make import-icons SRC=/path/to/imageres-icons.zip     # or a folder of .ico files
```

For `.ico` files you have, such as an `imageres.dll` export (`imageres-#2.ico` … `imageres-#41.ico`) or named
icons (`explorer.ico`, `taskmgr.ico`, `trashbin1.ico` …). Nothing in the archive is run: each
`.ico` is read into a temporary folder and converted to PNG at its largest size (usually 256 px).

- `scripts/win7-icon-map.txt` says which icon becomes which file: `<imageres id> <name>.png`, `<dll>:<id> <name>.png`
  for another DLL's export (`shell32:25 run.png` takes `shell32-#25.ico`), or `<file>.ico <name>.png` for named icons.
  Exported names may be `<dll>-#N.ico`, `<dll>-N.ico`, `#N.ico` or `N.ico` (no DLL part means imageres). Edit it to add
  or change entries; no code changes needed.
- Mapped icons are written to `icons/<name>.png` here and, once installed, to
  `~/Library/Application Support/Win7Mac/Assets/icons/`. Ids the map doesn't list, from any DLL, go to
  `_contact/<pack>/<dll>-<id>.png` only, and onto one labelled sheet, `_contact/<pack>.png` (`<pack>` is the source's
  name without `imageres-`, or `PACK=<name>`), so you can look at them and add a line to the map. Other unlisted `.ico`
  files are skipped.
- Running it again is safe: identical files are left alone. A file that is already there and differs (one you put
  there yourself, for example) is kept and reported as `keep`; `make import-icons SRC=… FORCE=1` replaces it.
- The shell reads the icons when it starts (it is restarted by `make install`); Finder reads the folder icons when it
  relaunches.

The icon names (`icons/<name>.png`), grouped as in `Sources/Win7Core/IconCatalog.swift`, which lists every name the shell
and the injected chrome read. Each is used only when the PNG exists; otherwise the drawn or system icon stays. Names
marked *(later)* are catalogued and mapped, but no site reads them yet.

- Folders: `folder.png` on the desktop, in Finder, in the Start menu's folder rows and search hits, and in jump lists;
  `folder-{documents,pictures,music,videos,downloads,desktop,user}.png` for the special folders (the same names Finder
  uses), each falling back to its drawn art.
- Files by type, on the desktop, in Finder, in the Start menu's search hits and in jump lists' recent items:
  `file-text.png` (text and source), `file-image.png`, `file-audio.png`, `file-video.png`, everything else `file.png`;
  applications, packages (`.rtfd`, `.pages`), aliases and items with a custom icon keep their own icon. `file-app.png`
  (a Control Panel fallback), `games.png` *(later)*.
- Places: `computer.png`, `drive.png`, `drive-system.png`, `drive-removable.png`, `drive-optical.png` (also Finder's
  Computer view drive tiles, and a Control Panel fallback), `network.png` (Explorer's navigation pane and the Control Panel), `favorites.png` (the
  Favorites star in Explorer's navigation pane, IE's command bar and the Control Panel), `help.png` (Explorer's Help
  button and the Control Panel), `recent-places.png` and `shared.png` (Finder's sidebar Recents and Shared rows; without
  them Finder's own icon stays), `user.png` (the home folder in Finder's sidebar, and the Start menu's user picture).
- `app-<bundle id>.png` (for example `app-com.apple.finder.png`): that application's icon in the taskbar, the Start menu,
  the Alt-Tab switcher, the taskbar thumbnails and the jump list. Mapped: Finder, Safari, Music, TextEdit, Terminal,
  Activity Monitor, System Settings, Calculator, Notes, Preview.
- Start menu right column (shown in the picture tile while you point at the row, when `icons/user.png` exists):
  `control-panel.png`, `devices.png` (Devices and Printers), `computer.png` (else `drive-system.png`), and
  `documents.png`, `pictures.png`, `music.png` (else `folder-documents.png`, `folder-pictures.png`, `folder-music.png`).
- `recycle-bin-empty.png` / `recycle-bin-full.png`: the desktop Recycle Bin.
- `tray-<name>.png`: the notification area (see Layout below).
- `cp-<name>.png`: the Control Panel's eight categories (48 pt) and its items (32 pt), `cp-<item id>` as in
  `Sources/Win7Core/ControlPanelCatalog.swift`; `cp-user-accounts.png` is both the category's and the item's icon.
  Without them it uses `network.png`, `devices.png`, `computer.png` and the like, else a drawn icon; `control-panel.png`
  is its window and taskbar icon.
- `dev-<name>.png`: Device Manager's categories and devices (16 pt) and Devices and Printers' tiles (48 pt), one per
  category: `dev-audio`, `dev-battery`, `dev-bluetooth`, `dev-camera`, `dev-computer`, `dev-disk`, `dev-display`,
  `dev-keyboard`, `dev-monitor`, `dev-mouse`, `dev-network`, `dev-printer`, `dev-processor`, `dev-storage`, `dev-usb`.
  Without one: `computer.png`, `drive.png`, `network.png`, `cp-mouse.png`, `cp-sound.png` or `cp-power-options.png`
  where Windows 7 uses the same picture, else a drawn icon.
- `run.png`: the Run dialog. `msgbox-{warning,question,error,info}.png`: `msgbox-error` in the Run dialog's error box,
  `msgbox-warning` and `msgbox-info` in decorated apps' critical and informational alerts; `msgbox-question` *(later)*.
- `ie-{add-favorite,home,print,help,page}.png`: IE's command bar buttons and the page icon on tabs (Safari reads them from
  the copy `make chrome` embeds).

Not every icon has a resource in Windows 7. A map line whose id is `ICON/-` names one of those: the import skips it,
the name is still catalogued (a PNG you put there yourself is used), and the drawn glyph stays otherwise. These are the
battery icons (`batmeter.dll` composes them at run time), IE's Add to Favorites (a toolbar bitmap strip) and the files
that are not on image 1 of the media (Sticky Notes, Mobility Center). Location and Other Sensors (`SensorsCpl.dll`) and
the Bluetooth and USB device icons (`bthprops.cpl`, `setupapi.dll`) are the lines still `ICON/?`.

## Layout

- `wallpaper.jpg` - desktop wallpaper
- `start-orb.png`, `start-orb-hover.png`, `start-orb-pressed.png` - Start orb images
- `sounds/startup.wav`, `sounds/alert.wav` - startup and alert sounds
- `sounds/navigation.wav` (Start menu folders), `sounds/recycle.wav` (Empty Recycle Bin),
  `sounds/hardware-insert.wav`, `sounds/hardware-remove.wav` (USB devices), `sounds/logoff.wav`,
  `sounds/shutdown.wav` (Log off / Shut down and Restart) - the sound scheme; a missing file is silence, never a
  drawn-in substitute. Off with macOS's "Play user interface sound effects", or
  `defaults write com.win7mac.shell W7SoundsDisabled -bool YES`
- `cursors/arrow.png`, `cursors/ibeam.png`, `cursors/hand.png` - cursor images (without them the procedural Aero
  cursors are used, in apps and in the shell)
- `cursors/hotspots.txt` - one line per cursor: name, x, y (for example `arrow 0 0`)
- `fonts/segoeui.ttf`, `fonts/segoeuib.ttf` - Segoe UI Regular and Bold, from your own Windows (`C:\Windows\Fonts\`).
  install.sh puts them into `~/Library/Fonts`. Decorated apps also register the Application Support copies for
  their own process and use them in place of the system font (see "Segoe UI" in the top-level README)
- `fonts/lucon.ttf` - Lucida Console, used by the Terminal profile when present (installed the same way)
- `terminal/Win7 Command Prompt.terminal` - the Terminal profile, generated by install.sh (not user-supplied)
- `icons/{documents,pictures,music,computer,control-panel,devices}.png` (32 pt), `icons/user.png` (48 pt),
  `icons/recycle-bin-empty.png`, `icons/recycle-bin-full.png`
- `icons/tray-<name>.png` (16 pt) - notification area icons, replacing the drawn ones: `wifi-0` … `wifi-4`, `wired`,
  `disconnected`, `no-network`, `volume-0` (muted) … `volume-4`, `battery-0` … `battery-4` (add `-charging` when
  plugged in, for example `battery-3-charging`), `chevron`, `action-center` (the Action Center flag) and
  `action-center-alert` (the flag with its red badge, when there are messages)
- `icons/folder.png`, `icons/folder-{documents,pictures,music,videos,downloads,desktop,user}.png` - Explorer folder
  icons in Finder and on the desktop, replacing the drawn ones (any size; 256 px or more stays sharp in large icon
  views). `make import-icons` fills them from an icon pack, or copy your own in. Each kind falls back to its drawn icon. Read by Finder from the Application Support copy only,
  when Finder starts. Turn the folder icons off with `defaults write com.apple.finder W7FolderIconsDisabled -bool YES`
  and relaunch Finder
- `icons/file.png`, `icons/file-{text,image,audio,video}.png`, `icons/app-<bundle id>.png`, `icons/drive-system.png`
  and the other names in `scripts/win7-icon-map.txt` - from `make import-icons` (see "Importing an icon pack")
- `_contact/` - contact sheets for choosing ids: `<dll>-<group>.png`, `<dll>.png` (from `make import-assets`) and
  `<pack>/<dll>-<id>.png`, `<pack>.png` (from `make import-icons`)

The shell looks in `~/Library/Application Support/Win7Mac/Assets/` first, then in the repo `Assets/`.
