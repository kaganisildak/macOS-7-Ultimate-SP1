#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const W7ThemeName;

typedef struct { CGFloat r, g, b, a; } W7RGBA;

typedef NS_ENUM(NSInteger, W7CaptionKind) { W7CaptionMinimize, W7CaptionMaximize, W7CaptionRestore, W7CaptionClose };
// Case prefix is W7State, not W7ControlState, so Swift names are given explicitly.
typedef NS_ENUM(NSInteger, W7ControlState) {
    W7StateNormal NS_SWIFT_NAME(normal),
    W7StateHover NS_SWIFT_NAME(hover),
    W7StatePressed NS_SWIFT_NAME(pressed),
    W7StateDisabled NS_SWIFT_NAME(disabled)
};

FOUNDATION_EXPORT W7RGBA W7RGBAFromHex(uint32_t rgb, CGFloat alpha);

// Metrics (points)
FOUNDATION_EXPORT const CGFloat W7TaskbarHeight;
FOUNDATION_EXPORT const CGFloat W7TitlebarHeight;
FOUNDATION_EXPORT const CGFloat W7CaptionCloseWidth;
FOUNDATION_EXPORT const CGFloat W7CaptionSmallWidth;
FOUNDATION_EXPORT const CGFloat W7CaptionHeight;
FOUNDATION_EXPORT const CGFloat W7MenuStripHeight;
FOUNDATION_EXPORT const CGFloat W7MenuItemHeight;
FOUNDATION_EXPORT const CGFloat W7MenuSeparatorHeight;
FOUNDATION_EXPORT const CGFloat W7MenuGutterWidth;
FOUNDATION_EXPORT const CGFloat W7MenuMinWidth;
FOUNDATION_EXPORT const CGFloat W7SnapPreviewInset;

// Drawing: all functions take a non-flipped (bottom-left origin) context.
/// Aero glass without the frame lines: an opaque-ish blue base (active `#9BB8DC→#ADC6E4`, inactive
/// `#D2DCE8→#DCE4EE`, alpha 0.92), the `#74B8FC` tint (0.42 / 0.20) and the white gloss over the top
/// half of `glassRect`. Callers that draw one part of a taller glass pass the whole glass rect and clip.
FOUNDATION_EXPORT void W7DrawGlassFill(CGContextRef ctx, CGRect glassRect, BOOL active);
/// W7DrawGlassFill inside a radius-6 rounded rect, plus the outer black and inner white frame lines.
FOUNDATION_EXPORT void W7DrawGlassFrame(CGContextRef ctx, CGRect rect, BOOL active);
FOUNDATION_EXPORT void W7DrawCaptionButton(CGContextRef ctx, CGRect rect, W7CaptionKind kind, W7ControlState state);
FOUNDATION_EXPORT void W7DrawTaskbarBackground(CGContextRef ctx, CGRect rect);
FOUNDATION_EXPORT void W7DrawTaskbarButton(CGContextRef ctx, CGRect rect, BOOL running, BOOL active, BOOL hover);
/// W7DrawTaskbarButton for a taskbar app button. A running button with `windowCount` 2 is
/// 3 pt narrower with one more button edge showing 3 pt to its right, with 3 or more two edges (3 and
/// 6 pt); fewer than 2 draws the plain button. On hover, a non-NULL `glow` (the icon's dominant
/// colour) adds a radial glow in that colour (0.75 → 0) from the bottom middle.
FOUNDATION_EXPORT void W7DrawTaskbarGroupButton(CGContextRef ctx, CGRect rect, BOOL running, BOOL active, BOOL hover,
                                                NSInteger windowCount, CGColorRef _Nullable glow);
FOUNDATION_EXPORT void W7DrawStartOrb(CGContextRef ctx, CGRect rect, W7ControlState state, CGImageRef _Nullable customOrb);
FOUNDATION_EXPORT void W7DrawMenuBackground(CGContextRef ctx, CGRect rect, CGFloat gutterWidth);
FOUNDATION_EXPORT void W7DrawMenuHighlight(CGContextRef ctx, CGRect rect);
FOUNDATION_EXPORT void W7DrawMenuStripBackground(CGContextRef ctx, CGRect rect);
/// Explorer text: command bar `#1E395B`, column headers `#4C607A`.
FOUNDATION_EXPORT const uint32_t W7ExplorerTextHex;
FOUNDATION_EXPORT const uint32_t W7ColumnHeaderTextHex;
/// Explorer back/forward orb (diameter = the rect's shorter side): a blue body `#3F7FCB→#1B4F9C`
/// with a cyan glow from the bottom, a gloss cap and a dark rim; hover is brighter, pressed darker,
/// disabled grey `#C4CCD6→#96A2B2`. A white arrow points left (back) or right (forward).
FOUNDATION_EXPORT void W7DrawNavButton(CGContextRef ctx, CGRect rect, BOOL forward, W7ControlState state);
/// The recessed capsule the back/forward orbs and their dropdown chevron sit in.
FOUNDATION_EXPORT void W7DrawNavTrough(CGContextRef ctx, CGRect rect);
typedef NS_ENUM(NSInteger, W7ChevronDirection) {
    W7ChevronRight NS_SWIFT_NAME(right),
    W7ChevronDown NS_SWIFT_NAME(down),
    W7ChevronUp NS_SWIFT_NAME(up),
    W7ChevronLeft NS_SWIFT_NAME(left)
};
/// A small filled triangle centred on `center`: ▸, ▾, ▴ or ◂.
FOUNDATION_EXPORT void W7DrawChevron(CGContextRef ctx, CGPoint center, W7ChevronDirection direction, uint32_t hex, CGFloat alpha);
/// Explorer address/search box: white, 1 pt border, radius 2.
FOUNDATION_EXPORT void W7DrawAddressBar(CGContextRef ctx, CGRect rect, BOOL focused);
/// Hover/pressed look of a breadcrumb segment, separator or address-bar button (nothing when normal).
FOUNDATION_EXPORT void W7DrawAddressButton(CGContextRef ctx, CGRect rect, W7ControlState state);
/// The refresh arrows, centred in `rect`.
FOUNDATION_EXPORT void W7DrawRefreshGlyph(CGContextRef ctx, CGRect rect, BOOL enabled);
/// Explorer command bar: `#F5F9FD→#E9F0F8` over `#DFE9F5→#DAE5F3`, a white top line and a `#A0AFC3`
/// bottom line.
FOUNDATION_EXPORT void W7DrawCommandBar(CGContextRef ctx, CGRect rect);
/// Command bar button: a subtle rounded highlight when hovered or pressed, nothing when normal.
FOUNDATION_EXPORT void W7DrawCommandButton(CGContextRef ctx, CGRect rect, W7ControlState state);
/// Navigation pane row: hover `#E5F3FB` with a `#70C0E7` border, selection `#CCE8FF` with `#99D1FF`.
FOUNDATION_EXPORT void W7DrawNavPaneRow(CGContextRef ctx, CGRect rect, BOOL selected, BOOL hover);
/// List-view column header background: white→`#F2F2F2`, `#D5D5D5` bottom line.
FOUNDATION_EXPORT void W7DrawColumnHeader(CGContextRef ctx, CGRect rect);
/// A light vertical separator at `x` inside the header `rect`.
FOUNDATION_EXPORT void W7DrawColumnHeaderSeparator(CGContextRef ctx, CGFloat x, CGRect rect);
/// Details pane: `#FDFEFF→#E6EEF7` with a `#D5DFE5` top line.
FOUNDATION_EXPORT void W7DrawDetailsPane(CGContextRef ctx, CGRect rect);
/// Round blue help button with a white "?".
FOUNDATION_EXPORT void W7DrawHelpButton(CGContextRef ctx, CGRect rect);
/// Explorer/Start menu search box: W7DrawAddressBar plus a `#1E395B` magnifier at the right end, or,
/// with `showsClear`, an × there (Windows 7's clear button while a search is typed).
FOUNDATION_EXPORT void W7DrawSearchBox(CGContextRef ctx, CGRect rect, BOOL focused, BOOL showsClear);

