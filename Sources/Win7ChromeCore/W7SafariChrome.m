// Internet Explorer 7-style chrome for Safari, the window side: L0–L3. The private hooks (L4) are
// W7SafariHooks.m, the diagnostics W7SafariDiagnostics.m.
//
// Layers, each guarded and able to fail on its own (Safari's own look stays wherever one does not apply):
//   L0  the gate (W7SafariShouldTheme): a decorated BrowserWindow in Safari's Separate tab layout, not a popup,
//       not full screen and provably not private. Private windows are never themed: no layer acts on them.
//   L1  the pale IE8 band behind the favourites and tab rows with the 1 px line along the tabs' bottom edge, painted over
//       the title bar glass through the generic W7TitlebarBandPainter hook (sampled from the IE8 reference,
//       where those rows are opaque; the caption and navigation row stay on the Aero glass).
//   L2  a click-through overlay drawing the IE7 orbs over the back/forward control, each orb centred in its own
//       segment, only when hook d is not installed.
//   L3  a 22 pt IE7 status bar at the bottom of the content view, with the content's safe area inset.
// Never touched or walked into: the address field (UnifiedField*) and every class W7SafariIsExcludedClassName
// names. Kill switch: `defaults write -g W7SafariChromeDisabled -bool YES` (next Safari launch). The glass tint
// of toolbar buttons is W7SafariGlass.m, the IE8 facsimile tabs W7SafariTabFacsimile.m.
#import "W7SafariInternal.h"
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

/// The glass frame's outer black and inner white lines; none with the frame overlay, where the caption has no side lines.
static const CGFloat kBandSideInset = 2;

#pragma mark - Pure models

BOOL W7SafariShouldTheme(W7SafariGateInputs in) {
    if (in.disabled || !in.isBrowserWindowClass || !in.decorated || !in.controllerFound) return NO;
    if (in.fullScreen) return NO;
    if (!in.popupKnown || in.isPopup) return NO;
    if (!in.isPrivateKnown && !in.browsingModeKnown) return NO;
    if (in.isPrivateKnown && in.isPrivate) return NO;
    if (in.browsingModeKnown && in.browsingMode != 0) return NO;
    return in.standaloneKnown ? in.showsStandaloneTabBar : in.toolbarIdentifierStandalone;
}

BOOL W7SafariToolbarIdentifierIsStandalone(NSString *identifier) {
    return [identifier isKindOfClass:NSString.class] && [identifier containsString:@"StandaloneTabBar"];
}

BOOL W7SafariChromeShouldStart(NSString *bundleID, BOOL disabled) {
    return !disabled && [bundleID isKindOfClass:NSString.class] && [bundleID isEqualToString:@"com.apple.Safari"];
}

static const char *const kExcludedPrefixes[] = {
    "UnifiedField", "InteriorUnifiedField", "_UnifiedFieldImageOffsetCell", "PopupWindowUnifiedFieldViewController",
    "CompletionList", "CompletionWindow", "AutoFill", "AuthenticationPanel", "ToolbarDownloads", "PrivacyReport",
    "LockdownMode",
};

BOOL W7SafariIsExcludedCName(const char *name) {
    if (!name || !*name) return YES;
    static const char kKVO[] = "NSKVONotifying_";   // a KVO subclass is judged by the class it observes
    if (strncmp(name, kKVO, sizeof kKVO - 1) == 0 && name[sizeof kKVO - 1]) name += sizeof kKVO - 1;
    for (size_t i = 0; i < sizeof kExcludedPrefixes / sizeof *kExcludedPrefixes; i++)
        if (strncmp(name, kExcludedPrefixes[i], strlen(kExcludedPrefixes[i])) == 0) return YES;
    return strstr(name, "WebExtension") != NULL;
}

BOOL W7SafariIsExcludedClassName(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0) return YES;
    return W7SafariIsExcludedCName(name.UTF8String);
}

/// the glass tint: this list plus anything of a popover's, judged on whole view trees (W7SafariGlass.m).
BOOL W7SafariIsGlassExcludedCName(const char *name) {
    return W7SafariIsExcludedCName(name) || (name && strstr(name, "Popover") != NULL);
}

/// The first excluded class at or under `v` (at most 8 deep), by its real class (not a KVO subclass). A tree
/// larger than the budget counts as excluded (fail closed).
static const char *W7SafariGlassExcludedBelow(NSView *v, int depth, int *budget) {
    if (!v || depth > 8) return NULL;
    if (--(*budget) < 0) return "(more than 256 views)";
    const char *name = class_getName([v class]);
    if (W7SafariIsGlassExcludedCName(name)) return name;
    for (NSView *sub in v.subviews) {
        const char *found = W7SafariGlassExcludedBelow(sub, depth + 1, budget);
        if (found) return found;
    }
    return NULL;
}

NSString *W7SafariGlassExclusionIn(NSView *view, NSView *stop) {
    if (!view) return @"(nil)";
    int budget = 256;
    const char *found = W7SafariGlassExcludedBelow(view, 0, &budget);
    for (NSView *a = view.superview; !found && a && a != stop; a = a.superview)
        if (W7SafariIsGlassExcludedCName(class_getName([a class]))) found = class_getName([a class]);
    return found ? @(found) : nil;
}

