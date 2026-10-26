#import <AppKit/AppKit.h>
#import <os/log.h>
#import <os/signpost.h>
#import <time.h>
#import "Win7Theme.h"

NS_ASSUME_NONNULL_BEGIN

/// Placeholder; injected chrome logic arrives in later tasks.
FOUNDATION_EXPORT NSString * W7ChromeCoreName(void);

/// Bundle IDs the dylib never activates in.
FOUNDATION_EXPORT NSArray<NSString *> *W7DefaultDenylist(void);

/// Decides whether the injected dylib should activate in this process.
FOUNDATION_EXPORT BOOL W7ShouldLoadInProcess(NSString *_Nullable bundleID,
                                             NSDictionary *_Nullable info,
                                             NSArray<NSString *> *extraDenylist,
                                             BOOL disabled);

/// Shared logger, subsystem com.win7mac.chrome.
FOUNDATION_EXPORT os_log_t W7Log(void);

// MARK: - Aero title bars

#define W7CaptionHitNone (-1)

typedef struct { CGRect minimize, maximize, close; } W7CaptionRects;

/// Whether a window gets the Aero title bar. decorateWindow evaluates it on the window's state after
/// Explorer adoption (Finder) and full-size conversion (W7ShouldConvertFullSizeWindow) have run.
FOUNDATION_EXPORT BOOL W7ShouldDecorateWindow(NSWindowStyleMask mask, BOOL isPanel, BOOL titlebarTransparent, BOOL isSheet);
/// Whether a full-size-content window is converted to a classic title bar and then decorated: one with an
/// NSToolbar (unified toolbar: Safari, Notes, Mail, System Settings), or a toolbar-less one of an Apple app
/// (`isAppleApp`, from W7IsAppleAppForFullSizeConversion: Terminal). Toolbar-less full-size windows of other
/// apps and windows whose class draws its own caption (Chromium, Electron) are never converted.
FOUNDATION_EXPORT BOOL W7ShouldConvertFullSizeWindow(NSWindowStyleMask mask, BOOL isPanel, BOOL isSheet,
                                                     BOOL hasToolbar, BOOL isAppleApp, NSString *windowClassName);
/// YES when `bundleID` has the prefix "com.apple." and is not in W7AppleFullSizeConversionExceptions.
FOUNDATION_EXPORT BOOL W7IsAppleAppForFullSizeConversion(NSString *_Nullable bundleID);
/// Apple bundle IDs whose toolbar-less full-size windows draw custom title-area content and are left alone.
FOUNDATION_EXPORT NSArray<NSString *> *W7AppleFullSizeConversionExceptions(void);
/// The mask the setStyleMask: guard passes on: FullSizeContentView stripped for a converted window unless
/// the mask carries FullScreen (native full screen keeps working); otherwise `mask` unchanged.
FOUNDATION_EXPORT NSWindowStyleMask W7GuardedStyleMask(NSWindowStyleMask mask, BOOL converted);
/// The toolbar style the setToolbarStyle: guard passes on: Expanded for a converted window (so SwiftUI
/// cannot move toolbar items up under the caption buttons), otherwise `style` unchanged.
FOUNDATION_EXPORT NSWindowToolbarStyle W7GuardedToolbarStyle(NSWindowToolbarStyle style, BOOL converted);
/// Swizzles -[NSWindow setStyleMask:] and -[NSWindow setToolbarStyle:] once so converted windows keep
/// FullSizeContentView off (except while the mask carries FullScreen) and the Expanded toolbar style.
/// Called from +[W7ChromeController start].
FOUNDATION_EXPORT void W7InstallConvertedWindowGuards(void);
/// The caption text: the window title, or the app's display name when the title is empty (Windows 7
/// shows the program name for untitled windows, e.g. System Settings).
FOUNDATION_EXPORT NSString *W7CaptionTitle(NSString *_Nullable windowTitle, NSString *_Nullable appName);
/// Caption button rects inside a non-flipped title bar of the given bounds.
FOUNDATION_EXPORT W7CaptionRects W7CaptionLayout(CGRect titlebarBounds);
/// Returns a W7CaptionKind raw value (Minimize/Maximize/Close) or W7CaptionHitNone.
FOUNDATION_EXPORT NSInteger W7CaptionHitTest(W7CaptionRects rects, CGPoint p);
/// AppKit coordinates; the taskbar is trimmed off the bottom on the primary screen only.
FOUNDATION_EXPORT CGRect W7MaximizedFrame(CGRect screenFrame, CGFloat taskbarHeight, BOOL isPrimaryScreen);

/// The Aero title bar. By default a static drawing (W7DrawGlassFrame) with no behind-window blur;
/// W7TitlebarBlurEnabled puts an NSVisualEffectView under the glass. The glass, icon and
/// title, and each caption button, are layer-backed views that redraw only on setNeedsDisplay.
@interface W7TitlebarView : NSView
/// `blur`: an NSVisualEffectView under the glass. -initWithFrame: passes W7TitlebarBlurEnabled().
- (instancetype)initWithFrame:(NSRect)frame blur:(BOOL)blur NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
/// Redraws everything: key/main, title or maximized state changed.
- (void)refresh;
/// The hover/pressed state the mouse handlers set (W7CaptionKind raw values or W7CaptionHitNone);
/// redraws only the buttons whose look changes (W7CaptionRedrawMask).
- (void)w7SetHover:(NSInteger)hover pressed:(NSInteger)pressed;
/// Minimize, maximize, close.
@property (nonatomic, readonly) NSArray<NSView *> *w7CaptionButtonViews;
/// The glass, icon and title.
@property (nonatomic, readonly) NSView *w7GlassView;
@end

/// Bit (1 << kind) for each caption button whose look differs between the two hover/pressed states
/// (W7CaptionKind raw values or W7CaptionHitNone; maximize and restore share W7CaptionMaximize).
FOUNDATION_EXPORT NSUInteger W7CaptionRedrawMask(NSInteger oldHover, NSInteger oldPressed, NSInteger newHover, NSInteger newPressed);
/// `defaults write -g W7TitlebarBlur -bool YES` (or an app's own domain): the behind-window blur under
/// the title bar glass, off by default. Read once per process.
FOUNDATION_EXPORT BOOL W7TitlebarBlurEnabled(void);

@interface W7ChromeController : NSObject
+ (void)start;
+ (void)decorateWindow:(NSWindow *)w NS_SWIFT_NAME(decorateWindow(_:));
@end

// MARK: - Menus

/// One visible row of an NSMenu, as the Windows 7 popup menu draws it.
@interface W7MenuNode : NSObject
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL isSeparator;
@property (nonatomic, readonly) NSControlStateValue state;
@property (nonatomic, readonly, copy, nullable) NSString *shortcut;
@property (nonatomic, readonly) BOOL hasSubmenu;
@property (nonatomic, readonly, strong, nullable) NSImage *image;
/// Index of the item in the source NSMenu.
@property (nonatomic, readonly) NSInteger sourceIndex;
- (instancetype)initWithTitle:(NSString *)title enabled:(BOOL)enabled isSeparator:(BOOL)isSeparator
                        state:(NSControlStateValue)state shortcut:(nullable NSString *)shortcut
                   hasSubmenu:(BOOL)hasSubmenu image:(nullable NSImage *)image
                  sourceIndex:(NSInteger)sourceIndex NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Calls the delegate's menuNeedsUpdate: (if implemented) and -[NSMenu update], then returns the
/// visible rows: hidden and alternate items skipped; leading, trailing and duplicate separators removed.
FOUNDATION_EXPORT NSArray<W7MenuNode *> *W7MenuNodes(NSMenu *menu) NS_SWIFT_UI_ACTOR;
/// W7MenuNodes for a context menu of `view`: after -[NSMenu update], an autoenabling menu's nil-target
/// items that W7ContextMenuItemTarget resolves from `view` are validated by that target (validateMenuItem:, else
/// validateUserInterfaceItem:, else enabled); the others keep AppKit's result. A nil `view` is W7MenuNodes.
FOUNDATION_EXPORT NSArray<W7MenuNode *> *W7MenuNodesForView(NSMenu *menu, NSView *_Nullable view) NS_SWIFT_UI_ACTOR;
/// Where a nil-target `item` of a context menu for `view` goes: the first responder up the chain (or its
/// supplementalTargetForAction:sender:) that implements the action, starting at the window's first responder when
/// that lies inside `view`, else at `view`; then the window's delegate. nil when the item has a target or no
/// action, without a view, or when that chain has no taker (AppKit's key-window resolution then applies).
FOUNDATION_EXPORT id _Nullable W7ContextMenuItemTarget(NSMenuItem *item, NSView *_Nullable view) NS_SWIFT_UI_ACTOR;
/// Windows-style shortcut text ("Ctrl+Alt+Shift+Cmd+S"), or nil when there is none to show.
FOUNDATION_EXPORT NSString *_Nullable W7ShortcutString(NSString *keyEquivalent, NSEventModifierFlags mask);
/// Next enabled, non-separator row in `direction` (+1/-1), wrapping. NSNotFound as `current` means
/// before the first row (+1) or after the last (-1). Returns NSNotFound if nothing is selectable.
FOUNDATION_EXPORT NSInteger W7NextSelectableIndex(NSArray<W7MenuNode *> *nodes, NSInteger current, NSInteger direction);

/// max(minWidth, W7MenuMinWidth, gutter + widestTitle + 40 + widestShortcut + 24).
FOUNDATION_EXPORT CGFloat W7MenuLayoutWidth(CGFloat widestTitle, CGFloat widestShortcut, CGFloat minWidth);
/// Total height of the rows (22 pt items, 7 pt separators), without the menu's padding.
FOUNDATION_EXPORT CGFloat W7MenuRowsHeight(NSArray<W7MenuNode *> *nodes);
/// Distance from the top of the first row to the top of row `index`.
FOUNDATION_EXPORT CGFloat W7MenuRowTop(NSArray<W7MenuNode *> *nodes, NSInteger index);
/// Row under a point `offset` points below the top of the first row, or NSNotFound.
FOUNDATION_EXPORT NSInteger W7MenuRowAtOffset(NSArray<W7MenuNode *> *nodes, CGFloat offset);
/// Screen frame (AppKit coordinates) for a menu whose top-left corner is requested at `topLeft`.
/// Shifts horizontally to stay on `visibleFrame`; opens upward when it doesn't fit below.
FOUNDATION_EXPORT CGRect W7MenuPopUpFrame(CGPoint topLeft, CGSize size, CGRect visibleFrame);
/// Screen frame for a cascaded submenu whose top aligns with `rowTop`: to the right of `parentFrame`,
/// flipped to the left when it doesn't fit, then kept on `visibleFrame` vertically.
FOUNDATION_EXPORT CGRect W7MenuSubmenuFrame(CGRect parentFrame, CGFloat rowTop, CGSize size, CGRect visibleFrame);

/// The Windows 7 popup menu.
@interface W7MenuWindow : NSPanel
/// Shows `menu` with its top-left corner at `screenPoint` and tracks it. Synchronous: returns after
/// the menu is dismissed and the chosen item's action has run. Main thread only; not re-entrant.
/// The caller's app should be active: key events (arrows, Return, Esc) only reach an active app, and
/// dismiss-on-deactivation only applies once the app has been active. An inactive caller still gets
/// mouse selection and dismissal by clicking elsewhere.
+ (void)popUpMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth
    NS_SWIFT_NAME(popUp(_:topLeft:minWidth:));
/// Same, plus `regions` (NSValue screen rects, outside the menu). When the mouse enters one,
/// tracking ends without running anything and its index is returned; otherwise NSNotFound.
/// The menu strip uses this to switch menus on hover.
+ (NSInteger)popUpMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth
         switchRegions:(nullable NSArray<NSValue *> *)regions
    NS_SWIFT_NAME(popUp(_:topLeft:minWidth:switchRegions:));
/// Same as popUpMenu:topLeft:minWidth:, but returns whether a menu window was actually shown. NO means
/// nothing appeared, so the caller falls back to a native menu: off the main thread, while a W7 menu tracks,
/// during a modal session (NSApp.modalWindow), a menu with a custom-view item (W7MenuHasCustomViewItem, also
/// after its delegate's menuNeedsUpdate:), an empty menu, or a failure before the first window. Never NO after
/// a menu has appeared.
+ (BOOL)showMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth;
/// Same as showMenu:topLeft:minWidth:; `chose` (may be NULL) is set to YES when an item was chosen (its action
/// has run by the time this returns), NO when the menu was dismissed or never shown.
+ (BOOL)showMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth chose:(nullable BOOL *)chose
    NS_SWIFT_NAME(show(_:topLeft:minWidth:chose:));
/// Same as showMenu:topLeft:minWidth:chose: for a context menu of `view`, as AppKit's own context menu:
/// nil-target items are validated and sent through W7ContextMenuItemTarget(item, view) when that finds a target
/// (else AppKit's key-window resolution, as before); with `view` and `event`, the view's willOpenMenu:withEvent:
/// runs once the menu has been updated and its didCloseMenu:withEvent: after the chosen action. Every shown menu
/// posts NSMenuDidBeginTrackingNotification before it appears and NSMenuDidEndTrackingNotification after the action.
+ (BOOL)showContextMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth
                forView:(nullable NSView *)view event:(nullable NSEvent *)event chose:(nullable BOOL *)chose
    NS_SWIFT_NAME(showContextMenu(_:topLeft:minWidth:for:event:chose:));
/// YES while a menu is being tracked.
+ (BOOL)isTracking;
/// A menu window for `menu` that is never shown or tracked, with row `highlightedRow` (an index into
/// W7MenuNodes(menu); NSNotFound for none) highlighted. For offscreen renders (the fidelity render
/// tool and tests): draw its contentView with cacheDisplayInRect:toBitmapImageRep:.
+ (instancetype)previewWindowForMenu:(NSMenu *)menu highlightedRow:(NSInteger)highlightedRow minWidth:(CGFloat)minWidth
    NS_SWIFT_NAME(previewWindow(for:highlightedRow:minWidth:)) NS_SWIFT_UI_ACTOR;
@end

/// marks `menu` so that Left, pressed in it as the root (outermost) W7 menu, closes it as Esc does: the
/// Start menu's jump list, which Windows 7 closes with Left. Unmarked root menus ignore Left (a submenu always closes
/// on Left). Kept on the menu itself (an associated object); NO clears it.
FOUNDATION_EXPORT void W7MenuSetLeftClosesRoot(NSMenu *menu, BOOL closes);
/// Whether W7MenuSetLeftClosesRoot marked `menu`.
FOUNDATION_EXPORT BOOL W7MenuLeftClosesRoot(NSMenu *_Nullable menu);

// MARK: - Menu strip and context menus

/// YES only for resizable, non-modal windows.
FOUNDATION_EXPORT BOOL W7ShouldShowMenuStrip(NSWindowStyleMask mask, BOOL isModal);
/// Visible top-level titles of `mainMenu`; the first uses `appName`.
FOUNDATION_EXPORT NSArray<NSString *> *W7MenuStripTitles(NSMenu *_Nullable mainMenu, NSString *appName);
/// The strip's title rects (NSValue rects, left to right from x 0, `height` tall): each title's
/// W7TextSize width rounded up, plus 8 pt padding on both sides. The strip caches them per titles and
/// height.
FOUNDATION_EXPORT NSArray<NSValue *> *W7MenuStripTitleRects(NSArray<NSString *> *titles, NSFont *font, CGFloat height);
/// Exchanges two class-method implementations of `cls`. NO if either is missing.
FOUNDATION_EXPORT BOOL W7SwizzleClassMethod(Class cls, SEL original, SEL replacement);
/// Exchanges two instance-method implementations of `cls`. NO if either is missing.
FOUNDATION_EXPORT BOOL W7SwizzleInstanceMethod(Class cls, SEL original, SEL replacement);
/// Once per process (dispatch_once): unless W7ContextMenusDisabled, W7InstallContextMenuHooksOnClass(NSMenu), so
/// every context-menu entry point of this macOS draws through W7MenuWindow and falls back to AppKit's menu when
/// that cannot show. With `defaults write -g W7MenuVerboseLog -bool YES`, first logs W7ContextMenuSelectorDump(NSMenu)
/// (selector names and encodings only) and, per call, which entry point ran and whether W7 or AppKit drew it.
FOUNDATION_EXPORT void W7InstallContextMenuHook(void);

// MARK: - Context menus everywhere

/// `defaults write -g W7ContextMenusDisabled -bool YES` (or an app's own domain): no context-menu hooks, and the
/// shell's menus are AppKit's (ShellMenus). Read once per process.
FOUNDATION_EXPORT BOOL W7ContextMenusDisabled(void);
/// Tests: forces W7ContextMenusDisabled (0 or 1); -1 goes back to the defaults.
FOUNDATION_EXPORT void W7ContextMenusUseDisabledOverride(NSInteger value);
/// YES when a visible item of `menu`, or of its submenus up to four levels down, has a custom view (which
/// W7MenuWindow cannot draw).
FOUNDATION_EXPORT BOOL W7MenuHasCustomViewItem(NSMenu *_Nullable menu);
/// YES when a hook should hand `menu` to W7MenuWindow: a menu, not `disabled`, on the main thread, no W7 menu
/// `tracking`, no custom-view item, no numberOfItemsInMenu: delegate (AppKit runs that protocol), and a visible
/// item — or a menuNeedsUpdate: delegate, which may fill an empty menu when W7MenuWindow updates it.
FOUNDATION_EXPORT BOOL W7ContextMenuShouldIntercept(NSMenu *_Nullable menu, BOOL tracking, BOOL mainThread, BOOL disabled);
/// YES when `cls` itself (not a superclass) implements `sel` with exactly the encoding `types`. Pass the
/// metaclass for a class method.
FOUNDATION_EXPORT BOOL W7ContextMenuOwnsExactMethod(Class cls, SEL sel, const char *types);
/// The hooked entry points, "+sel types" (class side) or "-sel types", in the order they are installed:
/// +popUpContextMenu:withEvent:forView:(withFont:), -popUpMenuPositioningItem:atLocation:inView:(appearance:)
/// (only without a positioning item), and the private funnels -_popUpContextMenu:withEvent:forView:withFont:
/// (the right-click path: -[NSView rightMouseDown:] → _showMenuForEvent: → _popUpMenuWithEvent:forView:),
/// -_popUpContextMenu:withContext:forView:withFont: and their completionBlock: variants (the block runs on the
/// main queue after the W7 menu; a block taking arguments goes to AppKit).
FOUNDATION_EXPORT NSArray<NSString *> *W7ContextMenuEntryPoints(void);
/// Hooks each W7ContextMenuEntryPoints entry that `cls` (class side: its metaclass) implements itself with exactly
/// that encoding; once per class. One line per entry: "<±sel>: hooked", ": not found", ": types <actual> (not
/// hooked)" or ": already hooked". Each hook runs in @try and calls the original whenever W7MenuWindow declines.
FOUNDATION_EXPORT NSArray<NSString *> *W7InstallContextMenuHooksOnClass(Class cls);
/// "±sel types" for every selector of `cls` (both sides) whose name contains "popUp" or "contextMenu" (any case),
/// sorted. Names and encodings only.
FOUNDATION_EXPORT NSArray<NSString *> *W7ContextMenuSelectorDump(Class cls);
/// The type encoding a block carries in its descriptor (Clang block ABI), or nil (not a block, or no signature).
FOUNDATION_EXPORT NSString *_Nullable W7BlockTypeEncoding(id _Nullable block);
/// Where a context menu opens (screen): a mouse event's location; for any other event (the keyboard's context-menu
/// key, showContextMenuForSelection:) with a view in a window, the view's selection (a text view's selected range, a
/// table's selected row) or else its visible top-left corner; otherwise (no event, a context object, no view) the
/// pointer.
FOUNDATION_EXPORT NSPoint W7ContextMenuAnchorPoint(id _Nullable eventOrContext, NSView *_Nullable view) NS_SWIFT_UI_ACTOR;
/// The font W7MenuWindow draws with: W7UIFont(12) (Segoe UI when installed, else the system font), never the
/// 13 pt macOS menu font.
FOUNDATION_EXPORT NSFont *W7MenuWindowFont(void);

/// The Windows-style "File Edit View" strip under the title bar.
@interface W7MenuStripController : NSTitlebarAccessoryViewController
@end

// MARK: - Peek and cursors

/// Makes windows near-transparent (alpha 0.08) while Aero Peek is active.
@interface W7PeekController : NSObject
- (instancetype)initWithWindowsProvider:(NSArray<NSWindow *> *(^)(void))provider
                                timeout:(NSTimeInterval)timeout NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/// Stores each window's alpha and sets 0.08. Idempotent while active. Main thread only.
- (void)begin;
/// Restores the stored alphas; no-op when not active. Cancels the timeout.
- (void)end;
/// Notification handlers used by +start; they hop to the main thread if needed.
- (void)handleBeginNotification:(NSNotification *)n;
- (void)handleEndNotification:(NSNotification *)n;
/// Subscribes (once) to com.win7mac.peek.begin / .end on NSDistributedNotificationCenter.
+ (void)start;
@end

// MARK: - Close channel

/// What the taskbar's jump list asks an app to close.
typedef NS_ENUM(NSInteger, W7CloseRequest) {
    /// "Close window": the key window, else the main window, else the frontmost eligible one.
    W7CloseRequestWindow = 0,
    /// "Close all windows": every eligible window.
    W7CloseRequestAllWindows = 1,
};

/// `com.win7mac.closeWindow.<pid>` / `com.win7mac.closeAllWindows.<pid>`: the distributed notification the shell
/// posts to the app with that pid. The name carries the target, as sandboxed apps drop userInfo.
FOUNDATION_EXPORT NSString *W7CloseChannelNotificationName(W7CloseRequest request, pid_t pid);
/// `com.win7mac.closeHandled.<pid>`: posted (no userInfo) by the app as soon as it handles a request, so the shell
/// takes no fallback while, say, a save sheet keeps the window open.
FOUNDATION_EXPORT NSString *W7CloseChannelAckName(pid_t pid);
/// A window the channel closes: it has a close button (NSWindowStyleMaskClosable), is not a panel or a sheet, and is
/// visible or minimized.
FOUNDATION_EXPORT BOOL W7CloseChannelWindowEligible(NSWindowStyleMask mask, BOOL isPanel, BOOL isSheet, BOOL isVisible,
                                                    BOOL isMiniaturized);
/// A window that keeps the app running at the exit check: titled, not a panel or a sheet, visible or
/// minimized, with or without a close button.
FOUNDATION_EXPORT BOOL W7CloseChannelWindowKeepsAppRunning(NSWindowStyleMask mask, BOOL isPanel, BOOL isSheet,
                                                           BOOL isVisible, BOOL isMiniaturized);
/// `W7CloseKeepAlive`: a global defaults array of bundle ids never quit after their last window closed
/// (`defaults write -g W7CloseKeepAlive -array <bundle id>…`; empty by default). The shell reads the same key.
FOUNDATION_EXPORT NSString *const W7CloseKeepAliveDefaultsKey;
/// Whether `bundleID` is kept alive by `list` (a W7CloseKeepAlive value; non-strings ignored). Finder always is.
FOUNDATION_EXPORT BOOL W7CloseChannelKeepsAliveInList(NSString *_Nullable bundleID, NSArray *_Nullable list);
/// Apps never quit after their last window closed: Finder, and the W7CloseKeepAlive list read from the defaults.
FOUNDATION_EXPORT BOOL W7CloseChannelKeepsAlive(NSString *_Nullable bundleID);
/// `defaults write -g W7CloseChannelDisabled -bool YES` (or the app's own domain): no observers are registered on
/// the next launch. Read once per process.
FOUNDATION_EXPORT BOOL W7CloseChannelDisabled(void);

/// Closes the app's windows when the taskbar asks (W7CloseChannelNotificationName), with performClose: as Cmd-W
/// would (the app's own save sheets run), then, after the run loop settles, quits the app with
/// `[NSApp terminate:nil]` (unsaved changes still ask) when no window that keeps it running is left
/// (W7CloseChannelWindowKeepsAppRunning) and the app is not W7CloseChannelKeepsAlive. Every entry point is in @try
/// and fails open. Main thread only, except the handlers.
/// The acknowledgement goes out as soon as a target is chosen, before performClose:. A main thread that is
/// busy for more than the shell's 0.7 s before the handler even runs can still let the shell's fallback act as well
/// (an Accessibility press, or the "Quit?" confirmation); that is accepted.
@interface W7CloseChannel : NSObject
/// `windows`: all the app's windows; `orderedWindows`: front to back. `terminate` runs after `settleDelay` when
/// nothing eligible is left. `disabled`: every request does nothing (the kill switch).
- (instancetype)initWithBundleID:(nullable NSString *)bundleID
                         windows:(NSArray<NSWindow *> *(^)(void))windows
                  orderedWindows:(NSArray<NSWindow *> *(^)(void))orderedWindows
                       keyWindow:(NSWindow *_Nullable (^)(void))keyWindow
                      mainWindow:(NSWindow *_Nullable (^)(void))mainWindow
                       terminate:(void (^)(void))terminate
                     settleDelay:(NSTimeInterval)settleDelay
                        disabled:(BOOL)disabled NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/// The window "Close window" closes: the key window, else the main window, else the frontmost visible one, each
/// only when eligible; nil when there is none.
- (nullable NSWindow *)targetWindow;
/// performClose: on targetWindow. Returns the number of windows asked to close (0 or 1), -1 when disabled.
- (NSInteger)closeWindow;
/// performClose: on every eligible window. Returns how many were asked to close, -1 when disabled.
- (NSInteger)closeAllWindows;
/// Eligible windows the app still has.
- (NSInteger)eligibleWindowCount;
/// Acknowledgements posted (W7CloseChannelAckName): one per handled request that asked at least one window to close.
@property (nonatomic, readonly) NSInteger acknowledgements;
/// Observers for +start: hop to the main thread, close, and acknowledge when a window was asked to close.
- (void)handleCloseWindowNotification:(NSNotification *)n NS_SWIFT_NAME(handleCloseWindowNotification(_:));
- (void)handleCloseAllWindowsNotification:(NSNotification *)n NS_SWIFT_NAME(handleCloseAllWindowsNotification(_:));
/// Once per process, from W7ChromeController's start: unless W7CloseChannelDisabled (or the shell), registers for
/// both notifications with this process's pid, delivered immediately (background apps too). Settles 0.5 s.
+ (void)start;
@end

