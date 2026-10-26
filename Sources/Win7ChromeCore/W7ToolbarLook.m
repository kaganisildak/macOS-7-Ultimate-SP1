// Windows 7 command-bar look for every app toolbar. Public API only, no hook.
//
// macOS 26/27 toolbar (seen on this macOS in a test window, decorated as decorateWindow leaves it): NSTitlebarView >
// NSToolbarView > NSGlassContainerView > NSView > one NSToolbarPlatterView per item or group > NSGlassEffectView >
// (content holder) > its contentView (NSView) > NSToolbarItemViewer > the item's view: AppKit's NSToolbarButton for an
// image item, the app's own view for a custom-view item (an NSButton, NSSearchToolbarItem's NSSearchToolbarItemView,
// a group's NSToolbarItemGroupPickerView, …). Labels sit in NSToolbarLabelStack views beside the glass container.
//
// The glass's public contentView fills the glass bounds (seen here: both {0,0,w,28}); the item viewer inside it is
// taller (y -23, h 51) and uses autoresizing frames. AppKit resets the glass's style and corner radius (not its tint)
// when it lays the platter out, through the KVO-observable setters.
//
// What is drawn or set, and nothing else:
//   - the band: W7DrawCommandBar (or the window's W7ToolbarLookSetBandFill fill: Messages' Messenger colours)
//     over the toolbar view's rect, painted by the window's Aero title bar (the
//     W7ToolbarLookBandPainterIdentifier painter among the title bar's band painters: the title bar's glass view lies
//     under every AppKit view in the title bar, so the toolbar draws over it; other painters are never touched);
//   - every visible platter: its glass gets the command bar's middle colour (white for a platter holding an
//     editable text field, the search field) through NSGlassEffectView's public tint/style/radius (W7SafariGlassApply
//     saves the originals per glass view and W7SafariGlassRestore puts them back), and an opaque plate as the first
//     subview of the glass's public contentView, drawing the band's own slice (the search box white) under every item
//     view, so the pill and its sheen are hidden; the three glass properties and the contentView are observed with
//     KVO (automatically notified keys only) and, when AppKit resets one or swaps the contentView, the plate is put
//     back first and the values re-applied, at most once per run-loop pass and kMaxReappliesPerSecond times a second
//     per window;
//   - plain button groups (a platter whose controls are all plain NSButtons, or such a button without a platter):
//     each button a click-through Windows 7 face (W7DrawCommandButton hover/pressed, nothing at rest) placed just below
//     it in the glass's public contentView (else the button's superview), above the plate.
// Never changed: item order, labels, images, actions, visibility, isBordered/bezelStyle (a borderless toolbar button
// shrinks on macOS 26+, 28×28 → 21×26, which would move the items), search fields, segmented groups, pop-ups and any
// other custom view. Dark appearance, the kill switch and window close restore everything.
// Kill switch: `defaults write -g W7ToolbarLookDisabled -bool YES`. Verbose: `defaults write -g W7ToolbarVerboseLog
// -bool YES` logs each window's title bar view tree once (class names and frames only).
#import "Win7ChromeCore.h"
#import <objc/runtime.h>

static const void *kToolbarLookKey = &kToolbarLookKey;   // on a window: its W7ToolbarLookState
static const void *kGlassWatcherKey = &kGlassWatcherKey; // on an observed glass: its watcher (outlives the observation)
static const void *kBandFillKey = &kBandFillKey;         // on a window: its band fill, an NSValue pointer
static void *kGlassKVOContext = &kGlassKVOContext;
static NSInteger gDisabledOverride = -1;
static const CGFloat kBandSideInset = 2;   // the glass frame's side lines (none with the frame overlay)
static const CGFloat kGlassRadius = 3;     // Windows 7 command buttons are rounded 3 pt
static const CGFloat kSearchBoxInset = 2;  // the white search box: 24 pt in a 28 pt platter, as the Explorer's
static const NSUInteger kMaxReappliesPerSecond = 10;
NSString *const W7ToolbarLookBandPainterIdentifier = @"com.win7mac.band.toolbar";

#pragma mark - Decision

BOOL W7ToolbarLookDisabled(void) {
    if (gDisabledOverride >= 0) return gDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7ToolbarLookDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

void W7ToolbarLookUseDisabledOverride(NSInteger value) { gDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

static BOOL W7ToolbarVerbose(void) {
    static BOOL verbose;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { verbose = [NSUserDefaults.standardUserDefaults boolForKey:@"W7ToolbarVerboseLog"]; }
        @catch (NSException *e) { verbose = NO; }
    });
    return verbose;
}

BOOL W7ToolbarLookAppliesToBundle(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class]) return YES;
    return ![bundleID isEqualToString:@"com.apple.Safari"] && ![bundleID isEqualToString:@"com.apple.finder"] &&
           ![bundleID isEqualToString:@"com.win7mac.shell"];
}

static NSView *W7ToolbarTitlebar(NSWindow *w) { return [w standardWindowButton:NSWindowCloseButton].superview; }

static BOOL W7ToolbarWindowIsDecorated(NSWindow *w) {
    for (NSView *v in W7ToolbarTitlebar(w).subviews) if ([v isKindOfClass:W7TitlebarView.class]) return YES;
    return NO;
}