// Start menu
/// The white programs pane inside the Start menu's glass: 8 pt in from the left and bottom, 10 pt from
/// the top, ending at x = `leftPaneWidth`.
FOUNDATION_EXPORT CGRect W7StartMenuProgramsRect(CGRect bounds, CGFloat leftPaneWidth);
/// Height of the search band along the bottom of the programs pane (44).
FOUNDATION_EXPORT const CGFloat W7StartMenuSearchBandHeight;
/// The 24 pt search box, centred in the search band, 8 pt in from the pane's sides.
FOUNDATION_EXPORT CGRect W7StartMenuSearchBoxRect(CGRect bounds, CGFloat leftPaneWidth);
/// The 48 pt user picture, centred in the right column, 14 pt from the top.
FOUNDATION_EXPORT CGRect W7StartMenuUserTileRect(CGRect bounds, CGFloat leftPaneWidth);
/// Distance from the menu's top to the first place in the right column: under the user tile (78), or
/// 16 without a user picture.
FOUNDATION_EXPORT CGFloat W7StartMenuPlacesTop(BOOL hasUserPicture);
/// The Start menu: dark glass `#28465A` at **0.85** (over the window's dark blur) with a white **0.12→0** gloss over the top fifth and
/// the glass frame lines (radius 6), then the white programs pane (radius 3, `#9DB2BF` border) with
/// the search band at its bottom (`searchBandHeight` high, `#F1F5FB`, top line `#D3DEED`).
FOUNDATION_EXPORT void W7DrawStartMenuBackground(CGContextRef ctx, CGRect bounds, CGFloat leftPaneWidth, CGFloat searchBandHeight);
/// The groove between groups of the Start menu's right column: a black **0.30** line over a white
/// **0.15** line, from `minX` to `maxX` at `y`.
FOUNDATION_EXPORT void W7DrawStartMenuSeparator(CGContextRef ctx, CGFloat minX, CGFloat maxX, CGFloat y);
/// The light glass ring round the Start menu's user picture: **6** pt wide, white **0.70→0.30**, radius
/// 5, a black **0.45** outer line and a white **0.8** line next to the picture. Draw the picture after.
FOUNDATION_EXPORT void W7DrawUserTileFrame(CGContextRef ctx, CGRect pictureRect);
// Standard controls inside app windows: the Windows 7 Aero visual style.
typedef NS_ENUM(NSInteger, W7CheckValue) {
    W7CheckOff NS_SWIFT_NAME(off),
    W7CheckOn NS_SWIFT_NAME(on),
    W7CheckMixed NS_SWIFT_NAME(mixed)
};
/// Side of the check box and radio button glyph box (13).
FOUNDATION_EXPORT const CGFloat W7CheckBoxSize;
/// Push button, radius 3, 1 px border, two vertical bands split at half height. Normal: border `#707070`,
/// `#F2F2F2→#EBEBEB` over `#DDDDDD→#CFCFCF`, a white 0.8 inner line. Hover: `#3C7FB1`,
/// `#EAF6FD→#D9F0FC` over `#BEE6FD→#A7D9F5`. Pressed: `#2C628B`, `#E5F4FC→#C4E5F6` over
/// `#98D1EF→#68B3DB`, no inner line. `isDefault` (normal state only): border `#3C7FB1` and an inner
/// `#3399FF` 0.6 ring in place of the white line. Disabled: border `#ADB2B5`, flat `#F4F4F4`.
FOUNDATION_EXPORT void W7DrawPushButton(CGContextRef ctx, CGRect rect, W7ControlState state, BOOL isDefault);
/// 13×13 check box in `rect13`: border `#8E8F8F` (hover/pressed `#3C7FB1`, disabled `#B1B1B1`), a 9×9 well
/// inset 2 shaded `#DFDFDF` (top-left) → `#FFFFFF` (bottom-right) (hover `#DEF9FA→#BFEBFF`, pressed
/// `#C2E4F6→#9CD6F2`, disabled flat `#F4F4F4`), a 2 px `#4D6185` check (disabled `#8D8D8D`) or, mixed, a
/// centred 7×7 `#4D6185` 0.85 square.
FOUNDATION_EXPORT void W7DrawCheckBox(CGContextRef ctx, CGRect rect13, W7ControlState state, W7CheckValue value);
/// 13×13 radio button: the check box's border and well colours on a circle; selected adds a 5×5 dot,
/// radial `#2A628F` (centre) → `#8CD1F2` (edge), ringed 1 px `#1D5281`.
FOUNDATION_EXPORT void W7DrawRadioButton(CGContextRef ctx, CGRect rect13, W7ControlState state, BOOL selected);
/// Legacy scroll bar track: `#F0F0F0` with a 1 px `#E3E3E3` line along both long edges.
FOUNDATION_EXPORT void W7DrawScrollerTrack(CGContextRef ctx, CGRect rect, BOOL vertical);
/// Scroll bar thumb in the knob rect `rect`: inset 1 pt across, radius 2, border `#979797`, fill across the
/// short axis (vertical: left→right) `#F3F3F3→#DBDBDB`; hover border `#3C7FB1`, fill `#E3F4FC→#A9DEF6`;
/// pressed border `#3C7FB1`, fill `#CEECF9→#86C6E8`. Thumbs at least 16 pt long get a centred grip of three
/// 1 pt `#B2B2B2` lines, each with a white line below (vertical) or to the right (horizontal).
FOUNDATION_EXPORT void W7DrawScrollerThumb(CGContextRef ctx, CGRect rect, BOOL vertical, W7ControlState state);

FOUNDATION_EXPORT void W7DrawSnapPreview(CGContextRef ctx, CGRect rect);
/// The default wallpaper: an original "Harmony-style" composition with no logo. A deep
/// blue vertical gradient `#0B3D91` → `#1A64C8` (60%) → `#0E4FA8` under a soft `#3D8BEA` **0.55** brightening at
/// (52%, 46%), six light ribbons (white **0→0.22→0** across, added) sweeping from the lower left to the upper right,
/// three white **0.35** hairlines along their edges and a white **0.18** bloom where they converge (62%, 40%).
/// Laid out in proportions of `rect` and deterministic; draw it into a context at the target pixel size.
FOUNDATION_EXPORT void W7DrawWallpaper(CGContextRef ctx, CGRect rect);

/// Segoe UI if installed in ~/Library/Fonts, otherwise the system font.
FOUNDATION_EXPORT NSFont *W7UIFont(CGFloat size);