// the glass tint tables and toolbar allow-list (applied in W7SafariGlass.m).

W7SafariGlassTint W7SafariToolbarGlassTint(BOOL backForward) {
    return backForward ? (W7SafariGlassTint){ 0xDCE6F4, 0.90 } : (W7SafariGlassTint){ 0xF7F9FC, 0.75 };
}
BOOL W7SafariGlassShouldStart(BOOL hooksEnabled, BOOL tintDisabled) { return hooksEnabled && !tintDisabled; }

BOOL W7SafariGlassItemAllowed(NSString *identifier) {
    static NSSet<NSString *> *allowed;
    if (!allowed) allowed = [NSSet setWithArray:@[
        @"BackForwardToolbarIdentifier", @"CombinedSidebarTabGroupToolbarIdentifier", @"SidebarToolbarIdentifier",
        @"TabGroupPickerToolbarIdentifier", @"NewTabToolbarIdentifier", @"TabPickerToolbarIdentifier",
        @"ShareToolbarIdentifier", @"ReloadPageToolbarIdentifier", @"HomeToolbarIdentifier", @"HistoryToolbarIdentifier",
        @"TopSitesToolbarIdentifier", @"CloudTabsToolbarIdentifier", @"ToggleBookmarksBarToolbarIdentifier",
        @"PrintToolbarIdentifier", @"MailPageToolbarIdentifier", @"TextSizingToolbarIdentifier",
    ]];
    return [identifier isKindOfClass:NSString.class] && [allowed containsObject:identifier];
}

W7IETabState W7SafariTabState(BOOL active, BOOL selected, BOOL highlighted, BOOL pinned, NSInteger state) {
    (void)pinned; (void)state;
    if (active) return W7IETabSelected;
    if (highlighted || selected) return W7IETabHover;
    return W7IETabNormal;
}

NSString *W7SafariStatusText(NSString *message, NSString *url, BOOL loading) {
    if ([message isKindOfClass:NSString.class] && message.length) return message;
    if ([url isKindOfClass:NSString.class] && url.length) return url;
    return loading ? @"" : @"Done";
}

BOOL W7SafariLoadingStatusIsLoading(int status) { return status != 0; }

CGFloat W7SafariProgressFraction(double estimated, BOOL loading) {
    if (!loading) return -1;
    if (isnan(estimated)) return 0;
    return MAX(0, MIN(1, estimated));
}

W7SafariBandLayout W7SafariBandLayoutFor(CGRect bounds, CGRect toolbar, CGRect tabBar, CGFloat inset) {
    W7SafariBandLayout l = { CGRectZero, CGRectZero };
    if (CGRectIsEmpty(bounds) || CGRectIsEmpty(toolbar)) return l;
    CGFloat bottom = CGRectGetMinY(bounds), top = MIN(CGRectGetMinY(toolbar), CGRectGetMaxY(bounds));
    if (top <= bottom) return l;
    CGFloat x = CGRectGetMinX(bounds) + inset, w = MAX(0, bounds.size.width - 2 * inset);
    if (!CGRectIsEmpty(tabBar)) {
        // The tab bar must lie between the titlebar's bottom and the toolbar (Safari's Separate layout).
        if (CGRectGetMaxY(tabBar) > top + 0.5 || CGRectGetMinY(tabBar) < bottom - 0.5) return l;
        l.tabRow = CGRectMake(x, CGRectGetMinY(tabBar), w, tabBar.size.height);
        if (top - CGRectGetMaxY(tabBar) >= 1)
            l.favoritesRow = CGRectMake(x, CGRectGetMaxY(tabBar), w, top - CGRectGetMaxY(tabBar));
        return l;
    }
    if (top - bottom >= 1) l.favoritesRow = CGRectMake(x, bottom, w, top - bottom);
    return l;
}

BOOL W7SafariThrottleAllows(double now, double last, double interval) { return last < 0 || now - last >= interval; }

static const NSInteger kMaxTabBarLines = 10;

BOOL W7SafariTabBarLogAllows(NSInteger linesSoFar, double now, double last) {
    return linesSoFar < kMaxTabBarLines && W7SafariThrottleAllows(now, last, 1);
}

static const NSInteger kMaxDiagnosticsRuns = 3;

BOOL W7SafariShouldRerunDiagnostics(NSInteger runsSoFar, BOOL accessoriesChanged, BOOL firstTabBarLayout) {
    return runsSoFar < kMaxDiagnosticsRuns && (accessoriesChanged || firstTabBarLayout);
}