BOOL W7ToolbarLookApplies(NSString *bundleID, NSWindow *w, BOOL disabled) {
    @try {
        if (disabled || !w || !W7ToolbarLookAppliesToBundle(bundleID)) return NO;
        NSToolbar *t = w.toolbar;
        if (!t || t.displayMode == NSToolbarDisplayModeLabelOnly) return NO;
        if (W7IsExplorerWindow(w)) return NO;
        return W7ToolbarWindowIsDecorated(w);
    } @catch (NSException *e) {
        return NO;
    }
}

W7SafariGlassTint W7ToolbarLookGlassTint(void) { return (W7SafariGlassTint){ 0xE9F0F8, 0.80 }; }
W7SafariGlassTint W7ToolbarLookSearchGlassTint(void) { return (W7SafariGlassTint){ 0xFFFFFF, 0.90 }; }

static BOOL W7ToolbarIsDark(NSAppearance *a) {
    static NSArray<NSAppearanceName> *names;
    if (!names) names = @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ];
    return a && [[a bestMatchFromAppearancesWithNames:names] isEqualToString:NSAppearanceNameDarkAqua];
}

static BOOL W7ToolbarCNameHasSuffix(const char *name, const char *suffix) {
    size_t n = strlen(name), s = strlen(suffix);
    return n >= s && strcmp(name + n - s, suffix) == 0;
}

/// AppKit's toolbar view: a direct child of the title bar view whose class name ends in "ToolbarView".
static NSView *W7ToolbarViewIn(NSWindow *w) {
    for (NSView *v in W7ToolbarTitlebar(w).subviews)
        if (W7ToolbarCNameHasSuffix(class_getName(object_getClass(v)), "ToolbarView")) return v;
    return nil;
}

#pragma mark - State

@class W7ToolbarButtonFace, W7ToolbarPlate, W7ToolbarGlassWatcher;

/// Per window: the faces placed, the glass views tinted and observed, the plates inserted (all weak: AppKit may drop
/// a viewer at any time), the watcher that re-applies the glass values, and the window's close observer.
@interface W7ToolbarLookState : NSObject
@property (nonatomic, strong) NSHashTable<W7ToolbarButtonFace *> *faces;
@property (nonatomic, strong) NSHashTable<NSView *> *glasses, *observed, *searchGlasses;
@property (nonatomic, strong) NSHashTable<W7ToolbarPlate *> *plates;
@property (nonatomic, strong) W7ToolbarGlassWatcher *watcher;
@property (nonatomic, strong) id closeToken;
@property (nonatomic) NSInteger logged;   // 0 nothing, 1 logged without buttons, 2 logged with buttons
@property (nonatomic) BOOL dumped, plateSkipLogged;
@end
@implementation W7ToolbarLookState
- (void)dealloc {
    if (_closeToken) [NSNotificationCenter.defaultCenter removeObserver:_closeToken];
}
@end

static W7ToolbarLookState *W7ToolbarState(NSWindow *w, BOOL create);
static NSView *W7ToolbarPlateGlass(W7ToolbarLookState *s, NSView *glass, NSView *band);

/// Observes the tinted glass views' public tintColor, style and cornerRadius (KVO, no hook) and, when something other
/// than the look changes one, re-applies the look's values on the next run-loop pass (once per pass, however many
/// changes), at most kMaxReappliesPerSecond times a second; past that it pauses until the next W7ToolbarLookApply.
@interface W7ToolbarGlassWatcher : NSObject
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic) BOOL applying, pending, paused, pauseLogged;
@property (nonatomic) CFAbsoluteTime periodStart;
@property (nonatomic) NSUInteger periodCount;
@end

@implementation W7ToolbarGlassWatcher
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kGlassKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    @try {
        if (self.applying || self.paused || self.pending || !NSThread.isMainThread) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - self.periodStart >= 1 || now < self.periodStart) { self.periodStart = now; self.periodCount = 0; }
        if (++self.periodCount > kMaxReappliesPerSecond) {
            self.paused = YES;
            if (!self.pauseLogged) {
                self.pauseLogged = YES;
                os_log(W7Log(), "toolbar look: glass reset %lu times in a second, re-applying paused until the next update",
                       (unsigned long)self.periodCount);
            }
            return;
        }
        self.pending = YES;
        __weak W7ToolbarGlassWatcher *weak = self;
        CFRunLoopRef main = CFRunLoopGetMain();
        CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{ [weak w7Reapply]; });
        CFRunLoopWakeUp(main);
    } @catch (NSException *e) { os_log_error(W7Log(), "toolbar glass observer failed: %{public}@", e.reason ?: @"unknown"); }
}

- (void)w7Reapply {
    @try {
        self.pending = NO;
        W7ToolbarLookState *s = W7ToolbarState(self.window, NO);
        if (!s || s.watcher != self || self.paused) return;
        self.applying = YES;
        // The plate first (a swapped contentView lost it, a view AppKit inserted below everything covers it; the
        // insert's layout pass may reset the glass), then the glass values.
        NSView *band = W7ToolbarViewIn(self.window);
        for (NSView *glass in s.glasses.allObjects) {
            if (band) W7ToolbarPlateGlass(s, glass, band);
            W7SafariGlassReapply(glass);
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "toolbar glass re-apply failed: %{public}@", e.reason ?: @"unknown"); }
    self.applying = NO;
}
@end

