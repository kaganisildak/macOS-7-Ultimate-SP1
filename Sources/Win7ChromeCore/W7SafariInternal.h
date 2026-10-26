// Shared between W7SafariChrome.m (L0–L3: the gate, bands, orb overlay, status bar, diagnostics) and
// W7SafariHooks.m (L4: the private hooks a–e, their restores and the runtime helpers both use). Not public.
#import "Win7ChromeCore.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// A selector registered once per call site (a function-static SEL).
#define W7SafariSel(name) ({ static SEL w7_sel_; if (!w7_sel_) w7_sel_ = sel_registerName(name); w7_sel_; })

#pragma mark Runtime helpers (W7SafariHooks.m)

/// `obj`'s method for `sel`, looked up on its real class, has exactly `types`.
FOUNDATION_EXPORT BOOL W7SafariHasTypes(id _Nullable obj, SEL sel, const char *types);
/// Reads a getter through objc_msgSend only when its encoding is exactly B16@0:8, Q16@0:8, q16@0:8, i16@0:8,
/// d16@0:8 or @16@0:8; NO (nil) otherwise, `out` untouched.
FOUNDATION_EXPORT BOOL W7SafariReadBool(id _Nullable obj, SEL sel, BOOL *out);
FOUNDATION_EXPORT BOOL W7SafariReadUInt64(id _Nullable obj, SEL sel, unsigned long long *out);
FOUNDATION_EXPORT BOOL W7SafariReadInteger(id _Nullable obj, SEL sel, NSInteger *out);
FOUNDATION_EXPORT BOOL W7SafariReadInt(id _Nullable obj, SEL sel, int *out);
FOUNDATION_EXPORT BOOL W7SafariReadDouble(id _Nullable obj, SEL sel, double *out);
FOUNDATION_EXPORT id _Nullable W7SafariReadObject(id _Nullable obj, SEL sel);
/// An object ivar (type encoding starting with '@'), or nil.
FOUNDATION_EXPORT id _Nullable W7SafariIvar(id _Nullable obj, const char *name);
FOUNDATION_EXPORT NSView *_Nullable W7SafariIvarView(id _Nullable obj, const char *name);
/// A window controller's window, only once loaded (asking an unloaded one would load its nib).
FOUNDATION_EXPORT NSWindow *_Nullable W7SafariControllerWindow(id _Nullable controller);
/// `cls`'s own (not inherited) method for `sel` when its encoding is exactly `types`; NULL (reported) otherwise.
FOUNDATION_EXPORT Method _Nullable W7SafariCheckedMethod(Class cls, SEL sel, const char *types);
/// One line for the diagnostics' hook report (also logged at once).
FOUNDATION_EXPORT void W7SafariReport(NSString *line);
FOUNDATION_EXPORT NSArray<NSString *> *W7SafariHookReport(void);

#pragma mark Hooks (W7SafariHooks.m)

typedef struct { uint64_t tabBarLayout, tabButtonLayout, tabButtonBackground, rehides; } W7SafariHookCounts;
/// Calls of the layout-rate hooks since the process started (for the diagnostics' calls/s).
FOUNDATION_EXPORT W7SafariHookCounts W7SafariHookCallCounts(void);
/// Hooks a–e on Safari's classes, by name, once (each logged).
FOUNDATION_EXPORT void W7SafariInstallHooks(void);
FOUNDATION_EXPORT BOOL W7SafariBackForwardHookInstalled(void);
FOUNDATION_EXPORT BOOL W7SafariColorsHookInstalled(void);
/// The controller's loading state and the current tab's estimated progress into its window's status bar, then the
/// window's facsimiles refreshed: unthrottled when `titlesMayHaveChanged` (a loading status change brings a title or
/// favicon; hook c's refresh then asks for the IE7 row again when the title's width changed), else at most 4/s.
FOUNDATION_EXPORT void W7SafariFeedLoading(id _Nullable controller, BOOL titlesMayHaveChanged);
/// A tab button's IE state from its -isActive / -isSelected / -isHighlighted / -isPinned / -state (W7SafariTabState).
FOUNDATION_EXPORT W7IETabState W7SafariTabButtonState(NSView *button);
/// IE7's tab row after Safari's tab bar layout (themed windows; fails open to Safari's), and Safari's row back.
FOUNDATION_EXPORT void W7SafariApplyIETabLayout(NSView *tabBar);
FOUNDATION_EXPORT void W7SafariRestoreIETabLayout(NSView *_Nullable tabBar);
/// from hook c's refresh: the tab's title field now (`titleChanged`: its string differs from the last
/// refresh). Measured when the title changed or the last IE7 pass saw it unsized; a width different from the one that
/// pass used asks the tab bar (found through the button's superviews) for one coalesced pass, once per width.
FOUNDATION_EXPORT void W7SafariNoteTabTitle(NSView *button, NSTextField *_Nullable field, BOOL titleChanged);
/// The object ivars of `cls` and its superclasses (up to NSView) whose name contains `word`, any case; found once per
/// class and kept (W7SafariHooks.m).
FOUNDATION_EXPORT NSArray<NSString *> *W7SafariIvarNamesContaining(Class cls, const char *word);
/// (W7SafariCommandBar.m; W7SafariLayoutCommandBar / W7SafariRemoveCommandBar are public, for the tests): the
/// new-tab stub after `afterTab` (hidden when `show` is NO).
FOUNDATION_EXPORT void W7SafariPlaceNewTabStub(NSView *tabBar, CGRect afterTab, BOOL show);
/// Hides (or shows again) every control of the tab bar's command bar for good (a layout fight with Safari).
FOUNDATION_EXPORT void W7SafariSetCommandBarSuppressed(NSView *tabBar, BOOL suppressed);
/// Hides each of the tab bar's controls whose rect a visible tab's frame crosses (never drawn over a tab).
FOUNDATION_EXPORT void W7SafariHideOverlaysOverTabs(NSView *tabBar);
/// Why a tab's styling pass stopped early (or, last, what it applied to a selected tab): logged once per tab button per
/// reason, always on (no titles), at most 80 lines per process.
typedef NS_ENUM(NSInteger, W7SafariTabNote) {
    W7SafariTabNoteWindowNil = 1, W7SafariTabNoteNotThemed, W7SafariTabNoteHiddenNeverStyled, W7SafariTabNoteUnifiedField,
    W7SafariTabNoteNoContent, W7SafariTabNoteFacsimileOff, W7SafariTabNoteFacsimileFailed, W7SafariTabNoteException,
    W7SafariTabNoteStyled,
};
FOUNDATION_EXPORT void W7SafariNoteTab(NSView *button, W7SafariTabNote note, NSString *_Nullable detail);
/// Whether `note` was already logged for `button` (check first when the detail costs something to format).
FOUNDATION_EXPORT BOOL W7SafariTabNoted(NSView *button, W7SafariTabNote note);