NSArray<NSValue *> *W7SafariSegmentRects(CGRect bounds, NSArray<NSNumber *> *widths) {
    NSUInteger n = widths.count;
    if (n == 0) return @[];
    CGFloat fixed = 0;
    NSUInteger autosized = 0;
    for (NSNumber *w in widths) {
        if (w.doubleValue > 0) fixed += w.doubleValue;
        else autosized++;
    }
    CGFloat share = autosized ? MAX(0, bounds.size.width - fixed) / autosized : 0;
    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:n];
    CGFloat x = CGRectGetMinX(bounds);
    for (NSNumber *w in widths) {
        CGFloat width = w.doubleValue > 0 ? w.doubleValue : share;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x, CGRectGetMinY(bounds), width, bounds.size.height)]];
        x += width;
    }
    return rects;
}

/// A square of side min(`maxSide`, the segment's width and height), centred in `segment`.
static CGRect W7SafariOrbIn(CGRect segment, CGFloat maxSide) {
    CGFloat d = MAX(0, MIN(maxSide, MIN(segment.size.width, segment.size.height)));
    return CGRectMake(CGRectGetMidX(segment) - d / 2, CGRectGetMidY(segment) - d / 2, d, d);
}

void W7SafariOverlayOrbRects(NSSegmentedControl *control, CGRect *back, CGRect *forward) {
    NSInteger n = MIN(control.segmentCount, 2);
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) [widths addObject:@([control widthForSegment:i])];
    NSArray<NSValue *> *rects = W7SafariSegmentRects(control.bounds, widths);
    if (back) *back = rects.count > 0 ? W7SafariOrbIn(rects[0].rectValue, W7IEBackOrbSize) : CGRectZero;
    if (forward) *forward = rects.count > 1 ? W7SafariOrbIn(rects[1].rectValue, W7IEForwardOrbSize) : CGRectZero;
}

#pragma mark - Per-window state

@implementation W7SafariWindowState
- (instancetype)init {
    if ((self = [super init])) {
        _loggedDecision = -1;
        _lastBandFrame = _lastGateFrame = CGRectNull;
        _lastAccessoryCount = NSNotFound;
        _lastTabBarLog = -1;
        _privateWindow = YES;   // until a gate read says otherwise
        _styledButtons = [NSHashTable weakObjectsHashTable];
        _styledTabBars = [NSHashTable weakObjectsHashTable];
    }
    return self;
}
@end

static const void *kWindowStateKey = &kWindowStateKey;