/// Text on Aero glass, as title bars draw it: black with an 8 pt white glow at 0.7, truncated at the
/// tail. Draws into the current NSGraphicsContext (in its own coordinates).
FOUNDATION_EXPORT void W7DrawGlassText(NSString *text, CGRect rect, NSFont *font, NSTextAlignment alignment);

NS_ASSUME_NONNULL_END

#pragma mark - Notification area icons (W7TrayIcons.m)

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, W7TrayIcon) {
    W7TrayIconWifi, W7TrayIconWired, W7TrayIconDisconnected, W7TrayIconNoNetwork,
    W7TrayIconVolume, W7TrayIconBattery, W7TrayIconChevron
};

/// A procedural 16 pt Windows 7 tray icon, drawn centred in `rect` (non-flipped context): light
/// shapes with a dark outline so it reads on the glass taskbar. `level` is the Wi-Fi bars 0-4, the
/// volume level (0 muted, 1 zero ... 4 high) or the battery bucket 0-4. `flag` is the battery's
/// plugged-in state, or a warning overlay on the network icons.
FOUNDATION_EXPORT void W7DrawTrayIcon(CGContextRef ctx, CGRect rect, W7TrayIcon kind, NSInteger level, BOOL flag);

/// The Action Center flag: a white flag on a pole, drawn like the other tray icons, with a
/// red ✕ badge at the bottom right when `hasMessages`.
FOUNDATION_EXPORT void W7DrawActionCenterFlag(CGContextRef ctx, CGRect rect, BOOL hasMessages);
/// The network list's signal strength: five ascending bars across `rect`, the first `bars`
/// (0-5) lit green, the rest grey.
FOUNDATION_EXPORT void W7DrawSignalBars(CGContextRef ctx, CGRect rect, NSInteger bars);

NS_ASSUME_NONNULL_END

#pragma mark - Explorer folder icons

NS_ASSUME_NONNULL_BEGIN

/// The folder icons Explorer shows: a plain folder, the user's home and its special folders.
typedef NS_ENUM(NSInteger, W7FolderIconKind) {
    W7FolderIconPlain NS_SWIFT_NAME(plain),
    W7FolderIconDocuments NS_SWIFT_NAME(documents),
    W7FolderIconPictures NS_SWIFT_NAME(pictures),
    W7FolderIconMusic NS_SWIFT_NAME(music),
    W7FolderIconVideos NS_SWIFT_NAME(videos),
    W7FolderIconDownloads NS_SWIFT_NAME(downloads),
    W7FolderIconDesktop NS_SWIFT_NAME(desktop),
    W7FolderIconUser NS_SWIFT_NAME(user)
};
/// Number of W7FolderIconKind values.
FOUNDATION_EXPORT const NSInteger W7FolderIconKindCount;

/// A procedural Windows 7 folder icon, `pointSize` × `scale` pixels square, sRGB, +1 retained (NULL for
/// a non-positive size). A manila folder: back panel `#E9C46A→#D9A93C` with its tab top-left, a
/// `#C99A2E` border, cream paper sheets (`#FFFFFF`, `#F4F1E8`, `#C8C2B0` edges) and a lighter,
/// slightly translucent front panel `#F7DE8B→#E8BE55`. By size class: under 28 pt a flat closed
/// folder, under 48 pt closed with the papers peeking out, from 48 pt open (the front panel tilted,
/// its top edge rising from left to right). Special kinds add an emblem on the front panel.
FOUNDATION_EXPORT CGImageRef _Nullable W7CreateFolderIconImage(W7FolderIconKind kind, CGFloat pointSize, CGFloat scale) CF_RETURNS_RETAINED;

/// W7DrawTaskbarGroupButton pre-rendered: a `size` × `scale` pixel sRGB image of the button
/// filling `size`, to blit instead of redrawing its gradients and paths; +1 retained, NULL for an empty
/// size. Drawn over the same background, it matches the direct drawing to within rounding.
FOUNDATION_EXPORT CGImageRef _Nullable W7CreateTaskbarButtonImage(CGSize size, CGFloat scale, BOOL running, BOOL active,
                                                                  BOOL hover, NSInteger windowCount,
                                                                  CGColorRef _Nullable glow) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END

#pragma mark - Aero cursors and desktop gadgets

NS_ASSUME_NONNULL_BEGIN

/// The procedural Windows 7 Aero cursors.
typedef NS_ENUM(NSInteger, W7CursorKind) {
    W7CursorArrow NS_SWIFT_NAME(arrow),
    W7CursorIBeam NS_SWIFT_NAME(ibeam),
    W7CursorHand NS_SWIFT_NAME(hand),
    W7CursorBusy NS_SWIFT_NAME(busy),
    W7CursorWorking NS_SWIFT_NAME(working),
    W7CursorResizeEW NS_SWIFT_NAME(resizeEW),
    W7CursorResizeNS NS_SWIFT_NAME(resizeNS),
    W7CursorResizeNWSE NS_SWIFT_NAME(resizeNWSE),
    W7CursorResizeNESW NS_SWIFT_NAME(resizeNESW),
    W7CursorMove NS_SWIFT_NAME(move),
    W7CursorNotAllowed NS_SWIFT_NAME(notAllowed),
    W7CursorCrosshair NS_SWIFT_NAME(crosshair),
    W7CursorHelp NS_SWIFT_NAME(help)
};
/// Number of W7CursorKind values.
FOUNDATION_EXPORT const NSInteger W7CursorKindCount;
/// Cursor side in points (32).
FOUNDATION_EXPORT const CGFloat W7CursorSize;
/// Frames of the busy ring's turn (18); busy and working take a frame index, the rest ignore it.
FOUNDATION_EXPORT const NSInteger W7CursorBusyFrameCount;
/// "arrow", "ibeam", "hand", "busy", "working", "resize-ew", "resize-ns", "resize-nwse", "resize-nesw",
/// "move", "unavailable", "crosshair", "help".
FOUNDATION_EXPORT NSString *W7CursorKindName(W7CursorKind kind);
/// Hot spot in points from the cursor's TOP-LEFT corner (NSCursor's convention): the arrow tip (1, 1),
/// the hand's fingertip (10, 1), the centre (16, 16) for the others.
FOUNDATION_EXPORT CGPoint W7CursorHotSpot(W7CursorKind kind);
/// Draws the cursor's 32 × 32 pt grid scaled onto `rect` (non-flipped context): a white body with a 1 px
/// black outline outside it and a soft black 0.45 drop shadow (1 px right, 1.5 px down, blur 2). The arrow
/// follows aero_arrow's tilt and tail; busy is a pale ring with a blue segment turned by `frame`.
FOUNDATION_EXPORT void W7DrawCursor(CGContextRef ctx, CGRect rect, W7CursorKind kind, NSInteger frame);
/// The cursor as a 32 × `scale` pixel square sRGB image, +1 retained (NULL for a non-positive scale).
FOUNDATION_EXPORT CGImageRef _Nullable W7CreateCursorImage(W7CursorKind kind, CGFloat scale, NSInteger frame) CF_RETURNS_RETAINED;
/// The cursor as an NSCursor (32 pt, with @1x and @2x representations and its hot spot), cached per kind
/// and frame. Thread-safe.
FOUNDATION_EXPORT NSCursor *W7ProceduralCursor(W7CursorKind kind, NSInteger frame);