/// The three glass values the look sets, and the contentView (AppKit rebuilds it when the search field expands or
/// collapses, taking the plate with the old one).
static NSArray<NSString *> *W7ToolbarGlassKeys(void) {
    static NSArray<NSString *> *keys;
    if (!keys) keys = @[ @"tintColor", @"style", @"cornerRadius", @"contentView" ];
    return keys;
}

NSArray<NSString *> *W7ToolbarLookObservableGlassKeys(Class cls) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    @try {
        // Automatic notification only: the relaxed unregistration rule (a glass deallocating while observed) needs it.
        if (cls) for (NSString *key in W7ToolbarGlassKeys()) if ([cls automaticallyNotifiesObserversForKey:key]) [out addObject:key];
    } @catch (NSException *e) { [out removeAllObjects]; }
    return out;
}

static void W7ToolbarObserveGlass(W7ToolbarLookState *s, NSView *glass) {
    if (!glass || [s.observed containsObject:glass]) return;
    NSArray<NSString *> *keys = W7ToolbarLookObservableGlassKeys(object_getClass(glass));
    for (NSString *key in keys) [glass addObserver:s.watcher forKeyPath:key options:0 context:kGlassKVOContext];
    objc_setAssociatedObject(glass, kGlassWatcherKey, s.watcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [s.observed addObject:glass];
}

static void W7ToolbarUnobserveGlass(W7ToolbarLookState *s, NSView *glass) {
    if (!glass || ![s.observed containsObject:glass]) return;
    for (NSString *key in W7ToolbarLookObservableGlassKeys(object_getClass(glass))) {   // the same keys (a KVO subclass inherits the answer)
        @try { [glass removeObserver:s.watcher forKeyPath:key context:kGlassKVOContext]; } @catch (NSException *e) {}
    }
    if (objc_getAssociatedObject(glass, kGlassWatcherKey) == s.watcher)
        objc_setAssociatedObject(glass, kGlassWatcherKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [s.observed removeObject:glass];
}

void W7ToolbarLookRestore(NSWindow *w);

static W7ToolbarLookState *W7ToolbarState(NSWindow *w, BOOL create) {
    W7ToolbarLookState *s = w ? objc_getAssociatedObject(w, kToolbarLookKey) : nil;
    if (!s && w && create) {
        s = [W7ToolbarLookState new];
        s.faces = [NSHashTable weakObjectsHashTable];
        s.glasses = [NSHashTable weakObjectsHashTable];
        s.observed = [NSHashTable weakObjectsHashTable];
        s.searchGlasses = [NSHashTable weakObjectsHashTable];
        s.plates = [NSHashTable weakObjectsHashTable];
        s.watcher = [W7ToolbarGlassWatcher new];
        s.watcher.window = w;
        __weak NSWindow *weak = w;
        s.closeToken = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:w queue:nil
                                                                   usingBlock:^(NSNotification *n) {
            @try { W7ToolbarLookRestore(weak); } @catch (NSException *e) {}
        }];
        objc_setAssociatedObject(w, kToolbarLookKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

BOOL W7ToolbarLookIsApplied(NSWindow *w) { return W7ToolbarState(w, NO) != nil; }
NSUInteger W7ToolbarLookButtonCount(NSWindow *w) { return W7ToolbarState(w, NO).faces.allObjects.count; }
NSUInteger W7ToolbarLookGlassCount(NSWindow *w) {
    NSUInteger n = 0;
    for (NSView *g in W7ToolbarState(w, NO).glasses.allObjects) n += W7SafariGlassIsStyled(g);
    return n;
}
static NSView *W7ToolbarGlassContentView(NSView *glass);

/// Plates in place: first in a tinted glass's current contentView (one left in a contentView AppKit swapped out is
/// not counted; it is still removed on restore).
NSUInteger W7ToolbarLookPlateCount(NSWindow *w) {
    W7ToolbarLookState *s = W7ToolbarState(w, NO);
    NSUInteger n = 0;
    for (NSView *glass in s.glasses.allObjects) {
        NSView *first = W7ToolbarGlassContentView(glass).subviews.firstObject;
        n += first && [s.plates containsObject:(W7ToolbarPlate *)first];
    }
    return n;
}

#pragma mark - The flat face

static void W7ToolbarInstallPressMonitor(void);

/// A Windows 7 command button face under one toolbar button: nothing at rest, W7DrawCommandButton on hover and while
/// pressed. Click-through; hover from its own tracking area (entered/exited only, nothing swallowed); pressed from a
/// local mouse-down monitor until the button's tracking loop ends.
@interface W7ToolbarButtonFace : NSView
@property (nonatomic, weak) NSButton *button;
@property (nonatomic, weak) NSView *anchor;   // the face's sibling just above it (the button or the viewer holding it)
@property (nonatomic) BOOL hover, pressed;
@end

@implementation W7ToolbarButtonFace
- (BOOL)isFlipped { return NO; }
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return NO; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    @try {
        for (NSTrackingArea *a in self.trackingAreas) if (a.owner == self) [self removeTrackingArea:a];
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp |
                                                                   NSTrackingInVisibleRect
                                                             owner:self userInfo:nil]];
    } @catch (NSException *e) {}
}

- (void)mouseEntered:(NSEvent *)e { if (!self.hover) { self.hover = YES; self.needsDisplay = YES; } }
- (void)mouseExited:(NSEvent *)e { if (self.hover) { self.hover = NO; self.needsDisplay = YES; } }

/// The button's frame in the face's superview, the face just below its anchor.
- (void)w7Place {
    NSButton *b = self.button;
    NSView *container = self.superview;
    if (!b || !container) return;
    NSRect r = [container convertRect:b.bounds fromView:b];
    if (!NSEqualRects(self.frame, r)) self.frame = r;
}

- (void)w7Moved:(NSNotification *)n { @try { [self w7Place]; } @catch (NSException *e) {} }

- (void)w7Detach {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self removeFromSuperview];
}