W7SafariWindowState *W7SafariState(NSWindow *w, BOOL create) {
    if (!w) return nil;
    W7SafariWindowState *s = objc_getAssociatedObject(w, kWindowStateKey);
    if (!s && create) {
        s = [W7SafariWindowState new];
        objc_setAssociatedObject(w, kWindowStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

BOOL W7SafariWindowIsThemed(NSWindow *w) {
    W7SafariWindowState *s = w ? objc_getAssociatedObject(w, kWindowStateKey) : nil;
    return s.themed;
}

void W7SafariSetWindowThemed(NSWindow *w, BOOL themed) {
    if (!w) return;
    W7SafariState(w, YES).themed = themed;
}

void W7SafariTrackStyled(NSWindow *w, NSView *view, BOOL isTabBar) {
    W7SafariWindowState *s = W7SafariState(w, NO);
    if (!s || !view) return;
    NSHashTable *table = isTabBar ? s.styledTabBars : s.styledButtons;
    if (![table containsObject:view]) [table addObject:view];
}

#pragma mark - Window lookups (bounded, never into excluded classes)

static BOOL W7SafariCNameHasSuffix(const char *name, const char *suffix) {
    size_t n = strlen(name), s = strlen(suffix);
    return n >= s && strcmp(name + n - s, suffix) == 0;
}

NSView *W7SafariTitlebarView(NSWindow *w) { return [w standardWindowButton:NSWindowCloseButton].superview; }

static BOOL W7SafariIsDecorated(NSWindow *w) {
    for (NSView *v in W7SafariTitlebarView(w).subviews) if ([v isKindOfClass:W7TitlebarView.class]) return YES;
    return NO;
}

/// AppKit's toolbar view: a direct child of the title bar view whose class ends in "ToolbarView".
NSView *W7SafariToolbarView(NSWindow *w) {
    for (NSView *v in W7SafariTitlebarView(w).subviews) {
        const char *cls = class_getName(object_getClass(v));
        if (!W7SafariIsExcludedCName(cls) && W7SafariCNameHasSuffix(cls, "ToolbarView")) return v;
    }
    return nil;
}

static BOOL W7SafariIsTabBarView(NSView *v) {
    static Class tabBarClass;
    static BOOL looked;
    if (!looked) { looked = YES; tabBarClass = objc_getClass("UnifiedTabBar"); }
    return v && tabBarClass && [v isKindOfClass:tabBarClass];
}

/// The UnifiedTabBar: an accessory's view, or a direct child of one (nothing deeper).
NSView *W7SafariTabBarView(NSWindow *w) {
    for (NSTitlebarAccessoryViewController *vc in w.titlebarAccessoryViewControllers) {
        if (W7SafariIsExcludedCName(class_getName(object_getClass(vc)))) continue;
        NSView *v = vc.view;
        if (W7SafariIsExcludedCName(class_getName(object_getClass(v)))) continue;
        if (W7SafariIsTabBarView(v)) return v;
        for (NSView *sub in v.subviews) if (W7SafariIsTabBarView(sub)) return sub;
    }
    return nil;
}

static NSSegmentedControl *W7SafariFindSegmented(NSView *v, int depth) {
    if (!v || depth > 2 || W7SafariIsExcludedCName(class_getName(object_getClass(v)))) return nil;
    if ([v isKindOfClass:NSSegmentedControl.class]) return (NSSegmentedControl *)v;
    for (NSView *sub in v.subviews) {
        NSSegmentedControl *c = W7SafariFindSegmented(sub, depth + 1);
        if (c) return c;
    }
    return nil;
}

/// The back/forward control: the view of the BackForwardToolbarIdentifier item (or of its group's subitems).
static NSSegmentedControl *W7SafariBackForwardControl(NSWindow *w) {
    for (NSToolbarItem *item in w.toolbar.items) {
        if (![item.itemIdentifier isEqualToString:@"BackForwardToolbarIdentifier"]) continue;
        NSSegmentedControl *c = W7SafariFindSegmented(item.view, 0);
        if (c) return c;
        if ([item isKindOfClass:NSToolbarItemGroup.class]) {
            for (NSToolbarItem *sub in ((NSToolbarItemGroup *)item).subitems) {
                c = W7SafariFindSegmented(sub.view, 0);
                if (c) return c;
            }
        }
    }
    return nil;
}

id W7SafariControllerForWindow(NSWindow *w) {
    Class bwc = objc_getClass("BrowserWindowController");
    if (!bwc || !w) return nil;
    SEL sel = W7SafariSel("browserWindowControllerForWindow:");
    Method m = class_getClassMethod(bwc, sel);
    const char *types = m ? method_getTypeEncoding(m) : NULL;
    id c = nil;
    if (types && strcmp(types, "@24@0:8@16") == 0) c = ((id (*)(id, SEL, id))objc_msgSend)(bwc, sel, w);
    if (!c && [w.windowController isKindOfClass:bwc]) c = w.windowController;
    return [c isKindOfClass:bwc] ? c : nil;
}

#pragma mark - L1: bands

@interface W7SafariBandPainter : NSObject <W7TitlebarBandPainter>
@end
@implementation W7SafariBandPainter
- (void)w7DrawBandsInTitlebarView:(NSView *)view window:(NSWindow *)w context:(CGContextRef)ctx {
    if (!W7SafariWindowIsThemed(w)) return;
    NSView *toolbar = W7SafariToolbarView(w), *tabBar = W7SafariTabBarView(w);
    CGRect tf = toolbar && !toolbar.isHiddenOrHasHiddenAncestor ? [view convertRect:toolbar.bounds fromView:toolbar] : CGRectZero;
    BOOL showsTabBar = tabBar && !tabBar.isHiddenOrHasHiddenAncestor;
    CGRect bf = showsTabBar ? [view convertRect:tabBar.bounds fromView:tabBar] : CGRectZero;
    // Remembered in the title bar view's coordinates, as W7SafariNoteTabBarFrame compares it.
    NSView *titlebar = W7SafariTitlebarView(w);
    W7SafariState(w, YES).lastBandFrame = showsTabBar && titlebar ? [titlebar convertRect:tabBar.bounds fromView:tabBar] : CGRectZero;
    W7SafariBandLayout l = W7SafariBandLayoutFor(view.bounds, tf, bf, W7FrameBorderIsShowing(w) ? 0 : kBandSideInset);
    // IE8 on Windows 7: the favourites and tab rows are one opaque pale band,
    // its 1 px line along the tabs' bottom edge (the facsimile tabs' buttons, else the tab scroll view's), white below.
    if (!CGRectIsEmpty(l.tabRow)) {
        CGFloat lineY = CGRectGetMinY(l.tabRow);
        if (!W7SafariFacsimileLineY(tabBar, view, &lineY)) {
            NSView *scroll = W7SafariIvarView(tabBar, "_scrollView");
            if (scroll) lineY = NSMinY([view convertRect:scroll.bounds fromView:scroll]);
        }
        CGRect band = CGRectIsEmpty(l.favoritesRow) ? l.tabRow : CGRectUnion(l.tabRow, l.favoritesRow);
        W7DrawIETabRowBand(ctx, band, lineY);
    }
}
@end

static W7SafariBandPainter *W7SafariSharedPainter(void) {
    static W7SafariBandPainter *painter;
    if (!painter) painter = [W7SafariBandPainter new];
    return painter;
}

static BOOL gStarted;

/// Re-runs the gate for `w` on the next run-loop pass (once, however often it is asked before then).
static void W7SafariScheduleGate(NSWindow *w, W7SafariWindowState *s) {
    if (!gStarted || s.gatePending) return;
    s.gatePending = YES;
    __weak NSWindow *weakWindow = w;
    __weak W7SafariWindowState *weakState = s;
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
        @try {
            weakState.gatePending = NO;
            NSWindow *win = weakWindow;
            if (win) W7SafariUpdateWindow(win);
        } @catch (NSException *e) { os_log_error(W7Log(), "Safari re-gate failed: %{public}@", e.reason ?: @"unknown"); }
    });
    CFRunLoopWakeUp(main);
}

void W7SafariNoteTabBarFrame(NSView *tabBar, NSWindow *w) {
    W7SafariWindowState *s = W7SafariState(w, NO);
    NSView *titlebar = W7SafariTitlebarView(w);
    if (!s || !titlebar) return;
    CGRect f = tabBar.isHiddenOrHasHiddenAncestor ? CGRectZero : [titlebar convertRect:tabBar.bounds fromView:tabBar];
    if (s.themed && !CGRectEqualToRect(f, s.lastBandFrame)) {
        s.lastBandFrame = f;
        W7TitlebarBandsNeedDisplay(w);
    }
    if (!CGRectEqualToRect(f, s.lastGateFrame)) {
        s.lastGateFrame = f;
        W7SafariScheduleGate(w, s);   // Separate ↔ Compact moves or replaces the tab bar
    }
}

#pragma mark - L2: orb overlay

/// The orbs drawn over the back/forward control, each centred in its own segment (W7SafariOverlayOrbRects) on
/// an opaque capsule across the whole control, so the native glyphs never show and a click on an orb lands in
/// that orb's segment. Transparent to events. Follows the segments' enabled states on each window update (two
/// BOOL compares; a redraw only on a change).
@interface W7SafariOrbOverlay : NSView
@property (nonatomic, weak) NSSegmentedControl *control;
@end
@implementation W7SafariOrbOverlay {
    BOOL _back, _forward;
}
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)viewWillMoveToWindow:(NSWindow *)w {
    [super viewWillMoveToWindow:w];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidUpdateNotification object:nil];
    if (w) [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(w7WindowDidUpdate:)
                                                      name:NSWindowDidUpdateNotification object:w];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)w7WindowDidUpdate:(NSNotification *)n {
    @try {
        NSSegmentedControl *c = self.control;
        BOOL back = c.segmentCount > 0 && [c isEnabledForSegment:0] && c.isEnabled;
        BOOL forward = c.segmentCount > 1 && [c isEnabledForSegment:1] && c.isEnabled;
        if (back != _back || forward != _forward) { _back = back; _forward = forward; self.needsDisplay = YES; }
    } @catch (NSException *e) { os_log_error(W7Log(), "orb overlay update failed: %{public}@", e.reason ?: @"unknown"); }
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    self.needsDisplay = YES;   // segment rects follow the control's width
}
- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        NSSegmentedControl *c = self.control;
        if (!ctx || !c) return;
        W7DrawIENavCapsule(ctx, NSInsetRect(self.bounds, 0.5, 0.5));
        CGRect back, forward;
        W7SafariOverlayOrbRects(c, &back, &forward);
        if (!CGRectIsEmpty(forward)) W7DrawNavButton(ctx, forward, YES, _forward ? W7StateNormal : W7StateDisabled);
        if (!CGRectIsEmpty(back)) W7DrawNavButton(ctx, back, NO, _back ? W7StateNormal : W7StateDisabled);
    } @catch (NSException *e) { os_log_error(W7Log(), "orb overlay draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

static void W7SafariInstallOrbOverlay(NSSegmentedControl *control, W7SafariWindowState *st) {
    if (st.orbOverlay.superview == control) return;
    W7SafariOrbOverlay *overlay = [[W7SafariOrbOverlay alloc] initWithFrame:control.bounds];
    overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    overlay.control = control;
    overlay.wantsLayer = YES;
    overlay.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    [control addSubview:overlay];
    [overlay w7WindowDidUpdate:nil];
    st.orbOverlay = overlay;
}

#pragma mark - L3: status bar

static const void *kStatusBarKey = &kStatusBarKey;

@implementation W7StatusBarView {
    NSString *_message, *_url;
    BOOL _loading;
    double _estimated;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _text = @"Done";
        _progress = -1;
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    }
    return self;
}

- (BOOL)isOpaque { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)mouseDown:(NSEvent *)e {}
- (void)rightMouseDown:(NSEvent *)e {}

- (void)w7Update {
    NSString *text = W7SafariStatusText(_message, _url, _loading);
    CGFloat progress = W7SafariProgressFraction(_estimated, _loading);
    BOOL textChanged = ![text isEqualToString:_text];
    // Redraw for a visible change only: progress in whole percent.
    BOOL progressChanged = (progress < 0) != (_progress < 0) || fabs(progress - _progress) >= 0.01;
    _text = [text copy];
    _progress = progress;
    if (textChanged || progressChanged) {
        self.needsDisplay = YES;
        // Keep the bar above content Safari may have added since.
        NSView *parent = self.superview;
        if (parent && parent.subviews.lastObject != self) [parent addSubview:self positioned:NSWindowAbove relativeTo:nil];
    }
}

- (void)w7SetMessage:(NSString *)message url:(NSString *)url {
    _message = [message copy];
    _url = [url copy];
    [self w7Update];
}

- (void)w7SetLoading:(BOOL)loading progress:(double)estimated {
    _loading = loading;
    _estimated = estimated;
    [self w7Update];
}

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        if (!ctx) return;
        NSRect b = self.bounds;
        W7DrawIEStatusBar(ctx, b);
        CGFloat right = NSMaxX(b) - 6;
        if (_progress >= 0) {
            NSRect trough = NSMakeRect(NSMaxX(b) - W7IEProgressWidth - 20, floor((b.size.height - 1 - 12) / 2), W7IEProgressWidth, 12);
            W7DrawIEProgress(ctx, trough, _progress);
            right = NSMinX(trough) - 8;
        }
        if (_text.length) {
            static NSDictionary *attrs;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
                ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
                attrs = @{ NSFontAttributeName: W7UIFont(11), NSForegroundColorAttributeName: NSColor.blackColor,
                           NSParagraphStyleAttributeName: ps };
            });
            NSFont *font = attrs[NSFontAttributeName];
            CGFloat h = ceil(font.ascender - font.descender);
            [_text drawInRect:NSMakeRect(6, floor((b.size.height - 1 - h) / 2), MAX(0, right - 6), h) withAttributes:attrs];
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "status bar draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