/// The Clock gadget: a chrome rim, a white face with hour and minute ticks, black hour and minute
/// hands and a red second hand, centred in `rect` (diameter = the shorter side). Angles are degrees
/// clockwise from 12.
FOUNDATION_EXPORT void W7DrawGadgetClock(CGContextRef ctx, CGRect rect, CGFloat hourDegrees, CGFloat minuteDegrees, CGFloat secondDegrees);
/// The CPU Meter's silver body (radius 14) behind its dials.
FOUNDATION_EXPORT void W7DrawGadgetMeterBody(CGContextRef ctx, CGRect rect);
/// One CPU Meter dial: a silver bezel, a black face with a white scale from -135° (0) to +135° (1)
/// whose last fifth is orange, and a red needle at `fraction` (clamped to 0...1).
FOUNDATION_EXPORT void W7DrawGadgetMeterDial(CGContextRef ctx, CGRect rect, CGFloat fraction);
/// The gadget hover toolbar (18 pt wide): a close × button (index 0; red when hovered), a disabled
/// options button (index 1, drawn at 0.4 alpha) and a drag grip below. `hoverIndex` -1 for none.
FOUNDATION_EXPORT void W7DrawGadgetToolbar(CGContextRef ctx, CGRect rect, NSInteger hoverIndex);
/// The same toolbar with the options button enabled when `optionsEnabled` (full alpha; light blue when hovered),
/// for a gadget that has options.
FOUNDATION_EXPORT void W7DrawGadgetToolbarWithOptions(CGContextRef ctx, CGRect rect, NSInteger hoverIndex, BOOL optionsEnabled);
/// The 16 pt square of toolbar button `index`, from the top: 1 pt in, 18 pt apart.
FOUNDATION_EXPORT CGRect W7GadgetToolbarButtonRect(CGRect toolbar, NSInteger index);

NS_ASSUME_NONNULL_END

#pragma mark - Internet Explorer 7 chrome for Safari

NS_ASSUME_NONNULL_BEGIN

/// The look of an IE7 tab.
typedef NS_ENUM(NSInteger, W7IETabState) {
    W7IETabNormal NS_SWIFT_NAME(normal),
    W7IETabHover NS_SWIFT_NAME(hover),
    W7IETabSelected NS_SWIFT_NAME(selected)
};
/// An IE tab's look (sRGB hex): a vertical fill `top`→`bottom`, a 1 px `border` on the top and sides (with a 1 px white
/// line just inside it when `innerLine`), a 1 px `bottomBorder` along the bottom only when `bottomLine` (the selected tab
/// joins the page below it), and `topInset`: how much lower than the selected tab the tab's top stands (pt).
typedef struct { uint32_t top, bottom, border, bottomBorder; bool bottomLine; CGFloat topInset; bool innerLine; } W7IETabColors;
/// (sampled from the IE8 reference): every tab has a 1 px `#A3A7AC` outline with a white inner line; selected
/// `#C3DDFB→#F0F4FB`, full height, no bottom line (it joins the `#F2F6FB` strip above the page); normal the row's own
/// `#E3EEFB` (an outline on the row), 2 pt lower, standing on the row's `#8B919F` line; hover `#F7FAFE→#E9F1FB`.
FOUNDATION_EXPORT W7IETabColors W7IETabColorsForState(W7IETabState state);
/// The pale band behind IE8's favourites and tab rows (sampled from the IE8 reference: opaque, not glass): a 1 px white
/// line along the top, `#F2F7FD→#E3EEFB` over the next 12 pt, then `#E3EEFB` down to the 1 px `#8B919F` line at `lineY`
/// (the tabs' bottom edge; clamped into `rect`), and the `#F2F6FB` strip above the page below that line.
FOUNDATION_EXPORT void W7DrawIETabRowBand(CGContextRef ctx, CGRect rect, CGFloat lineY);
/// Only a 1 px `#8DA7C8` line at `lineY` (clamped into `row`). Not drawn in Safari any more (the band,
/// W7DrawIETabRowBand, carries the row line); kept for its test only.
FOUNDATION_EXPORT void W7DrawIETabRowLine(CGContextRef ctx, CGRect row, CGFloat lineY);
/// A command bar / Favorites button's face: nothing (text and glyph on the row) when normal or disabled; a
/// flat 1 px `#A0B4CC` frame, radius 2, under the pointer; the same frame on a `#DCE6F2` fill when pressed.
FOUNDATION_EXPORT void W7DrawIECommandButtonFace(CGContextRef ctx, CGRect rect, W7ControlState state);
/// The small black ▾ of a command button's menu, centred on `center`.
FOUNDATION_EXPORT void W7DrawIEDropArrow(CGContextRef ctx, CGPoint center);
/// IE8's command bar and Favorites glyphs.
typedef NS_ENUM(NSInteger, W7IEGlyph) {
    W7IEGlyphFavorites NS_SWIFT_NAME(favorites),        // gold star
    W7IEGlyphAddFavorite NS_SWIFT_NAME(addFavorite),    // gold star with a green plus
    W7IEGlyphHome NS_SWIFT_NAME(home),                  // house, blue roof
    W7IEGlyphPrint NS_SWIFT_NAME(print),                // printer
    W7IEGlyphHelp NS_SWIFT_NAME(help),                  // blue circle with a white "?"
};
FOUNDATION_EXPORT void W7DrawIEGlyph(CGContextRef ctx, CGRect rect, W7IEGlyph glyph);
/// The same glyph disabled: greyed and at 40 % alpha.
FOUNDATION_EXPORT void W7DrawIEGlyphDisabled(CGContextRef ctx, CGRect rect, W7IEGlyph glyph);
/// The blank new-tab stub after the last tab (an unselected tab shape; lighter under the pointer).
FOUNDATION_EXPORT void W7DrawIENewTabStub(CGContextRef ctx, CGRect rect, BOOL hover);
/// Radius of a tab's top corners (2); its bottom corners are square.
FOUNDATION_EXPORT const CGFloat W7IETabRadius;
/// One IE7 tab in `rect` (W7IETabColorsForState, top corners rounded by W7IETabRadius; unselected tabs drawn
/// `topInset` lower than the rect's top).
FOUNDATION_EXPORT void W7DrawIETab(CGContextRef ctx, CGRect rect, W7IETabState state);
/// Where an IE8 facsimile tab puts its pieces in `bounds` (the Safari tab button's): `tab`, the tab shape
/// (unselected tabs W7IETabColors.topInset lower); `icon`, 16 pt at x + 6 (centred for a `pinned` tab), vertically
/// centred in `tab`; `title`, from 4 pt after the icon to 4 pt before the close glyph (when `closeShown` and the glyph
/// is at the right) or 6 pt before the tab's right edge (empty for a pinned tab); `close`, `closeRect` clamped into the
/// tab (empty when not shown). A close glyph LEFT of the title start (Safari's own place, over the favicon, kept after a
/// back-off; ) moves the title start to 4 pt after it instead, and the icon is left out when the glyph covers it
/// (the × wins, as in Safari): the title is never empty for a tab wider than icon + close + 24.
typedef struct { CGRect tab, icon, title, close; } W7IETabFacsimileLayout;
FOUNDATION_EXPORT W7IETabFacsimileLayout W7IETabFacsimileLayoutFor(CGRect bounds, W7IETabState state, BOOL pinned,
                                                                   CGRect closeRect, BOOL closeShown);