#pragma mark Facsimile tabs (W7SafariTabFacsimile.m)

FOUNDATION_EXPORT BOOL W7SafariFacsimileEnabled(void);
/// Hook c's styling of a tab button: alpha 0 on Safari's faces (saved first), the facsimile view on top, refreshed.
/// NO when it could not (the button is then Safari's own again).
FOUNDATION_EXPORT BOOL W7SafariFacsimileStyleButton(NSView *button);
/// Every saved alpha back (where it is still ours) and the facsimile view removed.
FOUNDATION_EXPORT void W7SafariFacsimileUnstyleButton(NSView *button);
FOUNDATION_EXPORT BOOL W7SafariFacsimileIsStyled(NSView *button);
/// Compares the button's state, title, icon and close button with what its facsimile drew; YES (and a redraw of that
/// tab) on a change.
FOUNDATION_EXPORT BOOL W7SafariFacsimileRefreshButton(NSView *button);
/// Faces Safari gave an alpha again since hook c zeroed them (the diagnostics' re-zeros per second).
FOUNDATION_EXPORT uint64_t W7SafariFacsimileRezeroCount(void);
/// The tab buttons' bottom edge (the first visible styled one) in `into`'s coordinates: where the row's line belongs.
FOUNDATION_EXPORT BOOL W7SafariFacsimileLineY(NSView *_Nullable tabBar, NSView *into, CGFloat *y);
/// The diagnostics' facsimile lines for a window (counts, alpha 0 read back, close button, the selected tab's layer).
FOUNDATION_EXPORT NSArray<NSString *> *W7SafariFacsimileDiagnostics(NSWindow *window);
/// Whether the icon a facsimile view last read from its button is a template image (drawn as IE's page icon).
FOUNDATION_EXPORT BOOL W7SafariFacsimileIconIsTemplate(NSView *_Nullable facsimile);

#pragma mark Close button at the right end (W7SafariTabCloseButton.m)

/// Safari's _closeButton of a styled tab moved to the tab's right end (W7SafariCloseButtonFrameFor), Safari's frame
/// saved first; nothing when it is already there, none is found, or the move backed off (a fight, logged once per
/// `window`). YES when the frame changed. Hook c calls it before the facsimile reads the button, the facsimile's
/// refresh calls it before reading the close rect, and the frame observer it installs (while the button is styled in
/// a themed window) calls it whenever Safari's own layout moved the button.
FOUNDATION_EXPORT BOOL W7SafariCloseButtonPlace(NSView *button, NSWindow *_Nullable window);
/// Safari's frame back exactly (when the frame is still ours) and the state dropped: every unstyle path.
FOUNDATION_EXPORT void W7SafariCloseButtonRestore(NSView *button);
/// the pointer entered the tab — a backed-off move is lifted (the next Place moves the × right again).
FOUNDATION_EXPORT void W7SafariCloseButtonLiftBackOff(NSView *button);

#pragma mark Window side (W7SafariChrome.m)