/// Builds cursors from `{arrow|ibeam|hand: {png: data, x: int, y: int}}` plist data. Unknown keys and
/// bad PNGs are skipped; nil or invalid data gives an empty dictionary.
FOUNDATION_EXPORT NSDictionary<NSString *, NSCursor *> *W7CursorsFromPlistData(NSData *_Nullable data);
/// Reads the embedded __DATA,__w7cursors section (if any) and swizzles the system cursors: imported
/// ones where present, the procedural Aero cursors otherwise.
/// Called from the dylib constructor; W7ChromeController.start calls it again (no-op) and sets the arrow.
FOUNDATION_EXPORT void W7InstallCursors(void);

// MARK: - Explorer theme for Finder

FOUNDATION_EXPORT const CGFloat W7ExplorerNavBarHeight;      // 34
FOUNDATION_EXPORT const CGFloat W7ExplorerCommandBarHeight;  // 32
FOUNDATION_EXPORT const CGFloat W7ExplorerDetailsPaneHeight; // 60

/// Address-bar segments as `{title, path}` pairs: "Computer" (`/`), or the home folder's name when
/// the folder is under `homePath`, then one segment per following path component. nil folder:
/// just Computer.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *W7BreadcrumbSegments(NSURL *_Nullable folder,
                                                                                       NSString *homePath);
/// Depth-first search of `root` for the item with this key equivalent and modifier mask. An uppercase
/// key counts as its lowercase plus Shift, on both sides. W7FindMenuItemMatching with the current
/// keyboard layout and no action hint. nil when nothing matches.
FOUNDATION_EXPORT NSMenuItem *_Nullable W7FindMenuItem(NSMenu *root, NSString *keyEquivalent,
                                                      NSEventModifierFlags mods) NS_SWIFT_UI_ACTOR;

/// How W7FindMenuItemMatching found its item.
typedef NS_ENUM(NSInteger, W7MenuMatch) {
    W7MenuMatchNone NS_SWIFT_NAME(none),
    W7MenuMatchKeyEquivalent NS_SWIFT_NAME(keyEquivalent),         // keyEquivalent equals the key
    W7MenuMatchUserKeyEquivalent NS_SWIFT_NAME(userKeyEquivalent), // userKeyEquivalent equals the key
    W7MenuMatchLocalizedKey NS_SWIFT_NAME(localizedKey),           // the layout-localized form of the key
    W7MenuMatchActionName NS_SWIFT_NAME(actionName)                // the action selector name holds the hint
};
/// The US-ANSI virtual key code (kVK_ANSI_*) of a single letter, digit or US punctuation character
/// (case-insensitive), or -1.
FOUNDATION_EXPORT NSInteger W7USVirtualKeyCode(NSString *character);
/// What `virtualKey` types in the keyboard layout `layoutData` ('uchr' data, as
/// kTISPropertyUnicodeKeyLayoutData gives it), with no modifiers or Shift only; nil when it can't.
FOUNDATION_EXPORT NSString *_Nullable W7TranslateVirtualKey(NSData *_Nullable layoutData, NSInteger virtualKey, BOOL shift);
/// The current keyboard layout's 'uchr' data (the ASCII-capable layout when the current input source
/// has none), or nil. Main thread.
FOUNDATION_EXPORT NSData *_Nullable W7CurrentKeyboardLayoutData(void) NS_SWIFT_UI_ACTOR;
/// The action-name hint for Finder's Back (Cmd+[ → "back") and Forward (Cmd+] → "forward"); nil otherwise.
FOUNDATION_EXPORT NSString *_Nullable W7MenuActionHint(NSString *keyEquivalent, NSEventModifierFlags mods);
/// W7FindMenuItem with fallbacks for menus whose key equivalents macOS localized to the keyboard layout
/// (Cmd+[ shows as Cmd+Ğ on Turkish Q). Whole-menu passes, in order, all requiring the same modifiers:
/// keyEquivalent equals the key; userKeyEquivalent equals it; the key is what the US key's position
/// types in `layoutData` (with Shift too when the modifiers include it). Last, when `actionHint` is
/// given, the first item whose action selector name contains it (any case). `how` reports which.
FOUNDATION_EXPORT NSMenuItem *_Nullable W7FindMenuItemMatching(NSMenu *root, NSString *keyEquivalent,
                                                              NSEventModifierFlags mods, NSData *_Nullable layoutData,
                                                              NSString *_Nullable actionHint,
                                                              W7MenuMatch *_Nullable how) NS_SWIFT_UI_ACTOR;
/// AppleScript that points Finder's front window at `posixPath` (`\` and `"` escaped).
FOUNDATION_EXPORT NSString *W7FinderGoScript(NSString *posixPath);
/// A Finder .savedSearch plist matching display names that contain `query`, scoped to `scopePath`.
FOUNDATION_EXPORT NSData *W7SavedSearchPlist(NSString *query, NSString *scopePath);
/// `url` when it is a file URL of a directory (trailing slash or NSURLIsDirectoryKey), else nil.
FOUNDATION_EXPORT NSURL *_Nullable W7ExplorerFolderURL(NSURL *_Nullable url);
/// Deletes `Win7Search-*.savedSearch` files in `directory` modified more than 24 h before `now`.
/// Returns how many were removed. Does file I/O: call it off the main thread.
FOUNDATION_EXPORT NSUInteger W7RemoveStaleSavedSearches(NSString *directory, NSDate *now);
/// AppleScript that prints Finder window `windowID` (the front Finder window when `windowID` <= 0) as
/// three lines: its AppleScript id, its name (title), then the POSIX path of its target folder.
FOUNDATION_EXPORT NSString *W7FinderTargetScript(NSInteger windowID);
/// Parses W7FinderTargetScript's output into `@{@"id": NSNumber, @"name": NSString, @"path": NSString}`
/// (the path without a trailing slash, except `/`; it may contain newlines, the name may not). nil
/// unless the id is a positive integer and the path is absolute.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable W7ParseFinderTargetOutput(NSString *output);
/// Whether a parsed answer belongs to the window: its `name` must equal `windowTitle`, and an answer
/// for "Finder window 1" (no `usedWindowID`) counts only when the window is `stillKey` on arrival.
FOUNDATION_EXPORT BOOL W7AcceptFinderTarget(NSDictionary<NSString *, id> *_Nullable parsed, NSString *windowTitle,
                                           BOOL usedWindowID, BOOL stillKey);

typedef NS_ENUM(NSInteger, W7TargetDecision) {
    W7TargetDecisionAccept NS_SWIFT_NAME(accept),           // show the answer's folder
    W7TargetDecisionKeep NS_SWIFT_NAME(keep),               // the current location still fits the title
    W7TargetDecisionTitleOnly NS_SWIFT_NAME(titleOnly),     // the current location is stale: title only
    W7TargetDecisionRequery NS_SWIFT_NAME(requery),         // the title changed during the query: ask again
    W7TargetDecisionWrongWindow NS_SWIFT_NAME(wrongWindow)  // the id answered for another window: forget it
};
/// What to do with an osascript answer (`parsed`, nil when the query failed) that was asked while
/// the window's title was `queryTitle`; it is now `currentTitle`, and the location shown was built for
/// `locationTitle`. Accept when W7AcceptFinderTarget does; Requery when the title moved meanwhile; a
/// mismatched answer for a specific id is WrongWindow; otherwise TitleOnly when the location shown no
/// longer matches the title, else Keep. WrongWindow callers also apply TitleOnly/Keep by the same rule.
FOUNDATION_EXPORT W7TargetDecision W7DecideFinderTarget(NSDictionary<NSString *, id> *_Nullable parsed,
                                                       NSString *queryTitle, NSString *currentTitle,
                                                       NSString *_Nullable locationTitle,
                                                       BOOL usedWindowID, BOOL stillKey);