/// `title` shortened in the middle with "…" so it is at most `maxWidth` wide in `font` (the title itself when it fits;
/// "" when not even "…" fits).
FOUNDATION_EXPORT NSString *W7IEMiddleTruncatedTitle(NSString *_Nullable title, CGFloat maxWidth, NSFont *font);
/// The close glyph on a facsimile tab: a 10 pt × in `#6E6E6E`, `#C75050` under the pointer, centred in `rect`.
typedef NS_ENUM(NSInteger, W7IETabCloseState) {
    W7IETabCloseHidden NS_SWIFT_NAME(hidden),
    W7IETabCloseNormal NS_SWIFT_NAME(normal),
    W7IETabCloseHover NS_SWIFT_NAME(hover)
};
FOUNDATION_EXPORT void W7DrawIETabCloseGlyph(CGContextRef ctx, CGRect rect, BOOL hover);
/// One IE8 facsimile tab in `bounds` (non-flipped): W7DrawIETab in its W7IETabFacsimileLayoutFor shape, the favicon
/// (`icon`, 16 pt; W7DrawIEPageIcon instead when it is a template image), the title as given (W7UIFont 12 pt, black, left-aligned, clipped: the caller shortens it with
/// W7IEMiddleTruncatedTitle) in `titleRect` (CGRectNull: the layout's `title`), and the close glyph.
/// Needs no current NSGraphicsContext (one is made for `ctx` for the text).
FOUNDATION_EXPORT void W7DrawIETabFacsimile(CGContextRef ctx, CGRect bounds, W7IETabState state, BOOL pinned,
                                            NSImage *_Nullable icon, NSString *_Nullable title, CGRect titleRect,
                                            CGRect closeRect, W7IETabCloseState close);
/// `title` (a facsimile's title room) narrowed so it overlaps none of `rects` (the tab's other controls): a control in
/// its left half moves its start to 4 pt after the control, one in its right half its end to 4 pt before; CGRectZero
/// when no room is left.
FOUNDATION_EXPORT CGRect W7IETabTitleRectAvoiding(CGRect title, const CGRect *_Nullable rects, NSInteger count);
/// A glyph (12 pt, `#4A4A4A`, centred in `rect`) for one of Safari's other in-tab controls drawn over by the facsimile:
/// a speaker for the audio button, a ring with a dot for anything else.
typedef NS_ENUM(NSInteger, W7IETabAccessory) {
    W7IETabAccessorySpeaker NS_SWIFT_NAME(speaker),
    W7IETabAccessoryGeneric NS_SWIFT_NAME(generic)
};
FOUNDATION_EXPORT void W7DrawIETabAccessoryGlyph(CGContextRef ctx, CGRect rect, W7IETabAccessory kind);
/// IE's generic page icon: a white page with a folded top-right corner, a 1 px `#7A8A9E`
/// outline and three short grey text lines, fitted into `rect` (drawn for 16 pt). The facsimile draws it in place of
/// a template tab icon (Safari's symbol placeholders: the Start Page star, the loading and private-browsing symbols).
FOUNDATION_EXPORT void W7DrawIEPageIcon(CGContextRef ctx, CGRect rect);
/// Height of the IE7 status bar (22) and width of its progress trough (100).
FOUNDATION_EXPORT const CGFloat W7IEStatusBarHeight;
FOUNDATION_EXPORT const CGFloat W7IEProgressWidth;
/// The IE7 status bar: `#F0F0F0→#E3E3E3` with a 1 px `#A0A0A0` top line.
FOUNDATION_EXPORT void W7DrawIEStatusBar(CGContextRef ctx, CGRect rect);
/// The status bar's progress trough (light grey, `#A5A5A5` border) filled from the left with the
/// Windows 7 green bar to `fraction`, clamped to 0…1.
FOUNDATION_EXPORT void W7DrawIEProgress(CGContextRef ctx, CGRect rect, CGFloat fraction);
/// IE7's back and forward orbs: the Explorer orbs (W7DrawNavButton) at 28 and 24 pt.
FOUNDATION_EXPORT const CGFloat W7IEBackOrbSize;
FOUNDATION_EXPORT const CGFloat W7IEForwardOrbSize;
/// The size W7DrawIENavOrbs fills: both orbs side by side, overlapping by 1 pt (51 × 28).
FOUNDATION_EXPORT CGSize W7IENavOrbsSize(void);
/// The back orb (left, vertically centred) and the forward orb in one recessed capsule
/// (W7DrawNavTrough), in `rect`'s lower-left W7IENavOrbsSize; a disabled orb is grey.
FOUNDATION_EXPORT void W7DrawIENavOrbs(CGContextRef ctx, CGRect rect, BOOL backEnabled, BOOL forwardEnabled);
/// An opaque pale blue capsule (`#E4EDF8→#C3D5EA`, fully rounded ends) filling `rect`, with the recessed
/// trough over it: the back/forward overlay's base, covering the native control under it.
FOUNDATION_EXPORT void W7DrawIENavCapsule(CGContextRef ctx, CGRect rect);
/// One orb (back or `forward`) as a square sRGB image of its size × `scale` pixels, +1 retained; NULL
/// for a non-positive scale.
FOUNDATION_EXPORT CGImageRef _Nullable W7CreateIENavOrbImage(BOOL forward, CGFloat scale) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END

#pragma mark - Window frame fidelity and message boxes

NS_ASSUME_NONNULL_BEGIN

// Reference audit. Measured with a pixel sampler on Assets/reference (reference only):
// - ThumbnailWin7.png, the taskbar thumbnail popup, the one Aero glass frame in the references: outer line
//   #277382 over a #3196A9 wallpaper (a dark navy line), light inner line #73A3B7 / #8DBCD2 next to it (white
//   about 0.20 at the sides, 0.28 along the top), glass #4F9FBE–#64A4C0 over the blurred bright wallpaper, a
//   glass margin 9–10 px wide round the thumbnails.
// - Windows_7_SP1_screenshot.png and Windows_7_Taskbar.png show no window caption or caption buttons; the
//   caption buttons and the static (unblurred) glass colours follow these targets instead: active glass
//   about #6FA6D4 under the gloss, inactive #B9C9DB, outer frame line #2B4E78 with a white inner line, close
//   #C75050 → #D7584B with a #4C1F1F border, minimize/maximize glass. Every caption glyph is white, 1.8 pt,
//   with a 1 pt #1F2F45 (0.8) outline, as Aero draws them.
// - Menu strip #F5F6F7 → #DDE4EE: no menu bar in the references; unchanged.
// Resulting constants (W7Drawing.m): active glass base #6893B4 → #6E9DBA, inactive #C9CBD0 → #CFD1D5, both at
// 0.92 under the #74B8FC tint (0.42 / 0.20) and the white 0.45 → 0 gloss; frame outer line #2B4E78 (1.0 active,
// 0.6 inactive), inner line white 0.30.
// recalibration, sampled with a pixel sampler from Assets/reference/Windows_Internet_Explorer_8.png (its
// glass is stored translucent: values are the reference composited over white, as an image viewer shows it; the
// caption averaged over x 400…990): outer line #151C27; highlight line under it #E1E9F3; caption glass #6C91C7 just
// under the highlight, #6A8FC6 in the middle and at the bottom (flat: no visible gloss); navigation row glass
// #7196CC; side frame glass #658AC1 with #E0E8F2 / #BBCAE3 light lines; favourites and tab rows OPAQUE (not glass):
// a white top line, #F2F7FD → #E3EEFB over 12 px, then #E3EEFB. Inactive frame: not in the reference (unchanged).
// Constants now: active glass base #546495 → #566697 (0.92, same tint), gloss white 0.03 → 0, frame outer line
// #151C27 (1.0 / 0.6), inner line white 0.80; an opaque caption then renders #6D91C6 / #6A8FC6 / #6B8FC7 / #E2E9F4
// (top / middle / bottom / highlight), within ±8 of the reference.