- (void)drawRect:(NSRect)dirty {
    @try {
        NSButton *b = self.button;
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        // b.window != self.window: a live resize moved the button into the overflow menu before the end-of-resize pass
        // detaches this face; nothing over the empty glass meanwhile.
        if (!ctx || !b || b.window != self.window || b.isHiddenOrHasHiddenAncestor || !b.isEnabled ||
            W7ToolbarIsDark(self.effectiveAppearance)) return;
        W7ControlState st = self.pressed ? W7StatePressed : self.hover ? W7StateHover : W7StateNormal;
        if (st != W7StateNormal) W7DrawCommandButton(ctx, NSRectToCGRect(self.bounds), st);
    } @catch (NSException *e) { os_log_error(W7Log(), "toolbar face draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

/// The glass's public contentView, else nil (no glass class before macOS 26).
static NSView *W7ToolbarGlassContentView(NSView *glass) {
    if (!glass) return nil;
    if (@available(macOS 26.0, *)) {
        if ([glass isKindOfClass:NSGlassEffectView.class]) return ((NSGlassEffectView *)glass).contentView;
    }
    return nil;
}

/// The glass's public contentView when `b` is inside it, else nil.
static NSView *W7ToolbarGlassContent(NSView *glass, NSView *b) {
    NSView *content = W7ToolbarGlassContentView(glass);
    return content && [b isDescendantOf:content] && content != b ? content : nil;
}

/// The face for `b` (an existing one, moved when AppKit re-parented things), placed below the direct child of its
/// container that holds the button.
static W7ToolbarButtonFace *W7ToolbarPlaceFace(W7ToolbarLookState *s, NSButton *b, NSView *glass) {
    NSView *container = W7ToolbarGlassContent(glass, b) ?: b.superview;
    if (!container) return nil;
    NSView *anchor = b;
    while (anchor.superview && anchor.superview != container) anchor = anchor.superview;
    if (anchor.superview != container) return nil;
    W7ToolbarButtonFace *face = nil;
    for (W7ToolbarButtonFace *f in s.faces) if (f.button == b) { face = f; break; }
    if (face && (face.superview != container || face.anchor != anchor)) {
        [face w7Detach];
        [s.faces removeObject:face];
        face = nil;
    }
    if (!face) {
        face = [[W7ToolbarButtonFace alloc] initWithFrame:NSZeroRect];
        face.wantsLayer = YES;
        face.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        face.button = b;
        face.anchor = anchor;
        [container addSubview:face positioned:NSWindowBelow relativeTo:anchor];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:face selector:@selector(w7Moved:) name:NSViewFrameDidChangeNotification object:b];
        if (anchor != b) [nc addObserver:face selector:@selector(w7Moved:) name:NSViewFrameDidChangeNotification object:anchor];
        [s.faces addObject:face];
        W7ToolbarInstallPressMonitor();
    }
    [face w7Place];
    return face;
}

BOOL W7ToolbarLookPressAt(NSWindow *window, NSPoint locationInWindow) {
    @try {
        W7ToolbarLookState *s = W7ToolbarState(window, NO);
        for (W7ToolbarButtonFace *face in s.faces.allObjects) {
            NSButton *b = face.button;
            if (!face.window || face.window != window || !b || b.window != face.window || b.isHiddenOrHasHiddenAncestor ||
                !b.isEnabled) continue;
            if (!NSPointInRect([face convertPoint:locationInWindow fromView:nil], face.bounds)) continue;
            face.pressed = YES;
            [face display];   // the button's tracking loop runs next; nothing redraws the face during it otherwise
            __weak W7ToolbarButtonFace *weak = face;
            CFRunLoopRef main = CFRunLoopGetMain();
            // After the button's tracking loop (its mode is not in the list), or while a modal dialog it opened runs.
            static NSArray *modes;
            if (!modes) modes = @[ NSDefaultRunLoopMode, NSModalPanelRunLoopMode ];
            CFRunLoopPerformBlock(main, (__bridge CFTypeRef)modes, ^{
                W7ToolbarButtonFace *f = weak;
                f.pressed = NO;
                f.needsDisplay = YES;
            });
            CFRunLoopWakeUp(main);
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

static void W7ToolbarInstallPressMonitor(void) {
    static BOOL installed;
    if (installed) return;
    installed = YES;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
        @try { if (event.window) W7ToolbarLookPressAt(event.window, event.locationInWindow); } @catch (NSException *e) {}
        return event;
    }];
}

#pragma mark - The plate

/// An opaque view at the bottom of a platter glass's contentView: the band's slice of the command bar (the search box
/// white), so the Liquid Glass pill and its sheen do not show through around the item views above it. Click-through.
@interface W7ToolbarPlate : NSView
@property (nonatomic, weak) NSView *band;
@property (nonatomic) BOOL searchBox;
@end

@implementation W7ToolbarPlate
- (BOOL)isFlipped { return NO; }
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return NO; }

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        if (!ctx || W7ToolbarIsDark(self.effectiveAppearance)) return;
        NSView *band = self.band;
        CGRect bounds = NSRectToCGRect(self.bounds);
        CGRect r = band && band.window && band.window == self.window ? NSRectToCGRect([self convertRect:band.bounds fromView:band])
                                                                     : bounds;
        W7ToolbarBandFill fill = W7ToolbarLookBandFill(self.window) ?: W7DrawCommandBar;
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, bounds);
        fill(ctx, r);
        CGContextRestoreGState(ctx);
        if (self.searchBox) W7DrawAddressBar(ctx, CGRectInset(bounds, 0, kSearchBoxInset), NO);
    } @catch (NSException *e) { os_log_error(W7Log(), "toolbar plate draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

NSView *W7ToolbarLookInsertPlate(NSView *container, NSView *band, BOOL searchBox) {
    @try {
        if (!container) return nil;
        W7ToolbarPlate *plate = nil;
        for (NSView *v in container.subviews) if ([v isKindOfClass:W7ToolbarPlate.class]) { plate = (W7ToolbarPlate *)v; break; }
        if (plate && container.subviews.firstObject == plate) {
            if (plate.band != band || plate.searchBox != searchBox) { plate.band = band; plate.searchBox = searchBox; plate.needsDisplay = YES; }
            if (!NSEqualRects(plate.frame, container.bounds)) plate.frame = container.bounds;
            return plate;
        }
        // A container that moves its children in -layout (Auto Layout, a stack) does so on its next layout pass, not
        // inside addSubview:; so the frames are taken after a layout and compared after another one.
        [container layoutSubtreeIfNeeded];
        NSMutableArray<NSView *> *others = [NSMutableArray array];
        NSMutableArray<NSValue *> *frames = [NSMutableArray array];
        for (NSView *v in container.subviews) {
            if (v == plate) continue;
            [others addObject:v];
            [frames addObject:[NSValue valueWithRect:v.frame]];
        }
        if (plate) [plate removeFromSuperview];
        else {
            plate = [[W7ToolbarPlate alloc] initWithFrame:container.bounds];
            plate.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            plate.wantsLayer = YES;
            plate.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
        }
        plate.band = band;
        plate.searchBox = searchBox;
        plate.frame = container.bounds;
        [container addSubview:plate positioned:NSWindowBelow relativeTo:nil];
        [container layoutSubtreeIfNeeded];
        BOOL moved = container.subviews.firstObject != plate || !NSEqualRects(plate.frame, container.bounds);
        for (NSUInteger i = 0; i < others.count; i++) moved = moved || !NSEqualRects(others[i].frame, frames[i].rectValue);
        if (moved) {
            [plate removeFromSuperview];
            for (NSUInteger i = 0; i < others.count; i++)
                if (!NSEqualRects(others[i].frame, frames[i].rectValue)) others[i].frame = frames[i].rectValue;
            return nil;
        }
        plate.needsDisplay = YES;
        return plate;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "toolbar plate failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

/// The plate for a tinted glass's current contentView (W7ToolbarLookInsertPlate: idempotent, a no-op when it is
/// already first), recorded for restore; nil, logged once per window, when the contentView would move its views.
static NSView *W7ToolbarPlateGlass(W7ToolbarLookState *s, NSView *glass, NSView *band) {
    NSView *content = W7ToolbarGlassContentView(glass);
    NSView *plate = content ? W7ToolbarLookInsertPlate(content, band, [s.searchGlasses containsObject:glass]) : nil;
    if (plate) [s.plates addObject:(W7ToolbarPlate *)plate];
    else if (!s.plateSkipLogged) {
        s.plateSkipLogged = YES;
        os_log(W7Log(), "toolbar look: a platter (%{public}@) takes no plate without moving its views; its pill stays visible",
               NSStringFromClass(content.class ?: NSNull.class));
    }
    return plate;
}

#pragma mark - Groups

/// Controls under `v` (never inside another control, never inside a face): at most 12 deep and 64 controls.
static void W7ToolbarCollectControls(NSView *v, int depth, NSMutableArray<NSControl *> *out) {
    if (!v || depth > 12 || out.count >= 64 || [v isKindOfClass:W7ToolbarButtonFace.class]) return;
    if ([v isKindOfClass:NSControl.class]) { [out addObject:(NSControl *)v]; return; }
    for (NSView *sub in v.subviews) W7ToolbarCollectControls(sub, depth + 1, out);
}

/// The NSToolbarPlatterView holding `v` below `stop`, or nil (no platters before macOS 26).
static NSView *W7ToolbarPlatterOf(NSView *v, NSView *stop) {
    static Class platterClass;
    static BOOL looked;
    if (!looked) { looked = YES; platterClass = objc_getClass("NSToolbarPlatterView"); }
    if (!platterClass) return nil;
    for (NSView *p = v.superview; p && p != stop; p = p.superview) if ([p isKindOfClass:platterClass]) return p;
    return nil;
}

/// A platter's glass: a direct child that is an NSGlassEffectView.
static NSView *W7ToolbarPlatterGlass(NSView *platter) {
    static Class glassClass;
    static BOOL looked;
    if (!looked) { looked = YES; glassClass = NSClassFromString(@"NSGlassEffectView"); }
    if (!platter || !glassClass) return nil;
    for (NSView *sub in platter.subviews) if ([sub isKindOfClass:glassClass]) return sub;
    return nil;
}

static BOOL W7ToolbarIsPlainButton(NSControl *c) {
    return [c isKindOfClass:NSButton.class] && ![c isKindOfClass:NSPopUpButton.class];
}

#pragma mark - Band

@interface W7ToolbarBandPainter : NSObject <W7TitlebarBandPainter>
@end
@implementation W7ToolbarBandPainter
- (void)w7DrawBandsInTitlebarView:(NSView *)view window:(NSWindow *)w context:(CGContextRef)ctx {
    if (!W7ToolbarLookIsApplied(w) || W7ToolbarIsDark(view.effectiveAppearance) || !w.toolbar.isVisible) return;
    NSView *tv = W7ToolbarViewIn(w);
    if (!tv || tv.isHiddenOrHasHiddenAncestor) return;
    CGRect r = CGRectIntersection(NSRectToCGRect(view.bounds), NSRectToCGRect([view convertRect:tv.bounds fromView:tv]));
    r = CGRectInset(r, W7FrameBorderIsShowing(w) ? 0 : kBandSideInset, 0);
    if (CGRectIsEmpty(r) || CGRectIsNull(r)) return;
    W7ToolbarBandFill fill = W7ToolbarLookBandFill(w) ?: W7DrawCommandBar;
    fill(ctx, r);
}
@end

static W7ToolbarBandPainter *W7ToolbarSharedPainter(void) {
    static W7ToolbarBandPainter *painter;
    if (!painter) painter = [W7ToolbarBandPainter new];
    return painter;
}

#pragma mark - Band fill

W7ToolbarBandFill W7ToolbarLookBandFill(NSWindow *w) {
    NSValue *v = w ? objc_getAssociatedObject(w, kBandFillKey) : nil;
    return [v isKindOfClass:NSValue.class] ? (W7ToolbarBandFill)v.pointerValue : NULL;
}

void W7ToolbarLookSetBandFill(NSWindow *w, W7ToolbarBandFill fill) {
    @try {
        if (!w || W7ToolbarLookBandFill(w) == fill) return;
        objc_setAssociatedObject(w, kBandFillKey, fill ? [NSValue valueWithPointer:(const void *)fill] : nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        W7TitlebarBandsNeedDisplay(w);
        for (W7ToolbarPlate *plate in W7ToolbarState(w, NO).plates.allObjects) plate.needsDisplay = YES;
    } @catch (NSException *e) { os_log_error(W7Log(), "toolbar band fill failed: %{public}@", e.reason ?: @"unknown"); }
}

#pragma mark - Diagnostics

static void W7ToolbarDumpView(NSView *v, int depth, NSMutableString *out, int *lines) {
    if (!v || depth > 16 || *lines >= 200) return;
    (*lines)++;
    [out appendFormat:@"%*s%s %@%@\n", depth * 2, "", class_getName(object_getClass(v)), NSStringFromRect(v.frame),
                      v.isHidden ? @" hidden" : @""];
    for (NSView *sub in v.subviews) W7ToolbarDumpView(sub, depth + 1, out, lines);
}

NSString *W7ToolbarLookTreeDump(NSWindow *w) {
    @try {
        NSMutableString *out = [NSMutableString string];
        int lines = 0;
        W7ToolbarDumpView(W7ToolbarTitlebar(w), 0, out, &lines);
        return out;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"dump failed: %@", e.reason ?: @"unknown"];
    }
}

static void W7ToolbarLogTree(NSWindow *w) {
    NSArray<NSString *> *lines = [W7ToolbarLookTreeDump(w) componentsSeparatedByString:@"\n"];
    NSUInteger chunks = (lines.count + 24) / 25;
    for (NSUInteger i = 0; i < chunks; i++) {
        NSRange r = NSMakeRange(i * 25, MIN(25, lines.count - i * 25));
        os_log(W7Log(), "toolbar look tree %lu/%lu (%{public}@):\n%{public}@", (unsigned long)i + 1, (unsigned long)chunks,
               NSStringFromClass(w.class), [[lines subarrayWithRange:r] componentsJoinedByString:@"\n"]);
    }
}

#pragma mark - Apply and restore

void W7ToolbarLookRestore(NSWindow *w) {
    @try {
        W7ToolbarLookState *s = W7ToolbarState(w, NO);
        if (!s) return;
        objc_setAssociatedObject(w, kToolbarLookKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (s.closeToken) [NSNotificationCenter.defaultCenter removeObserver:s.closeToken];
        s.closeToken = nil;
        for (NSView *glass in s.observed.allObjects) W7ToolbarUnobserveGlass(s, glass);   // before the values go back
        for (W7ToolbarButtonFace *face in s.faces.allObjects) [face w7Detach];
        for (W7ToolbarPlate *plate in s.plates.allObjects) [plate removeFromSuperview];
        for (NSView *glass in s.glasses.allObjects) W7SafariGlassRestore(glass);
        [s.faces removeAllObjects];
        [s.plates removeAllObjects];
        [s.glasses removeAllObjects];
        [s.searchGlasses removeAllObjects];
        if (W7TitlebarBandPainterForIdentifier(w, W7ToolbarLookBandPainterIdentifier) == W7ToolbarSharedPainter())
            W7SetTitlebarBandPainterForIdentifier(w, W7ToolbarLookBandPainterIdentifier, nil);
    } @catch (NSException *e) { os_log_error(W7Log(), "toolbar look restore failed: %{public}@", e.reason ?: @"unknown"); }
}

/// Whether `controls` hold a visible editable text field (the search field): its platter is the white search box.
static BOOL W7ToolbarHoldsTextField(NSArray<NSControl *> *controls) {
    for (NSControl *c in controls)
        if ([c isKindOfClass:NSTextField.class] && ((NSTextField *)c).isEditable && !c.isHiddenOrHasHiddenAncestor) return YES;
    return NO;
}

void W7ToolbarLookApply(NSWindow *w) {
    @try {
        if (!w) return;
        NSToolbar *t = w.toolbar;
        if (!t || W7ToolbarIsDark(w.effectiveAppearance)) {
            W7ToolbarLookRestore(w);
            return;
        }
        W7ToolbarLookState *s = W7ToolbarState(w, YES);
        s.watcher.paused = NO;   // a full update starts re-applying again
        s.watcher.periodCount = 0;
        if (W7TitlebarBandPainterForIdentifier(w, W7ToolbarLookBandPainterIdentifier) == W7ToolbarSharedPainter())
            W7TitlebarBandsNeedDisplay(w);
        else W7SetTitlebarBandPainterForIdentifier(w, W7ToolbarLookBandPainterIdentifier, W7ToolbarSharedPainter());
        NSView *tv = W7ToolbarViewIn(w);
        if (!tv || !t.isVisible) return;   // nothing to restyle now; the band painter checks visibility when drawing

        NSMutableArray<NSControl *> *controls = [NSMutableArray array];
        W7ToolbarCollectControls(tv, 0, controls);
        // Groups: one per platter (controls without a platter are a group each), in the order found.
        NSMutableArray<NSView *> *keys = [NSMutableArray array];
        NSMutableArray<NSMutableArray<NSControl *> *> *groups = [NSMutableArray array];
        for (NSControl *c in controls) {
            NSView *key = W7ToolbarPlatterOf(c, tv) ?: c;
            NSUInteger i = [keys indexOfObjectIdenticalTo:key];
            if (i == NSNotFound) { [keys addObject:key]; [groups addObject:[NSMutableArray arrayWithObject:c]]; }
            else [groups[i] addObject:c];
        }
        NSHashTable<NSView *> *keepFaces = [NSHashTable weakObjectsHashTable], *keepGlass = [NSHashTable weakObjectsHashTable],
                              *keepPlates = [NSHashTable weakObjectsHashTable];
        NSUInteger faceless = 0, unplated = 0;
        for (NSUInteger i = 0; i < groups.count; i++) {
            BOOL plain = YES, visible = NO;
            for (NSControl *c in groups[i]) {
                plain = plain && W7ToolbarIsPlainButton(c);
                visible = visible || !c.isHiddenOrHasHiddenAncestor;
            }
            if (!visible) continue;
            BOOL platter = keys[i] != groups[i].firstObject;   // label text fields have none: not tinted, not counted
            // Every visible platter: the tint is its glass's (an ancestor of the item's view), the plate goes under the
            // item views; no control is touched.
            NSView *glass = platter ? W7ToolbarPlatterGlass(keys[i]) : nil;
            if (glass && glass.isHiddenOrHasHiddenAncestor) glass = nil;
            if (glass) {
                BOOL text = W7ToolbarHoldsTextField(groups[i]);
                s.watcher.applying = YES;
                BOOL tinted = W7SafariGlassApply(glass, text ? W7ToolbarLookSearchGlassTint() : W7ToolbarLookGlassTint(), YES,
                                                 kGlassRadius);
                s.watcher.applying = NO;
                if (tinted) {
                    [s.glasses addObject:glass];
                    [keepGlass addObject:glass];
                    if (text) [s.searchGlasses addObject:glass];
                    else [s.searchGlasses removeObject:glass];
                    W7ToolbarObserveGlass(s, glass);
                    NSView *plate = W7ToolbarPlateGlass(s, glass, tv);
                    if (plate) [keepPlates addObject:plate];
                    else unplated++;
                } else glass = nil;
            }
            if (!plain) { faceless += platter; continue; }   // faces only for plain NSButtons
            for (NSControl *c in groups[i]) {
                if (c.isHiddenOrHasHiddenAncestor) continue;
                W7ToolbarButtonFace *face = W7ToolbarPlaceFace(s, (NSButton *)c, glass);
                if (face) [keepFaces addObject:face];
            }
        }
        // What no longer qualifies (an item removed or hidden, a group that gained a pop-up) gets its native look back.
        for (W7ToolbarButtonFace *face in s.faces.allObjects)
            if (![keepFaces containsObject:face]) { [face w7Detach]; [s.faces removeObject:face]; }
        for (W7ToolbarPlate *plate in s.plates.allObjects)
            if (![keepPlates containsObject:plate]) { [plate removeFromSuperview]; [s.plates removeObject:plate]; }
        for (NSView *glass in s.glasses.allObjects)
            if (![keepGlass containsObject:glass]) {
                W7ToolbarUnobserveGlass(s, glass);
                W7SafariGlassRestore(glass);
                [s.glasses removeObject:glass];
                [s.searchGlasses removeObject:glass];
            }

        if (W7ToolbarVerbose() && !s.dumped) { s.dumped = YES; W7ToolbarLogTree(w); }
        NSUInteger buttons = s.faces.allObjects.count;
        NSInteger level = buttons ? 2 : t.items.count ? 1 : 0;
        if (level > s.logged) {   // one line per window; a second only when buttons appear after an empty first pass
            s.logged = level;
            os_log(W7Log(), "toolbar look: %lu items, %lu buttons restyled (%lu platters tinted, %lu plated, %lu without a "
                            "plate, %lu groups without faces)",
                   (unsigned long)t.items.count, (unsigned long)buttons, (unsigned long)W7ToolbarLookGlassCount(w),
                   (unsigned long)W7ToolbarLookPlateCount(w), (unsigned long)unplated, (unsigned long)faceless);
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "toolbar look failed: %{public}@", e.reason ?: @"unknown");
        W7ToolbarLookRestore(w);
    }
}

void W7ToolbarLookUpdate(NSWindow *w) {
    @try {
        static NSString *bundleID;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ bundleID = [NSBundle.mainBundle.bundleIdentifier copy]; });
        if (W7ToolbarLookApplies(bundleID, w, W7ToolbarLookDisabled())) W7ToolbarLookApply(w);
        else W7ToolbarLookRestore(w);
    } @catch (NSException *e) { os_log_error(W7Log(), "toolbar look update failed: %{public}@", e.reason ?: @"unknown"); }
}

#pragma mark - Install

/// W7ToolbarLookUpdate on the next run-loop pass (after AppKit's own insertion or layout), once per window.
static void W7ToolbarScheduleUpdate(NSWindow *w) {
    static NSHashTable<NSWindow *> *pending;
    if (!w) return;
    if (!pending) pending = [NSHashTable weakObjectsHashTable];
    if ([pending containsObject:w]) return;
    [pending addObject:w];
    __weak NSWindow *weak = w;
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
        @try {
            NSWindow *win = weak;
            if (!win) return;
            [pending removeObject:win];
            W7ToolbarLookUpdate(win);
        } @catch (NSException *e) { os_log_error(W7Log(), "toolbar look re-apply failed: %{public}@", e.reason ?: @"unknown"); }
    });
    CFRunLoopWakeUp(main);
}

void W7ToolbarLookInstall(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    @try {
        if (!W7ToolbarLookAppliesToBundle(NSBundle.mainBundle.bundleIdentifier)) return;
        if (W7ToolbarLookDisabled()) {
            os_log(W7Log(), "toolbar look: off (W7ToolbarLookDisabled)");
            return;
        }
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        NSOperationQueue *main = NSOperationQueue.mainQueue;
        for (NSNotificationName name in @[ NSToolbarWillAddItemNotification, NSToolbarDidRemoveItemNotification ])
            [nc addObserverForName:name object:nil queue:main usingBlock:^(NSNotification *n) {
                @try {
                    for (NSWindow *w in NSApp.windows) if (w.toolbar && w.toolbar == n.object) W7ToolbarScheduleUpdate(w);
                } @catch (NSException *e) {}
            }];
        [nc addObserverForName:NSWindowDidEndLiveResizeNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            @try { if ([n.object isKindOfClass:NSWindow.class] && W7ToolbarLookIsApplied(n.object)) W7ToolbarScheduleUpdate(n.object); }
            @catch (NSException *e) {}
        }];
        // Window close: each styled window's state observes its own window (W7ToolbarState).
        [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"AppleInterfaceThemeChangedNotification" object:nil
                                                                    queue:main usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                @try { for (NSWindow *w in NSApp.windows) if (w.toolbar) W7ToolbarLookUpdate(w); }
                @catch (NSException *e) { os_log_error(W7Log(), "toolbar look appearance update failed: %{public}@", e.reason ?: @"unknown"); }
            });
        }];
    } @catch (NSException *e) { os_log_error(W7Log(), "toolbar look install failed: %{public}@", e.reason ?: @"unknown"); }
}