/// AppleScript that prints the POSIX path of each item selected in Finder's front window, one per line.
FOUNDATION_EXPORT NSString *W7FinderSelectionScript(void);
/// The absolute paths in osascript output, one per line (CRLF tolerated, blank and relative lines
/// dropped, trailing slashes removed except on `/`).
FOUNDATION_EXPORT NSArray<NSString *> *W7ParsePathLines(NSString *output);
/// "1 item", "N items"; an empty string for a negative (unknown) count.
FOUNDATION_EXPORT NSString *W7ItemCountText(NSInteger count);
/// Items Finder shows in `path` (hidden files skipped), or -1 when it can't be read. File I/O: call it
/// off the main thread.
FOUNDATION_EXPORT NSInteger W7CountVisibleItems(NSString *path);
/// Visible, non-package subfolders of `path` as `{title, path}` pairs (title = display name), sorted
/// like Finder (localized standard compare), at most `limit`. File I/O: call it off the main thread.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *W7SubfolderEntries(NSString *path, NSUInteger limit);
/// YES only in Finder, for TBrowser* windows or, as a fallback, windows with a toolbar.
FOUNDATION_EXPORT BOOL W7ExplorerShouldAdopt(NSString *_Nullable bundleID, NSString *windowClassName, BOOL hasToolbar);
/// Turns a Finder browser window into a Windows 7 Explorer window (idempotent): drops the full-size
/// content view and transparent title bar, hides the toolbar, and adds the navigation and command
/// bars. Call before +[W7ChromeController decorateWindow:].
FOUNDATION_EXPORT void W7ExplorerAdopt(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// The Explorer glass in `view`'s coordinates: from the top of the title bar to the bottom of the
/// navigation bar, plus 8 pt more so the frame's bottom edge lies under the opaque command bar. The
/// title bar and the nav bar both draw this rect, so the gradient runs on without a seam. Without a
/// nav bar it is the title bar's bounds.
FOUNDATION_EXPORT CGRect W7ExplorerGlassRect(NSWindow *window, NSView *view) NS_SWIFT_UI_ACTOR;
/// YES once W7ExplorerAdopt has run on `window` (no title text, icon or menu strip).
FOUNDATION_EXPORT BOOL W7IsExplorerWindow(NSWindow *window) NS_SWIFT_UI_ACTOR;

// MARK: - Explorer "Browse folders" option

/// Defaults suite of the dylib's own preferences ("com.win7mac.chrome").
FOUNDATION_EXPORT NSString *const W7ExplorerBrowseSuiteName;
/// BOOL in that suite: YES opens each folder in its own window; NO (the default) in the same window.
FOUNDATION_EXPORT NSString *const W7ExplorerOpenFoldersInNewWindowKey;
/// Test seam: reads and writes the preference in `suiteName` instead (nil: W7ExplorerBrowseSuiteName).
FOUNDATION_EXPORT void W7ExplorerUseBrowseDefaultsSuite(NSString *_Nullable suiteName);
/// The preference, cached; the cache follows writes from anywhere (key-value observed).
FOUNDATION_EXPORT BOOL W7ExplorerOpensFoldersInNewWindow(void);
/// Writes the preference (applies to the next folder opened, in every Explorer window).
FOUNDATION_EXPORT void W7ExplorerSetOpensFoldersInNewWindow(BOOL openInNewWindow);
/// What the hooked -isToolbarVisible tells Finder: YES for an Explorer window in same-window mode
/// (Finder opens folders in a new window when a browser window's toolbar is hidden), else `actualVisible`.
FOUNDATION_EXPORT BOOL W7ExplorerReportedToolbarVisible(BOOL actualVisible, BOOL isExplorerWindow, BOOL openInNewWindow);
/// Guard on the image the installer scans: YES only for Finder's executable (a path ending in
/// "/Finder.app/Contents/MacOS/Finder"). NULL: NO.
FOUNDATION_EXPORT BOOL W7ExplorerBrowseImageIsFinder(const char *_Nullable imagePath);
/// Replaces `cls`'s OWN argument-free BOOL -isToolbarVisible (inherited ones are left alone) with one
/// that returns W7ExplorerReportedToolbarVisible(original, receiver's window is Explorer, preference).
/// The receiver's window: itself (NSWindow), -window (NSWindowController), the loaded view's window
/// (NSViewController), or an object-returning -window; none gives the original value. Idempotent: YES
/// when the class is (now or already) hooked, NO when it has no such method. Main thread.
FOUNDATION_EXPORT BOOL W7ExplorerHookToolbarVisibleOnClass(Class cls) NS_SWIFT_UI_ACTOR;
/// The classes of one loaded image (objc_copyClassNamesForImage, exact dyld path) that own an
/// argument-free BOOL -isToolbarVisible; only that image is scanned, and nothing is hooked. Classes owning
/// a same-named method of another type are logged and left out. Empty for an unknown image.
FOUNDATION_EXPORT NSArray<Class> *W7ExplorerBrowseHookCandidates(NSString *imagePath) NS_SWIFT_UI_ACTOR;
/// The first of `imageNames` whose Mach-O file type (`fileTypes`, parallel: mach_header.filetype) is
/// MH_EXECUTE, in dyld's own spelling; nil when there is none or the lists differ in length. Never
/// assumes image 0 (Ammonia's loader is image 0 under injection).
FOUNDATION_EXPORT NSString *_Nullable W7ExplorerExecutableImageName(NSArray<NSNumber *> *fileTypes,
                                                                   NSArray<NSString *> *imageNames);
/// Fallback when no image is MH_EXECUTE: the entry of `loadedImages` (dyld image names, in any order) that is the main executable at
/// `mainExecutablePath`, spelled as the runtime spells it; nil when none is. Paths are compared
/// standardized, with symlinks resolved and a leading /private dropped from /private/var, /private/tmp
/// and /private/etc. Never assumes image 0 (Ammonia's loader is image 0 under injection).
FOUNDATION_EXPORT NSString *_Nullable W7ExplorerMainImageName(NSString *_Nullable mainExecutablePath,
                                                             NSArray<NSString *> *loadedImages);
/// Once per process: finds the main executable among the loaded images (the MH_EXECUTE image, else
/// NSBundle.mainBundle.executablePath matched by W7ExplorerMainImageName) and, when it is Finder's
/// (W7ExplorerBrowseImageIsFinder), hooks
/// W7ExplorerBrowseHookCandidates of that image only (never a full class-list scan), logging each class,
/// the scan time, and when nothing was found. Called from Finder only.
FOUNDATION_EXPORT void W7ExplorerInstallBrowseHook(void) NS_SWIFT_UI_ACTOR;
/// The Organize menu of an Explorer window (Finder's entries, then the two Browse folders options with
/// the current one checked); nil for any other window.
FOUNDATION_EXPORT NSMenu *_Nullable W7ExplorerOrganizeMenu(NSWindow *window) NS_SWIFT_UI_ACTOR;

// MARK: - Explorer navigation pane visibility

/// At most this many forced expands per window within W7SidebarForcePeriod (3 in 10 s), so a Finder
/// that keeps collapsing its sidebar is not fought in a loop.
FOUNDATION_EXPORT const NSUInteger W7SidebarMaxForcedExpands;
FOUNDATION_EXPORT const NSTimeInterval W7SidebarForcePeriod;
/// How long after a sidebar menu action (View ▸ Hide Sidebar) a collapse counts as the user's (3 s).
FOUNDATION_EXPORT const NSTimeInterval W7SidebarUserActionWindow;

/// Whether to open an Explorer window's navigation pane: only when it is collapsed, the user has not
/// hidden it in this window, and fewer than W7SidebarMaxForcedExpands expands ran recently.
FOUNDATION_EXPORT BOOL W7ShouldExpandSidebar(BOOL collapsed, BOOL hiddenByUser, NSUInteger recentForcedExpands);
/// Whether a collapse is the user's choice: a divider drag, or within W7SidebarUserActionWindow of a
/// sidebar menu action (`secondsSinceSidebarAction` < 0: none yet). Never during a live window resize:
/// that is NSSplitViewController auto-collapsing a narrow window, and the pane returns when it widens.
FOUNDATION_EXPORT BOOL W7SidebarCollapseIsUsers(BOOL liveResize, BOOL dividerDrag, NSTimeInterval secondsSinceSidebarAction);
/// YES for a menu action that shows or hides the sidebar: its selector name contains "sidebar" in any
/// case (NSSplitViewController's toggleSidebar:, or Finder's own; titles are localized, selectors not).
FOUNDATION_EXPORT BOOL W7IsSidebarMenuAction(SEL _Nullable action);
/// Every item of `root` (and its submenus) whose action W7IsSidebarMenuAction accepts, breadth-first.
FOUNDATION_EXPORT NSArray<NSMenuItem *> *W7SidebarMenuItems(NSMenu *_Nullable root) NS_SWIFT_UI_ACTOR;
/// The NSSplitViewItem whose view contains `sidebar`, found by walking up to each enclosing split view
/// whose delegate is an NSSplitViewController (innermost first). nil when there is none.
FOUNDATION_EXPORT NSSplitViewItem *_Nullable W7SidebarSplitItem(NSView *sidebar) NS_SWIFT_UI_ACTOR;

typedef NS_ENUM(NSInteger, W7SidebarExpandResult) {
    W7SidebarExpandResultNotFound NS_SWIFT_NAME(notFound),             // no split item or split view hosts it
    W7SidebarExpandResultAlreadyVisible NS_SWIFT_NAME(alreadyVisible), // nothing to do
    W7SidebarExpandResultSplitItem NS_SWIFT_NAME(splitItem),           // its NSSplitViewItem was uncollapsed
    W7SidebarExpandResultDivider NS_SWIFT_NAME(divider)                // the first divider was moved to 200 pt
};
/// YES when the sidebar is found and collapsed (`found` reports whether it was found at all).
FOUNDATION_EXPORT BOOL W7SidebarIsCollapsed(NSWindow *window, NSView *_Nullable sidebar, BOOL *_Nullable found) NS_SWIFT_UI_ACTOR;
/// Shows `window`'s sidebar without animation. Through the NSSplitViewItem hosting `sidebar` (or, with
/// no sidebar view, the window's sidebar-behaviour split item); otherwise, when `sidebar` is in the
/// first pane of a split view and that pane is collapsed, by moving the first divider to 200 pt.
FOUNDATION_EXPORT W7SidebarExpandResult W7ExpandSidebar(NSWindow *window, NSView *_Nullable sidebar) NS_SWIFT_UI_ACTOR;

/// Keeps one Explorer window's navigation pane (Finder's sidebar) shown, unless the user hides it in
/// that window (respected until the window closes). Owned by the window's content styler.
NS_SWIFT_UI_ACTOR
@interface W7ExplorerSidebarKeeper : NSObject
- (instancetype)initWithWindow:(NSWindow *)window NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Expands a collapsed sidebar (at most W7SidebarMaxForcedExpands per W7SidebarForcePeriod) unless the
/// user hid it. The first call is the adoption check, where a collapse is never the user's; later
/// calls come from the throttled maintenance pass. `sidebar` may be nil (no sidebar view found). A
/// collapse during a live window resize is left alone until the window is wider than where it
/// happened, then re-opened outside the rate limit.
- (void)checkSidebar:(nullable NSView *)sidebar;
@end

// MARK: - Standard controls

/// Bool read through NSUserDefaults.standardUserDefaults, so the global domain (`defaults write -g
/// W7ControlsDisabled -bool YES`) and an app's own domain both work: when YES the control hooks are not installed.
FOUNDATION_EXPORT NSString *const W7ControlsDisabledKey;

typedef NS_ENUM(NSInteger, W7ButtonKind) {
    W7ButtonKindNone NS_SWIFT_NAME(none),
    W7ButtonKindPush NS_SWIFT_NAME(push),
    W7ButtonKindCheckBox NS_SWIFT_NAME(checkBox),
    W7ButtonKindRadio NS_SWIFT_NAME(radio)
};

/// Which Windows 7 control a button cell is: switch and radio types are check boxes and radio buttons;
/// any other type is a push button when bordered with bezel style Automatic (0), Push (1) or
/// FlexiblePush (2); everything else is None.
FOUNDATION_EXPORT W7ButtonKind W7ButtonKindFor(NSBezelStyle bezelStyle, BOOL bordered, NSButtonType buttonType);
/// Whether a button draws as Windows 7: in-scope kind, light appearance, not in a toolbar. Every window
/// of an injected app counts (panels and sheets too).
FOUNDATION_EXPORT BOOL W7ShouldDrawW7Button(NSBezelStyle bezelStyle, BOOL bordered, NSButtonType buttonType,
                                            BOOL isDark, BOOL inToolbar);
/// YES when `cls` has its own implementation (not NSButtonCell's) of any cell drawing method: drawWithFrame,
/// drawInteriorWithFrame, drawBezelWithFrame, drawImage:withFrame and drawTitle:withFrame (…inView:).
FOUNDATION_EXPORT BOOL W7CellClassOverridesDrawing(Class _Nullable cls);
/// Whether a cell class (by name) gets the Windows 7 drawing: NSButtonCell, and AppKit's NSAlert cells
/// (_NSAlertButtonCell, _NSAlertCheckboxButtonCell) while they override no drawing method. App subclasses,
/// pop-up cells and every other subclass keep their own drawing.
FOUNDATION_EXPORT BOOL W7CellClassNameEligible(NSString *className, BOOL overridesDrawing);
/// W7CellClassNameEligible for a cell's isa class (cached per class); a KVO subclass (NSKVONotifying_…) is
/// judged as the class it observes. Both the override check and the drawing hooks use it.
FOUNDATION_EXPORT BOOL W7IsEligibleCellClass(Class _Nullable cls);
/// Whether AppKit is told the cell overrides drawing, so it draws through the cell (classic path)
/// instead of its SwiftUI-hosted button: an eligible cell class (W7IsEligibleCellClass), an in-scope kind,
/// not in a toolbar. Independent of appearance: the choice is cached by AppKit, and a dark button then falls
/// back to the original cell drawing.
FOUNDATION_EXPORT BOOL W7ShouldForceCellDrawing(Class _Nullable cellClass, NSBezelStyle bezelStyle, BOOL bordered,
                                                NSButtonType buttonType, BOOL inToolbar);
/// Whether a scroller draws as Windows 7 (light appearance).
FOUNDATION_EXPORT BOOL W7ShouldDrawW7Scroller(BOOL isDark);
/// Whether a scroller instance is switched to the Windows 7 scroller class: its class is exactly
/// NSScroller (not an app subclass, not KVO-observed, not already switched) and the appearance is light.
FOUNDATION_EXPORT BOOL W7ShouldAdoptScroller(Class _Nullable instanceClass, BOOL isDark);
/// YES for the dark Aqua appearance name (as returned by bestMatchFromAppearancesWithNames:).
FOUNDATION_EXPORT BOOL W7IsDarkAppearanceName(NSAppearanceName _Nullable name);
/// Whether the private AppKit methods the button hook relies on have the expected type encodings:
/// `-[NSButtonCell _classForOverrideCheck]` "#16@0:8" and `-[NSButtonCell _buttonType]` "Q16@0:8".
FOUNDATION_EXPORT BOOL W7ControlHookSignaturesOK(const char *_Nullable classForOverrideCheckTypes,
                                                 const char *_Nullable buttonTypeTypes);
/// The Windows 7 thumb rect in a scroller's `bounds`: AppKit's knob rect along the scroll axis, the
/// full scroller thickness across it.
FOUNDATION_EXPORT CGRect W7ScrollerThumbRect(CGRect bounds, CGRect knobRect, BOOL vertical);
/// `title` with system (catalog) foreground colours replaced: black, or `#838383` when disabled. Colours
/// the app set itself are kept.
FOUNDATION_EXPORT NSAttributedString *W7ControlTitle(NSAttributedString *title, BOOL enabled);
/// Installs the control hooks once: the classic-drawing override check and the cell drawing hooks for
/// buttons, and the scroller adoption hooks. Does nothing when W7ControlsDisabled is set or a private
/// method is missing or has an unexpected signature. Returns whether the hooks are installed.
FOUNDATION_EXPORT BOOL W7InstallControlHooks(void);
/// Switches every eligible scroller under `view` (inclusive) to the Windows 7 scroller class and makes
/// its scroll view use legacy (always visible) scrollers. No-op unless the hooks are installed.
FOUNDATION_EXPORT void W7AdoptScrollersInView(NSView *view) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - Explorer folder icons in Finder

NS_ASSUME_NONNULL_BEGIN

/// What the folder-icon hook knows about a Finder item: from its FINode (folder, package, a copy or
/// download in progress) and from the file system (W7FolderFileTraits).
typedef NS_OPTIONS(NSUInteger, W7FolderNodeTraits) {
    W7FolderNodeIsFolder = 1 << 0,
    W7FolderNodeIsPackage = 1 << 1,
    W7FolderNodeIsVolume = 1 << 2,        // a mount point (volume root)
    W7FolderNodeIsAlias = 1 << 3,         // FinderInfo kIsAlias
    W7FolderNodeIsSymlink = 1 << 4,
    W7FolderNodeHasCustomIcon = 1 << 5,   // FinderInfo kHasCustomIcon (a pasted icon)
    W7FolderNodeIsCustomized = 1 << 6,    // macOS folder customization (tint, symbol, emoji): com.apple.icon.folder#S
    W7FolderNodeInProgress = 1 << 7,      // Finder shows copy or download progress on the icon
    W7FolderNodeIsLocked = 1 << 8,        // UF_IMMUTABLE or SF_IMMUTABLE (Finder's "Locked")
    W7FolderNodeIsUnreadable = 1 << 9,    // access(R_OK) fails: no read permission, drop boxes
    W7FolderNodeIsPlainFile = 1 << 10,    // a readable regular file: no alias, custom icon or lock
};

/// The Finder icon is replaced only for a plain folder: a folder and none of the other traits.
FOUNDATION_EXPORT BOOL W7ShouldReplaceFolderIcon(W7FolderNodeTraits traits);
/// File-system traits of the item at `path`, without following a symlink: IsFolder for a directory,
/// IsSymlink, IsVolume, IsAlias / HasCustomIcon (FinderInfo flags), IsLocked (immutable flags),
/// IsUnreadable, IsCustomized (the customization extended attribute), IsPackage (the bundle bit, or a
/// package by its extension), IsPlainFile for a readable regular file without the alias or custom-icon flag
/// that is not locked (an unreadable file gets IsUnreadable instead). 0 when it is missing.
FOUNDATION_EXPORT W7FolderNodeTraits W7FolderFileTraits(NSString *path);
/// The override name for a Finder file icon: for exactly W7FolderNodeIsPlainFile, the type of `path`'s
/// extension through UTType as IconOverrideNames.fileType maps it — image → "file-image", movie → "file-video",
/// audio → "file-audio", text → "file-text", anything else or no extension → "file"; nil for any other traits
/// (folders, packages, aliases, symlinks, custom icons, locked, unreadable, in progress). Never reads the file.
FOUNDATION_EXPORT NSString *_Nullable W7FileIconOverrideName(W7FolderNodeTraits traits, NSString *_Nullable path);
/// Whether the hook replaces Finder's image with the type icon `name` at the requested `size`: Windows 7
/// shows thumbnails from Medium icons (48) up, so "file-image", "file-video", "file-audio" and "file" are replaced
/// only when the shorter side of `size` is below 48 pt (16-32: list, column, small icons) and keep Finder's image
/// (its Quick Look thumbnail, album art, PDF page) at 48 pt and more; "file-text" (and any other name) is replaced
/// at every size, as Windows 7 never thumbnails text. NO for a nil name or an empty size. Pure.
FOUNDATION_EXPORT BOOL W7FileIconOverrideAppliesAtSize(NSString *_Nullable name, NSSize size);
/// The Explorer picture for a location (address bar, details pane): a plain folder → W7FolderIconImage of its
/// kind (special folders by path); a volume root → the user's "drive-system" (`/`) or "drive" icon; a plain file
/// → its W7FileIconOverrideName icon. nil when that icon is absent and for everything else (packages, aliases,
/// locked or customized folders, missing paths), so the caller keeps Finder's or NSWorkspace's icon. A new
/// NSImage `points` square each call (the caller may resize it); thread-safe (file-system traits are read).
FOUNDATION_EXPORT NSImage *_Nullable W7ExplorerIconForPath(NSString *path, CGFloat points);
/// Home and its special folders (Desktop, Documents, Downloads, Music, Pictures, Movies) as
/// standardized paths → W7FolderIconKind, from NSFileManager, computed once.
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *W7FolderIconSpecialPaths(void);
/// The icon kind for a folder path: its entry in `specialPaths` (paths compared standardized, without
/// a trailing slash), otherwise plain.
FOUNDATION_EXPORT W7FolderIconKind W7FolderIconKindForPath(NSString *path, NSDictionary<NSString *, NSNumber *> *specialPaths);
/// The asset that overrides a kind's drawn icon: "folder", "folder-documents", "folder-pictures",
/// "folder-music", "folder-videos", "folder-downloads", "folder-desktop", "folder-user" (as
/// `<asset root>/icons/<name>.png`).
FOUNDATION_EXPORT NSString *W7FolderIconAssetName(W7FolderIconKind kind);
/// Where override assets are looked up: `root` (tests), or nil for ~/Library/Application Support/Win7Mac/Assets.
/// Clears the icon caches.
FOUNDATION_EXPORT void W7FolderIconUseAssetRoot(NSString *_Nullable root);
/// Replaces the special-folder map the hook uses (tests); nil restores W7FolderIconSpecialPaths().
FOUNDATION_EXPORT void W7FolderIconUseSpecialPaths(NSDictionary<NSString *, NSNumber *> *_Nullable specialPaths);
/// The bitmap size (points) an icon of `points` is rendered at: rounded up to a whole point, and above
/// 64 pt up to a multiple of 8, so a size slider reuses a few bitmaps instead of rendering every size.
FOUNDATION_EXPORT CGFloat W7FolderIconBucketPoints(CGFloat points);
/// A new NSImage of `size` for `kind`, with 1x and 2x bitmap representations (the override asset when
/// there is one, otherwise W7CreateFolderIconImage), from a thread-safe cache keyed by kind and bucket
/// (W7FolderIconBucketPoints of the shorter side). A square `size` reuses the bucket bitmaps as they
/// are; a non-square one gets the square icon centred in it, never stretched.
FOUNDATION_EXPORT NSImage *_Nullable W7FolderIconImage(W7FolderIconKind kind, NSSize size);
/// Tests: how many rendered folder bitmaps W7FolderIconImage's cache holds. Every icon-loader reset
/// (W7UserIconsClearCaches, W7UserIconsUseEmbedded, W7FolderIconUseAssetRoot) empties that cache.
FOUNDATION_EXPORT NSUInteger W7FolderIconCachedBitmapCount(void);

/// The address bar drop-down's 16 pt row icon for the folder `path`, judged by the path alone (no file-system
/// access): a volume (W7NavPanePathIsMountPoint) → the user's "drive-system" (`/`) or "drive" icon when present; a
/// package (its extension's UTType conforms to com.apple.package, `Tool.app`) → NSImageNameFolder; otherwise
/// W7FolderIconImage of its kind (special folders by path), else NSImageNameFolder. A new image each call.
FOUNDATION_EXPORT NSImage *W7ExplorerMenuIconForPath(NSString *path);
/// The Explorer command bar Help button's 16 pt picture: the user's "help" icon, or nil to draw W7DrawHelpButton.
/// Kept until the icon loader resets (W7UserIconsGeneration), so a redraw allocates nothing. Main thread.
FOUNDATION_EXPORT NSImage *_Nullable W7ExplorerCommandHelpIcon(void) NS_SWIFT_UI_ACTOR;

/// Type encoding the hooked -iconImageForNode: must have: `@24@0:8r^{TFENode=^{OpaqueNodeRef}}16`.
FOUNDATION_EXPORT const char *const W7FolderIconNodeMethodTypes;
/// Hooks `cls`'s own -iconImageForNode: when its type encoding is exactly W7FolderIconNodeMethodTypes.
/// The replacement calls the original, resolves the node with `+[nodeClass nodeFromNodeRef:]` and returns
/// a Windows 7 folder icon of the original's size for a plain folder, and for a plain file the user's icon of
/// its type (W7FileIconOverrideName through W7UserIconImageSized) when that PNG exists and
/// W7FileIconOverrideAppliesAtSize allows it at the original's size (pictures, videos, audio and generic files
/// keep Finder's thumbnail at 48 pt and more; text files are replaced at every size); anything else, or any
/// failure, returns the original. Only the outermost hooked level on the thread decides (hooked implementations
/// that Finder's call reaches through super pass Finder's image up untouched), and instances of
/// W7FolderIconUseSkippedClasses always get the original. Logs one diagnostic line per class on its
/// first call. Idempotent per class. NO when not hooked.
FOUNDATION_EXPORT BOOL W7FolderIconHookClass(Class _Nullable cls, Class _Nullable nodeClass);
/// Finder only, and not with `defaults write com.apple.finder W7FolderIconsDisabled -bool YES` (or -g).
FOUNDATION_EXPORT BOOL W7FolderIconHookShouldInstall(NSString *_Nullable bundleID, BOOL disabled);
/// The classes of `classes` that own -iconImageForNode: with exactly W7FolderIconNodeMethodTypes, minus
/// `skippedNames` (each skip is logged).
FOUNDATION_EXPORT NSArray<Class> *W7FolderIconHookCandidates(NSArray<Class> *classes, NSSet<NSString *> *skippedNames);
/// W7FolderIconHookCandidates over every class the runtime registered for the image `imageName` (a
/// dyld image name, as class_getImageName returns it).
FOUNDATION_EXPORT NSArray<Class> *W7FolderIconHookCandidatesInImage(NSString *imageName, NSSet<NSString *> *skippedNames);
/// Finder's classes that are never hooked: TDesktopViewController (the desktop is not Explorer).
FOUNDATION_EXPORT NSSet<NSString *> *W7FolderIconSkippedClassNames(void);
/// The classes whose instances always keep Finder's icon (even through a hooked superclass's method
/// that they inherit or call super into) and are never reloaded: set once at install from
/// W7FolderIconSkippedClassNames, at most 4; nil clears (tests). Read lock-free.
FOUNDATION_EXPORT void W7FolderIconUseSkippedClasses(NSArray<Class> *_Nullable classes);
/// Every live instance of `baseClass` serving the windows: view controllers found as a view's next
/// responder (a view controller's view), as the delegate or data source of a collection, table or
/// outline view, or in the content view controller tree. Each instance once.
FOUNDATION_EXPORT NSArray *W7FolderIconBrowserControllers(NSArray<NSWindow *> *windows, Class _Nullable baseClass) NS_SWIFT_UI_ACTOR;
/// Sends -reloadIconsInView to each W7FolderIconBrowserControllers instance that answers it; returns how many.
FOUNDATION_EXPORT NSUInteger W7FolderIconReloadBrowserViews(NSArray<NSWindow *> *windows, Class _Nullable baseClass) NS_SWIFT_UI_ACTOR;
/// Once per process: hooks every class of Finder's executable image that owns -iconImageForNode:
/// (W7FolderIconHookCandidatesInImage, the image found through TBrowserViewController's class) except
/// W7FolderIconSkippedClassNames, with FINode, then reloads the icons of the browser views already open.
FOUNDATION_EXPORT void W7ExplorerInstallFolderIconHook(void);

// MARK: - Rendering and responsiveness

/// os_signpost log: subsystem com.win7mac.chrome, category "perf" (Instruments' os_signpost track).
FOUNDATION_EXPORT os_log_t W7PerfLog(void);
/// `defaults write -g W7PerfLog -bool YES`: log main-thread intervals over 16 ms. Read once per process.
FOUNDATION_EXPORT BOOL W7PerfLogEnabled(void);
/// Whether an interval of `seconds` gets a log line: enabled, on the main thread and over 16 ms.
FOUNDATION_EXPORT BOOL W7PerfShouldLog(double seconds, BOOL isMainThread, BOOL enabled);
/// Ends a W7_PERF_BEGIN interval's timing: logs `name` when W7PerfShouldLog says so.
FOUNDATION_EXPORT void W7PerfFinish(const char *name, uint64_t startNanos);

/// A signposted, timed interval around a block of code: W7_PERF_BEGIN(name) … W7_PERF_END(name), with a
/// bare identifier as the name (it becomes the signpost name). Use in one scope.
#define W7_PERF_BEGIN(label) \
    os_signpost_id_t w7_sp_##label = os_signpost_id_generate(W7PerfLog()); \
    os_signpost_interval_begin(W7PerfLog(), w7_sp_##label, #label); \
    uint64_t w7_t0_##label = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
#define W7_PERF_END(label) \
    os_signpost_interval_end(W7PerfLog(), w7_sp_##label, #label); \
    W7PerfFinish(#label, w7_t0_##label)

/// `text`'s size in `font`, as -sizeWithAttributes: with only the font gives it, cached per (text,
/// font): menu strips and menus measure the same titles on every draw and hit test.
FOUNDATION_EXPORT NSSize W7TextSize(NSString *text, NSFont *font);

// MARK: - Native title in decorated windows

/// The title visibility the setTitleVisibility: guard passes on: Hidden for a decorated window (the Aero
/// bar draws the caption text, so AppKit's own title would show twice), otherwise `visibility`.
FOUNDATION_EXPORT NSWindowTitleVisibility W7GuardedTitleVisibility(NSWindowTitleVisibility visibility, BOOL decorated);
/// The value the setTitlebarAppearsTransparent: guard passes on: YES for a decorated window (AppKit's title
/// bar material stays off under the Aero bar), otherwise `transparent`.
FOUNDATION_EXPORT BOOL W7GuardedTitlebarAppearsTransparent(BOOL transparent, BOOL decorated);
/// YES for the class names of AppKit's toolbar/title bar title views: after stripping leading underscores,
/// an AppKit name (prefix "NS") ending in "ToolbarTitleView", "TitlebarTitleView" or "ToolbarTitleField"
/// (NSToolbarTitleView, _NSToolbarTitleField; the names vary between macOS releases).
FOUNDATION_EXPORT BOOL W7IsNativeTitleViewClassName(NSString *_Nullable className);
/// The same match on a C class name (as class_getName returns it), without allocating.
FOUNDATION_EXPORT BOOL W7IsNativeTitleViewClassCName(const char *_Nullable className);
/// Swizzles -[NSWindow setTitleVisibility:] and -[NSWindow setTitlebarAppearsTransparent:] once so a
/// decorated window keeps W7GuardedTitleVisibility / W7GuardedTitlebarAppearsTransparent values when the
/// app (SwiftUI especially) re-sets them later. Logs the first coercion per window and setter. Called from
/// +[W7ChromeController start].
FOUNDATION_EXPORT void W7InstallDecoratedWindowGuards(void);
/// For a decorated window, hides (never removes, never shows again: decorated windows are never undecorated)
/// every visible native title view in a bounded walk of its title bar view (the close button's superview):
/// its direct children, and the direct children of a "…ToolbarView" among them, nothing deeper. Hidden are
/// views whose class matches W7IsNativeTitleViewClassCName, and AppKit's own title field (a direct
/// NSTextField child showing the window title). The Aero bar's own view is skipped. Logs once per window and
/// class. Returns how many views it hid; 0 for undecorated windows. decorateWindow and its settled pass call it.
FOUNDATION_EXPORT NSUInteger W7HideNativeTitleViews(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// W7HideNativeTitleViews, also reporting how many views the walk examined (tests bound the walk with it).
FOUNDATION_EXPORT NSUInteger W7HideNativeTitleViewsVisited(NSWindow *window, NSUInteger *_Nullable visitedViews) NS_SWIFT_UI_ACTOR;
/// The become-key/main re-hide: runs W7HideNativeTitleViews on a decorated window at most once per main
/// run-loop turn (both notifications arrive on one window switch). YES when it ran the pass.
FOUNDATION_EXPORT BOOL W7RehideNativeTitleViewsOncePerTurn(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// One line for os_log describing the window's title bar: class, title, titleVisibility, transparency,
/// toolbar (displayMode, style, item identifiers) and the title-like views (class names containing
/// "Title", text fields) under the title bar view, the hide pass's root, at any depth, each with its depth,
/// whether the bounded hide pass reaches it, and its hidden state. The Aero bar's views are left out.
FOUNDATION_EXPORT NSString *W7TitlebarDiagnostics(NSWindow *window) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - Explorer selection details, contextual command bar, selection highlight

NS_ASSUME_NONNULL_BEGIN

/// One selected Finder item, as the details pane and the command bar need it. Built off the main
/// thread from URL resource values (+infoForURL:), or filled in directly (tests).
@interface W7ExplorerItemInfo : NSObject
@property (nonatomic, copy) NSString *name;
/// Finder's kind ("JPEG image", the type's localized description); nil when unknown.
@property (nonatomic, copy, nullable) NSString *typeName;
/// A folder Finder browses into (packages and apps are files).
@property (nonatomic) BOOL isFolder;
/// Conforms to public.image.
@property (nonatomic) BOOL isImage;
/// An image, a PDF or text (plain, rich, HTML, source): Finder's File ▸ Print can print it.
@property (nonatomic) BOOL isPrintable;
/// Some application opens it by default.
@property (nonatomic) BOOL hasDefaultApp;
/// Bytes (files only); -1 when unknown.
@property (nonatomic) long long fileSize;
@property (nonatomic, copy, nullable) NSDate *modified;
@property (nonatomic, copy, nullable) NSDate *created;
/// Image dimensions in pixels; zero when unknown or not an image.
@property (nonatomic) NSSize pixelSize;
/// The file it was read from (nil in tests).
@property (nonatomic, copy, nullable) NSURL *url;
/// File I/O: call it off the main thread. Every item gets its name, kind flags, folder flag, size and
/// modification date from one resource-value read. Only `detailed` (a single selected item) also reads
/// the type description, the creation date, the default application and, for an image that is not
/// dataless (W7ExplorerFileIsDataless), the pixel size from the image header.
+ (instancetype)infoForURL:(NSURL *)url detailed:(BOOL)detailed;
/// Name only (from the URL): what an item falls back to when reading it failed.
+ (instancetype)nameOnlyInfoForURL:(NSURL *)url;
@end

/// A file whose contents are not on disk: iCloud reports it NotDownloaded (`downloadingStatus`, the
/// NSURLUbiquitousItemDownloadingStatusKey value, nil when not ubiquitous) or its stat flags have
/// SF_DATALESS. Its image header is never read (that would download it).
FOUNDATION_EXPORT BOOL W7ExplorerFileIsDataless(NSString *_Nullable downloadingStatus, uint32_t fileFlags);

typedef NS_ENUM(NSInteger, W7ExplorerDetailsTitleStyle) {
    W7ExplorerDetailsTitlePlain NS_SWIFT_NAME(plain),     // the folder's item count, body font
    W7ExplorerDetailsTitleHeading NS_SWIFT_NAME(heading), // "N items selected", large
    W7ExplorerDetailsTitleName NS_SWIFT_NAME(name)        // one item's name, large and bold
};

/// What the details pane shows: a title, an optional grey subtitle (the kind) and name/value rows.
@interface W7ExplorerDetailsContent : NSObject
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) W7ExplorerDetailsTitleStyle titleStyle;
@property (nonatomic, readonly, copy, nullable) NSString *subtitle;
/// Row labels ("Date modified:") and their values, parallel.
@property (nonatomic, readonly, copy) NSArray<NSString *> *labels;
@property (nonatomic, readonly, copy) NSArray<NSString *> *values;
- (instancetype)initWithTitle:(NSString *)title style:(W7ExplorerDetailsTitleStyle)style
                     subtitle:(nullable NSString *)subtitle labels:(NSArray<NSString *> *)labels
                       values:(NSArray<NSString *> *)values NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Windows 7 file size: "N bytes" ("1 byte") under 1 KB, else KB / MB / GB / TB (powers of 1000, as
/// Finder counts) with one decimal under 100 ("1.2 MB", "12.3 MB", a trailing .0 dropped) and none
/// from 100 up ("123 MB"); the decimal separator is `locale`'s. Negative: "—".
FOUNDATION_EXPORT NSString *W7ExplorerSizeText(long long bytes, NSLocale *locale);
/// Short date and short time in `locale` and `timeZone` ("16.10.2026 14:32" in tr_TR).
FOUNDATION_EXPORT NSString *W7ExplorerDateText(NSDate *date, NSLocale *locale, NSTimeZone *timeZone);
/// The details pane for a selection:
/// - nothing: the folder's item count (W7ItemCountText; `folderTitle` when unknown), plain, no rows;
/// - one file: its name (bold), its kind as the subtitle, then Date modified, Size, Date created and,
///   for an image with known dimensions, Dimensions ("1920 x 1080");
/// - one folder: its name, "File folder", Date modified;
/// - several: "N items selected" (heading), Date modified as the range "first - last" (one date when
///   they are equal), Size as the total of the files ("—" without files).
/// Unknown dates and sizes leave their row out.
FOUNDATION_EXPORT W7ExplorerDetailsContent *W7ExplorerDetailsForItems(NSArray<W7ExplorerItemInfo *> *items,
                                                                    NSString *folderTitle, NSInteger folderItemCount,
                                                                    NSLocale *locale, NSTimeZone *timeZone);
/// Selections larger than this (1000) are not read item by item: only their count is shown.
FOUNDATION_EXPORT const NSUInteger W7ExplorerSelectionReadLimit;
/// A selection that was counted but not read: "N items selected" (heading) and no rows.
FOUNDATION_EXPORT W7ExplorerDetailsContent *W7ExplorerDetailsForUnreadSelection(NSUInteger count);

/// Command bar buttons left of the view buttons.
typedef NS_ENUM(NSInteger, W7ExplorerCommand) {
    W7ExplorerCommandOrganize NS_SWIFT_NAME(organize),     // Organize ▾
    W7ExplorerCommandOpen NS_SWIFT_NAME(open),             // Open (a folder, or several items): Finder's Open
    W7ExplorerCommandOpenMenu NS_SWIFT_NAME(openMenu),     // Open ▾ (one file with a default app): split button
    W7ExplorerCommandOpenWith NS_SWIFT_NAME(openWith),     // Open with ▾ (one file without a default app)
    W7ExplorerCommandShare NS_SWIFT_NAME(share),           // Share with ▾
    W7ExplorerCommandSlideShow NS_SWIFT_NAME(slideShow),   // Slide show
    W7ExplorerCommandPrint NS_SWIFT_NAME(print),           // Print
    W7ExplorerCommandEmail NS_SWIFT_NAME(email),           // E-mail
    W7ExplorerCommandBurn NS_SWIFT_NAME(burn),             // Burn (always disabled)
    W7ExplorerCommandNewFolder NS_SWIFT_NAME(newFolder),   // New folder
    // The Computer view's set (W7ExplorerCommandsForComputer).
    W7ExplorerCommandSystemProperties NS_SWIFT_NAME(systemProperties),   // System Settings ▸ About
    W7ExplorerCommandUninstallProgram NS_SWIFT_NAME(uninstallProgram),   // Finder's Go ▸ Applications
    W7ExplorerCommandMapNetworkDrive NS_SWIFT_NAME(mapNetworkDrive),     // Finder's Go ▸ Connect to Server…
    W7ExplorerCommandOpenControlPanel NS_SWIFT_NAME(openControlPanel),   // the shell's Control Panel
    W7ExplorerCommandCount NS_SWIFT_NAME(count)
};

/// The buttons for a selection, in Windows 7 order (NSNumber-wrapped W7ExplorerCommand). Always
/// Organize first and Share with, Burn, New folder around the rest as Windows 7 orders them. Nothing
/// selected: Slide show when `folderHasImages`. One folder: Open. One file: Open ▾ (Open with ▾
/// without a default app), Slide show for an image, Print when printable, E-mail. Several: Open,
/// Slide show when any is an image, Print when all are printable files, E-mail when all are files.
FOUNDATION_EXPORT NSArray<NSNumber *> *W7ExplorerCommandsForItems(NSArray<W7ExplorerItemInfo *> *items, BOOL folderHasImages);
/// The buttons for a counted but unread selection (kinds and files unknown): Organize, Open, Burn,
/// New folder. No Share with: there are no files to hand over (and the folder is not what was selected).
FOUNDATION_EXPORT NSArray<NSNumber *> *W7ExplorerCommandsForUnreadSelection(void);
FOUNDATION_EXPORT NSString *W7ExplorerCommandTitle(W7ExplorerCommand command);
/// Organize, Open ▾, Open with ▾ and Share with draw a ▾.
FOUNDATION_EXPORT BOOL W7ExplorerCommandHasMenu(W7ExplorerCommand command);

/// Explorer item highlight states (icon and list views).
typedef NS_ENUM(NSInteger, W7ExplorerSelectionState) {
    W7ExplorerSelectionNone NS_SWIFT_NAME(none),
    W7ExplorerSelectionHover NS_SWIFT_NAME(hover),
    W7ExplorerSelectionSelected NS_SWIFT_NAME(selected),
    W7ExplorerSelectionSelectedUnfocused NS_SWIFT_NAME(selectedUnfocused),
};
/// sRGB hex colours of a highlight: a 1 pt border and a vertical fill from `top` to `bottom`.
typedef struct { uint32_t border, top, bottom; bool visible; } W7ExplorerSelectionColors;
/// Hover #B8D6FB / #EBF4FD→#DBEAFC; selected #84ACDD / #DCEBFC→#C1DBFC; selected and unfocused
/// #D9D9D9 / #F8F8F8→#E5E5E5; none is invisible.
FOUNDATION_EXPORT W7ExplorerSelectionColors W7ExplorerSelectionColorsForState(W7ExplorerSelectionState state);
/// Selected beats hover; a selection in a view without focus is SelectedUnfocused.
FOUNDATION_EXPORT W7ExplorerSelectionState W7ExplorerSelectionStateFor(BOOL selected, BOOL focused, BOOL hovered);
FOUNDATION_EXPORT const CGFloat W7ExplorerSelectionRadius;   // 3
/// The highlight for `state` in `rect` (radius 3, the 1 pt border inside `rect`), in a context whose
/// y axis points up (`flipped` NO) or down.
FOUNDATION_EXPORT void W7DrawExplorerSelection(CGContextRef ctx, CGRect rect, W7ExplorerSelectionState state, BOOL flipped);

/// Finder only, and not with `defaults write com.apple.finder W7ExplorerSelectionDisabled -bool YES` (or -g).
/// The same switch also leaves Finder's -selectionChanged unhooked (W7ExplorerSelection.m; the
/// details pane then follows the selection through polling only). Read once, at Finder's launch.
FOUNDATION_EXPORT BOOL W7ExplorerSelectionHighlightShouldInstall(NSString *_Nullable bundleID, BOOL disabled);
/// The highlight hooks act on Finder's classes, so they apply Finder-wide: every icon and list view
/// Finder shows (Explorer windows, search and Trash windows, and any other browser view it draws),
/// not only adopted Explorer windows. In a dark appearance they leave Finder's own look.
/// YES for a dark appearance (DarkAqua family), where no Windows 7 highlight is drawn.
FOUNDATION_EXPORT BOOL W7ExplorerAppearanceIsDark(NSAppearance *_Nullable appearance);
/// Icon view: hooks `cls`'s own -updateLayer (exactly `v16@0:8`, as on TIconSelectionView) so that
/// after the original the view's layer shows the Windows 7 highlight: selected, or selected-unfocused
/// when the nearest superview answering -useActiveAppearance says NO (without one: when the window is
/// not key). In a dark appearance the layer is left as the original drew it (a highlight drawn while
/// light is taken off again). Idempotent. NO when not hooked.
FOUNDATION_EXPORT BOOL W7ExplorerHookIconSelectionClass(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// How a Finder icon title is drawn.
typedef NS_ENUM(NSInteger, W7ExplorerIconTitleLook) {
    W7ExplorerIconTitleFinder NS_SWIFT_NAME(finder),            // Finder's own bubble and text colour
    W7ExplorerIconTitleDarkNoBubble NS_SWIFT_NAME(darkNoBubble) // no bubble, dark text (on the light Win7 look)
};
/// `finderBubble`: what Finder's own -titleBubbleViewIsSelected says (selected, a drop target or being
/// dragged; focused or not). A bubble Finder would show is suppressed only in a light appearance, and
/// then always together with dark text — Finder's selected title colour is white
/// (alternateSelectedControlTextColor), which would vanish without its bubble. Otherwise Finder's look.
FOUNDATION_EXPORT W7ExplorerIconTitleLook W7ExplorerIconTitleLookFor(BOOL finderBubble, BOOL dark);
/// The dark title colour: black, or black at 0.5 alpha for a dimmed title (a cut item).
FOUNDATION_EXPORT NSColor *W7ExplorerIconTitleDarkColor(BOOL dimmed);
/// Icon view titles: hooks `cls`'s own -titleBubbleViewIsSelected (exactly `B16@0:8`) and
/// -_titleFontColor (exactly `@16@0:8`) of TIconView as a pair — both or neither, so the bubble is
/// never taken away while the text stays white. Each asks W7ExplorerIconTitleLookFor with the original
/// bubble answer and the view's appearance: DarkNoBubble answers NO and W7ExplorerIconTitleDarkColor
/// (dimmed from an `isTitleDimmed` of type `B16@0:8`); Finder answers the originals. Idempotent.
FOUNDATION_EXPORT BOOL W7ExplorerHookIconTitleClass(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// List view: `cls` (an NSTableRowView subclass, TListRowView) draws the Windows 7 highlight in
/// -drawSelectionInRect: (selected, or selected-unfocused when the row is not emphasized). Only when
/// that draw hook is installed, and once it has actually painted a row of this class (a per-class
/// latch), does -interiorBackgroundStyle answer NSBackgroundStyleNormal, and only for a selected row
/// the hook draws (a highlight style, a light appearance), so cell text stays black
/// exactly where the light highlight is under it. Its own methods are replaced, inherited ones
/// overridden for that class only, once their type encodings match NSTableRowView's. Idempotent. NO
/// when not hooked.
FOUNDATION_EXPORT BOOL W7ExplorerHookListRowClass(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// Once per process, when W7ExplorerSelectionHighlightShouldInstall: TIconSelectionView, TIconView
/// titles and TListRowView (each logged; a missing class or a changed encoding leaves Finder's look).
FOUNDATION_EXPORT void W7ExplorerInstallSelectionHighlight(void) NS_SWIFT_UI_ACTOR;

/// The details pane view: up to three stacked icons on the left (48 pt) and the content's text on
/// the right, the rows in columns of at most three; columns that do not fit the width are left out.
@interface W7ExplorerDetailsView : NSView
@property (nonatomic, strong, nullable) W7ExplorerDetailsContent *content;
/// Front icon first; at most three are drawn.
@property (nonatomic, copy) NSArray<NSImage *> *icons;
/// Where the front icon is drawn.
@property (nonatomic, readonly) NSRect iconFrame;
/// The text rects drawn for the current bounds and content (title, subtitle, then each shown label
/// and value).
- (NSArray<NSValue *> *)textFrames;
@end

/// What the selection tracker needs from its Explorer window (W7ExplorerController; a fake in tests).
@protocol W7ExplorerSelectionHost <NSObject>
@property (nonatomic, readonly, weak, nullable) NSWindow *window;
/// The folder the window shows, or nil.
@property (nonatomic, readonly, nullable) NSURL *currentFolder;
@end

/// What Finder has selected in one Explorer window.
@interface W7ExplorerSelectionSnapshot : NSObject
/// The selected files (empty when nothing is selected or the selection was too large to read).
@property (nonatomic, readonly, copy) NSArray<NSURL *> *urls;
/// Parallel to `urls`.
@property (nonatomic, readonly, copy) NSArray<W7ExplorerItemInfo *> *items;
/// Finder's selected count (-selectedNodesCount), -1 when it could not be asked.
@property (nonatomic, readonly) NSInteger selectedCount;
/// YES when the count exceeded W7ExplorerSelectionReadLimit and the items were not read.
@property (nonatomic, readonly) BOOL unread;
/// With nothing selected: whether the folder holds an image (Slide show).
@property (nonatomic, readonly) BOOL folderHasImages;
/// The folder the snapshot was read in.
@property (nonatomic, readonly, copy, nullable) NSString *folderPath;
/// YES when it came from a browser view; NO when there was none to ask.
@property (nonatomic, readonly) BOOL known;
- (instancetype)initWithURLs:(NSArray<NSURL *> *)urls items:(NSArray<W7ExplorerItemInfo *> *)items count:(NSInteger)count
                      unread:(BOOL)unread folderHasImages:(BOOL)folderHasImages folderPath:(nullable NSString *)folderPath
                       known:(BOOL)known NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Follows Finder's selection in one window (W7ExplorerSelection.m). URLs come from the browser view
/// controller's Services requestor (-writeSelectionToPasteboard:types: into a private pasteboard;
/// public.file-url, else NSFilenamesPboardType). A selected count of 0 is trusted (nothing is read), a
/// count above W7ExplorerSelectionReadLimit is shown unread. Item attributes load off the main thread;
/// a later read supersedes an unfinished one; an item whose loader fails or throws is logged and kept
/// with its name only. Main thread.
NS_SWIFT_UI_ACTOR
@interface W7ExplorerSelectionTracker : NSObject
- (instancetype)initWithHost:(id<W7ExplorerSelectionHost>)host onChange:(void (^)(void))onChange NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, strong, nullable) W7ExplorerSelectionSnapshot *snapshot;
/// Debounce: each call restarts a `debounceInterval` (0.1 s) wait, but a read never waits more than
/// `maxDebounceWait` (0.5 s) after the first call of a burst.
@property (nonatomic) NSTimeInterval debounceInterval;
@property (nonatomic) NSTimeInterval maxDebounceWait;
/// Builds one item's info (default +infoForURL:detailed:), called off the main thread. Test seam.
@property (nonatomic, copy) W7ExplorerItemInfo *_Nullable (^infoLoader)(NSURL *url, BOOL detailed);
/// How many reads ran (after debouncing). Test seam.
@property (nonatomic, readonly) NSUInteger readCount;
- (void)setNeedsUpdate;
/// Cheap check run with the window's refresh: a changed selected count schedules a read.
- (void)poll;
/// The browser view controller that just reported a change (used when its view is in the host's window).
- (void)noteBrowser:(NSViewController *)browser;
/// Finder's selected count right now (-selectedNodesCount of the window's browser view), -1 when
/// there is no browser view or it can't be asked. Main thread, no I/O.
- (NSInteger)liveSelectedCount;
@end

typedef NS_ENUM(NSInteger, W7ExplorerShareDecision) {
    W7ExplorerShareSelection NS_SWIFT_NAME(selection),   // share the selected files
    W7ExplorerShareFolder NS_SWIFT_NAME(folder),         // nothing selected: share the open folder
    W7ExplorerShareAskFinder NS_SWIFT_NAME(askFinder),   // selection unknown: ask Finder (the osascript path)
    W7ExplorerShareBeep NS_SWIFT_NAME(beep),             // nothing to share: beep
};
/// Share with: a known selection's files; a known empty selection shares `folderPath` (beep without
/// one); an unread selection (over the read limit) beeps — never the folder in its place; no snapshot,
/// or one that could not ask a browser view, asks Finder.
FOUNDATION_EXPORT W7ExplorerShareDecision W7ExplorerShareDecisionFor(W7ExplorerSelectionSnapshot *_Nullable selection,
                                                                     NSString *_Nullable folderPath);

typedef NS_ENUM(NSInteger, W7ExplorerSlideShowPlan) {
    W7ExplorerSlideShowSelection NS_SWIFT_NAME(selection),       // ⌥⌘Y on Finder's selection as it is
    W7ExplorerSlideShowWholeFolder NS_SWIFT_NAME(wholeFolder),   // ⌘A, ⌥⌘Y, then ⌥⌘A when Quick Look closes
};
/// Slide show selects everything only for a selection known to be empty: a snapshot that is `known`
/// with a selected count of 0, a `liveCount` (W7ExplorerSelectionTracker -liveSelectedCount, read just
/// before) of 0 too, and `canRestore` (Finder has a Deselect All item and the Quick Look panel can be
/// watched). Anything else — no snapshot, not known, a count of -1, a stale snapshot — only sends ⌥⌘Y,
/// so a selection that was never seen is never replaced.
FOUNDATION_EXPORT W7ExplorerSlideShowPlan W7ExplorerSlideShowPlanFor(W7ExplorerSelectionSnapshot *_Nullable selection,
                                                                    NSInteger liveCount, BOOL canRestore);

NS_ASSUME_NONNULL_END

// MARK: - System Settings: security-pane exclusion and window background
//
// On macOS 26+ the System Settings sidebar is Liquid Glass and cannot be restyled with public API, so the
// Control Panel look is limited to a white window background while the visible pane is not a security pane.

NS_ASSUME_NONNULL_BEGIN

/// The bundle ids of the System Settings security panes (Privacy & Security, Home privacy, Security
/// improvements, Touch ID & Password, Users & Groups, Lock Screen, Passwords). Each runs in a process of
/// its own; W7DefaultDenylist includes them all, so nothing of ours ever runs in one.
FOUNDATION_EXPORT NSArray<NSString *> *W7SettingsExcludedExtensionIDs(void);
/// W7SettingsExcludedExtensionIDs plus the sidebar and legacy ids of the same panes
/// (com.apple.settings.privacyAndSecurity, com.apple.preference.security, …).
FOUNDATION_EXPORT NSArray<NSString *> *W7SettingsExcludedPaneIDs(void);
/// YES when the pane must stay native: an unknown id (nil, empty, whitespace, only an anchor), or one of
/// W7SettingsExcludedPaneIDs, compared without case, surrounding whitespace or a `?…`/`#…` anchor, also
/// as the prefix of a sub-pane id (`<excluded>.<more>`).
FOUNDATION_EXPORT BOOL W7SettingsPaneIsExcluded(NSString *_Nullable paneID);
/// The pane id detection reports: the host view controller configuration's extension bundle id when
/// there is one, else the remote view's service bundle id, else nil.
FOUNDATION_EXPORT NSString *_Nullable W7SettingsResolvePaneID(NSString *_Nullable configurationID,
                                                              NSString *_Nullable remoteServiceID);
/// One pane is excluded when neither source knows its id, or either source names an excluded pane.
FOUNDATION_EXPORT BOOL W7SettingsProbeIsExcluded(NSString *_Nullable configurationID, NSString *_Nullable remoteServiceID);
/// The visible panes under `root` (hidden subtrees skipped): one probe per view owned by a `hostClass`
/// view controller (`_EXHostViewController`), with "configuration" = [[vc configuration] extensionIdentity]
/// .bundleIdentifier and "remote" = the service bundle id of the first `remoteViewClass` view
/// (`NSRemoteView`) under it (its nextResponder's, else its remoteViewController's
/// serviceBundleIdentifier); a remote view outside any host gets a probe of its own. Keys are left out
/// when unknown. Every private call is checked with respondsToSelector and its type encoding. A nil
/// class finds nothing of that kind. Bounded walk.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *W7SettingsProbePanes(NSView *_Nullable root,
                                                                                      Class _Nullable hostClass,
                                                                                      Class _Nullable remoteViewClass) NS_SWIFT_UI_ACTOR;
/// YES when there is at least one probe and none is excluded (W7SettingsProbeIsExcluded).
FOUNDATION_EXPORT BOOL W7SettingsProbesAllowStyling(NSArray<NSDictionary<NSString *, NSString *> *> *probes);

/// System Settings (com.apple.systempreferences) only, and not with
/// `defaults write com.apple.systempreferences W7SettingsPanelDisabled -bool YES`.
FOUNDATION_EXPORT BOOL W7SettingsPanelShouldInstall(NSString *_Nullable bundleID, BOOL disabled);

/// `style` YES in the main Settings window (one with a sidebar: a view under the content view whose class
/// name ends in "SplitViewItemViewWrapper" with a BOOL -isSidebar answering YES; it is only looked at): a white
/// window background, recorded in the window's snapshot (target held weakly, value before the first change)
/// just before it is first changed. Nothing else is changed. `style` NO, or no sidebar found: the recorded
/// value is put back on the recorded window and the snapshot dropped, so nothing re-applies it. Idempotent
/// both ways. Each transition is logged as a `name: original → current` line (W7SettingsLastTransitionLines).
/// Returns the number of sidebar wrappers found.
FOUNDATION_EXPORT NSUInteger W7SettingsApplyWindowBackground(NSWindow *window, BOOL style) NS_SWIFT_UI_ACTOR;
/// The `name: original → current` lines of the window's last transition ("styled" or "restored").
FOUNDATION_EXPORT NSArray<NSString *> *W7SettingsLastTransitionLines(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Probes the window's panes with the given classes and applies the window background when
/// W7SettingsProbesAllowStyling and the window's appearance is light; otherwise restores it. Logs a summary line whenever it changes (the view
/// tree too, with `defaults write com.apple.systempreferences W7SettingsPanelVerboseLog -bool YES`).
/// Returns whether the window is styled now.
FOUNDATION_EXPORT BOOL W7SettingsRefreshWindowWithClasses(NSWindow *window, Class _Nullable hostClass,
                                                          Class _Nullable remoteViewClass) NS_SWIFT_UI_ACTOR;
/// A host view controller changed its pane. With a window: that window is refreshed now
/// (W7SettingsRefreshWindowWithClasses), so an excluded pane goes native in the same turn. Without one the
/// pane is unknown, so every styled window goes native now. `followUps`: refresh again on the next run-loop
/// pass and after 0.5 s (the hooks pass YES, with _EXHostViewController and NSRemoteView).
FOUNDATION_EXPORT void W7SettingsHostChangedWithClasses(NSViewController *vc, Class _Nullable hostClass,
                                                        Class _Nullable remoteViewClass, BOOL followUps) NS_SWIFT_UI_ACTOR;
/// W7SettingsRefreshWindowWithClasses with _EXHostViewController and NSRemoteView (NSClassFromString).
FOUNDATION_EXPORT BOOL W7SettingsRefreshWindow(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Hooks `sel` (exactly `types`: "v24@0:8@16" or "v16@0:8") so that after the original it reports a pane change
/// (W7SettingsHostChangedWithClasses with follow-ups) for `host` instances. The method is patched on `host`
/// when `host` defines it, otherwise on the nearest superclass that does, where the hook only reacts to `host`
/// instances. Returns the class patched (logged), or Nil when no class defines it with that encoding. A class
/// and selector are patched at most once.
/// W7SettingsPanelInstall calls it for -[_EXHostViewController setConfiguration:] and -viewWillAppear.
FOUNDATION_EXPORT Class _Nullable W7SettingsHookHostSelector(Class host, SEL sel, const char *types) NS_SWIFT_UI_ACTOR;
/// Called from +[W7ChromeController start]. Logs once whether this process is a System Settings pane
/// extension (diagnostic only). Then, when W7SettingsPanelShouldInstall: the -[_EXHostViewController
/// setConfiguration:] / -viewWillAppear re-checks (patched on the nearest class that defines each), the window title, appearance and
/// key/main re-checks, and a first refresh of the open windows. Everything fails open to the native look.
FOUNDATION_EXPORT void W7SettingsPanelInstall(void) NS_SWIFT_UI_ACTOR;

// System Settings sidebar view-tree diagnostics: nothing is
// drawn, set or hooked. Only the sidebar pane is walked, never the pane content area. Names and numbers only.

/// `defaults write -g W7SettingsSidebarDisabled -bool YES`: the sidebar kill switch, which skips even the dump. Read once.
FOUNDATION_EXPORT BOOL W7SettingsSidebarDisabled(void);
/// Tests: 1 or 0 forces W7SettingsSidebarDisabled, -1 goes back to the defaults.
FOUNDATION_EXPORT void W7SettingsSidebarUseDisabledOverride(NSInteger value);
/// `defaults write -g W7SettingsVerboseLog -bool YES`: the sidebar dump, once per System Settings main window. Read once.
FOUNDATION_EXPORT BOOL W7SettingsVerboseLog(void);
/// Tests: 1 or 0 forces W7SettingsVerboseLog, -1 goes back to the defaults.
FOUNDATION_EXPORT void W7SettingsUseVerboseLogOverride(NSInteger value);
/// System Settings (com.apple.systempreferences), a window with a sidebar, the verbose switch on, the kill switch
/// off, and the window not dumped yet.
FOUNDATION_EXPORT BOOL W7SettingsSidebarShouldDump(NSString *_Nullable bundleID, BOOL hasSidebar, BOOL disabled, BOOL verbose,
                                                   BOOL alreadyDumped);
/// The split view pane that holds the window's sidebar (public API only): the pane of the first NSSplitViewController
/// (in the window's view controller tree, else the delegate of the first NSSplitView under the content view) whose
/// item has NSSplitViewItemBehaviorSidebar; else a plain NSSplitView's first pane. Other panes are never searched: the
/// walk for a split view stops at it. nil when there is none.
FOUNDATION_EXPORT NSView *_Nullable W7SettingsSidebarPane(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
/// The sidebar's dump: a `sidebar source=` line (how it was found, split view, pane, item behaviour, view controller
/// class), `ancestor` lines up to the window's root view (class and frame only, never their other children), one
/// inventory line per SwiftUI host (`host`), glass container (`glass`: NSVisualEffectView or a class named *Glass*) and
/// table/outline view (`list`: rows, columns, row height, style, row view and cell view classes, frame in the window),
/// `row N` lines for the first rows of the first list (row view, cell view class, its imageView/textField classes,
/// image size, font point size; views that exist already, none is made), a `summary:` line, then the tree
/// (W7MessagesViewTreeLines, 24 deep, 400 views). `sidebar: none found` without one. Never a row title or any text.
FOUNDATION_EXPORT NSArray<NSString *> *W7SettingsSidebarDump(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
/// When W7SettingsSidebarShouldDump(bundleID, a sidebar pane found, W7SettingsSidebarDisabled(), W7SettingsVerboseLog(),
/// …): marks the window and logs W7SettingsSidebarDump a second later (os_log, in chunks); YES when it scheduled one.
/// Fails open.
FOUNDATION_EXPORT BOOL W7SettingsSidebarDiagnosticsUpdateForBundle(NSWindow *_Nullable window,
                                                                   NSString *_Nullable bundleID) NS_SWIFT_UI_ACTOR;
/// W7SettingsSidebarDiagnosticsUpdateForBundle with the main bundle's identifier (every other app: one string compare).
/// W7ChromeController calls it on every key/main change.
FOUNDATION_EXPORT void W7SettingsSidebarDiagnosticsUpdate(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - Procedural cursor fallback

NS_ASSUME_NONNULL_BEGIN

/// The NSCursor class methods the dylib and the shell replace, by selector name, with the W7CursorKind
/// (as NSNumber) each becomes: arrow, I-beam, pointing hand, the six resize cursors, crosshair, not allowed.
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *W7SwizzledCursorKinds(void);
/// `imported[W7CursorKindName(kind)]` when it is an NSCursor, otherwise the procedural cursor when
/// `allowProcedural`, otherwise nil (the system cursor stays).
FOUNDATION_EXPORT NSCursor *_Nullable W7ResolveCursor(NSDictionary<NSString *, NSCursor *> *imported, W7CursorKind kind,
                                                      BOOL allowProcedural);
/// W7ResolveCursor with procedural cursors allowed (never nil).
FOUNDATION_EXPORT NSCursor *W7CursorForKind(NSDictionary<NSString *, NSCursor *> *imported, W7CursorKind kind);
/// `defaults write -g W7ProceduralCursorsDisabled -bool YES`: only imported cursors replace the system
/// ones (read from the global domain at install, i.e. on the next app launch).
FOUNDATION_EXPORT BOOL W7ProceduralCursorsDisabled(void);
/// Once per process (until W7UninstallCursors): swizzles every W7SwizzledCursorKinds cursor to
/// W7ResolveCursor(imported, …, !W7ProceduralCursorsDisabled()), falling back to the system cursor; with
/// procedural cursors disabled and nothing imported it swizzles nothing. Doesn't set the cursor: callers
/// do that once AppKit has launched. W7InstallCursors calls it with the embedded __DATA,__w7cursors
/// cursors (or none), from the dylib constructor; the shell calls it with the cursors under Assets/.
FOUNDATION_EXPORT void W7InstallCursorsWithImported(NSDictionary<NSString *, NSCursor *> *imported);
/// Swizzles the cursors back (for tests); a later W7InstallCursorsWithImported installs again.
FOUNDATION_EXPORT void W7UninstallCursors(void);

NS_ASSUME_NONNULL_END

// MARK: - Internet Explorer 7-style Safari chrome

NS_ASSUME_NONNULL_BEGIN

/// Draws per-window bands over a decorated window's title bar glass. Generic: the title bar knows nothing
/// about who paints or why. Main thread only.
NS_SWIFT_UI_ACTOR @protocol W7TitlebarBandPainter <NSObject>
/// Called by the title bar's glass view after the glass (W7DrawGlassFrame) and before the icon and title,
/// with `ctx` in `view`'s coordinates (non-flipped, the title bar's bounds, which include the toolbar and
/// the titlebar accessories). Exceptions are caught and logged by the caller.
- (void)w7DrawBandsInTitlebarView:(NSView *)view window:(NSWindow *)window context:(CGContextRef)ctx
    NS_SWIFT_NAME(w7DrawBands(inTitlebarView:window:context:));
@end
/// the window's Aero title bar asks a small ordered list of painters on every glass draw (the toolbar band,
/// Safari's rows, later the Messenger band), each under its own identifier, in the order they were first set; each
/// painter draws in its own saved graphics state, and an exception in one does not stop the others. At most 8.
/// Sets (retained, per window; a new identifier goes last, a known one keeps its place) or, with nil, removes the
/// painter for `identifier`, and redraws the glass. Other identifiers are never touched.
FOUNDATION_EXPORT void W7SetTitlebarBandPainterForIdentifier(NSWindow *window, NSString *identifier,
                                                             id<W7TitlebarBandPainter> _Nullable painter) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT id<W7TitlebarBandPainter> _Nullable W7TitlebarBandPainterForIdentifier(NSWindow *window, NSString *identifier) NS_SWIFT_UI_ACTOR;
/// The identifiers of the window's painters, in drawing order.
FOUNDATION_EXPORT NSArray<NSString *> *W7TitlebarBandPainterIdentifiers(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// The identifier W7SetTitlebarBandPainter and W7TitlebarBandPainterForWindow use (Safari's band).
FOUNDATION_EXPORT NSString *const W7TitlebarBandPainterDefaultIdentifier;
/// W7SetTitlebarBandPainterForIdentifier / W7TitlebarBandPainterForIdentifier with W7TitlebarBandPainterDefaultIdentifier.
FOUNDATION_EXPORT void W7SetTitlebarBandPainter(NSWindow *window, id<W7TitlebarBandPainter> _Nullable painter) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT id<W7TitlebarBandPainter> _Nullable W7TitlebarBandPainterForWindow(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Marks a decorated window's title bar glass for redrawing (the bands moved); nothing for other windows.
FOUNDATION_EXPORT void W7TitlebarBandsNeedDisplay(NSWindow *window) NS_SWIFT_UI_ACTOR;

/// What the L0 gate knows about a Safari window (C `bool` fields, so Swift sees Bool). A `…Known` flag says the value was read through a method
/// whose type encoding matched; an unknown value never counts.
typedef struct {
    bool disabled;                      // W7SafariChromeDisabled
    bool isBrowserWindowClass;          // the window's class is exactly BrowserWindow
    bool decorated;                     // it has the Aero title bar
    bool controllerFound;               // +[BrowserWindowController browserWindowControllerForWindow:]
    bool isPrivateKnown, isPrivate;     // -isPrivate (B16@0:8)
    bool browsingModeKnown;             // -browsingMode (Q16@0:8); 0 normal, 1 private
    unsigned long long browsingMode;
    bool popupKnown, isPopup;           // -isPopupWindow (B16@0:8)
    bool fullScreen;
    bool standaloneKnown, showsStandaloneTabBar;   // -showsStandaloneUnifiedTabBar (B16@0:8)
    bool toolbarIdentifierStandalone;   // W7SafariToolbarIdentifierIsStandalone, used when the method is unknown
} W7SafariGateInputs;
/// L0: theme only a plain, decorated BrowserWindow (not disabled, not a popup, not full screen) with its
/// controller, in Safari's Separate tab layout (showsStandaloneUnifiedTabBar, or the toolbar identifier when
/// that is unknown), and provably not private: at least one of isPrivate/browsingMode known, and every known
/// one says normal (isPrivate NO, browsingMode 0). Anything unknown fails closed.
FOUNDATION_EXPORT BOOL W7SafariShouldTheme(W7SafariGateInputs inputs);
/// YES when `identifier` contains "StandaloneTabBar" (BrowserStandaloneTabBarToolbarIdentifier-v4).
FOUNDATION_EXPORT BOOL W7SafariToolbarIdentifierIsStandalone(NSString *_Nullable identifier);
/// Safari only (`com.apple.Safari`), and not with `defaults write -g W7SafariChromeDisabled -bool YES`.
FOUNDATION_EXPORT BOOL W7SafariChromeShouldStart(NSString *_Nullable bundleID, BOOL disabled);
/// Classes that are never touched, walked into or restyled: the address field and its parts (UnifiedField*,
/// InteriorUnifiedField, _UnifiedFieldImageOffsetCell, PopupWindowUnifiedFieldViewController), completion
/// and AutoFill lists, AuthenticationPanel, ToolbarDownloads*, PrivacyReport*, LockdownMode* and web extension
/// items. A KVO subclass (NSKVONotifying_…) is judged by the class it observes. YES for nil.
FOUNDATION_EXPORT BOOL W7SafariIsExcludedClassName(NSString *_Nullable className);

/// A tab's IE7 look: the active tab is selected; hovered or multi-selected tabs are hover; pinned tabs and
/// Safari's layout `state` keep the same colours (pinned tabs are only narrower).
FOUNDATION_EXPORT W7IETabState W7SafariTabState(BOOL active, BOOL selected, BOOL highlighted, BOOL pinned, NSInteger state);
/// The status bar text: the status message, else its URL, else "Done" when not loading ("" while loading).
FOUNDATION_EXPORT NSString *W7SafariStatusText(NSString *_Nullable message, NSString *_Nullable url, BOOL loading);
/// Safari's loading status (BrowserViewController -loadingStatus): 0 is complete, anything else loading.
FOUNDATION_EXPORT BOOL W7SafariLoadingStatusIsLoading(int status);
/// The progress bar's fraction: `estimated` clamped to 0…1 (NaN → 0) while loading, -1 (hidden) otherwise.
FOUNDATION_EXPORT CGFloat W7SafariProgressFraction(double estimated, BOOL loading);

/// The band rows in the title bar's coordinates (non-flipped): the tab row is the tab bar's frame, the
/// favourites row everything between the tab bar's top and the toolbar's bottom (under the toolbar when
/// there is no tab bar); both `sideInset` in from the sides (the glass frame lines). CGRectZero for a row
/// that is not there; both zero without a toolbar or when the tab bar is not below it.
typedef struct { CGRect tabRow; CGRect favoritesRow; } W7SafariBandLayout;
FOUNDATION_EXPORT W7SafariBandLayout W7SafariBandLayoutFor(CGRect bounds, CGRect toolbarFrame, CGRect tabBarFrame, CGFloat sideInset);

/// Diagnostics pacing: a throttled line may be logged at `now` when nothing was logged yet (`last` < 0) or at
/// least `interval` seconds have passed.
FOUNDATION_EXPORT BOOL W7SafariThrottleAllows(double now, double last, double interval);
/// Hook b's tab bar line: at most once a second (W7SafariThrottleAllows) and at most 10 lines per window.
FOUNDATION_EXPORT BOOL W7SafariTabBarLogAllows(NSInteger linesSoFar, double now, double last);
/// The once-per-window diagnostics run again (at most 3 runs per window in all) when the number of titlebar
/// accessories changed or a UnifiedTabBar laid out for the first time in the window.
FOUNDATION_EXPORT BOOL W7SafariShouldRerunDiagnostics(NSInteger runsSoFar, BOOL accessoriesChanged, BOOL firstTabBarLayout);

/// Whether the window is themed (the flag the hooks read; the gate sets it). Setting it alone applies or
/// removes nothing else (tests use it to stand in for a themed window).
FOUNDATION_EXPORT BOOL W7SafariWindowIsThemed(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT void W7SafariSetWindowThemed(NSWindow *window, BOOL themed) NS_SWIFT_UI_ACTOR;

/// L3: the IE7 status bar (22 pt) at the bottom of the window's content view: the status text at the left,
/// a 100 pt progress trough at the right while loading. Never a zone, lock or security indicator. Clicks
/// stop at it (they never reach the page under it).
@interface W7StatusBarView : NSView
/// What is shown (W7SafariStatusText of the last message and the loading state).
@property (nonatomic, readonly, copy) NSString *text;
/// The progress bar's fraction, or < 0 when it is hidden.
@property (nonatomic, readonly) CGFloat progress;
/// Safari's status message (its string and URL, either may be nil).
- (void)w7SetMessage:(nullable NSString *)message url:(nullable NSString *)url;
/// Safari's loading state and estimated progress.
- (void)w7SetLoading:(BOOL)loading progress:(double)estimated;
@end
/// Adds the status bar (once) and adds 22 to the content view's additionalSafeAreaInsets.bottom (Safari
/// passes it on to the web view's obscured insets). Returns it; nil without a content view.
FOUNDATION_EXPORT W7StatusBarView *_Nullable W7SafariInstallStatusBar(NSWindow *window) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT W7StatusBarView *_Nullable W7SafariStatusBarForWindow(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
/// Removes the status bar and gives the inset back.
FOUNDATION_EXPORT void W7SafariRemoveStatusBar(NSWindow *window) NS_SWIFT_UI_ACTOR;

/// The IE7 orb image for a back/forward segment: 28 pt (back) or 24 pt (forward), with 1x and 2x bitmap
/// representations, not a template; created once.
FOUNDATION_EXPORT NSImage *W7SafariOrbImage(BOOL forward) NS_SWIFT_UI_ACTOR;
/// Puts the orb images into a back/forward segmented control (segment 0 back, 1 forward), keeping Safari's
/// images to put back; menus and tooltips are left alone.
FOUNDATION_EXPORT void W7SafariApplyBackForward(NSSegmentedControl *control) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT void W7SafariRestoreBackForward(NSSegmentedControl *control) NS_SWIFT_UI_ACTOR;
/// Un-theming: shows what the tab bar hook hid (backdrops) and lets Safari decide every separator again (its
/// -_updateSeparatorVisibilityForTabBarItem:isHighlighted: per item, the highlighted item as such; alpha 1 when
/// that method is not there with v28@0:8@16B24), then asks for a layout.
FOUNDATION_EXPORT void W7SafariRestoreTabBar(NSView *tabBar) NS_SWIFT_UI_ACTOR;
/// Un-theming: takes the tab button's facsimile off and lets
/// Safari settle its own background views (-updateBackgroundAppearance) once the window is no longer themed.
FOUNDATION_EXPORT void W7SafariRestoreTabButton(NSView *button) NS_SWIFT_UI_ACTOR;

/// L2 geometry: the rects of a segmented control's segments in `bounds`, from `widths` (its widthForSegment:
/// values): fixed widths (> 0) from the left, autosized ones (0) sharing what is left equally (all autosized:
/// bounds.width / count).
FOUNDATION_EXPORT NSArray<NSValue *> *W7SafariSegmentRects(CGRect bounds, NSArray<NSNumber *> *widths);
/// The overlay's orbs for `control`: the back orb (at most 28 pt) centred in segment 0 and the forward orb (at
/// most 24 pt) centred in segment 1, each square and no larger than its segment; CGRectZero for a missing one.
FOUNDATION_EXPORT void W7SafariOverlayOrbRects(NSSegmentedControl *control, CGRect *_Nullable back, CGRect *_Nullable forward) NS_SWIFT_UI_ACTOR;

// L4 hooks. Each checks the exact type encoding of `cls`'s OWN method first (an inherited one, or a changed
// encoding, leaves Safari's own code), calls the original first and acts only for themed windows, inside
// @try; for a view whose window is no longer themed (full screen, a torn-off tab) it takes its look off again.
// Idempotent per class. NO when nothing was hooked. Implemented in W7SafariHooks.m.
/// a. -_needsUncoloredTitlebar (B16@0:8) answers YES and -backgroundColorInTabBarEnabled (B16@0:8) NO for a
/// themed window's controller (no website tint over the bands). Either alone may be hooked.
FOUNDATION_EXPORT BOOL W7SafariHookWindowControllerColors(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// b. UnifiedTabBar -layout (v16@0:8): sets every separator's -setSeparatorAlphaValue: (v24@0:8d16) to 0 and hides
/// _backdropView / _pinnedTabRegionBackdropView, so the band shows through, except a backdrop that is capture-only
/// (-captureOnly B16@0:8) or grouped (-groupName @16@0:8), the source the glass tabs sample, or that holds
/// _tabContainer / _scrollView: those stay visible (marked, so later passes stop at the mark). Also after
/// -_updateSeparatorVisibilityForTabBarItem:isHighlighted: (v28@0:8@16B24) when that matches. Each pass also
/// reports the tab bar's frame to the window side, which re-runs the gate when it changed (Separate ↔ Compact).
FOUNDATION_EXPORT BOOL W7SafariHookTabBar(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// c. UnifiedTabBarButton -updateBackgroundAppearance and -layout (both v16@0:8, both or neither; also -setActive:
/// v20@0:8B16 and -viewDidMoveToWindow v16@0:8 when they match): for a visible button without a _unifiedField whose
/// _contentView is inside it, in a themed window with the facsimile on: _contentGlassView, _backgroundView,
/// _visualEffectBackground, _visualEffectBackgroundHighlight and _contentView at alpha 0 (saved first; never hidden,
/// so the button keeps every click) and the IE8 facsimile view as its topmost subview (W7DrawIETabFacsimile of its
/// state, title, favicon and close button), and Safari's _closeButton moved to the tab's right end (
/// W7SafariCloseButtonFrameFor; its frame put back on unstyle). Otherwise the button is Safari's own again. The title
/// and icon are only read, for drawing.
FOUNDATION_EXPORT BOOL W7SafariHookTabButton(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// d. ToolbarController -_prepareBackForwardSegmentedControl: (v24@0:8@16): W7SafariApplyBackForward for a
/// control in a themed window, W7SafariRestoreBackForward otherwise (decided once the control is in a window,
/// on the next run-loop pass, when it is not yet).
FOUNDATION_EXPORT BOOL W7SafariHookBackForward(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// e. BrowserWindowController -_setStatusMessage: (v24@0:8@16; the message's -string and -url) and
/// -loadingStatusDidChangeInBrowserViewController: / -updateFluidProgressForBrowserViewController:
/// (v24@0:8@16; -currentTabLoadingStatus i16@0:8, -currentBrowserViewController @16@0:8 -estimatedProgress
/// d16@0:8) feed the window's W7StatusBarView. Each optional; YES when any is hooked.
FOUNDATION_EXPORT BOOL W7SafariHookStatus(Class _Nullable cls) NS_SWIFT_UI_ACTOR;

/// Once per process, in Safari only (W7SafariChromeShouldStart): installs the L4 hooks unless
/// `defaults write -g W7SafariHooksDisabled -bool YES`, then themes or un-themes each window (L0 gate) as it
/// becomes key or main or enters/leaves full screen. Called from +[W7ChromeController start].
FOUNDATION_EXPORT void W7SafariChromeStart(void) NS_SWIFT_UI_ACTOR;
/// For tests: marks the chrome started without the bundle check or the window observers, and installs the L4
/// hooks on the classes registered under Safari's names when `installHooks` (once per process). Windows are
/// then themed only through W7SafariUpdateWindow.
FOUNDATION_EXPORT void W7SafariChromeStartForTesting(BOOL installHooks) NS_SWIFT_UI_ACTOR;
/// Re-runs the L0 gate for one window and applies (L1 bands, L2 orbs or hook d's images, L3 status bar) or
/// removes the theme to match.
FOUNDATION_EXPORT void W7SafariUpdateWindow(NSWindow *window) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - Aero frame borders and Windows 7 message boxes

NS_ASSUME_NONNULL_BEGIN

/// The overlay's frame for a window frame (AppKit coordinates): W7FrameBorderWidth more on the left, right
/// and bottom, none on top (the caption is the window's own).
FOUNDATION_EXPORT CGRect W7FrameBorderOverlayFrame(CGRect windowFrame);
/// The window inside an overlay of `overlayBounds` (overlay coordinates); empty when it does not fit.
FOUNDATION_EXPORT CGRect W7FrameBorderHoleRect(CGRect overlayBounds);
/// Whether the overlay shows the full frame (W7FrameBorderModeFramed): only for a visible window that is not
/// minimized, full screen (or entering it), occluded or maximized (W7MaximizedFrame: Windows 7 draws no side
/// frame on a maximized window; its overlay shows only the top wedges, W7FrameBorderModeMaximized).
/// Kept for its tests; the overlay itself uses W7FrameBorderModeFor.
FOUNDATION_EXPORT BOOL W7FrameBorderShouldShow(BOOL parentVisible, BOOL miniaturized, BOOL fullScreen,
                                               BOOL occluded, BOOL maximized);
/// `defaults write -g W7FrameBorderDisabled -bool YES` (or an app's own domain): no frame overlays. Read once
/// per process, unless overridden.
FOUNDATION_EXPORT BOOL W7FrameBorderDisabled(void);
/// Test seam: 1 disables, 0 enables, -1 goes back to the defaults value.
FOUNDATION_EXPORT void W7FrameBorderUseDisabledOverride(NSInteger value);
/// Test seam: 1 treats every window as visible and not occluded, 0 as hidden, -1 reads the window's state.
FOUNDATION_EXPORT void W7FrameBorderUseVisibilityOverride(NSInteger value);
/// The window's corner radius at the top (`top`) or bottom (W7FrameCorners.m): its top-left / bottom-left radius
/// from AppKit's private -_cornerRadii (an NSViewCornerRadii), else -_topCornerRadius / -_bottomCornerRadius,
/// each only when it exists with the expected type, else 16 (macOS 27's default).
FOUNDATION_EXPORT CGFloat W7WindowCornerRadius(NSWindow *window, BOOL top) NS_SWIFT_UI_ACTOR;

// Window corners. Two paths, decided per window and logged once
// ("frame corners: radius path …" / "frame corners: wedge path …"):
// - radius: the window itself gets Windows 7 corners (6 pt top, square bottom) through -[NSWindow
//   _setCornerRadii:], checked by reading the radii back at once and again after one run-loop turn; restored
//   to AppKit's default while the window is closed or full screen;
// - wedges: the window keeps AppKit's radius and the overlay paints over its corners (W7CreateFrameCoverPath).
// Either way the overlay paints the window's outer 1 pt and whatever corner wedge the window's radius leaves.

/// `defaults write -g W7CornerRadiusHookDisabled -bool YES` (or an app's own domain): never set window radii, the
/// wedges only. Read once per process, unless overridden.
FOUNDATION_EXPORT BOOL W7CornerRadiusHookDisabled(void);
/// Test seam: 1 disables, 0 enables, -1 goes back to the defaults value.
FOUNDATION_EXPORT void W7CornerRadiusUseDisabledOverride(NSInteger value);
/// Whether NSWindow -_cornerRadii / -_setCornerRadii: and NSViewCornerRadii's radius accessors exist with the
/// type encodings this code was written against (checked once per process).
FOUNDATION_EXPORT BOOL W7CornerRadiusSetterAvailable(void);
/// Sets the window's top corners to `top` and bottom corners to `bottom`; YES when reading them back gives
/// those values. NO, touching nothing, when disabled or unavailable.
FOUNDATION_EXPORT BOOL W7SetWindowCornerRadii(NSWindow *window, CGFloat top, CGFloat bottom) NS_SWIFT_UI_ACTOR;
/// Whether the window's radii read back as `top` / `bottom` (NO when they can't be read).
FOUNDATION_EXPORT BOOL W7WindowCornerRadiiAre(NSWindow *window, CGFloat top, CGFloat bottom) NS_SWIFT_UI_ACTOR;
/// Gives the window AppKit's default radii back (-_setCornerRadii: nil).
FOUNDATION_EXPORT void W7RestoreWindowCornerRadii(NSWindow *window) NS_SWIFT_UI_ACTOR;

/// What a window's overlay shows: nothing; the 8 pt frame with the window's edge and corner wedges;
/// or, for a maximized window (W7MaximizedFrame), only the top wedges and the top edge (Windows 7 draws no side
/// frame there). The overlay's frame is W7FrameBorderOverlayFrame in both cases, which is what the shell's
/// window lists recognise it by.
typedef NS_ENUM(NSInteger, W7FrameBorderMode) {
    W7FrameBorderModeHidden,
    W7FrameBorderModeFramed,
    W7FrameBorderModeMaximized,
};
/// Hidden unless the window is visible, not minimized, not full screen (or entering it) and not occluded;
/// then maximized or framed.
FOUNDATION_EXPORT W7FrameBorderMode W7FrameBorderModeFor(BOOL parentVisible, BOOL miniaturized, BOOL fullScreen,
                                                         BOOL occluded, BOOL maximized);
typedef NS_ENUM(NSInteger, W7FrameCornerPath) {
    W7FrameCornerPathUndecided,   // no overlay, or not decided yet
    W7FrameCornerPathWedges,
    W7FrameCornerPathRadius,
};
/// The corner path of the window's overlay.
FOUNDATION_EXPORT W7FrameCornerPath W7FrameBorderCornerPath(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Gives a decorated window its frame overlay (idempotent; nothing when disabled): a borderless child window
/// that ignores the mouse, follows the window's frame, level, key state and visibility (W7FrameBorderModeFor)
/// and draws W7DrawFrameBorder, or W7DrawMaximizedFrameCorners while the window is maximized; it also runs the
/// window's corner path. The window owns it; closing the window releases it. W7TitlebarView calls it when
/// it moves into a window's title bar. Returns whether the window has an overlay afterwards.
FOUNDATION_EXPORT BOOL W7FrameBorderAttach(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// The window's overlay, or nil.
FOUNDATION_EXPORT NSWindow *_Nullable W7FrameBorderOverlay(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// YES while the window's overlay is shown, framed or maximized (the caption then draws W7DrawCaptionGlassSlice:
/// square, opaque, no side lines).
FOUNDATION_EXPORT BOOL W7FrameBorderIsShowing(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Overlays alive in the process (tests check that closing a window releases its overlay).
FOUNDATION_EXPORT NSInteger W7FrameBorderLiveOverlayCount(void) NS_SWIFT_UI_ACTOR;

@interface W7TitlebarView (W7FrameBorder)
/// Height of the caption glass from the window's top: the title bar's, or an Explorer window's glass down
/// through its navigation bar (W7ExplorerGlassRect). The frame overlay's side glass matches it row for row.
@property (nonatomic, readonly) CGFloat w7GlassHeight;
@end

/// The message box geometry in the alert's content view: the top of the button strip and the caption height.
typedef struct { CGFloat stripTop, captionHeight; } W7MessageBoxLayout;
/// Top of the button strip: the buttons' top plus half the gap to the content above (at most 16, none when
/// that content overlaps); 0 without buttons (a null rect). `contentAboveMinY` CGFLOAT_MAX when nothing is above.
FOUNDATION_EXPORT CGFloat W7MessageBoxStripTop(CGRect buttons, CGFloat contentAboveMinY);
/// The caption band along the top: the free margin above the content less 2, at most 30, none under 16.
FOUNDATION_EXPORT CGFloat W7MessageBoxCaptionHeight(CGFloat contentHeight, CGFloat topmostContentMaxY);
/// An alert window is restyled only when it is a panel, owned by an NSAlert (its delegate, whose window it is),
/// with the alert's buttons in its content view, in light appearance and not disabled.
FOUNDATION_EXPORT BOOL W7ShouldStyleMessageBox(BOOL isPanel, BOOL ownedByAlert, BOOL buttonsInContent, BOOL dark,
                                               BOOL disabled);
/// `defaults write -g W7MessageBoxDisabled -bool YES` (or an app's own domain). Read once per process.
FOUNDATION_EXPORT BOOL W7MessageBoxDisabled(void);
/// Test seam: 1 disables, 0 enables, -1 goes back to the defaults value.
FOUNDATION_EXPORT void W7MessageBoxUseDisabledOverride(NSInteger value);
/// Puts a Windows 7 message box backdrop (W7DrawMessageBoxBackground: white, the grey button strip, the caption
/// glass with the title, W7CaptionTitle of the window title and the app name) under an NSAlert window's own views,
/// once. YES when it did so now. The backdrop draws nothing while the window's appearance is dark.
FOUNDATION_EXPORT BOOL W7StyleMessageBoxIfNeeded(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// The current strip top and caption height of a styled (or stylable) alert window; zeros otherwise.
FOUNDATION_EXPORT W7MessageBoxLayout W7MessageBoxGeometry(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Once per process: restyles alert windows as they become key (W7StyleMessageBoxIfNeeded). Called from
/// +[W7ChromeController start].
FOUNDATION_EXPORT void W7InstallMessageBoxes(void) NS_SWIFT_UI_ACTOR;

// MARK: - Explorer navigation pane tree

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN

/// The asset root W7FolderIconImage reads its overrides from: W7FolderIconUseAssetRoot's, else
/// ~/Library/Application Support/Win7Mac/Assets (W7ExplorerFolderIcons.m; the navigation pane shares it).
FOUNDATION_EXPORT NSString *W7FolderIconAssetRootPath(void);

FOUNDATION_EXPORT const CGFloat W7NavPaneIconSize;      // 16: every row icon
FOUNDATION_EXPORT const CGFloat W7NavPaneIconGap;       // 4: icon to text
FOUNDATION_EXPORT const CGFloat W7NavPaneChildIndent;   // 12: extra indent of a group's children

/// The Windows 7 icon of a sidebar row, by its target, as a name: "user" (home), a folder kind's
/// W7FolderIconAssetName ("folder-desktop", "folder-documents", "folder-downloads", "folder-pictures",
/// "folder-music", "folder-videos"), "applications" (/Applications, /System/Applications), "drive-system"
/// (`/`), "drive" (any other volume), "network", "computer", "recycle-bin" (the Trash; W7NavPaneIconImage
/// picks empty or full), "recent-places" (Recents: a class containing RecentDocuments, or Finder's
/// MyLibraries/myDocuments.cannedSearch) and "shared" (Shared: Finder's
/// MyLibraries/Shared{Documents,WithMe,ByMe}.cannedSearch; no node class names it). nil keeps Finder's icon: AirDrop, iCloud, file
/// providers, tags and every other target. `nodeClassName` is the FINode subclass (FIDSNode_Trash,
/// FIDSNode_NetworkSidebar, FIDSNode_Computer, …), which decides first; then `path` (special folders compared
/// standardized).
FOUNDATION_EXPORT NSString *_Nullable W7NavPaneIconNameForTarget(NSString *_Nullable nodeClassName, NSString *_Nullable path,
                                                                 BOOL isVolume,
                                                                 NSDictionary<NSString *, NSNumber *> *specialPaths);
/// Fallback when a row's target can't be read: its title looked up in `titleNames` (title → icon name),
/// ignoring case and diacritics. nil when unknown.
FOUNDATION_EXPORT NSString *_Nullable W7NavPaneIconNameForTitle(NSString *_Nullable title,
                                                                NSDictionary<NSString *, NSString *> *titleNames);
/// Titles for W7NavPaneIconNameForTitle: the display names of `specialPaths` (home → "user") and of
/// /Applications as this process localizes them, plus English and Turkish names of the Trash, Network,
/// Applications, Macintosh HD, Recents and Shared. File I/O (display names).
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *W7NavPaneTitleIconNames(NSDictionary<NSString *, NSNumber *> *specialPaths);

/// The Windows 7 tree node a sidebar section header stands for.
typedef NS_ENUM(NSInteger, W7NavPaneGroupKind) {
    W7NavPaneGroupUnknown NS_SWIFT_NAME(unknown),       // no icon
    W7NavPaneGroupFavorites NS_SWIFT_NAME(favorites),   // the yellow star
    W7NavPaneGroupLocations NS_SWIFT_NAME(locations),   // the computer
    W7NavPaneGroupTags NS_SWIFT_NAME(tags),             // a tag
    W7NavPaneGroupCloud NS_SWIFT_NAME(cloud),           // a cloud
};
/// By the header's title (English or Turkish: Favorites/Favoriler, Locations/Konumlar, Tags/Etiketler,
/// iCloud), else by the icon names of its visible children: a drive, network or computer means
/// Locations, a user or special folder Favorites.
FOUNDATION_EXPORT W7NavPaneGroupKind W7NavPaneGroupKindFor(NSString *_Nullable title, NSArray<NSString *> *childIconNames);

/// A child row's cell frame indented by `indent` (its width shrinks by as much, never below 0).
FOUNDATION_EXPORT NSRect W7NavPaneIndentedCellFrame(NSRect frame, CGFloat indent);
/// Finder's text frame moved to start `gap` after an `iconSide` icon centred in `imageFrame`, its right
/// edge kept; unchanged when that moves it by more than W7NavPaneChildIndent (another coordinate space)
/// or the image frame is empty.
FOUNDATION_EXPORT NSRect W7NavPaneTextFrame(NSRect textFrame, NSRect imageFrame, CGFloat iconSide, CGFloat gap);

/// The icon for a W7NavPaneIconNameForTarget name, `points` square with 1x and 2x representations:
/// the user's icon through W7UserIconBitmap (`<asset root>/icons/<name>.png`, else the embedded PNG), else the
/// drawn fallback — W7FolderIconImage for "user" (after user.png) and the folder kinds, the plain folder
/// with an application badge for "applications", W7DrawNavPaneGlyph for the drives, network and computer.
/// "recycle-bin" has no drawn fallback (recycle-bin-full.png when the Trash holds anything, else
/// recycle-bin-empty.png). Cached per name, size, scale and W7UserIconsGeneration. nil when there is nothing to show.
FOUNDATION_EXPORT NSImage *_Nullable W7NavPaneIconImage(NSString *name, CGFloat points);
/// The section header icon for `kind` (`points` square): the star (favorites.png first, else drawn), the
/// computer (computer.png first), the tag or the cloud; nil for Unknown.
FOUNDATION_EXPORT NSImage *_Nullable W7NavPaneGroupIconImage(W7NavPaneGroupKind kind, CGFloat points);
/// Whether the Trash at `trashPath` holds anything (an entry other than .DS_Store); NO when unreadable.
FOUNDATION_EXPORT BOOL W7NavPaneTrashIsFull(NSString *trashPath);
/// The Trash W7NavPaneIconImage looks at: `path` (tests), or nil for ~/.Trash. W7NavPaneIconImage
/// reads it at most once per 1.5 s; this call drops the remembered answer.
FOUNDATION_EXPORT void W7NavPaneUseTrashDirectory(NSString *_Nullable path);
/// A volume's mount point, judged without file I/O: `/` or `/Volumes/<name>`.
FOUNDATION_EXPORT BOOL W7NavPanePathIsMountPoint(NSString *_Nullable path);
/// Node classes whose sidebar icon Finder keeps: AirDrop, iCloud and cloud libraries, file providers, tags
/// (Recents maps to recent-places since Finder's icon staying only while recent-places.png is absent).
FOUNDATION_EXPORT BOOL W7NavPaneNodeClassKeepsFinderIcon(NSString *_Nullable nodeClassName);

/// `defaults write com.apple.finder W7ExplorerNavPaneDisabled -bool YES` (or -g): no tree look
/// (the navigation pane stays). Read once per process.
FOUNDATION_EXPORT BOOL W7NavPaneTreeDisabled(void);
/// Tests: YES/NO in place of the W7ExplorerNavPaneDisabled default; nil reads the default again.
FOUNDATION_EXPORT void W7NavPaneUseTreeDisabled(NSNumber *_Nullable disabled);
/// `defaults write com.apple.finder W7ExplorerNavPaneDiagnostics -bool YES` (or -g): the sidebar dump at
/// adoption and after 2 s, and the first calls of each hook and node lookup. Off by default. Read once.
FOUNDATION_EXPORT BOOL W7NavPaneDiagnosticsEnabled(void);
/// Tests: YES/NO in place of the W7ExplorerNavPaneDiagnostics default; nil reads the default again.
FOUNDATION_EXPORT void W7NavPaneUseDiagnosticsEnabled(NSNumber *_Nullable enabled);
/// Counts one diagnostics line written (every diagnostics log site calls it); the total, for tests.
FOUNDATION_EXPORT void W7NavPaneNoteDiagnosticLine(void);
FOUNDATION_EXPORT NSUInteger W7NavPaneDiagnosticLineCount(void);
/// Tests: the clock the Trash fullness TTL reads (monotonic seconds); nil for CLOCK_UPTIME_RAW.
FOUNDATION_EXPORT void W7NavPaneUseClock(double (^_Nullable clock)(void));
/// How often the Trash directory's vnode source fired (each forgets the fullness and gives every
/// Recycle Bin row its current icon).
FOUNDATION_EXPORT NSUInteger W7NavPaneTrashWatchFireCount(void);
/// Re-runs the navigation pane styler of an adopted Explorer window now (its 10 Hz refresh: rows
/// changed → restyle, then the icon keeper). For tests, whose main-queue timers cannot run.
FOUNDATION_EXPORT void W7NavPaneRefreshStylerForWindow(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
/// The tree look applies to `view`: not disabled and its window (else the app) not in a dark appearance.
FOUNDATION_EXPORT BOOL W7NavPaneTreeActive(NSView *_Nullable view) NS_SWIFT_UI_ACTOR;
/// Finder only, and not disabled.
FOUNDATION_EXPORT BOOL W7NavPaneHooksShouldInstall(NSString *_Nullable bundleID, BOOL disabled);
/// Hooks Finder's sidebar cell class (TSidebarItemCell, an NSTableCellView) after checking each
/// encoding exactly: -image (`@16@0:8`) answers the Windows 7 icon of the cell's target, -imageSize
/// (`d16@0:8`) W7NavPaneIconSize, -_textFieldFrame (`{CGRect=…}16@0:8`) W7NavPaneTextFrame, and an
/// added -setFrame: indents the cell by W7NavPaneChildIndent when AppKit puts it at its outline cell
/// frame (so it never indents twice); an added -viewDidMoveToWindow re-sets the frame, because AppKit
/// sets it before the cell is in its row. The target comes from the cell's `_node` ivar (exactly
/// `{TFENode="fNodeRef"^{OpaqueNodeRef}}`) through `+[nodeClass nodeFromNodeRef:]`; without it, from the
/// cell's title. Each replacement runs inside @try, falls back to Finder's value, and does nothing while
/// W7NavPaneTreeActive is NO. Idempotent; logs once per class. YES when -image was hooked.
FOUNDATION_EXPORT BOOL W7NavPaneHookCellClass(Class _Nullable cellClass, Class _Nullable nodeClass) NS_SWIFT_UI_ACTOR;
/// The icon name the hook maps `cell` to (cached per cell until its node or title changes), or nil.
/// From the node: its class and file URL, else its -original's (sidebar entries can be alias nodes);
/// when neither names an icon (and the class is not one Finder keeps), from the cell's title.
FOUNDATION_EXPORT NSString *_Nullable W7NavPaneCellIconName(NSView *cell) NS_SWIFT_UI_ACTOR;
/// The icon name for any sidebar row: W7NavPaneCellIconName for a hooked cell, else `title` mapped by
/// W7NavPaneIconNameForTitle (the styler's fallback when Finder's cells are not the hooked class).
FOUNDATION_EXPORT NSString *_Nullable W7NavPaneRowIconName(NSView *_Nullable cell, NSString *_Nullable title) NS_SWIFT_UI_ACTOR;
/// Keeps one row's image view in step with the tree look. Active (W7NavPaneTreeActive): the row's
/// Windows 7 icon (W7NavPaneRowIconName) replaces what it shows, Finder's image and tint remembered.
/// Inactive, or no icon for the row any more: an image view showing one of our icons gets Finder's back
/// — the cell's own -updateNameAndIcon (exactly `v16@0:8`) when it has one, else the remembered image
/// and tint. YES when the image view changed.
FOUNDATION_EXPORT BOOL W7NavPaneSyncRowIcon(NSImageView *imageView, NSView *_Nullable cell, NSString *_Nullable title) NS_SWIFT_UI_ACTOR;
/// Whether `cell` is of a class W7NavPaneHookCellClass hooked (its -image hook keeps its icon).
FOUNDATION_EXPORT BOOL W7NavPaneCellIsHooked(NSView *_Nullable cell) NS_SWIFT_UI_ACTOR;
/// The styler's periodic pass over the visible rows of `outline`: W7NavPaneSyncRowIcon on each row whose
/// cell is not hooked. Nothing while the tree look is off (kill switch, dark appearance); undoing our
/// icons then is the job of the row restyle the change triggers. Returns how many rows it checked.
FOUNDATION_EXPORT NSUInteger W7NavPaneKeepRowIcons(NSOutlineView *_Nullable outline) NS_SWIFT_UI_ACTOR;
/// Whether `image` is one W7NavPaneIconImage / W7NavPaneGroupIconImage made.
FOUNDATION_EXPORT BOOL W7NavPaneImageIsOurs(NSImage *_Nullable image);
/// Re-applies the hooked look to a cell (one Finder made before the hooks were installed, or after a
/// light/dark switch): W7NavPaneSyncRowIcon on its image view, and its indent. No-op for other cells.
FOUNDATION_EXPORT void W7NavPaneRefreshCell(NSView *cell) NS_SWIFT_UI_ACTOR;

/// The hooked methods, for the call counts the diagnostics log.
typedef NS_ENUM(NSInteger, W7NavPaneHookKind) {
    W7NavPaneHookImage NS_SWIFT_NAME(image),
    W7NavPaneHookImageSize NS_SWIFT_NAME(imageSize),
    W7NavPaneHookTextFrame NS_SWIFT_NAME(textFrame),
    W7NavPaneHookSetFrame NS_SWIFT_NAME(setFrame),
    W7NavPaneHookMovedToWindow NS_SWIFT_NAME(movedToWindow),
    W7NavPaneHookKindCount NS_SWIFT_NAME(count)
};
/// How often a hook ran (the first three calls of each are logged with the receiver and the mapping).
FOUNDATION_EXPORT NSUInteger W7NavPaneHookCallCount(W7NavPaneHookKind kind);
/// "-image N, -imageSize N, …" for the diagnostics log.
FOUNDATION_EXPORT NSString *W7NavPaneHookCallSummary(void);
/// Once per process, when W7NavPaneHooksShouldInstall: hooks TSidebarItemCell (it must be in Finder's
/// image) with FINode. Logged.
FOUNDATION_EXPORT void W7ExplorerInstallNavPaneHooks(void) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - Dialog panels

NS_ASSUME_NONNULL_BEGIN

/// W7ShouldDecorateWindow with dialog panels: a panel is decorated only when `isDialogPanel` (W7IsDialogPanel),
/// and then even with a transparent title bar (the standard About panel has one), as long as its content is not
/// full size. Sheets, untitled, full-size-content and full-screen windows never are.
FOUNDATION_EXPORT BOOL W7ShouldDecorateWindowOrDialog(NSWindowStyleMask mask, BOOL isPanel, BOOL isDialogPanel,
                                                      BOOL titlebarTransparent, BOOL isSheet);
/// AppKit's own panels, left native: NSColorPanel, NSFontPanel, NSSavePanel, NSOpenPanel, NSRemote/NSLocal
/// Save/OpenPanel, NSPrintPanel…, NSPageLayout…, NSSharingServicePicker…, NSAlertPanel,
/// NSSpellingPanel (as prefixes, leading underscores ignored).
FOUNDATION_EXPORT BOOL W7IsSystemPanelClassName(NSString *_Nullable className);
/// A dialog-like panel (About, Preferences, Get Info): titled and closable, not a utility, HUD, non-activating
/// or document-modal panel, at the normal level, not floating, not a sheet, not an NSAlert's window, and no
/// class in `classChain` (the window's class and its superclasses below NSWindow) a system panel.
FOUNDATION_EXPORT BOOL W7IsDialogPanel(NSWindowStyleMask mask, NSInteger level, BOOL isFloatingPanel, BOOL isSheet,
                                       BOOL ownedByAlert, NSArray<NSString *> *classChain);
/// Bits (1 << W7CaptionKind) of the caption buttons shown: all three for a window; a dialog's close, and
/// maximize when it is resizable.
FOUNDATION_EXPORT NSUInteger W7CaptionVisibleButtons(BOOL dialog, NSWindowStyleMask mask);
/// W7CaptionHitTest, ignoring buttons not in `visibleButtons`.
FOUNDATION_EXPORT NSInteger W7CaptionHitTestVisible(W7CaptionRects rects, CGPoint p, NSUInteger visibleButtons);
/// Where the caption title must end: the left edge of the leftmost visible button.
FOUNDATION_EXPORT CGFloat W7CaptionTitleMaxX(W7CaptionRects rects, NSUInteger visibleButtons);
/// Whether an NSAlert owns the window (its delegate, whose window it is): the test W7MessageBox.m restyles by.
FOUNDATION_EXPORT BOOL W7WindowIsAlertPanel(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;

@interface W7TitlebarView (W7DialogPanel)
/// A Windows 7 dialog caption: close only (and maximize when the window is resizable). Set by decorateWindow.
@property (nonatomic) BOOL w7DialogCaption;
@end

/// `defaults write -g W7DialogPanelDisabled -bool YES` (or an app's own domain): panels stay native. Read once
/// per process, unless overridden.
FOUNDATION_EXPORT BOOL W7DialogPanelDisabled(void);
/// Test seam: 1 disables, 0 enables, -1 goes back to the defaults value.
FOUNDATION_EXPORT void W7DialogPanelUseDisabledOverride(NSInteger value);
/// W7IsDialogPanel for a live window (an NSPanel, unless disabled; never one whose content view is an NSRemoteView,
/// drawn by another process).
FOUNDATION_EXPORT BOOL W7IsDialogPanelWindow(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
/// Height of the bottom band (48 pt) that must hold only push buttons for the strip to be drawn.
FOUNDATION_EXPORT const CGFloat W7DialogPanelStripBand;
/// The top of the Windows 7 button strip in `content` (from its bottom, whether or not it is flipped): when every
/// visible view reaching into the bottom W7DialogPanelStripBand points is a titled push button or a help button (not
/// a pop-up or image-only button; containers are
/// looked into; plain empty views and separators are ignored), the buttons' top plus half the gap to the content
/// above, at most 16 (W7MessageBoxStripTop). 0 when there is no strip (or for SwiftUI hosting content).
FOUNDATION_EXPORT CGFloat W7DialogPanelStripTop(NSView *_Nullable content) NS_SWIFT_UI_ACTOR;
/// "top=N" or "none (reason)", for the diagnostics line.
FOUNDATION_EXPORT NSString *W7DialogPanelStripDiagnostics(NSView *_Nullable content) NS_SWIFT_UI_ACTOR;
/// Gives a decorated dialog panel its Windows 7 body, once: a white background in light appearance (its own
/// colour in dark) and, unless the content is a SwiftUI hosting view, a backdrop under its views that draws only the
/// button strip (W7DrawMessageBoxBackground clipped to the strip and its line; nothing without a strip), so a content
/// view's own background stays visible above it. Logs the panel once. YES when it did so now.
FOUNDATION_EXPORT BOOL W7StyleDialogPanel(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Whether W7StyleDialogPanel styled the window.
FOUNDATION_EXPORT BOOL W7DialogPanelIsStyled(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - Font substitution

NS_ASSUME_NONNULL_BEGIN

/// Whether a request of `weight` gets the bold face (weight at least NSFontWeightSemibold).
FOUNDATION_EXPORT BOOL W7FontSubstitutionUsesBoldFace(CGFloat weight);
/// The face for `weight`: `bold` for bold weights, else `regular`; nil (keep the system font) when that face is
/// missing.
FOUNDATION_EXPORT NSString *_Nullable W7FontSubstitutionFaceName(CGFloat weight, NSString *_Nullable regular,
                                                                 NSString *_Nullable bold);
/// A system font request is substituted only when enabled, in light appearance, not monospaced, at 9 pt or more.
FOUNDATION_EXPORT BOOL W7ShouldSubstituteSystemFont(CGFloat pointSize, BOOL monospacedRequest, BOOL light, BOOL disabled);
/// Only app processes (a main bundle ending in .app), not extensions or services.
FOUNDATION_EXPORT BOOL W7FontSubstitutionAppliesToBundlePath(NSString *_Nullable bundlePath);
/// ~/Library/Application Support/Win7Mac/Assets/fonts of the real home folder (also in sandboxed apps).
FOUNDATION_EXPORT NSString *W7FontSubstitutionFontDirectory(void);
/// `defaults write -g W7FontSubstitutionDisabled -bool YES` (or an app's own domain). Read once per process.
FOUNDATION_EXPORT BOOL W7FontSubstitutionDisabled(void);
/// Test seam: 1 disables, 0 enables, -1 goes back to the defaults value.
FOUNDATION_EXPORT void W7FontSubstitutionUseDisabledOverride(NSInteger value);
/// Test seam: 1 light, 0 dark, -1 follows the app's appearance.
FOUNDATION_EXPORT void W7FontSubstitutionUseLightOverride(NSInteger value);
/// Registers `dir`/segoeui.ttf (and segoeuib.ttf) for this process; when the regular face loads, swizzles
/// NSFont's system font class methods (once) and turns substitution on. Without it nothing is registered or
/// swizzled. Returns whether substitution is on.
FOUNDATION_EXPORT BOOL W7FontSubstitutionInstallFromDirectory(NSString *dir);
/// Whether the NSFont class methods are swizzled / substitution is on.
FOUNDATION_EXPORT BOOL W7FontSubstitutionIsSwizzled(void);
FOUNDATION_EXPORT BOOL W7FontSubstitutionIsActive(void);
/// Test seam: substitution off (the swizzled methods return the system fonts again) and the cache emptied.
FOUNDATION_EXPORT void W7FontSubstitutionDeactivate(void);
/// Once per process, in apps only: W7FontSubstitutionInstallFromDirectory(W7FontSubstitutionFontDirectory()),
/// falling back to the copies install.sh put in ~/Library/Fonts and then to Segoe UI installed for the user (sandboxed
/// apps can read neither folder), then follows the app's appearance. Logs once when the font is not imported. Called from +[W7ChromeController start].
FOUNDATION_EXPORT void W7InstallFontSubstitution(void) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - Safari glass tint

NS_ASSUME_NONNULL_BEGIN

/// A glass tint: an sRGB colour (0xRRGGBB) and its alpha.
typedef struct { uint32_t rgb; CGFloat alpha; } W7SafariGlassTint;
/// A toolbar button's glass tint: the IE7 button face #F7F9FC 0.75; the back/forward capsule #DCE6F4 0.90.
FOUNDATION_EXPORT W7SafariGlassTint W7SafariToolbarGlassTint(BOOL backForward);
/// Toolbar items whose glass may be tinted: Safari's own buttons (back/forward, sidebar, tab group, new tab, tab
/// overview, share, reload, home, history, top sites, iCloud tabs, bookmarks bar, print, mail, text size). Never
/// the address field (InputFields…), downloads, privacy report, Lockdown Mode, AutoFill, website settings or any
/// unknown (web extension) item.
FOUNDATION_EXPORT BOOL W7SafariGlassItemAllowed(NSString *_Nullable identifier);
/// The glass tint runs only with the private hooks on and without `defaults write -g W7SafariGlassTintDisabled -bool YES`.
FOUNDATION_EXPORT BOOL W7SafariGlassShouldStart(BOOL hooksEnabled, BOOL tintDisabled);
/// The class name of the first view excluded from styling (W7SafariIsExcludedClassName, or a popover's) at or under
/// `view` (at most 8 deep) or among its ancestors below `stop`, judged by the real class (not a KVO subclass); nil
/// when there is none.
FOUNDATION_EXPORT NSString *_Nullable W7SafariGlassExclusionIn(NSView *view, NSView *_Nullable stop) NS_SWIFT_UI_ACTOR;

/// Whether glass styling acts at all (W7SafariGlassStart sets it; tests may set it directly).
FOUNDATION_EXPORT void W7SafariGlassSetEnabled(BOOL enabled) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT BOOL W7SafariGlassEnabled(void) NS_SWIFT_UI_ACTOR;
/// Styles one glass view through NSGlassEffectView's public API (each method checked with respondsToSelector and
/// its exact type encoding): `tint`, style .clear when `clearStyle`, `cornerRadius` when >= 0. The view's original
/// style, tint and corner radius are saved the first time (associated object). Each value is read first and set
/// only when it differs. NO when the view has no tintColor/setTintColor: (nothing is changed then).
FOUNDATION_EXPORT BOOL W7SafariGlassApply(NSView *glass, W7SafariGlassTint tint, BOOL clearStyle, CGFloat cornerRadius) NS_SWIFT_UI_ACTOR;
/// Puts back exactly what W7SafariGlassApply saved (the tint always; style and radius when they were changed);
/// forgets the saved state.
FOUNDATION_EXPORT void W7SafariGlassRestore(NSView *glass) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT BOOL W7SafariGlassIsStyled(NSView *glass) NS_SWIFT_UI_ACTOR;
/// W7SafariGlassApply again with the values the last W7SafariGlassApply used (each set only when it differs); NO
/// when the view is not styled.
FOUNDATION_EXPORT BOOL W7SafariGlassReapply(NSView *glass) NS_SWIFT_UI_ACTOR;
/// One toolbar platter (NSToolbarPlatterView): styles its glass with W7SafariToolbarGlassTint and style .clear, or
/// returns why not (disabled, window not themed, hidden, no glass, an excluded view inside it or above it below
/// `stop`, an item not on the allow-list, dark appearance), taking earlier styling off then.
FOUNDATION_EXPORT NSString *_Nullable W7SafariGlassStylePlatter(NSView *platter, NSView *_Nullable stop) NS_SWIFT_UI_ACTOR;
/// AppKit's -[NSToolbarPlatterView layout] (v16@0:8, own method) resets its glass's style: after it, a platter
/// styled here gets its style and tint back (nothing for any other platter; styling comes off when its window is
/// no longer themed). Idempotent.
FOUNDATION_EXPORT BOOL W7SafariHookPlatterLayout(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// The window path (gate re-runs, key/main changes, toolbar items added, appearance changes): styles the window's
/// toolbar platters and tab bar glass controls; in an unthemed or dark window, or with glass styling off, restores
/// everything instead.
FOUNDATION_EXPORT void W7SafariGlassUpdateWindow(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Restores every glass view styled in the window (un-theming, window close).
FOUNDATION_EXPORT void W7SafariGlassRemoveWindow(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// How many glass views in the window are styled now.
FOUNDATION_EXPORT NSUInteger W7SafariGlassStyledCount(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// IE7's row order (address row, menu strip, tab row): the menu strip accessory belongs at index 0. YES when a strip
/// found at `stripIndex` must move (found and not first).
FOUNDATION_EXPORT BOOL W7SafariMenuStripNeedsMove(NSUInteger stripIndex);
/// Moves the window's W7MenuStripController back to titlebar accessory index 0 (remove + insert) when it is not
/// there, logging where it was and where the tab bar accessory is. YES when it moved. Called on the next main-queue
/// pass after theming and after tab bar layouts (at most once a second, 5 moves per window), never during layout.
FOUNDATION_EXPORT BOOL W7SafariEnsureMenuStripFirst(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// IE7's tab row: each tab sized to its title plus `padding` within `minWidth`…`maxWidth`, `gap` apart; when
/// they do not fit, every tab shrinks in proportion, none below `floorWidth` (IE8 does the same). Defaults 120, 220, 2,
/// 76 (Safari's glass and stack insets, icon and close button; the live pass replaces the padding per tab with what
/// Safari's own layout needed when it truncated the title) and 100.
typedef struct { CGFloat minWidth, maxWidth, gap, padding, floorWidth; } W7SafariIETabMetrics;
FOUNDATION_EXPORT const W7SafariIETabMetrics W7SafariIETabDefaultMetrics;
/// The tabs' x positions and widths from their title widths, left-aligned from `startX` (8, or just after the pinned
/// tabs or the Favorites group), shrunk in proportion down to `floorWidth` when they would not fit before `maxX`. NO
/// when not even the floor fits (Safari's own layout and scrolling then run inside that room); `xs`/`widths` (count
/// entries each) are filled only on YES. YES for no tabs.
FOUNDATION_EXPORT BOOL W7SafariIETabLayout(const CGFloat *_Nullable titleWidths, NSInteger count, CGFloat startX, CGFloat maxX,
                                           W7SafariIETabMetrics metrics, CGFloat *_Nullable xs, CGFloat *_Nullable widths);
/// Whether hook b re-frames Safari's tabs to W7SafariIETabLayout (W7SafariChromeStart: private hooks on and no
/// `defaults write -g W7SafariIETabLayoutDisabled -bool YES`).
FOUNDATION_EXPORT void W7SafariIETabLayoutSetEnabled(BOOL enabled) NS_SWIFT_UI_ACTOR;
/// W7SafariIETabLayout behind a decision: when every title is unsized (width 0 or less: at window restore
/// the title fields are empty or not yet sized), `titlesUnsized` and nothing written, so the pass keeps Safari's own
/// widths instead of freezing every tab at the floor; `overflow` when W7SafariIETabLayout answers NO; else `applied`.
typedef NS_ENUM(NSInteger, W7SafariIETabLayoutResult) {
    W7SafariIETabLayoutApplied NS_SWIFT_NAME(applied),
    W7SafariIETabLayoutOverflow NS_SWIFT_NAME(overflow),
    W7SafariIETabLayoutTitlesUnsized NS_SWIFT_NAME(titlesUnsized)
};
FOUNDATION_EXPORT W7SafariIETabLayoutResult W7SafariIETabLayoutDecide(const CGFloat *_Nullable titleWidths, NSInteger count, CGFloat startX,
                                                                     CGFloat maxX, W7SafariIETabMetrics metrics, CGFloat *_Nullable xs,
                                                                     CGFloat *_Nullable widths);
/// A pass asked for by a title whose width changed runs on the main queue at most once per this interval (0.1 s) per
/// tab bar, coalesced.
FOUNDATION_EXPORT const CFTimeInterval W7SafariIETabRelayoutInterval;
/// Per tab bar: IE7 passes applied (any trigger), passes deferred to Safari (titles unsized), requests by title changes,
/// and the coalesced passes those requests ran (`relayouts`).
typedef struct { NSInteger passes, deferred, requested, relayouts; } W7SafariIETabLayoutCounts;
FOUNDATION_EXPORT W7SafariIETabLayoutCounts W7SafariIETabLayoutCountsFor(NSView *_Nullable tabBar) NS_SWIFT_UI_ACTOR;
/// UnifiedTabBar -_layoutButtonsAnimated: (v20@0:8B16): the tab separators re-zeroed and W7SafariApplyIETabLayout
/// after the original, for a themed window. Once per class.
FOUNDATION_EXPORT BOOL W7SafariHookTabBarButtonLayout(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// Safari resolves the hovered tab with its own `-_tabBarButtonAtPoint:` from its layout model,
/// which keeps Safari's frames after the IE7 pass (the × and highlight landed on the wrong tab). Hooks that own method
/// (exactly `@32@0:8{CGPoint=dd}16`, else not hooked and reported once; called by W7SafariHookTabBar): while the IE7
/// layout is in force on a themed window (applied, not reserving / backed off / dragging) it answers the visible,
/// unhidden button whose real frame in the tab bar's coordinates holds the point (the selected tab in Safari's backdrop
/// container included; the selected one wins an overlap), nil between tabs; otherwise Safari's own answer. No
/// allocation per call. After a pass that moved buttons, Safari's `-_updateHighlightedTabBarButton` (if `v16@0:8`) is
/// called once so the highlight corrects at once.
FOUNDATION_EXPORT BOOL W7SafariHookTabBarButtonAtPoint(Class _Nullable cls) NS_SWIFT_UI_ACTOR;
/// The diagnostics' line for a tab bar's IE7 layout (passes, deferred, requested, backed off, and the hover hook's
/// counts: answered by frames / passed to Safari).
FOUNDATION_EXPORT NSString *W7SafariIETabLayoutDiagnostics(NSView *_Nullable tabBar) NS_SWIFT_UI_ACTOR;
/// Every tab separator of the tab bar at alpha 0: the values of _tabBarItemsToTabBarButtonSeparators
/// (through -setSeparatorAlphaValue: when it has it), and every view whose class name contains "Separator" held by a
/// tab bar or visible tab button ivar whose name contains "separator" (a view, or an array/set/dictionary/map table of
/// them), or sitting directly in the backdrop's tab container or the tab scroll view's document view. Nothing else is
/// touched; what was zeroed through alphaValue is put back to 1 (where still 0) by W7SafariRestoreTabBar.
FOUNDATION_EXPORT void W7SafariZeroTabSeparators(NSView *tabBar) NS_SWIFT_UI_ACTOR;
/// The verbose diagnostics' tab bar dump (W7SafariVerboseLog, once per process): the UnifiedTabBar subtree to depth
/// 14, at most 120 views, one line each with class, frame, alpha, hidden, whether the layer has a non-clear background
/// or a border, and for a separator which ivar or table holds it; then the ivars of the tab bar's and the tab button's
/// classes whose name contains "separator", "divider" or "line" (name, type and the value's class).
/// (the hover geometry investigation): one line per class of the tab bar's and tab button's chains with their own
/// instance method names containing hover, highlight, mouse, point, track, closeButton, visible, under, location or
/// hit (sorted, at most 200 per class); the tab bar chain's ivars whose name contains frame, rect, layout, hover,
/// highlight, track, mouse, point or button (name and type encoding); and the tracking areas (rect, options, owner
/// class) of the tab bar, the tab scroll view and its document view, and each visible tab button. Never any text.
FOUNDATION_EXPORT NSArray<NSString *> *W7SafariTabBarDump(NSView *tabBar) NS_SWIFT_UI_ACTOR;
/// Called by W7SafariChromeStart: sets W7SafariGlassEnabled and, when enabled, installs the platter hook, and
/// observes window close (restore), toolbar item additions and appearance changes (once per process).
FOUNDATION_EXPORT void W7SafariGlassStart(BOOL enabled) NS_SWIFT_UI_ACTOR;

// MARK: Safari IE8 facsimile tabs

/// Whether hook c draws the IE8 facsimile tabs (W7SafariFacsimileStart sets it; tests may set it directly).
FOUNDATION_EXPORT void W7SafariFacsimileSetEnabled(BOOL enabled) NS_SWIFT_UI_ACTOR;
/// The facsimile runs only with the private hooks on and without `defaults write -g W7SafariFacsimileTabsDisabled -bool YES`.
FOUNDATION_EXPORT BOOL W7SafariFacsimileShouldStart(BOOL hooksEnabled, BOOL disabled);
/// Called by W7SafariChromeStart: sets whether the facsimile is on and, when it is, observes window close (every saved
/// alpha back) and window updates (titles and favicons that changed without a layout pass, at most 4 a second per
/// window), once per process.
FOUNDATION_EXPORT void W7SafariFacsimileStart(BOOL enabled) NS_SWIFT_UI_ACTOR;
/// The facsimile view hook c put on a tab button (its topmost subview, transparent to events), or nil.
FOUNDATION_EXPORT NSView *_Nullable W7SafariFacsimileViewForButton(NSView *button) NS_SWIFT_UI_ACTOR;
/// How many times a facsimile view has drawn, and how many redraws its refreshes asked for (once per change of the
/// tab's state, title, favicon or close button; a pass with nothing changed asks for none).
FOUNDATION_EXPORT NSUInteger W7SafariFacsimileDrawCount(NSView *facsimile) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT NSUInteger W7SafariFacsimileRedrawRequests(NSView *facsimile) NS_SWIFT_UI_ACTOR;
/// Refreshes each styled tab of a themed window (compare only; a redraw of a tab that changed), at most 4 times a second
/// per window unless `force` (window updates and Safari's loading updates call it).
FOUNDATION_EXPORT void W7SafariFacsimileRefreshWindow(NSWindow *_Nullable window, BOOL force) NS_SWIFT_UI_ACTOR;
/// Safari's _closeButton of `button` in `into`'s coordinates (CGRectZero when there is none inside the button);
/// `shown`: Safari shows it (not hidden, alpha above 0.01).
FOUNDATION_EXPORT CGRect W7SafariFacsimileCloseRect(NSView *button, NSView *_Nullable into, BOOL *_Nullable shown) NS_SWIFT_UI_ACTOR;

// MARK: Safari tab close button at the right end

/// Where hook c puts Safari's own `_closeButton` of a styled tab (IE8: the × at the tab's right end; Safari has it at
/// the left over the favicon): its right edge W7SafariCloseButtonRightInset (6) from the tab's right edge, vertically
/// centred, Safari's size, on whole points. `tab` is the tab's rect in the close button's superview's coordinates,
/// clipped to that superview's bounds by the caller (Safari's NSStackView; AppKit hit-tests only inside it), so when
/// the stack view is inset from the tab the × is 6 pt from the stack view's right edge instead.
FOUNDATION_EXPORT const CGFloat W7SafariCloseButtonRightInset;
FOUNDATION_EXPORT CGRect W7SafariCloseButtonFrameFor(CGRect tab, CGSize size);
/// Setting the frame again at an unchanged geometry (the tab's width, the superview's bounds and the ×'s own size:
/// Safari's animations are not a fight) more than this many times in one second (Safari keeps putting it
/// back: a layout fight) backs the move off for that button; the × then stays where Safari puts it until 10 s pass,
/// the tab is resized or the pointer enters the tab.
FOUNDATION_EXPORT const NSInteger W7SafariCloseButtonMaxResetsPerSecond;
/// What hook c did with a tab's close button: none inside the button; found but not moved (unstyled, or Safari's frame
/// kept after a restore); moved to the right end; or backed off after a fight (left where Safari puts it).
typedef NS_ENUM(NSInteger, W7SafariCloseButtonPlacement) {
    W7SafariCloseButtonNotFound NS_SWIFT_NAME(notFound),
    W7SafariCloseButtonUntouched NS_SWIFT_NAME(untouched),
    W7SafariCloseButtonMoved NS_SWIFT_NAME(moved),
    W7SafariCloseButtonBackedOff NS_SWIFT_NAME(backedOff)
};
FOUNDATION_EXPORT W7SafariCloseButtonPlacement W7SafariCloseButtonPlacementOf(NSView *button) NS_SWIFT_UI_ACTOR;
/// Re-sets counted in the current second for a button's close button (a set after Safari moved it back, at an
/// unchanged tab width); our own set never counts.
FOUNDATION_EXPORT NSInteger W7SafariCloseButtonResets(NSView *button) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - Safari Internet Explorer rows

NS_ASSUME_NONNULL_BEGIN

/// Flexible and fixed spaces and separators (Safari's sidebar tracking separator included): left out of IE's row.
FOUNDATION_EXPORT BOOL W7SafariToolbarItemIsSpacer(NSString *identifier);
/// IE's navigation row from Safari's item identifiers: BackForwardToolbarIdentifier, InputFieldsToolbarIdentifier,
/// then every other item in Safari's order (the search box slot at the right); spacers dropped. Idempotent.
FOUNDATION_EXPORT NSArray<NSString *> *W7SafariIEToolbarOrder(NSArray<NSString *> *identifiers);
/// The removals and insertions (dictionaries: insert BOOL, index, identifier) that turn `current` into `target`
/// without ever removing `protectedIdentifier` (the address item: other items move around it); nil when that
/// cannot be done.
FOUNDATION_EXPORT NSArray<NSDictionary *> *_Nullable W7SafariToolbarEdits(NSArray<NSString *> *current, NSArray<NSString *> *target,
                                                                           NSString *_Nullable protectedIdentifier);
/// Puts the window's toolbar into IE's order (public NSToolbar API), first saving Safari's order, centred items and
/// autosave flag per toolbar identifier, with autosave off on every toolbar sharing it; restores them exactly when
/// the last themed window using the identifier is un-themed or closes. Logs the order and the address item's width
/// before and after.
FOUNDATION_EXPORT void W7SafariApplyToolbarOrder(NSWindow *window) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT void W7SafariRestoreToolbarOrder(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// `defaults write -g W7SafariToolbarOrderDisabled -bool YES` turns the reorder off (W7SafariChromeStart).
FOUNDATION_EXPORT void W7SafariToolbarOrderSetEnabled(BOOL enabled) NS_SWIFT_UI_ACTOR;

/// The first menu item under `menu` (breadth first) whose action is `actions[0]`, else `actions[1]`, …; nil if none.
FOUNDATION_EXPORT NSMenuItem *_Nullable W7SafariFindMenuItem(NSMenu *_Nullable menu, NSArray<NSString *> *actions) NS_SWIFT_UI_ACTOR;
/// The ▾ menu of an IE command from copies of Safari's own items in `main` (Safari's real selectors, older
/// guesses as fallbacks): "Page" (zoomIn:, zoomOut:, zoomToStandardSize:, saveDocumentTo:, saveDocumentToPDF:, the
/// Text Encoding submenu, toggleReader:, page source when a Develop menu is on); "Safety" (createPrivateBrowsingWindow:,
/// clearHistoryAndWebsiteData:, showPrivacyReport:, showCertificateInformation:); "Tools" (showDownloads:,
/// showExtensionsSettings:, showPreferences: under Safari's own title, toggleStatusBar:, toggleFullScreen:);
/// "Favorites" (★'s right-click / long-press menu: toggleBookmarksSidebar:, toggleReadingListSidebar:, toggleBookmarks:,
/// toggleHistoryInBookmarksView:, toggleFavoritesBar:); "Help" (Safari's Help menu). Missing items are skipped, the
/// order kept; `found` gets the actions used. nil when Safari has none of them.
FOUNDATION_EXPORT NSMenu *_Nullable W7SafariBuildCommandMenu(NSMenu *_Nullable main, NSString *command,
                                                             NSMutableArray<NSString *> *found) NS_SWIFT_UI_ACTOR;
/// A command button's width: 6 pt margins, a 16 pt glyph, 4 pt to the text, the text, 12 pt for a ▾; at least 26.
FOUNDATION_EXPORT CGFloat W7SafariCommandButtonWidth(CGFloat textWidth, BOOL glyph, BOOL arrow);
/// Right-aligned buttons ending at `rightEdge`, `gap` apart, in order from the left: fills `xs`, returns the left edge.
FOUNDATION_EXPORT CGFloat W7SafariCommandBarLayout(const CGFloat *widths, NSInteger count, CGFloat rightEdge, CGFloat gap,
                                                   CGFloat *_Nullable xs);
/// Whether the tab row gets the ★/✚ group, new-tab stub and command bar (W7SafariChromeStart: private hooks on and no
/// `defaults write -g W7SafariCommandBarDisabled -bool YES`).
FOUNDATION_EXPORT void W7SafariCommandBarSetEnabled(BOOL enabled) NS_SWIFT_UI_ACTOR;

/// Places the tab bar's ★/✚ group (at the tab row's left) and the right-aligned command bar for the tabs' `row` (tab
/// bar coordinates), building the controls on the first call, moving `tabsStartX` after the group and `tabsMaxX`
/// before the commands; and takes them all away again. Called by the IE tab layout pass (themed windows).
FOUNDATION_EXPORT void W7SafariLayoutCommandBar(NSView *tabBar, CGRect row, CGFloat *_Nullable tabsStartX, CGFloat *_Nullable tabsMaxX) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT void W7SafariRemoveCommandBar(NSView *_Nullable tabBar) NS_SWIFT_UI_ACTOR;

// Safari's real selectors (W7SafariCommandActions.m).
/// What ★ Favorites performs, in order (IE8's Favorites Center → Safari's Bookmarks sidebar): `toggleBookmarksSidebar:`,
/// `safari_toggleSidebar:`, `toggleBookmarks:`, then the older guess `toggleSidebar:`.
FOUNDATION_EXPORT NSArray<NSString *> *W7SafariFavoritesActions(void) NS_SWIFT_UI_ACTOR;
/// What Print performs: `safari_printDocument:`, then the older guesses.
FOUNDATION_EXPORT NSArray<NSString *> *W7SafariPrintActions(void) NS_SWIFT_UI_ACTOR;
/// Performs a Safari menu item through its own menu, exactly as a menu click, after `[menu update]` (Safari's own
/// validation); `enabled` gets that verdict. YES when sent.
FOUNDATION_EXPORT BOOL W7SafariPerformMenuItem(NSMenuItem *item, BOOL *_Nullable enabled) NS_SWIFT_UI_ACTOR;
/// Sends a toolbar item's own action (its control's action/target when the view is a control, else the item's) when
/// enabled. YES when sent or when Safari's control is disabled (its own state: nothing to do); NO when the item is not
/// there or its view is no control and it has no action (the caller falls back to the menu).
FOUNDATION_EXPORT BOOL W7SafariPerformToolbarItem(NSWindow *_Nullable window, NSString *identifier) NS_SWIFT_UI_ACTOR;
/// ✚ Add to Favorites follows Safari's validation of Add Bookmark… (the item's target, asked `validateMenuItem:` /
/// `validateUserInterfaceItem:` as its menu would; the click path runs `[menu update]` itself): disabled on the Start
/// Page or an empty tab, with the tooltip "Open a page first". Run on tab selection, loading changes, key changes and
/// the tab row's layout; at most once per 250 ms per window unless `force`, and a throttled call runs when the interval
/// ends, so the last change is never lost. Only the key window's own bar takes the verdict (another window keeps its
/// last state), and a click never trusts the cached state: it validates afresh. Nothing without a bar.
FOUNDATION_EXPORT void W7SafariCommandBarRevalidate(NSWindow *_Nullable window, BOOL force) NS_SWIFT_UI_ACTOR;
/// Tests: the main menu the bar resolves against (nil: NSApp.mainMenu).
FOUNDATION_EXPORT void W7SafariCommandBarSetMainMenu(NSMenu *_Nullable menu) NS_SWIFT_UI_ACTOR;
/// Tests: a control of a tab bar's command bar by name ("Favorites", "AddFavorite", "Stub", "Home", "Print", "Page",
/// "Safety", "Tools", "Help"); nil until laid out, or when Safari has no item for it.
FOUNDATION_EXPORT NSView *_Nullable W7SafariCommandBarControl(NSView *tabBar, NSString *name) NS_SWIFT_UI_ACTOR;
/// Tests: the selector a direct control resolved to (nil for a ▾ command); whether it is drawn disabled; what a click
/// does, without the event (YES when Safari's item or action was sent; nothing while disabled); the menu a ▾ command
/// (or ★'s right-click / long press) opens, built now from Safari's menus (nil when it has none).
FOUNDATION_EXPORT NSString *_Nullable W7SafariCommandControlAction(NSView *control) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT BOOL W7SafariCommandControlIsDisabled(NSView *control) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT BOOL W7SafariCommandControlClick(NSView *control) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT NSMenu *_Nullable W7SafariCommandControlMenu(NSView *control) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - The user's imported icons

NS_ASSUME_NONNULL_BEGIN

/// The icon names the dylib reads: exactly the lines of scripts/chrome-icon-names.txt (what `make chrome` embeds).
FOUNDATION_EXPORT NSArray<NSString *> *W7UserIconNames(void);
/// A binary or XML plist `{name: PNG data}` (the `__w7icons` section): keeps entries whose key is a plain name
/// (`[A-Za-z0-9][A-Za-z0-9._-]*`) and whose value is NSData of 1 byte to 512 KB. Never throws; empty on bad input.
FOUNDATION_EXPORT NSDictionary<NSString *, NSData *> *W7UserIconsFromPlistData(NSData *data);
/// Tests: the embedded icons to use instead of the section (filtered as W7UserIconsFromPlistData does); nil restores
/// the section, read lazily once. Clears the icon caches, the folder bitmaps included.
FOUNDATION_EXPORT void W7UserIconsUseEmbedded(NSDictionary<NSString *, NSData *> *_Nullable icons);
/// Drops the icon caches (the folder bitmaps too), so files and absences are looked at again (W7FolderIconUseAssetRoot
/// calls it).
FOUNDATION_EXPORT void W7UserIconsClearCaches(void);
/// The user's icon `name`, `points` square (0 < points ≤ 512) with 1x and 2x bitmaps drawn aspect-fit, from
/// `<W7FolderIconAssetRootPath()>/icons/<name>.png` when it is a regular file (no symlink) of at most 2 MB holding a
/// PNG of at most 1024 px, else the `__w7icons` section's PNG, else nil. The source is decoded once per name (an
/// absence is remembered too) and the image cached per name and size (both caches bounded at 64 MB by bitmap
/// bytes), until W7FolderIconUseAssetRoot or W7UserIconsUseEmbedded. Callers that see many sizes (Finder's slider)
/// round them with W7FolderIconBucketPoints, or use W7UserIconImageSized. Thread-safe; never throws.
/// The image is SHARED by every caller: do not mutate it (no setSize:, no setTemplate:, no added representations);
/// hand AppKit a copy (`[image copy]`) or W7UserIconImageSized's image where it may be resized.
FOUNDATION_EXPORT NSImage *_Nullable W7UserIconImage(NSString *name, CGFloat points);
/// A new NSImage of `size` (the caller owns it and may resize it) built from the cached W7UserIconImage bitmaps of
/// the bucket W7FolderIconBucketPoints(shorter side): a square size reuses them as they are, a non-square one gets
/// the square icon centred, never stretched. nil when there is no icon or the size is empty or over 512 pt.
FOUNDATION_EXPORT NSImage *_Nullable W7UserIconImageSized(NSString *name, NSSize size);
/// The same icon as a CGImage object `pixels` square (1 ≤ pixels ≤ 1024), drawn aspect-fit in sRGB; not cached
/// (callers cache what they build from it): never call it per draw. nil when there is no icon.
FOUNDATION_EXPORT id _Nullable W7UserIconBitmap(NSString *name, size_t pixels);
/// The decoded source image for `name` (the asset file, else the embedded PNG) as a CGImage object, from the
/// loader's per-name cache; nil when absent. W7FolderIconImage reads its folder overrides through it.
FOUNDATION_EXPORT id _Nullable W7UserIconSourceImage(NSString *name);
/// A counter that changes on every cache reset (W7UserIconsClearCaches, W7FolderIconUseAssetRoot,
/// W7UserIconsUseEmbedded): callers that keep an icon compare it instead of asking again. Lock-free.
FOUNDATION_EXPORT NSUInteger W7UserIconsGeneration(void);
/// Tests: how many source PNGs have been decoded in this process.
FOUNDATION_EXPORT NSUInteger W7UserIconDecodeCount(void);

// MARK: - IE command bar and page icons, message box icons, the app's own icon

/// The user's icon name for an IE command bar glyph: `favorites`, `ie-add-favorite`, `ie-home`, `ie-print`, `ie-help`
/// (nil for an unknown value). The command button (W7SafariCommandBar.m) draws W7UserIconImage(name, 16) in its 16 pt
/// glyph rect when the PNG exists (at 40 % while disabled), kept per W7UserIconsGeneration so a redraw allocates
/// nothing; else W7DrawIEGlyph / W7DrawIEGlyphDisabled as before.
FOUNDATION_EXPORT NSString *_Nullable W7IEGlyphIconName(W7IEGlyph glyph);
/// The icon a facsimile tab draws for Safari's `safariIcon`: a template image (Safari's symbol placeholder) becomes
/// the user's `ie-page` icon (16 pt, a non-template image) when it exists, else stays the template (W7DrawIETabFacsimile
/// then draws IE's page icon); a real favicon and nil come back unchanged. The page icon is kept per
/// W7UserIconsGeneration (no allocation per draw). Never changes `safariIcon`. Main thread.
FOUNDATION_EXPORT NSImage *_Nullable W7IETabIconFor(NSImage *_Nullable safariIcon) NS_SWIFT_UI_ACTOR;

/// The user's icon for an alert style: critical → `msgbox-warning`, informational → `msgbox-info`, warning → nil (the
/// app's own icon, W7AppIconOverrideAppliedImage).
FOUNDATION_EXPORT NSString *_Nullable W7MessageBoxIconName(NSAlertStyle style);
/// YES only when not `disabled` and `alert.icon` is still the application icon (NSApp.applicationIconImage, or the
/// image named NSImageNameApplicationIcon that NSAlert shows by default): an icon the app chose itself stays.
FOUNDATION_EXPORT BOOL W7MessageBoxShouldReplaceIcon(NSAlert *alert, BOOL disabled) NS_SWIFT_UI_ACTOR;
/// NO in Safari; YES elsewhere.
FOUNDATION_EXPORT BOOL W7MessageBoxIconsApplyInApp(NSString *_Nullable bundleID);
/// A new 64 pt image (the caller may hand it to AppKit) for `style`: W7UserIconImageSized of W7MessageBoxIconName when
/// that PNG exists, else a copy of `appIcon`, else nil.
FOUNDATION_EXPORT NSImage *_Nullable W7MessageBoxIconImage(NSAlertStyle style, NSImage *_Nullable appIcon) NS_SWIFT_UI_ACTOR;
/// The app icon an alert may show: `applied` (W7AppIconOverrideAppliedImage) only while it is still `current`
/// (NSApp.applicationIconImage, the same object); nil once the app set an icon of its own, or when none was applied.
FOUNDATION_EXPORT NSImage *_Nullable W7MessageBoxAppIcon(NSImage *_Nullable applied, NSImage *_Nullable current);
/// `defaults write -g W7MessageBoxIconsDisabled -bool YES` (or an app's own domain). Read once per process.
FOUNDATION_EXPORT BOOL W7MessageBoxIconsDisabled(void);
/// Tests: forces W7MessageBoxIconsDisabled (0 or 1); -1 goes back to the defaults.
FOUNDATION_EXPORT void W7MessageBoxIconsUseDisabledOverride(NSInteger value);
/// On the window-became-key path (W7InstallMessageBoxes): sets the owning NSAlert's icon to W7MessageBoxIconImage(its
/// style, W7MessageBoxAppIcon(W7AppIconOverrideAppliedImage(), NSApp.applicationIconImage)) when
/// W7MessageBoxShouldReplaceIcon (W7MessageBoxIconsDisabled) and W7MessageBoxIconsApplyInApp say so. YES when the icon
/// was set; NO (nothing changed) otherwise or on any failure. On a critical alert AppKit draws the icon set here
/// (msgbox-warning) as the main picture with the application's icon as its small badge (seen live).
FOUNDATION_EXPORT BOOL W7MessageBoxApplyUserIcon(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;

/// `app-<bundleID>` when `bundleID` is a plain name (`[A-Za-z0-9][A-Za-z0-9._-]*`, IconOverrideNames.app's rules),
/// else nil.
FOUNDATION_EXPORT NSString *_Nullable W7AppIconOverrideName(NSString *_Nullable bundleID);
/// Not `disabled` (W7AppIconDisabled), a W7AppIconOverrideName exists, and not the shell (`com.win7mac.shell`).
FOUNDATION_EXPORT BOOL W7AppIconOverrideShouldApply(NSString *_Nullable bundleID, BOOL disabled);
/// Whether this process looks its icon up at all: a W7AppIconOverrideName exists, not the shell, and the main bundle
/// is an `.app` (W7FontSubstitutionAppliesToBundlePath), so extensions, XPC and view services never do.
FOUNDATION_EXPORT BOOL W7AppIconOverrideAppliesToProcess(NSString *_Nullable bundleID, NSString *_Nullable bundlePath);
/// The image the install step would apply: a new 128 pt image (1x and 2x, W7UserIconImageSized) of
/// `app-<bundleID>` (the asset file, else the `__w7icons` section) when the decision says yes; else nil.
FOUNDATION_EXPORT NSImage *_Nullable W7AppIconOverrideImage(NSString *_Nullable bundleID, BOOL disabled);
/// `defaults write -g W7AppIconDisabled -bool YES` (or an app's own domain). Read once per process.
FOUNDATION_EXPORT BOOL W7AppIconDisabled(void);
/// Once per process, from W7ChromeController's start (after the constructor's eligibility check, before any window is
/// decorated), only when W7AppIconOverrideAppliesToProcess: NSApp.applicationIconImage = W7AppIconOverrideImage(main
/// bundle id, W7AppIconDisabled()) when there is one. One log line: `app icon: app-<bundle id> applied / absent /
/// disabled`. Fails open.
FOUNDATION_EXPORT void W7AppIconOverrideInstall(void) NS_SWIFT_UI_ACTOR;
/// The image W7AppIconOverrideInstall applied (the app's own icon for `.warning` alerts), or nil.
FOUNDATION_EXPORT NSImage *_Nullable W7AppIconOverrideAppliedImage(void);

NS_ASSUME_NONNULL_END

// MARK: - Windows 7 command-bar look for app toolbars

NS_ASSUME_NONNULL_BEGIN

/// `defaults write -g W7ToolbarLookDisabled -bool YES` (or an app's own domain). Read once per process.
FOUNDATION_EXPORT BOOL W7ToolbarLookDisabled(void);
/// Tests: 1 or 0 overrides the defaults value, a negative value goes back to it.
FOUNDATION_EXPORT void W7ToolbarLookUseDisabledOverride(NSInteger value);
/// Not Safari (its own IE8 treatment, W7SafariGlass.m), Finder (the Explorer bars) or the shell. nil counts as an app.
FOUNDATION_EXPORT BOOL W7ToolbarLookAppliesToBundle(NSString *_Nullable bundleID);
/// Not `disabled`, W7ToolbarLookAppliesToBundle, and `window` is decorated (has the Aero title bar), is not an
/// Explorer window, and has an NSToolbar whose displayMode is not label-only. (Decorated windows always have the
/// Expanded toolbar style: decorateWindow sets it, so the app's own style, .preference included, is not looked at.)
FOUNDATION_EXPORT BOOL W7ToolbarLookApplies(NSString *_Nullable bundleID, NSWindow *_Nullable window, BOOL disabled) NS_SWIFT_UI_ACTOR;
/// The tint every visible Liquid Glass platter gets (style .clear, radius 3): the command bar's middle #E9F0F8 at 0.80.
FOUNDATION_EXPORT W7SafariGlassTint W7ToolbarLookGlassTint(void);
/// The tint of a platter holding an editable text field (the search field): white at 0.90, as the Windows 7 search box.
FOUNDATION_EXPORT W7SafariGlassTint W7ToolbarLookSearchGlassTint(void);
/// The identifier of the toolbar band among the title bar's band painters (W7SetTitlebarBandPainterForIdentifier).
FOUNDATION_EXPORT NSString *const W7ToolbarLookBandPainterIdentifier;
/// Public API only, no hook:
///   - the band: the window's Aero title bar paints the Windows 7 command bar (W7DrawCommandBar) behind AppKit's
///     toolbar view through the W7ToolbarLookBandPainterIdentifier painter, beside any other band painter;
///   - every visible toolbar platter (a Liquid Glass NSToolbarPlatterView; the tint is a property of its glass, an
///     ancestor of the item's view, so no control is touched) gets its glass tinted through W7SafariGlassApply
///     (W7ToolbarLookGlassTint, or W7ToolbarLookSearchGlassTint when it holds an editable text field; .clear; radius
///     3; originals saved per glass view) and an opaque plate as the first subview of the glass's public contentView
///     (W7ToolbarLookInsertPlate: the band's own slice, the search box white), under every item view, hiding the pill
///     and its sheen; the three glass properties and the glass's contentView are observed with KVO (only keys the
///     class notifies automatically, W7ToolbarLookObservableGlassKeys) and, when AppKit resets them (it does on a
///     platter layout) or swaps the contentView, the plate is put back first and the values re-applied, at most once
///     per run-loop pass and 10 times a second per window (then it waits for the next W7ToolbarLookApply and logs it
///     once);
///   - only plain NSButtons (AppKit's NSToolbarButton for image items, or an item's custom NSButton; never a pop-up)
///     get a flat Windows 7 face (W7DrawCommandButton hover and pressed, nothing at rest) as their sibling just below
///     them at their frame, click-through; a face whose button left the window (overflow) draws and presses nothing.
/// Item order, labels, images, actions, visibility, borders, bezels and custom views are never changed. Idempotent: a
/// second pass adds only what is new and takes the look off platters that are gone or hidden. In dark appearance it
/// restores instead. One log line per window (`toolbar look: N items, M buttons restyled`); with `defaults write -g
/// W7ToolbarVerboseLog -bool YES` also the title bar's view tree once (W7ToolbarLookTreeDump). Fails open.
FOUNDATION_EXPORT void W7ToolbarLookApply(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Puts back everything W7ToolbarLookApply changed in the window: every face and plate removed, every observation
/// ended, every glass view's tint, style and radius restored exactly, our band painter removed (no other). Nothing
/// when the look is not on. Also runs when the window closes (the look observes its own window).
FOUNDATION_EXPORT void W7ToolbarLookRestore(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// The window path: W7ToolbarLookApply when W7ToolbarLookApplies(main bundle, window, W7ToolbarLookDisabled()), else
/// W7ToolbarLookRestore. W7ChromeController calls it after decorating, on every key/main change.
FOUNDATION_EXPORT void W7ToolbarLookUpdate(NSWindow *window) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT BOOL W7ToolbarLookIsApplied(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// How many buttons have a Windows 7 face now, how many glass platters are tinted, and how many plates are in.
FOUNDATION_EXPORT NSUInteger W7ToolbarLookButtonCount(NSWindow *window) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT NSUInteger W7ToolbarLookGlassCount(NSWindow *window) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT NSUInteger W7ToolbarLookPlateCount(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// The public glass keys the look observes on a glass view of class `cls` (tintColor, style, cornerRadius,
/// contentView, in that order): only those `cls` notifies automatically (+automaticallyNotifiesObserversForKey:), so
/// a glass that deallocates while observed is safe under the relaxed unregistration rule.
FOUNDATION_EXPORT NSArray<NSString *> *W7ToolbarLookObservableGlassKeys(Class cls);
/// The plate in `container` (a platter glass's contentView): the one already there (moved back to the bottom), else
/// a new click-through view at the container's bounds inserted below every subview, drawing W7DrawCommandBar (or the
/// window's W7ToolbarLookSetBandFill fill) over `band`'s bounds (the toolbar view; the container's bounds without it) clipped to itself, or, with `searchBox`, the
/// Explorer search box's white field (W7DrawAddressBar); nothing in dark appearance. nil, with nothing left behind
/// (the plate removed, the other subviews' frames put back), when inserting it moved any other subview: the frames
/// are taken after `layoutSubtreeIfNeeded` and compared after another one, so a container that moves its children in
/// its next layout pass (Auto Layout, a stack) is caught too.
FOUNDATION_EXPORT NSView *_Nullable W7ToolbarLookInsertPlate(NSView *container, NSView *_Nullable band, BOOL searchBox) NS_SWIFT_UI_ACTOR;
/// The local mouse-down monitor's work, for tests: presses the face under `locationInWindow` (a visible, enabled
/// button still in `window`) and schedules its release for the next default- or modal-panel-mode pass (never the
/// button's tracking loop). NO when no face was pressed.
FOUNDATION_EXPORT BOOL W7ToolbarLookPressAt(NSWindow *window, NSPoint locationInWindow) NS_SWIFT_UI_ACTOR;
/// The title bar view's subtree, one view per line (indent, class name, frame, hidden): at most 200 lines, 16 deep.
/// Never a title, label or string value.
FOUNDATION_EXPORT NSString *W7ToolbarLookTreeDump(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// A toolbar band fill: draws the band over `rect` (the toolbar view's rect in the context's coordinates).
typedef void (*W7ToolbarBandFill)(CGContextRef ctx, CGRect rect);
/// the window's toolbar band fill in place of W7DrawCommandBar, for the band painter and every plate (an app
/// look's own colours: Messages' Messenger band, W7DrawMessengerBandBackground); NULL puts the command bar back.
/// Redraws the band and the plates. Kept on the window whether or not the look is on now.
FOUNDATION_EXPORT void W7ToolbarLookSetBandFill(NSWindow *window, W7ToolbarBandFill _Nullable fill) NS_SWIFT_UI_ACTOR;
/// The window's band fill, NULL for the command bar.
FOUNDATION_EXPORT W7ToolbarBandFill _Nullable W7ToolbarLookBandFill(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Once, from W7ChromeController's start, when not disabled and the app is not skipped (Safari, Finder, the shell):
/// re-runs W7ToolbarLookUpdate on the next run-loop pass after toolbar items are added or removed and after a live
/// resize, on appearance changes, and restores a window when it closes. No method is hooked.
FOUNDATION_EXPORT void W7ToolbarLookInstall(void) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

// MARK: - Finder's Computer location as the Windows 7 Computer view

NS_ASSUME_NONNULL_BEGIN

/// The volume-facts key holding the volume's POSIX path (NSString). Every other key of a facts dictionary is the
/// NSURLResourceKey it was read under (W7ComputerVolumeResourceKeys).
FOUNDATION_EXPORT NSString *const W7ComputerVolumePathKey;
/// What W7ComputerReadVolumeFacts reads per volume: localized name, root / internal / removable / ejectable / local /
/// browsable flags, the type name (cd9660, udf, cddafs: optical), total, important-usage and plain available capacity
/// (the fallback when a volume has no important-usage value), and the localized format description ("APFS").
FOUNDATION_EXPORT NSArray<NSURLResourceKey> *W7ComputerVolumeResourceKeys(void);
/// The mounted volumes (NSFileManager -mountedVolumeURLsIncludingResourceValuesForKeys:, hidden volumes skipped),
/// one facts dictionary each. File-system I/O, possibly slow for network volumes: never on the main thread in the
/// app. Never logs a path or a name.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *W7ComputerReadVolumeFacts(void);

typedef NS_ENUM(NSInteger, W7ComputerDriveKind) {
    W7ComputerDriveSystem NS_SWIFT_NAME(system),         // the root file system: Windows' system drive
    W7ComputerDriveInternal NS_SWIFT_NAME(internal),     // another internal volume
    W7ComputerDriveRemovable NS_SWIFT_NAME(removable),   // removable, or ejectable and not internal (USB, disk images)
    W7ComputerDriveOptical NS_SWIFT_NAME(optical),       // a CD/DVD/Blu-ray file system
    W7ComputerDriveNetwork NS_SWIFT_NAME(network)        // not local
};
typedef NS_ENUM(NSInteger, W7ComputerGroupKind) {
    W7ComputerGroupHardDisks NS_SWIFT_NAME(hardDisks),   // "Hard Disk Drives"
    W7ComputerGroupRemovable NS_SWIFT_NAME(removable),   // "Devices with Removable Storage"
    W7ComputerGroupNetwork NS_SWIFT_NAME(network)        // "Network Location"
};

/// One drive tile of the Computer view.
@interface W7ComputerRow : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) W7ComputerDriveKind kind;
/// Bytes; -1 when unknown.
@property (nonatomic, readonly) long long total;
@property (nonatomic, readonly) long long free;
/// The user's icon name: "drive-system", "drive", "drive-removable", "drive-optical" or "network".
@property (nonatomic, readonly, copy) NSString *iconName;
@property (nonatomic, readonly) BOOL ejectable;
/// The file system's localized name ("APFS"), or nil.
@property (nonatomic, readonly, copy, nullable) NSString *formatName;
/// W7ComputerCapacityIsLow(free, total): the bar is red.
@property (nonatomic, readonly) BOOL low;
- (instancetype)initWithName:(NSString *)name path:(NSString *)path kind:(W7ComputerDriveKind)kind total:(long long)total
                        free:(long long)free ejectable:(BOOL)ejectable formatName:(nullable NSString *)formatName
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface W7ComputerGroup : NSObject
@property (nonatomic, readonly) W7ComputerGroupKind kind;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSArray<W7ComputerRow *> *rows;
@end

/// The system's own and invisible volumes: not browsable, devfs, or under /System/Volumes/ or /private/var/vm.
FOUNDATION_EXPORT BOOL W7ComputerVolumeIsHidden(NSDictionary<NSString *, id> *facts);
/// Groups in Windows 7 order — "Hard Disk Drives" (the system drive first, then the rest by name), "Devices with
/// Removable Storage", "Network Location" (each by name) — without empty groups and hidden volumes. Network: not
/// local; system: the root file system (or `/`); optical: a cd9660/udf/cddafs volume; removable: removable, or
/// ejectable and not internal; anything else internal. Facts without a path are skipped; a missing name falls back
/// to the path's last component. Pure.
FOUNDATION_EXPORT NSArray<W7ComputerGroup *> *W7ComputerGroupsFromVolumes(NSArray<NSDictionary<NSString *, id> *> *facts);
/// Free space under 10 % of a known total.
FOUNDATION_EXPORT BOOL W7ComputerCapacityIsLow(long long freeBytes, long long totalBytes);
/// The used part of the bar (0…1), or -1 (no bar) when the total is unknown.
FOUNDATION_EXPORT double W7ComputerUsedFraction(long long freeBytes, long long totalBytes);
/// "117 GB free of 460 GB": whole gigabytes (10⁹ bytes, as Finder counts), rounded down; a value of 1000 GB or more in
/// terabytes with one decimal, rounded down, as Windows 7 shows it ("3.9 TB free of 4.0 TB", "900 GB free of 2.0 TB");
/// megabytes when the total is under 1 GB; "" when either value is unknown (negative) or the total is 0.
FOUNDATION_EXPORT NSString *W7ComputerCapacityText(long long freeBytes, long long totalBytes);
/// "Local Disk" (system, internal), "Removable Disk", "CD Drive", "Network Drive".
FOUNDATION_EXPORT NSString *W7ComputerDriveTypeName(W7ComputerDriveKind kind);
/// The details pane for a selected drive: its name (bold), the type as the subtitle, then Total size, Free space
/// (W7ExplorerSizeText) and File system, each left out when unknown.
FOUNDATION_EXPORT W7ExplorerDetailsContent *W7ComputerDetailsForRow(W7ComputerRow *row, NSLocale *locale);
/// The details pane with nothing selected: the computer's name (bold), then Processor and Memory ("16 GB", binary
/// gigabytes, one decimal when not whole) when known.
FOUNDATION_EXPORT W7ExplorerDetailsContent *W7ComputerDetailsForComputer(NSString *name, NSString *_Nullable processor,
                                                                       unsigned long long memoryBytes);
/// The Properties text: "Type: …", "File system: …", "Used space: …", "Free space: …", "Total size: …", one per line.
FOUNDATION_EXPORT NSString *W7ComputerPropertiesText(W7ComputerRow *row, NSLocale *locale);
/// The location signal (Finder's own location model, no AppleScript of its own): Finder's Computer location has no
/// folder path (`locationPath` nil or empty) and its window is titled with the computer's name (`computerName`, from
/// NSHost; Finder never titles it "Computer", so that literal does not count); the location must have been read for the
/// window's current title (otherwise a navigation is in flight). A represented `x-finder:Computer` URL (any case)
/// counts too, with the same title check (an unverified guess: macOS 27 Finder leaves representedURL nil). The overlay
/// also never counts the adoption seed, a location built from the title before any query answered.
FOUNDATION_EXPORT BOOL W7ExplorerIsComputerLocation(NSString *_Nullable locationPath, NSString *_Nullable locationTitle,
                                                    NSString *_Nullable windowTitle, NSString *_Nullable computerName,
                                                    NSURL *_Nullable representedURL);
/// System properties, Uninstall or change a program, Map network drive, Open Control Panel.
FOUNDATION_EXPORT NSArray<NSNumber *> *W7ExplorerCommandsForComputer(void);
/// `x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension`, as the Control Panel's System item.
FOUNDATION_EXPORT NSURL *W7ComputerSystemPropertiesURL(void);
/// The distributed notification (no userInfo) the shell answers by showing its Control Panel.
FOUNDATION_EXPORT NSString *const W7ControlPanelShowNotificationName;

/// `defaults write -g W7ComputerViewDisabled -bool YES` (or Finder's domain). Read once per process.
FOUNDATION_EXPORT BOOL W7ComputerViewDisabled(void);
/// Tests: 1 or 0 overrides the defaults value, a negative value goes back to it.
FOUNDATION_EXPORT void W7ComputerViewUseDisabledOverride(NSInteger value);
/// The computer's name (NSHost localizedName), read once off the main thread; nil until it has arrived.
FOUNDATION_EXPORT NSString *_Nullable W7ComputerName(void);
/// Tests: the name W7ComputerName answers; nil goes back to NSHost's.
FOUNDATION_EXPORT void W7ComputerViewUseComputerName(NSString *_Nullable name);
/// Tests: volume facts from `provider`, synchronously on the main thread, instead of W7ComputerReadVolumeFacts off it.
FOUNDATION_EXPORT void W7ComputerViewUseVolumeFacts(NSArray<NSDictionary<NSString *, id> *> *_Nullable (^_Nullable provider)(void));
/// The answer to one volume read, given on the main thread.
typedef void (^W7ComputerVolumeReadCompletion)(NSArray<NSDictionary<NSString *, id> *> *facts);
/// Tests: `reader` is called on the main thread for each volume read (instead of W7ComputerReadVolumeFacts on the
/// overlay's one serial queue) and answers through the completion, on the main thread, whenever it likes; it takes
/// precedence over W7ComputerViewUseVolumeFacts. nil goes back to the real read. Reads are single-flight: while one is
/// in flight a reload only asks for one more after it, and an answer overtaken by a reload or a hide is dropped.
FOUNDATION_EXPORT void W7ComputerViewUseVolumeReader(void (^_Nullable reader)(W7ComputerVolumeReadCompletion completion));
/// How long a volume read may take before the overlay gives up on it: 10 s. Over the budget with nothing shown yet (a
/// hung network mount), the overlay fails open (Finder's view until the window navigates); drives already shown stay.
/// The late read is never joined by another worker.
FOUNDATION_EXPORT NSTimeInterval W7ComputerVolumeReadBudget(void);
/// Tests: the read budget in seconds; 0 or less goes back to 10.
FOUNDATION_EXPORT void W7ComputerViewUseReadBudget(NSTimeInterval seconds);
/// Tests: the Computer commands report their effects to `sink` instead of performing them — ("yield", bundle id) for
/// the activation handed to the shell, ("post", name) for the distributed notification, ("open", URL) for a URL —
/// and `shellRunning` (1 or 0) answers whether the shell runs. A negative value and nil go back to the real ones.
FOUNDATION_EXPORT void W7ComputerViewUseCommandSink(NSInteger shellRunning,
                                                   void (^_Nullable sink)(NSString *effect, NSString *argument));

/// The Computer view's tiles (flipped, white): each group's header, then its drive tiles (W7DrawComputerTile) in lines
/// that fill the width. Click selects (empty space deselects), double-click or Return opens, the arrow keys move the
/// selection, a right-click (or Control-click) selects and shows `menuForRow` through W7MenuWindow. Main thread.
@interface W7ExplorerComputerView : NSView
@property (nonatomic, copy) NSArray<W7ComputerGroup *> *groups;
/// Index into the groups' rows in order, NSNotFound when nothing is selected.
@property (nonatomic, readonly) NSInteger selectedIndex;
@property (nonatomic, readonly, nullable) W7ComputerRow *selectedRow;
@property (nonatomic, copy, nullable) void (^onSelectionChange)(void);
@property (nonatomic, copy, nullable) void (^onOpen)(W7ComputerRow *row);
@property (nonatomic, copy, nullable) NSMenu *_Nullable (^menuForRow)(W7ComputerRow *row);
/// Selects a row (out of range: nothing) and reports it through onSelectionChange when it changed.
- (void)selectRowAtIndex:(NSInteger)index;
- (NSRect)frameOfRowAtIndex:(NSInteger)index;
/// The row under `point` (view coordinates), or NSNotFound.
- (NSInteger)rowIndexAtPoint:(NSPoint)point;
/// The height the tiles need at `width`.
- (CGFloat)heightForWidth:(CGFloat)width;
@end

/// The Computer view shown in `window` now (an Explorer window on Finder's Computer location), or nil.
FOUNDATION_EXPORT W7ExplorerComputerView *_Nullable W7ExplorerComputerViewForWindow(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
/// Tests: gives an adopted Explorer window the location (path, title), as an accepted location query would.
FOUNDATION_EXPORT void W7ExplorerSetLocationForTesting(NSWindow *window, NSString *_Nullable path, NSString *title) NS_SWIFT_UI_ACTOR;
/// Finder's Go ▸ Computer in `window` (its own menu item, by selector cmdGoToComputer:, else Shift-Command-C). NO when
/// missing or disabled.
FOUNDATION_EXPORT BOOL W7ExplorerGoToComputer(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
/// Tests: performs a Computer command bar `command` for the adopted Explorer window, as its button does.
FOUNDATION_EXPORT void W7ExplorerPerformComputerCommandForTesting(NSWindow *window, W7ExplorerCommand command) NS_SWIFT_UI_ACTOR;
/// Whether a click with `flags` on the nav pane's Locations header goes to the Computer location: not with Control,
/// which is a right-click (the outline view's context menu).
FOUNDATION_EXPORT BOOL W7NavPaneComputerClickNavigates(NSEventModifierFlags flags);

NS_ASSUME_NONNULL_END

// MARK: - Messages view-tree diagnostics

NS_ASSUME_NONNULL_BEGIN

/// Messages' bundle identifier, `com.apple.MobileSMS`.
FOUNDATION_EXPORT NSString *const W7MessagesBundleIdentifier;
/// `defaults write -g W7MessagesLookDisabled -bool YES`: the kill switch, which skips even the dump. Read once per process.
FOUNDATION_EXPORT BOOL W7MessagesLookDisabled(void);
/// Tests: 1 or 0 forces W7MessagesLookDisabled, -1 goes back to the defaults.
FOUNDATION_EXPORT void W7MessagesLookUseDisabledOverride(NSInteger value);
/// `defaults write -g W7MessagesVerboseLog -bool YES`: the view-tree dump, once per Messages main window. Read once.
FOUNDATION_EXPORT BOOL W7MessagesVerboseLog(void);
/// Tests: 1 or 0 forces W7MessagesVerboseLog, -1 goes back to the defaults.
FOUNDATION_EXPORT void W7MessagesUseVerboseLogOverride(NSInteger value);
/// A titled, resizable window that is neither a panel nor a sheet.
FOUNDATION_EXPORT BOOL W7MessagesIsMainWindowShape(NSWindowStyleMask mask, BOOL isPanel, BOOL isSheet);
/// Messages, a main window, the verbose switch on, the kill switch off, and the window not dumped yet.
FOUNDATION_EXPORT BOOL W7MessagesShouldDump(NSString *_Nullable bundleID, BOOL mainWindowShape, BOOL disabled, BOOL verbose,
                                            BOOL alreadyDumped);
/// The view tree under `root`, one line per view: indentation (2 spaces a level), class name, frame `(x,y wxh)` and
/// flags: hidden, alpha, `SwiftUI-host` (SwiftUI's NSHostingView in the class chain), `AppKit-core-host` (AppKit's
/// internal _NSCoreHostingView inside its own controls), `SwiftUI`, `split vertical= panes=`,
/// `table|outline rows= cols= rowHeight=`, `collection sections= items=`, `text-field editable=`, `text-view
/// editable=`, `effect material=`, `(ours)` (not descended). At most `maxDepth` levels below `root`, `maxViews` view
/// lines and 12 children per view (then `+N more subviews`). Names and numbers only: never a string value, title,
/// tool tip, placeholder, accessibility label or identifier.
FOUNDATION_EXPORT NSArray<NSString *> *W7MessagesViewTreeLines(NSView *_Nullable root, NSUInteger maxDepth,
                                                               NSUInteger maxViews) NS_SWIFT_UI_ACTOR;
/// The window's dump: a `window` line (class, frame, contentLayoutRect, style mask, toolbar identifier and style,
/// accessory count, whether the Aero title bar is on), `toolbar items:` (identifiers only), then one inventory line per
/// SwiftUI host (`host`), split view with its pane frames (`split`), table, outline and collection view (frames in
/// window coordinates, at most 20 of each), a `summary:` line (counts, AppKit core hosts included) and the tree from the window's root view (W7MessagesViewTreeLines, 30 deep,
/// 400 views). Never the window title or any text.
FOUNDATION_EXPORT NSArray<NSString *> *W7MessagesWindowDump(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
/// When W7MessagesShouldDump(bundleID, the window's shape, W7MessagesLookDisabled(), W7MessagesVerboseLog(), …): marks
/// the window and logs W7MessagesWindowDump a second later (os_log, in chunks); YES when it scheduled one. The dump
/// draws and changes nothing (the band is W7MessagesBandUpdateForBundle's). Fails open.
FOUNDATION_EXPORT BOOL W7MessagesLookUpdateForBundle(NSWindow *_Nullable window, NSString *_Nullable bundleID) NS_SWIFT_UI_ACTOR;
/// W7MessagesLookUpdateForBundle and W7MessagesBandUpdateForBundle with the main bundle's identifier (every other app:
/// one string compare). W7ChromeController calls it on every key/main change, after the toolbar look.
FOUNDATION_EXPORT void W7MessagesLookUpdate(NSWindow *_Nullable window) NS_SWIFT_UI_ACTOR;
/// In Messages only: logs once whether the Messenger band is on (or killed) and whether the diagnostics are on. No hook,
/// no observer.
FOUNDATION_EXPORT void W7MessagesLookInstall(void) NS_SWIFT_UI_ACTOR;

// MARK: Messenger band
//
// Messages on macOS 27 is a UIKit (Catalyst) app: its content (conversation list, transcript, composer) is not AppKit
// and is never touched. What is drawn is chrome: in a decorated Messages main window, the window's Aero title bar
// paints a Windows Live Messenger header band in the toolbar's own band (under the caption, under every toolbar item,
// through the stackable band painters), and the toolbar look's band and plates take the Messenger colours.

/// The Messenger band's identifier among the title bar's band painters: `com.win7mac.band.messenger`.
FOUNDATION_EXPORT NSString *const W7MessagesBandPainterIdentifier;
typedef NS_ENUM(NSInteger, W7MessengerBandVariant) {
    W7MessengerBandVariantNone NS_SWIFT_NAME(none),
    W7MessengerBandVariantCompact NS_SWIFT_NAME(compact),
    W7MessengerBandVariantFull NS_SWIFT_NAME(full)
};
/// Full when `height` is at least W7MessengerBandHeight (64), compact when at least W7MessengerCompactBandHeight (32),
/// else none.
FOUNDATION_EXPORT W7MessengerBandVariant W7MessengerBandVariantForHeight(CGFloat height);
/// The narrowest free span that takes the header (tile, a short name): 140 pt full, 90 pt compact.
FOUNDATION_EXPORT CGFloat W7MessengerBandMinimumContentWidth(BOOL compact);
/// Where the band goes, in the title bar's coordinates (non-flipped):
///   band    = `toolbar` ∩ (`bounds` without its top W7TitlebarHeight, the caption), inset `sideInset` at both sides:
///             the space the toolbar band gives; the Messenger background fills it;
///   variant = W7MessengerBandVariantForHeight(band height);
///   box     = 64 (full) or 32 (compact) pt high, as wide as the band, vertically centred in it;
///   content = the widest free span of the box (the leftmost of equal ones) between `occupied` rects (the toolbar's
///             items: controls, platters, label stacks) that overlap the box vertically, each widened by 6 pt; zero when
///             it is narrower than W7MessengerBandMinimumContentWidth. The header is drawn only there, so no tile or
///             text ever lies under an item.
/// Everything zero (variant none) when the band is empty.
typedef struct {
    W7MessengerBandVariant variant;
    CGRect band, box, content;
} W7MessengerBandGeometry;
FOUNDATION_EXPORT W7MessengerBandGeometry W7MessengerBandGeometryFor(CGRect bounds, CGRect toolbar, CGFloat sideInset,
                                                                    const CGRect *_Nullable occupied, NSUInteger count);
/// W7MessengerBandGeometryFor for a window's title bar `view` (the glass view or the title bar view): its bounds, the
/// toolbar view's rect, the side inset of the toolbar band (2 pt, none with the frame overlay), and the toolbar's
/// visible controls, platters and label stacks (at most 32, 12 deep). Variant none without a visible toolbar view.
FOUNDATION_EXPORT W7MessengerBandGeometry W7MessagesBandGeometryForWindow(NSWindow *window, NSView *view) NS_SWIFT_UI_ACTOR;
/// The display name the band shows: NSFullUserName(), else NSUserName(). Never anything read from a window.
FOUNDATION_EXPORT NSString *W7MessagesDisplayName(void);
/// Every string the band draws: the display name, the status title ("Available") and the four Messenger commands.
/// Takes no window: nothing shown comes from Messages (titles, labels, contacts and messages are never read).
FOUNDATION_EXPORT NSArray<NSString *> *W7MessagesBandStrings(void);
/// Messages (`bundleID`), not `disabled` (W7MessagesLookDisabled), a main window (W7MessagesIsMainWindowShape) with the
/// Aero title bar, in light appearance.
FOUNDATION_EXPORT BOOL W7MessagesBandApplies(NSString *_Nullable bundleID, NSWindow *_Nullable window, BOOL disabled) NS_SWIFT_UI_ACTOR;
/// Puts the band on: the W7MessagesBandPainterIdentifier painter last among the window's band painters (it re-adds
/// itself last when another painter was added after it, on the next run-loop pass), and the toolbar look's band fill
/// W7DrawMessengerBandBackground. The painter draws, on every glass draw in light appearance with a visible toolbar,
/// the Messenger background over the geometry's band and, in its content span, W7DrawMessengerHeader (the compact
/// variant when the band is under 64 pt; nothing under 32) with the user's picture (W7UserIconImageSized "user",
/// cached per size and icon generation; the drawn silhouette without one), W7MessagesDisplayName and Available.
/// Toolbar items are never moved, hidden or covered (the glass lies under every AppKit view in the title bar). One log
/// line per window, the first time the toolbar band is laid out (`Messenger band: full`, `Messenger band: compact
/// (toolbar band N pt, under 64)`, `Messenger band: none (…)`, plus `, header left out: no free span` when the items
/// leave no room); restores when the window closes. Idempotent. Fails open.
FOUNDATION_EXPORT void W7MessagesBandApply(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// Takes the band off: our painter removed (no other), the toolbar band fill put back when it is ours. Nothing when
/// the band is not on.
FOUNDATION_EXPORT void W7MessagesBandRestore(NSWindow *window) NS_SWIFT_UI_ACTOR;
FOUNDATION_EXPORT BOOL W7MessagesBandIsApplied(NSWindow *window) NS_SWIFT_UI_ACTOR;
/// W7MessagesBandApply when W7MessagesBandApplies(bundleID, window, W7MessagesLookDisabled()), else
/// W7MessagesBandRestore; YES when the band is on afterwards.
FOUNDATION_EXPORT BOOL W7MessagesBandUpdateForBundle(NSWindow *_Nullable window, NSString *_Nullable bundleID) NS_SWIFT_UI_ACTOR;
/// The line logged for the window (W7MessagesBandApply), nil before it was logged.
FOUNDATION_EXPORT NSString *_Nullable W7MessagesBandLogLine(NSWindow *window) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END