/// Width of the glass frame Windows 7 draws on the left, right and bottom of a window (8).
FOUNDATION_EXPORT const CGFloat W7FrameBorderWidth;
/// Radius of the frame's outer top corners (6); its bottom corners are square.
FOUNDATION_EXPORT const CGFloat W7FrameOuterRadius;
/// The frame overlay: glass in the ring of `bounds` (top corners rounded by W7FrameOuterRadius, bottom
/// corners square) round the window `hole` (its corner radii `holeTopRadius` / `holeBottomRadius`), reaching
/// into the window over its edge and corner wedges. The top `captionHeight`
/// points are W7DrawGlassFill over that band, so the glass matches the caption row for row; below it the
/// band's bottom colour, flat; all over white (opaque). The
/// outer #151C27 line runs round the whole outside, across the window's top edge too; the white inner line
/// only inside the ring.
FOUNDATION_EXPORT void W7DrawFrameBorder(CGContextRef ctx, CGRect bounds, CGRect hole, CGFloat holeTopRadius,
                                         CGFloat holeBottomRadius, CGFloat captionHeight, BOOL active);
/// The caption glass of a window with a frame overlay: W7DrawCaptionGlassSlice of the whole `glassRect`.
FOUNDATION_EXPORT void W7DrawGlassCaption(CGContextRef ctx, CGRect glassRect, BOOL active);

// Window corners. The overlay paints over the window's own rounded corners and 1 pt edge, so the
// window shows Windows 7 corners: the frame's 6 pt outer top corners and square bottom ones (maximized:
// square). Everything the overlay and the caption paint is opaque (glass over white), so neither tone
// depends on what is behind it, and the caption glass is one function both draw, so the two meet without
// a seam.

/// How far into the window the overlay paints all round (1): over macOS's own edge line and corner arcs.
FOUNDATION_EXPORT const CGFloat W7FrameEdgeCover;
/// The boxes at the corners of `hole` (the window, overlay coordinates) that hold the corner wedges: each
/// the window's corner radius (clamped to half the window's shorter side) plus W7FrameEdgeCover on a side;
/// CGRectNull where the window's corner is square, and for the bottom corners of a maximized window.
/// Geometry for tests (it states where the wedges are); the drawing does not call it.
typedef struct { CGRect topLeft, topRight, bottomLeft, bottomRight; } W7FrameCornerWedges;
FOUNDATION_EXPORT W7FrameCornerWedges W7FrameCornerWedgeRects(CGRect hole, CGFloat windowTopRadius,
                                                              CGFloat windowBottomRadius, BOOL maximized);
/// The part of `hole` the overlay paints, +1 retained, to fill non-zero: `hole` less its inside, which is `hole`
/// inset by W7FrameEdgeCover along the straight edges, with corner arcs concentric with the window's own, 2 pt
/// inside them at the top (clear of the arcs' antialiased rim, where caption glass meets caption glass) and
/// W7FrameEdgeCover at the bottom. So the window's edge line, its corner arcs and its transparent corner
/// wedges are all under glass. Geometry for tests: W7DrawFrameBorder and W7DrawMaximizedFrameCorners cut the
/// same inside shape out of their glass rather than filling this path.
/// Maximized: only the top W7FrameEdgeCover + windowTopRadius rows of that (the top edge and top wedges).
FOUNDATION_EXPORT CGPathRef W7CreateFrameCoverPath(CGRect hole, CGFloat windowTopRadius, CGFloat windowBottomRadius,
                                                   BOOL maximized) CF_RETURNS_RETAINED;
/// The rects W7DrawFrameBorder draws its ring in, one transparency layer each (nothing window-sized
/// per frame): the top strip (outer corners, top edge and wedges), the bottom strip (bottom frame, edge and
/// wedges) and the left and right columns between them (frame plus side edge). On whole points, disjoint, and
/// together covering the ring; just `bounds` (count 1) when the window is too small to split. Returns the count.
FOUNDATION_EXPORT size_t W7FrameRingStrips(CGRect bounds, CGRect hole, CGFloat holeTopRadius, CGFloat holeBottomRadius,
                                           CGRect strips[_Nonnull 4]);
/// The caption glass inside `slice` only, for the part of a caption whose whole glass is `glassRect` (same
/// coordinates): white, W7DrawGlassFill over `glassRect`, and the white 0.30 inner line one point below its
/// top. The title bar draws its caption with it and the overlay its top wedges, so equal window rects give
/// equal pixels.
FOUNDATION_EXPORT void W7DrawCaptionGlassSlice(CGContextRef ctx, CGRect slice, CGRect glassRect, BOOL active);
/// A maximized window's overlay: W7CreateFrameCoverPath (maximized) of `hole` filled with the caption slice of
/// the window's top `captionHeight` points. No frame, no lines.
FOUNDATION_EXPORT void W7DrawMaximizedFrameCorners(CGContextRef ctx, CGRect hole, CGFloat windowTopRadius,
                                                   CGFloat captionHeight, BOOL active);
/// A Windows 7 message box behind an alert's own views: white, a #F0F0F0 button strip from the bottom up
/// to `stripTop` with a 1 pt #DFDFDF line on it, and, when `captionHeight` > 0, the caption glass along the
/// top `captionHeight` points with a #151C27 line under it.
FOUNDATION_EXPORT void W7DrawMessageBoxBackground(CGContextRef ctx, CGRect bounds, CGFloat stripTop,
                                                  CGFloat captionHeight, BOOL active);

NS_ASSUME_NONNULL_END

#pragma mark - Standard controls, slice 2

NS_ASSUME_NONNULL_BEGIN

// Drawing primitives only (and the render gallery): nothing in the dylib draws app controls with them yet.
// They are to be wired once the control-hook approach has been validated live.