W7StatusBarView *W7SafariStatusBarForWindow(NSWindow *w) {
    return w ? objc_getAssociatedObject(w, kStatusBarKey) : nil;
}

NSString *W7SafariInsetsString(NSEdgeInsets i) {
    return [NSString stringWithFormat:@"{%g,%g,%g,%g}", i.top, i.left, i.bottom, i.right];
}

W7StatusBarView *W7SafariInstallStatusBar(NSWindow *w) {
    @try {
        W7StatusBarView *bar = W7SafariStatusBarForWindow(w);
        if (bar) return bar;
        NSView *content = w.contentView;
        if (!content) return nil;
        NSRect b = content.bounds;
        CGFloat h = W7IEStatusBarHeight;
        bar = [[W7StatusBarView alloc] initWithFrame:NSMakeRect(0, content.isFlipped ? NSMaxY(b) - h : 0, b.size.width, h)];
        bar.autoresizingMask = NSViewWidthSizable | (content.isFlipped ? NSViewMinYMargin : NSViewMaxYMargin);
        NSEdgeInsets before = content.safeAreaInsets;
        [content addSubview:bar positioned:NSWindowAbove relativeTo:nil];
        NSEdgeInsets extra = content.additionalSafeAreaInsets;
        extra.bottom += h;
        content.additionalSafeAreaInsets = extra;
        objc_setAssociatedObject(w, kStatusBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        os_log(W7Log(), "Safari status bar: safeAreaInsets before %{public}@ after %{public}@ (additional %{public}@)",
               W7SafariInsetsString(before), W7SafariInsetsString(content.safeAreaInsets), W7SafariInsetsString(extra));
        return bar;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "status bar install failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

void W7SafariRemoveStatusBar(NSWindow *w) {
    @try {
        W7StatusBarView *bar = W7SafariStatusBarForWindow(w);
        if (!bar) return;
        objc_setAssociatedObject(w, kStatusBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSView *content = bar.superview;
        [bar removeFromSuperview];
        if (content) {
            NSEdgeInsets extra = content.additionalSafeAreaInsets;
            extra.bottom = MAX(0, extra.bottom - W7IEStatusBarHeight);
            content.additionalSafeAreaInsets = extra;
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "status bar removal failed: %{public}@", e.reason ?: @"unknown"); }
}

#pragma mark - Menu strip above the tab bar

BOOL W7SafariMenuStripNeedsMove(NSUInteger stripIndex) { return stripIndex != NSNotFound && stripIndex > 0; }

static const NSInteger kMaxMenuStripMoves = 5;

BOOL W7SafariEnsureMenuStripFirst(NSWindow *w) {
    @try {
        NSArray<NSTitlebarAccessoryViewController *> *accessories = w.titlebarAccessoryViewControllers;
        NSUInteger index = NSNotFound, tabBarIndex = NSNotFound;
        for (NSUInteger i = 0; i < accessories.count; i++) {
            NSTitlebarAccessoryViewController *vc = accessories[i];
            if (index == NSNotFound && [vc isKindOfClass:W7MenuStripController.class]) index = i;
            if (tabBarIndex == NSNotFound && vc.isViewLoaded && (W7SafariIsTabBarView(vc.view) ||
                [vc.view.subviews indexOfObjectPassingTest:^BOOL(NSView *v, NSUInteger j, BOOL *stop) { return W7SafariIsTabBarView(v); }] != NSNotFound))
                tabBarIndex = i;
        }
        if (!W7SafariMenuStripNeedsMove(index)) return NO;
        NSTitlebarAccessoryViewController *strip = accessories[index];
        [w removeTitlebarAccessoryViewControllerAtIndex:(NSInteger)index];
        [w insertTitlebarAccessoryViewController:strip atIndex:0];
        os_log(W7Log(), "Safari chrome: menu strip moved from accessory index %lu to 0 (tab bar accessory at %ld of %lu)",
               (unsigned long)index, tabBarIndex == NSNotFound ? -1L : (long)tabBarIndex, (unsigned long)accessories.count);
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari menu strip reorder failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

/// W7SafariEnsureMenuStripFirst on the next main-queue pass (never inside a layout pass), themed windows only, at
/// most kMaxMenuStripMoves moves per window (Safari re-inserting its tab bar above it for good would stop here).
void W7SafariScheduleMenuStripCheck(NSWindow *w, W7SafariWindowState *st) {
    if (!st.themed || st.stripCheckPending || st.menuStripMoves >= kMaxMenuStripMoves) return;
    st.stripCheckPending = YES;
    __weak NSWindow *weakWindow = w;
    __weak W7SafariWindowState *weakState = st;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            W7SafariWindowState *s = weakState;
            NSWindow *win = weakWindow;
            s.stripCheckPending = NO;
            if (win && s.themed && W7SafariEnsureMenuStripFirst(win)) s.menuStripMoves++;
        } @catch (NSException *e) { os_log_error(W7Log(), "Safari menu strip check failed: %{public}@", e.reason ?: @"unknown"); }
    });
}

#pragma mark - L0: gate, apply, remove

static W7SafariGateInputs W7SafariReadGate(NSWindow *w, id controller) {
    W7SafariGateInputs in;
    memset(&in, 0, sizeof in);
    in.isBrowserWindowClass = strcmp(class_getName(w.class), "BrowserWindow") == 0;
    if (!in.isBrowserWindowClass) return in;
    in.decorated = W7SafariIsDecorated(w);
    in.controllerFound = controller != nil;
    BOOL isPrivate = NO, popup = NO, standalone = NO;
    unsigned long long mode = 0;
    in.isPrivateKnown = W7SafariReadBool(controller, W7SafariSel("isPrivate"), &isPrivate);
    in.isPrivate = isPrivate;
    in.browsingModeKnown = W7SafariReadUInt64(controller, W7SafariSel("browsingMode"), &mode);
    in.browsingMode = mode;
    in.popupKnown = W7SafariReadBool(controller, W7SafariSel("isPopupWindow"), &popup);
    in.isPopup = popup;
    in.fullScreen = (w.styleMask & NSWindowStyleMaskFullScreen) != 0;
    in.standaloneKnown = W7SafariReadBool(controller, W7SafariSel("showsStandaloneUnifiedTabBar"), &standalone);
    in.showsStandaloneTabBar = standalone;
    in.toolbarIdentifierStandalone = W7SafariToolbarIdentifierIsStandalone(w.toolbar.identifier);
    return in;
}

/// With hook a installed, asks Safari to recompute its title bar colour now (it answers the hook).
static void W7SafariRecolorTitlebar(id controller) {
    SEL recolor = W7SafariSel("updateTitlebarColor");
    if (W7SafariColorsHookInstalled() && W7SafariHasTypes(controller, recolor, "v16@0:8"))
        ((void (*)(id, SEL))objc_msgSend)(controller, recolor);
}

static void W7SafariApply(NSWindow *w, id controller, W7SafariWindowState *st) {
    st.themed = YES;
    W7SetTitlebarBandPainter(w, W7SafariSharedPainter());   // L1
    NSSegmentedControl *control = W7SafariBackForwardControl(w);
    st.backForward = control;
    if (control) {
        if (W7SafariBackForwardHookInstalled()) W7SafariApplyBackForward(control);   // d
        else W7SafariInstallOrbOverlay(control, st);                                 // L2
    }
    W7SafariInstallStatusBar(w);                                                     // L3
    W7SafariApplyToolbarOrder(w);                                                    // IE's navigation row
    W7SafariScheduleMenuStripCheck(w, st);                                           // menu strip above the tabs
    W7SafariFeedLoading(controller, NO);
    W7SafariRecolorTitlebar(controller);
    NSView *tabBar = W7SafariTabBarView(w);
    tabBar.needsLayout = YES;
    id buttons = W7SafariIvar(tabBar, "_visibleTabBarButtons");
    if ([buttons conformsToProtocol:@protocol(NSFastEnumeration)])
        for (NSView *b in buttons) if ([b isKindOfClass:NSView.class]) b.needsLayout = YES;
    W7TitlebarBandsNeedDisplay(w);
}

static void W7SafariRemove(NSWindow *w, id controller, W7SafariWindowState *st) {
    st.themed = NO;
    W7SetTitlebarBandPainter(w, nil);
    NSSegmentedControl *control = st.backForward;
    if (control) W7SafariRestoreBackForward(control);
    [st.orbOverlay removeFromSuperview];
    W7SafariRemoveStatusBar(w);
    for (NSView *b in st.styledButtons.allObjects) W7SafariRestoreTabButton(b);
    [st.styledButtons removeAllObjects];
    for (NSView *t in st.styledTabBars.allObjects) W7SafariRestoreTabBar(t);
    [st.styledTabBars removeAllObjects];
    W7SafariGlassRemoveWindow(w);   // toolbar and tab bar glass back to Safari's
    W7SafariRestoreToolbarOrder(w);  // Safari's item order, centring and autosave
    // The menu strip stays at titlebar accessory index 0: it is our own accessory, and index 0 is where
    // W7ChromeController puts it in every decorated window (W7SafariEnsureMenuStripFirst only puts it back there).
    st.lastBandFrame = CGRectNull;
    W7SafariRecolorTitlebar(controller);
}

void W7SafariUpdateWindow(NSWindow *w) {
    @try {
        if (!gStarted || ![w isKindOfClass:NSWindow.class]) return;
        if (strcmp(class_getName(w.class), "BrowserWindow") != 0) return;   // no lookups at all for other windows
        W7SafariGuardToolbarAutosave(w);   // also un-themed windows sharing a reordered toolbar
        id controller = W7SafariControllerForWindow(w);
        W7SafariGateInputs in = W7SafariReadGate(w, controller);
        BOOL theme = W7SafariShouldTheme(in);
        W7SafariWindowState *st = W7SafariState(w, YES);
        st.privateWindow = (in.isPrivateKnown && in.isPrivate) || (in.browsingModeKnown && in.browsingMode != 0) ||
                           (!in.isPrivateKnown && !in.browsingModeKnown);
        if (st.loggedDecision != theme) {
            st.loggedDecision = theme;
            os_log(W7Log(), "Safari chrome gate %{public}@: %d (decorated %d controller %d private %d/%d mode %d/%llu popup %d/%d "
                            "fullScreen %d standalone %d/%d identifier %d)",
                   NSStringFromClass(w.class), theme, in.decorated, in.controllerFound, in.isPrivateKnown, in.isPrivate,
                   in.browsingModeKnown, in.browsingMode, in.popupKnown, in.isPopup, in.fullScreen, in.standaloneKnown,
                   in.showsStandaloneTabBar, in.toolbarIdentifierStandalone);
        }
        if (theme && !st.themed) W7SafariApply(w, controller, st);
        else if (!theme && st.themed) W7SafariRemove(w, controller, st);
        if (theme) W7SafariGlassUpdateWindow(w);   // toolbar glass, and tab glass for the key state
        if (theme && st.diagnosticsRuns == 0) W7SafariScheduleDiagnostics(w, st);
        else if (theme) W7SafariMaybeRerunDiagnostics(w, st, NO);   // accessories added or removed since
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari window update failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// Marks the chrome started (and installs the hooks, unless `hooks` is NO) without the bundle check or the
/// window observers.
static void W7SafariBegin(BOOL hooks) {
    if (!gStarted) {
        gStarted = YES;
        W7SafariDiagnosticsNoteStart();
    }
    if (hooks) W7SafariInstallHooks();
}

void W7SafariChromeStartForTesting(BOOL installHooks) {
    @try { W7SafariBegin(installHooks); }
    @catch (NSException *e) { os_log_error(W7Log(), "Safari chrome test start failed: %{public}@", e.reason ?: @"unknown"); }
}

void W7SafariChromeStart(void) {
    static BOOL observing;
    if (observing) return;
    @try {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (!W7SafariChromeShouldStart(NSBundle.mainBundle.bundleIdentifier, [defaults boolForKey:@"W7SafariChromeDisabled"])) return;
        observing = YES;
        BOOL hooks = ![defaults boolForKey:@"W7SafariHooksDisabled"];
        if (!hooks) W7SafariReport(@"private hooks disabled (W7SafariHooksDisabled)");
        W7SafariBegin(hooks);
        W7SafariGlassStart(W7SafariGlassShouldStart(hooks, [defaults boolForKey:@"W7SafariGlassTintDisabled"]));
        W7SafariFacsimileStart(W7SafariFacsimileShouldStart(hooks, [defaults boolForKey:@"W7SafariFacsimileTabsDisabled"]));
        W7SafariIETabLayoutSetEnabled(hooks && ![defaults boolForKey:@"W7SafariIETabLayoutDisabled"]);
        W7SafariCommandBarSetEnabled(hooks && ![defaults boolForKey:@"W7SafariCommandBarDisabled"]);
        W7SafariToolbarOrderSetEnabled(![defaults boolForKey:@"W7SafariToolbarOrderDisabled"]);       // public API only
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        void (^update)(NSNotification *) = ^(NSNotification *n) {
            W7SafariUpdateWindow(n.object);
            W7SafariCommandBarRevalidate(n.object, NO);   // ✚ follows the key window's validation (throttled)
        };
        // Resigning key/main re-tints the toolbar glass for the inactive window; the gate itself is unchanged.
        for (NSNotificationName name in @[ NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
                                           NSWindowDidResignKeyNotification, NSWindowDidResignMainNotification,
                                           NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification ])
            [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:update];
        for (NSWindow *w in [NSApp.windows copy]) W7SafariUpdateWindow(w);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari chrome start failed: %{public}@", e.reason ?: @"unknown");
    }
}