/// W7SafariIsExcludedClassName on a C class name, without allocating.
FOUNDATION_EXPORT BOOL W7SafariIsExcludedCName(const char *_Nullable name);
/// W7SafariIsExcludedCName, or a class name containing "Popover".
FOUNDATION_EXPORT BOOL W7SafariIsGlassExcludedCName(const char *_Nullable name);
/// After a tab bar layout (themed or not): redraws the bands when the tab bar moved, and re-runs the gate on
/// the next run-loop pass when its frame changed (Separate ↔ Compact). One conversion when nothing changed.
FOUNDATION_EXPORT void W7SafariNoteTabBarFrame(NSView *tabBar, NSWindow *_Nullable window);
/// Hook b's diagnostics, on every tab bar layout pass: at most once a second per window (never for a private
/// window) one line with the tab bar's frame, hidden state, alpha, superview chain (under NSTitlebarView, an
/// accessory or the toolbar?), window title and visible button count; and the window's diagnostics again when
/// the tab bar lays out there for the first time or the accessory count changed (W7SafariShouldRerunDiagnostics).
FOUNDATION_EXPORT void W7SafariObserveTabBarLayout(NSView *tabBar, NSWindow *_Nullable window);
/// AppKit's toolbar view (a title bar child whose class ends in "ToolbarView") and the UnifiedTabBar (an
/// accessory's view or its direct child), never an excluded class; nil when not there.
FOUNDATION_EXPORT NSView *_Nullable W7SafariToolbarView(NSWindow *_Nullable window);
FOUNDATION_EXPORT NSView *_Nullable W7SafariTabBarView(NSWindow *_Nullable window);
/// Per window state (W7SafariChrome.m keeps it as an associated object; W7SafariDiagnostics.m reads it).
@interface W7SafariWindowState : NSObject
@property (nonatomic) BOOL themed;
@property (nonatomic) NSInteger loggedDecision;   // -1 nothing logged, else the last logged decision
@property (nonatomic) NSInteger diagnosticsRuns;   // capped by W7SafariShouldRerunDiagnostics
@property (nonatomic) NSUInteger lastAccessoryCount;  // NSNotFound until the first diagnostics run
@property (nonatomic) BOOL sawTabBar;                  // a UnifiedTabBar has laid out in this window
@property (nonatomic) CFTimeInterval lastTabBarLog;   // -1: never
@property (nonatomic) NSInteger tabBarLines;          // lines logged, capped by W7SafariTabBarLogAllows
@property (nonatomic) BOOL privateWindow;              // the gate could not rule private browsing out: no logging
@property (nonatomic) BOOL gatePending;
@property (nonatomic) BOOL stripCheckPending;      // a menu strip order check is queued
@property (nonatomic) NSInteger menuStripMoves;     // times the strip was moved back to index 0, capped
@property (nonatomic) CFTimeInterval lastFacsimileRefresh;   // W7SafariFacsimileRefreshWindow's throttle
@property (nonatomic) BOOL closeButtonFightLogged;           // a close button's move backed off: logged once per window
@property (nonatomic, weak) id commandBar;                    // the tab bar's W7SafariCommandBar
@property (nonatomic, weak) NSView *orbOverlay;
@property (nonatomic, weak) NSSegmentedControl *backForward;
@property (nonatomic) CGRect lastBandFrame;   // the tab bar in the title bar view, as the bands were drawn
@property (nonatomic) CGRect lastGateFrame;   // the tab bar in the title bar view, as the gate last saw it
@property (nonatomic, strong) NSHashTable<NSView *> *styledButtons;
@property (nonatomic, strong) NSHashTable<NSView *> *styledTabBars;
@end
FOUNDATION_EXPORT W7SafariWindowState *_Nullable W7SafariState(NSWindow *_Nullable window, BOOL create);
FOUNDATION_EXPORT NSView *_Nullable W7SafariTitlebarView(NSWindow *_Nullable window);
FOUNDATION_EXPORT id _Nullable W7SafariControllerForWindow(NSWindow *_Nullable window);
FOUNDATION_EXPORT NSString *W7SafariInsetsString(NSEdgeInsets insets);
/// W7SafariEnsureMenuStripFirst on the next main-queue pass, themed windows only, at most 5 moves per window.
FOUNDATION_EXPORT void W7SafariScheduleMenuStripCheck(NSWindow *window, W7SafariWindowState *state);

/// Autosave off on the window's toolbar when its identifier is one we reorder (any window, themed or not).
FOUNDATION_EXPORT void W7SafariGuardToolbarAutosave(NSWindow *window);

#pragma mark Diagnostics (W7SafariDiagnostics.m)

FOUNDATION_EXPORT void W7SafariDiagnosticsNoteStart(void);
/// The window's diagnostics a second from now (when it is still themed), counting the run.
FOUNDATION_EXPORT void W7SafariScheduleDiagnostics(NSWindow *window, W7SafariWindowState *state);
/// Again when the accessory count moved since the last run (or the tab bar laid out for the first time), within the cap.
FOUNDATION_EXPORT void W7SafariMaybeRerunDiagnostics(NSWindow *window, W7SafariWindowState *state, BOOL firstTabBar);

/// Remembers a styled tab button or tab bar of a themed window, for un-theming.
FOUNDATION_EXPORT void W7SafariTrackStyled(NSWindow *_Nullable window, NSView *view, BOOL isTabBar);

NS_ASSUME_NONNULL_END