/// Text field / search field box: white with a 1 pt #ABADB3 border, #3399FF when `focused`; a disabled box is
/// filled #F4F4F4 with a #CBCBCB border.
FOUNDATION_EXPORT void W7DrawTextFieldBox(CGContextRef ctx, CGRect rect, BOOL focused, BOOL enabled);
/// Pop-up button as a Windows 7 combo: the push-button look (radius 3, #707070 border, #F2F2F2 → #EBEBEB over
/// #DDDDDD → #CFCFCF, white inner line), a 1 pt separator and a black ▾ in a 17 pt well at the right end. Hover:
/// #EAF6FD → #D9F0FC over #BEE6FD → #A7D9F5 with a #3C7FB1 border; pressed: #E5F4FC → #C4E5F6 over #98D1EF →
/// #68B3DB, border #2C628B; disabled drawn at 0.5 alpha.
FOUNDATION_EXPORT void W7DrawComboBox(CGContextRef ctx, CGRect rect, W7ControlState state);
/// One tab of a Windows 7 tab strip, `rect` the tab (its bottom on the pane's top line): #F0F0F0 (hover
/// #EAF6FD → #D8EEF9) with a #8C8C8C border on the top and sides, radius 2; `selected` white, open at the
/// bottom so it joins the pane. Callers make the selected tab 2 pt taller and 2 pt wider on each side.
FOUNDATION_EXPORT void W7DrawTabItem(CGContextRef ctx, CGRect rect, BOOL selected, BOOL hover);
/// The tab view's pane: white with a 1 pt #8C8C8C border.
FOUNDATION_EXPORT void W7DrawTabPane(CGContextRef ctx, CGRect rect);
/// Progress bar: a #BCBCBC-bordered trough (#E6E6E6 → #F7F7F7, radius 2) with the Windows 7 green #06B025 fill
/// from the left to `fraction` (clamped to 0...1) and the Aero gloss (white 0.55 → 0.10) over its top half.
FOUNDATION_EXPORT void W7DrawProgressBar(CGContextRef ctx, CGRect rect, CGFloat fraction);
/// Horizontal slider channel: 4 pt tall, centred in `rect`, #E7EAEA with a #B0B0B0 top and side line and a
/// white bottom line (recessed).
FOUNDATION_EXPORT void W7DrawSliderTrack(CGContextRef ctx, CGRect rect);
/// Slider thumb (the rectangular Windows 7 thumb, typically 11 × 21): #F2F2F2 → #D6D6D6 with a #707070 border
/// and a white inner line, radius 2; hover #E5F4FC → #B3DCF4 with #3C7FB1; pressed #CDE9F8 → #8CC7EA with #2C628B.
FOUNDATION_EXPORT void W7DrawSliderThumb(CGContextRef ctx, CGRect rect, W7ControlState state);
/// Group box (NSBox): an etched frame, a 1 pt #D5DFE5 line with a white line inside it, radius 3, its top edge
/// on `rect`'s top with a gap of `titleWidth` + 4 starting 6 pt in for the title (drawn by the caller in black).
FOUNDATION_EXPORT void W7DrawGroupBox(CGContextRef ctx, CGRect rect, CGFloat titleWidth);

#pragma mark - Explorer navigation pane glyphs

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN

/// The Windows 7 Favorites star, centred in `rect` (side = the shorter side): five points, a yellow
/// `#FFEB73→#EDA814` fill (top→bottom) and a `#B8800D` outline.
FOUNDATION_EXPORT void W7DrawFavoritesStar(CGContextRef ctx, CGRect rect);
/// The navigation pane tree expander, an 8 pt glyph centred in `rect`: collapsed an outlined ▷
/// (`#8A8A8A`, hover `#1CC4F7`), expanded a filled ◢ (`#262626`, hover `#82DFFB` with a `#1CC4F7` edge).
FOUNDATION_EXPORT void W7DrawTreeExpander(CGContextRef ctx, CGRect rect, BOOL expanded, BOOL hover);

/// Procedural navigation pane icons, the fallbacks when the user has no PNG for them.
typedef NS_ENUM(NSInteger, W7NavPaneGlyph) {
    W7NavPaneGlyphComputer NS_SWIFT_NAME(computer),       // a monitor on a stand, blue screen
    W7NavPaneGlyphDrive NS_SWIFT_NAME(drive),             // a grey hard-disk box with a green light
    W7NavPaneGlyphSystemDrive NS_SWIFT_NAME(systemDrive), // the drive with a blue four-pane mark
    W7NavPaneGlyphNetwork NS_SWIFT_NAME(network),         // a blue globe with white meridians
    W7NavPaneGlyphTag NS_SWIFT_NAME(tag),                 // a grey label tag with a hole
    W7NavPaneGlyphCloud NS_SWIFT_NAME(cloud),             // a light blue cloud
    W7NavPaneGlyphAppBadge NS_SWIFT_NAME(appBadge),       // a small blue application window (a badge)
    W7NavPaneGlyphRemovableDrive NS_SWIFT_NAME(removableDrive), // a grey drive box with a dark slot
    W7NavPaneGlyphOpticalDrive NS_SWIFT_NAME(opticalDrive)      // a silver disc with a hole
};
/// Draws `glyph` into `rect` (a square works best; the drawing is centred at the shorter side).
FOUNDATION_EXPORT void W7DrawNavPaneGlyph(CGContextRef ctx, CGRect rect, W7NavPaneGlyph glyph);

NS_ASSUME_NONNULL_END

#pragma mark - Computer view (W7ComputerDrawing.m)

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const CGFloat W7ComputerTileWidth;          // 266: one drive tile (icon, gaps and the 200 pt bar)
FOUNDATION_EXPORT const CGFloat W7ComputerTileHeight;         // 58
FOUNDATION_EXPORT const CGFloat W7ComputerCapacityBarWidth;   // 200
FOUNDATION_EXPORT const CGFloat W7ComputerCapacityBarHeight;  // 12
FOUNDATION_EXPORT const CGFloat W7ComputerGroupHeaderHeight;  // 24

/// Where a drive tile's parts go, in a non-flipped tile rect: the 48 pt icon 5 pt from the left, vertically
/// centred; 6 pt right of it, top to bottom, the name (16 pt high, 5 pt under the top), the capacity bar (200 × 12,
/// shorter when the tile is narrower, 3 pt under the name) and the capacity text (14 pt high, 2 pt under the bar).
typedef struct { CGRect icon, name, bar, text; } W7ComputerTileLayout;
FOUNDATION_EXPORT W7ComputerTileLayout W7ComputerTileLayoutFor(CGRect tile);
/// The used part of a capacity bar: inside its 1 pt border, from the left, (width − 2) × `usedFraction` rounded to
/// whole points; `usedFraction` is clamped to 0…1 (NaN counts as 0).
FOUNDATION_EXPORT CGRect W7ComputerCapacityFillRect(CGRect bar, double usedFraction);
/// A capacity bar: `#E6E6E6` trough, the used part `#06B025` (`#DA2626` when `low`), a 1 pt `#BCBCBC` border.
FOUNDATION_EXPORT void W7DrawComputerCapacityBar(CGContextRef ctx, CGRect bar, double usedFraction, BOOL low);
/// A group header ("Hard Disk Drives"): the title in W7UIFont 12 bold `#1E395B` at the left, vertically centred, then
/// a 1 pt `#D5DFE5` rule from 6 pt after the title to the right edge.
FOUNDATION_EXPORT void W7DrawComputerGroupHeader(CGContextRef ctx, CGRect rect, NSString *title);
/// A drive tile (W7ComputerTileLayoutFor): the selection (`#CCE8FF` / `#99D1FF`) or hover (`#E5F3FB` / `#70C0E7`)
/// background of W7DrawNavPaneRow, the icon (`icon`, else the `fallback` glyph), the name (W7UIFont 12, black), and
/// for a `usedFraction` of 0 or more the capacity bar and `capacityText` (W7UIFont 11, `#6D6D6D`). Text is clipped
/// to the tile.
FOUNDATION_EXPORT void W7DrawComputerTile(CGContextRef ctx, CGRect tile, CGImageRef _Nullable icon, W7NavPaneGlyph fallback,
                                          NSString *name, NSString *_Nullable capacityText, double usedFraction, BOOL low,
                                          BOOL selected, BOOL hover);

