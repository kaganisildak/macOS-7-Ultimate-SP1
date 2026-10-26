# Visual fidelity pass

The Windows 7 look is drawn procedurally (`Sources/Win7Theme`). This pass compared each component with
Windows 7 reference screenshots and tuned the drawing values. The screenshots are a **visual reference
only**: they live in `Assets/reference/` (git-ignored), are never committed or shipped, and no pixels
are copied from them. The gallery shows them cropped by CSS.

## Rendering and the gallery

```sh
swift build --product Win7RenderTool -Xswiftc -plugin-path -Xswiftc "$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins/testing"
.build/debug/Win7RenderTool <outDir>      # every component at 2x: <outDir>/<name>.png
scripts/render-gallery.sh                  # renders into build/fidelity/renders and writes build/fidelity/gallery.html
```

`Win7RenderTool` draws with the shipped code: the theme functions for glass, caption buttons, the
taskbar and the Start menu, `W7TitlebarView` for title bars, `W7MenuStripController` for the menu strip,
`W7MenuWindow` (an unshown preview window) for the popup menu, and a Finder-like window adopted with
`W7ExplorerAdopt` for the Explorer bars. The taskbar and the Start menu are Win7Shell views, which the
tool can't link, so their renders repeat the shell's layout around the same theme calls
(`Renderer.drawTaskbar`, `StartMenuRender`). Glass is drawn over the default wallpaper, as it is seen on
the desktop. The taskbar and Start menu sit on a behind-window blur that an offscreen render can't
produce; the renders stand in for it by darkening the wallpaper with black 0.30 (the live blur turns
#0B9FF9 into about #156FA9). `Tests/Win7RenderToolTests` renders every component and checks each PNG has visible pixels.

## References

In `Assets/reference/`, downloaded from Wikipedia (the file pages are named after the
files):

| File | What it shows | Source |
|---|---|---|
| `Windows_7_SP1_screenshot.png` (640×480, scaled to 50%) | desktop, Start menu open, taskbar | https://en.wikipedia.org/wiki/File:Windows_7_SP1_screenshot.png |
| `Windows_7_Taskbar.png` (800×40, 100%, transparent glass) | orb, pinned and active buttons, tray, clock | https://en.wikipedia.org/wiki/File:Windows_7_Taskbar.png |
| `Action_Center_on_Windows_7.png` (386×258, about 50%, inactive window) | an Explorer-style Control Panel window | https://en.wikipedia.org/wiki/File:Action_Center_on_Windows_7.png |
| `ThumbnailWin7.png` (486×206) | taskbar thumbnails, a running button with several windows | https://en.wikipedia.org/wiki/File:ThumbnailWin7.png |

None shows a popup menu, a menu bar, an active title bar at full size or an Explorer command bar; for
those the source is the Windows 7 Aero default theme ("Sky", colorization `0x6B74B8FC`), as noted below.

Reference colours were read as sRGB by decoding the PNG into an sRGB bitmap. NSBitmapImageRep
`colorAt` with `usingColorSpace(.sRGB)` shifts untagged images (#F0F0F0 reads as #F3F3F3), so it was not
used.

## Findings

| Component | Property | Before | After / target | Source | Status |
|---|---|---|---|---|---|
| Taskbar | glass | `rgba(20,38,60,0.78)` + white 0.18→0 gloss, no blur: dark navy, and content behind the bar showed through sharply | a dark behind-window blur (`NSVisualEffectView` `.hudWindow`, dark) under a flat `#3B97DB` tint at 0.50, no gloss: #0B9FF9 under it gives #2880C2 (measured live) | SP1 (wallpaper #0B9FF9 → taskbar #2883C2); Taskbar.png is flat from row 2 down | changed (a later pass added the blur and recalibrated the tint) |
| Taskbar | top edge | 1 pt white 0.30 | 1 pt black 0.80, then 1 pt white 0.50 | Taskbar.png rows 0–1 (black 0.68, #CFD6DC 0.52) | changed |
| Taskbar | running/active button | white 0.15/0.30 fill, white 0.35 border | framed glass: black outer line (0.42/0.50/0.60), white inner line (0.32/0.45/0.55), white gloss fading over the top ¾ (active 0.73→0.08) | Taskbar.png active button (x 245–304) | changed |
| Taskbar | orb size | diameter = bar height (40) | 0.9 × height (36), centred | Taskbar.png orb spans y 2–37, x 9–44 | changed |
| Taskbar | orb look | radial `#3E8CE0→#0C3B7A`, small flag (0.31 d) | dark body `#1B5486→#062F55`, cyan `#22E2FF` bottom glow, gloss 0.80→0.12, dark rim + light halo, flag ≈ 0.45 d | Taskbar.png (rim #00375E, glow #03DFFD, gloss #C6DAE8) | changed |
| Taskbar | orb overhang | inside the bar | inside the bar | the 40 px reference doesn't overhang (only the 30 px small-icon taskbar does) | no change |
| Taskbar | clock font, tray spacing | W7UIFont 12, items 18/28/24/24 | Segoe UI 9 pt (12 px), icon pitch ≈ 24 px | Taskbar.png | matches |
| Caption buttons | corners | each button radius 3 all round | hang from the frame: square top, only the group's outer bottom corners rounded (radius 4) | Win7 default theme; Action Center (low-res, inactive) | changed |
| Caption buttons | border | black 0.4 | black 0.4 + white 0.35 inner line | Win7 default theme | changed |
| Caption buttons | glyph | white 1.6 pt with a one-sided black 0.55 shadow | white 1.8 pt with a black 0.55 outline 3.4 pt wide | Win7 default theme | changed |
| Title bar glass | tint/gloss | values | unchanged | Action Center is inactive and 50%: no reliable active sample | no change |
| Menus | background, gutter, highlight | `#F0F0F0`, `#F1F1F1`/`#E2E3E3`, `#F2F8FD→#DCEBFC` / `#AECFF7` | unchanged | Win7 default theme (no menu in the references) | no change |
| Menu strip | order under the title bar | added last among bottom titlebar accessories: below an app's own bars (TextEdit's format bar) | inserted first, so it sits directly under the title bar | Windows 7 menu bar placement | changed (see below) |
| Start menu | right pane | the taskbar glass (dark navy) | the same dark blur, then dark glass `#28465A` at 0.85 + white 0.12→0 gloss on the top fifth, frame lines | SP1 (#2E5165–#425D6D) | changed |
| Start menu | search clear | none | an × replaces the magnifier while searching; clicking it clears the search and shows the program list | Windows 7 | changed |
| Start menu | left pane | white, flush with the menu's left, top and bottom edges | white pane inset in the glass (8 pt left/bottom, 10 pt top), radius 3, `#9DB2BF` border | SP1 (glass margin 4 px at 50%, border #9AA4A8/#9DB2BF) | changed |
| Start menu | search box | NSSearchField (macOS rounded field, magnifier left) on `#EDEDED` | 44 pt band `#F1F5FB` with a `#D3DEED` top line; white box with a 1 pt border, grey italic hint, magnifier right | SP1 (band #F1F5FB, top line #D3DEED) | changed |
| Start menu | All Programs | "All Programs  ▸" text | ▸ at the left, title aligned with the program names, under a light line | SP1 | changed |
| Start menu | user tile | white 0.6 hairline round the picture; bold name | 6 pt light glass ring; the name is the first (regular) place and opens the home folder | SP1 | changed |
| Start menu | right column | gaps between groups, white 0.22 hover | grooves between groups, taskbar-button hover glass, shadowed white text | SP1 | changed |
| Start menu | Shut down | white 0.18 rounded rects | taskbar-button glass, white text, a ▸ glyph | SP1 | changed |
| Start menu | user tile overhang | inside the menu | Windows 7's tile overhangs the menu top by about half its height | SP1 | gap: needs a taller, partly transparent window (the 400×535 size is fixed by Global Constraints) |
| Explorer | list stripes | Finder's alternating row colours | plain white list | Win7 Details view; finder6 live screenshot shows stripes | changed |
| Explorer | nav bar, command bar, headers, details pane | values | unchanged | Action Center is a Control Panel window at 50%, inactive | no change |
| Explorer | navigation pane icons | Finder's SF Symbol line icons, accent-tinted | Windows 7 full-colour icons | Win7 Explorer | gap (see below) |
| Desktop | icon label shadow, selection | black 0.8 shadow (0, −1) blur 2; selection `rgba(170,205,240,0.45)` / `rgba(125,162,206,0.85)` | unchanged | SP1 "Recycle Bin" label is 50% scaled; no measurable difference | no change |

## Not changed, and why

- **Menu strip under a real NSToolbar.** The strip is now the first bottom titlebar accessory, so it sits
  above an app's own accessory bars (TextEdit's format bar is an NSTextView inspector bar, a bottom
  accessory). A real `NSToolbar` still comes first: AppKit always lays bottom accessories out below the
  toolbar. The only public way above it is `NSLayoutAttributeTop`, which needs
  `NSWindowStyleMaskFullSizeContentView` and suppresses the normal title bar, which would move every
  app's content under the title bar. Not done.
- **Explorer navigation pane icons.** Finder's sidebar rows hold private model objects; the only public
  handle is each cell's image view, which shows an SF Symbol. Full-colour icons would need each row's
  folder URL (private API), or matching localized display names against known folders, which mislabels
  renamed and non-folder items (AirDrop, Network, tags) and would fight Finder re-setting the images.
- **Start menu tile overhang.** See the table.