NS_ASSUME_NONNULL_END

#pragma mark - Calculator (W7CalculatorDrawing.m)

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const CGFloat W7CalculatorDisplayHeight;     // 24: the display box
FOUNDATION_EXPORT const CGFloat W7CalculatorDisplayFontSize;   // 18: the number, before shrinking to fit

/// A Windows 7 Calculator key: radius 3, a 1 pt `#8E8F8F` border; normal `#F0F0F0→#E5E5E5` (top→bottom) with a white
/// inner line along the top, hover `#DDE9F7`, pressed `#C4D8EF` (the label 1 pt lower), disabled `#F4F4F4` with an
/// `#ADB2B5` border and a `#8D8D8D` label. The label is W7UIFont 12, black, centred. Every key, `=` included, uses
/// these faces.
FOUNDATION_EXPORT void W7DrawCalculatorKey(CGContextRef ctx, CGRect rect, NSString *label, W7ControlState state);
/// The display box: white, a 1 pt `#8E8F8F` border (radius 2); `text` right-aligned 6 pt from the right in W7UIFont
/// at W7CalculatorDisplayFontSizeFitting; with `memory`, the memory indicator "M" (W7UIFont 12) 6 pt from the left.
FOUNDATION_EXPORT void W7DrawCalculatorDisplay(CGContextRef ctx, CGRect rect, NSString *text, BOOL memory);
/// The display font size for `text` in `width` points: 18, one point smaller until it fits, at least 8.
FOUNDATION_EXPORT CGFloat W7CalculatorDisplayFontSizeFitting(NSString *text, CGFloat width);
/// The window's light blue body behind the display and keys: `#DDE7F3→#EEF3FA` (top→bottom).
FOUNDATION_EXPORT void W7DrawCalculatorBody(CGContextRef ctx, CGRect rect);

NS_ASSUME_NONNULL_END

#pragma mark - Windows Live Messenger (W7MessengerDrawing.m)

NS_ASSUME_NONNULL_BEGIN

/// A Messenger "buddy" status. Only Available is shown today (Messages has no presence API the chrome may read).
typedef NS_ENUM(NSInteger, W7MessengerStatus) {
    W7MessengerStatusAvailable NS_SWIFT_NAME(available),
    W7MessengerStatusBusy NS_SWIFT_NAME(busy),
    W7MessengerStatusAway NS_SWIFT_NAME(away),
    W7MessengerStatusOffline NS_SWIFT_NAME(offline)
};

FOUNDATION_EXPORT const CGFloat W7MessengerBandHeight;          // 64: the full header band
FOUNDATION_EXPORT const CGFloat W7MessengerCompactBandHeight;   // 32: the compact variant (name and status on one line)
FOUNDATION_EXPORT const CGFloat W7MessengerTileSide;            // 48: the picture tile in the full band
FOUNDATION_EXPORT const CGFloat W7MessengerCompactTileSide;     // 24: in the compact band
FOUNDATION_EXPORT const CGFloat W7MessengerStatusOrbSide;       // 12

/// The orb's body colour: available `#5BCB3A`, busy `#E2412F`, away `#F4C02E`, offline `#A5A5A5`.
FOUNDATION_EXPORT uint32_t W7MessengerStatusColor(W7MessengerStatus status);
/// "Available", "Busy", "Away", "Appear offline".
FOUNDATION_EXPORT NSString *W7MessengerStatusTitle(W7MessengerStatus status);
/// The Messenger toolbar row: "Send an instant message", "Send a file", "Video call", "Add a contact".
FOUNDATION_EXPORT NSArray<NSString *> *W7MessengerToolbarLabels(void);
/// A status orb in `rect` (12 pt): a circle of the status colour, a 1 pt rim of that colour at 60 % brightness, and a
/// white gloss (0.75→0.15) over the upper half.
FOUNDATION_EXPORT void W7DrawMessengerStatusOrb(CGContextRef ctx, CGRect rect, W7MessengerStatus status);
/// The header band's background: `#DFEFFC→#C4DDF5` (top→bottom) over `rect`.
FOUNDATION_EXPORT void W7DrawMessengerBandBackground(CGContextRef ctx, CGRect rect);
/// The picture tile: radius 4 (2 under 40 pt), a 1 pt `#8EAACC` border, a white→`#E8F0FA` frame (3 pt, 2 under 40 pt)
/// and inside it `picture` scaled to fill (centred, cropped), or a drawn head-and-shoulders silhouette `#7F9FC7` on
/// `#F3F7FC→#D5E2F1` when there is none.
FOUNDATION_EXPORT void W7DrawMessengerPictureTile(CGContextRef ctx, CGRect rect, CGImageRef _Nullable picture);
/// The width of a Messenger toolbar command: its label in W7UIFont 12, plus 6 pt on each side.
FOUNDATION_EXPORT CGFloat W7MessengerCommandWidth(NSString *label);
/// A Messenger toolbar command drawn as a DISABLED flat Windows 7 command button: no face (W7DrawCommandButton draws
/// nothing for W7StateDisabled), the label centred in W7UIFont 12, `#6D6D6D`.
FOUNDATION_EXPORT void W7DrawMessengerCommand(CGContextRef ctx, CGRect rect, NSString *label);

/// Where the header's parts go in `content` (non-flipped). Full (`compact` NO, 64 pt): the 48 pt tile 8 pt from the
/// left, vertically centred; 10 pt right of it the name (13 pt bold, 18 pt high, 5 pt under the top), under it the
/// status line (16 pt: the 12 pt orb, 4 pt, the status title in 12 pt, 3 pt, a 7×4 ▾), and along the bottom (4 pt up)
/// the commands, 20 pt high, 2 pt apart. Compact (32 pt): the 24 pt tile 4 pt from the left, then on one line the
/// name, 10 pt, the status line, 14 pt, the commands. The name is shortened to fit; a command that does not fit whole is
/// left out with every one after it; the status goes (orb, title and ▾ together) when it does not fit whole, in the
/// compact line when the name would get less than 40 pt. Nothing passes content's right edge minus 4 pt; parts left
/// out are CGRectZero.
typedef struct {
    CGRect tile, name, orb, status, arrow;
    CGRect commands[4];
    NSUInteger commandCount;
} W7MessengerHeaderLayout;
FOUNDATION_EXPORT W7MessengerHeaderLayout W7MessengerHeaderLayoutFor(CGRect content, BOOL compact, NSString *name,
                                                                     W7MessengerStatus status);
/// The header's contents in `content` (W7MessengerHeaderLayoutFor; no background): the picture tile, the name
/// (13 pt bold `#1C4F8C`), the orb, the status title and ▾ (12 pt `#1C4F8C`), and the commands (W7DrawMessengerCommand).
FOUNDATION_EXPORT void W7DrawMessengerHeader(CGContextRef ctx, CGRect content, BOOL compact, CGImageRef _Nullable picture,
                                             NSString *name, W7MessengerStatus status);

NS_ASSUME_NONNULL_END
