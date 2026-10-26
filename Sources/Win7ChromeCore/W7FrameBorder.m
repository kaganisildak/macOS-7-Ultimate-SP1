#import "Win7ChromeCore.h"
#import <objc/message.h>
#import <objc/runtime.h>

// the 8 pt Aero glass frame Windows 7 draws on the left, right and bottom of a window, as a
// borderless child window above the decorated window. It ignores the mouse (resize edges stay the window's),
// follows the window's frame, level and key state, and hides whenever the window is not plainly on screen.
// it also paints over the window's own rounded corners and 1 pt edge (a maximized window's overlay
// only over its top corners), and, where AppKit allows it, gives the window Windows 7 radii (W7FrameCorners.m).

static const void *kFrameBorderKey = &kFrameBorderKey;
static NSInteger gLiveOverlays;
static NSInteger gDisabledOverride = -1;
static NSInteger gVisibilityOverride = -1;

CGRect W7FrameBorderOverlayFrame(CGRect f) {
    CGFloat b = W7FrameBorderWidth;
    return CGRectMake(f.origin.x - b, f.origin.y - b, f.size.width + 2 * b, f.size.height + b);
}

CGRect W7FrameBorderHoleRect(CGRect bounds) {
    CGFloat b = W7FrameBorderWidth;
    CGFloat w = bounds.size.width - 2 * b, h = bounds.size.height - b;
    if (w <= 0 || h <= 0) return CGRectNull;
    return CGRectMake(bounds.origin.x + b, bounds.origin.y + b, w, h);
}

BOOL W7FrameBorderShouldShow(BOOL parentVisible, BOOL miniaturized, BOOL fullScreen, BOOL occluded, BOOL maximized) {
    return W7FrameBorderModeFor(parentVisible, miniaturized, fullScreen, occluded, maximized) == W7FrameBorderModeFramed;
}

W7FrameBorderMode W7FrameBorderModeFor(BOOL parentVisible, BOOL miniaturized, BOOL fullScreen, BOOL occluded, BOOL maximized) {
    if (!parentVisible || miniaturized || fullScreen || occluded) return W7FrameBorderModeHidden;
    return maximized ? W7FrameBorderModeMaximized : W7FrameBorderModeFramed;
}

BOOL W7FrameBorderDisabled(void) {
    if (gDisabledOverride >= 0) return gDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7FrameBorderDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

void W7FrameBorderUseDisabledOverride(NSInteger value) { gDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

void W7FrameBorderUseVisibilityOverride(NSInteger value) { gVisibilityOverride = value < 0 ? -1 : (value ? 1 : 0); }

NSInteger W7FrameBorderLiveOverlayCount(void) { return gLiveOverlays; }

/// Whether the window fills W7MaximizedFrame of its screen (as the caption's maximize button leaves it).
static BOOL W7FrameBorderIsMaximized(NSWindow *w) {
    NSScreen *s = w.screen;
    if (!s) return NO;
    return NSEqualRects(w.frame, W7MaximizedFrame(s.frame, W7TaskbarHeight, s == NSScreen.screens.firstObject));
}

static W7TitlebarView *W7FrameBorderTitlebar(NSWindow *w) {
    for (NSView *v in [w standardWindowButton:NSWindowCloseButton].superview.subviews) {
        if ([v isKindOfClass:W7TitlebarView.class]) return (W7TitlebarView *)v;
    }
    return nil;
}

#pragma mark - Overlay window

/// Draws W7DrawFrameBorder, or for a maximized window W7DrawMaximizedFrameCorners; transparent to events.
@interface W7FrameBorderView : NSView
@property (nonatomic) BOOL active, maximized;
@property (nonatomic) CGFloat captionHeight, topRadius, bottomRadius;
@end

@implementation W7FrameBorderView
- (BOOL)isFlipped { return NO; }
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        if (!ctx) return;
        NSRect b = self.bounds;
        if (self.maximized) W7DrawMaximizedFrameCorners(ctx, W7FrameBorderHoleRect(b), self.topRadius, self.captionHeight, self.active);
        else W7DrawFrameBorder(ctx, b, W7FrameBorderHoleRect(b), self.topRadius, self.bottomRadius, self.captionHeight, self.active);
    } @catch (NSException *e) { os_log_error(W7Log(), "frame border draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

/// The overlay: borderless, clear, shadowless, never key or main, not an accessibility window (the shell's
/// window lists come from Accessibility), and titled "W7FrameBorder" for anything listing windows by name.
@interface W7FrameBorderWindow : NSWindow
@end

@implementation W7FrameBorderWindow
- (instancetype)init {
    self = [super initWithContentRect:NSMakeRect(0, 0, 32, 32) styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered defer:YES];
    if (self) {
        gLiveOverlays++;
        self.releasedWhenClosed = NO;
        self.opaque = NO;
        self.backgroundColor = NSColor.clearColor;
        self.hasShadow = NO;
        self.ignoresMouseEvents = YES;
        self.excludedFromWindowsMenu = YES;
        self.animationBehavior = NSWindowAnimationBehaviorNone;
        self.collectionBehavior = NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenNone;
        self.title = @"W7FrameBorder";
        W7FrameBorderView *v = [[W7FrameBorderView alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
        v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.contentView = v;
    }
    return self;
}
- (void)dealloc { gLiveOverlays--; }
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (BOOL)isAccessibilityElement { return NO; }
@end

#pragma mark - Controller (one per decorated window, owned by it)

// The controller lives as long as its window: closing only hides the overlay, so a window that is closed
// and shown again (isReleasedWhenClosed NO: Settings windows, single-window apps reopened from the Dock)
// gets it back from the key/occlusion notifications of the reopen. The window's deallocation releases the
// controller, whose dealloc closes the overlay.

@interface W7FrameBorder : NSObject
@property (nonatomic, readonly) W7FrameBorderWindow *overlay;
@property (nonatomic, readonly) BOOL showing;
@property (nonatomic, readonly) W7FrameCornerPath cornerPath;
- (instancetype)initWithWindow:(NSWindow *)w;
- (void)sync;
@end

@implementation W7FrameBorder {
    __weak NSWindow *_parent;
    BOOL _fullScreenTransition;
    BOOL _closing;   // from will-close until the main run loop's next pass, when AppKit has ordered the window out
    BOOL _radiusApplied;   // the window has W7FrameOuterRadius / 0 radii from us
    BOOL _radiusChecked;   // they outlived a run-loop turn once (and the radius path was logged)
    BOOL _radiusCheckPending;
}

- (instancetype)initWithWindow:(NSWindow *)w {
    if ((self = [super init])) {
        _parent = w;
        _overlay = [W7FrameBorderWindow new];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        NSArray<NSNotificationName> *names = @[
            NSWindowDidMoveNotification, NSWindowDidResizeNotification, NSWindowDidEndLiveResizeNotification,
            NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification,
            NSWindowDidChangeOcclusionStateNotification, NSWindowDidChangeScreenNotification,
            NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
            NSWindowDidBecomeMainNotification, NSWindowDidResignMainNotification,
        ];
        for (NSNotificationName name in names) [nc addObserver:self selector:@selector(w7Changed:) name:name object:w];
        [nc addObserver:self selector:@selector(w7WillEnterFullScreen:) name:NSWindowWillEnterFullScreenNotification object:w];
        [nc addObserver:self selector:@selector(w7DidExitFullScreen:) name:NSWindowDidExitFullScreenNotification object:w];
        [nc addObserver:self selector:@selector(w7DidExitFullScreen:) name:NSWindowDidEnterFullScreenNotification object:w];
        [nc addObserver:self selector:@selector(w7WillClose:) name:NSWindowWillCloseNotification object:w];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_overlay close];
}

- (void)w7Changed:(NSNotification *)n {
    @try { [self sync]; }
    @catch (NSException *e) { os_log_error(W7Log(), "frame border sync failed: %{public}@", e.reason ?: @"unknown"); }
}

/// Hidden for the whole transition. A failed entry has no notification (only the app's own delegate hears
/// windowDidFailToEnterFullScreen:), so the flag is also dropped if the window is still not full screen
/// once a transition should long be over.
- (void)w7WillEnterFullScreen:(NSNotification *)n {
    _fullScreenTransition = YES;
    [self w7Changed:n];
    __weak W7FrameBorder *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        W7FrameBorder *s = weakSelf;
        NSWindow *p = s ? s->_parent : nil;
        if (!s || !s->_fullScreenTransition || (p.styleMask & NSWindowStyleMaskFullScreen)) return;
        s->_fullScreenTransition = NO;
        [s w7Changed:n];
    });
}

/// Did exit full screen, or did enter it (the mask then carries FullScreen, which keeps the overlay hidden).
- (void)w7DidExitFullScreen:(NSNotification *)n {
    _fullScreenTransition = NO;
    [self w7Changed:n];
}

/// Hides the overlay and keeps the controller for a reopen. Syncs that arrive while AppKit is still closing
/// the window (it is still visible) keep it hidden until the main run loop's next pass.
- (void)w7WillClose:(NSNotification *)n {
    @try {
        _closing = YES;
        [self w7Hide];
        [self w7ApplyRadius:NO];
        // A run-loop block, not dispatch_async: the main queue is not drained while a main-queue block runs a
        // nested run loop (modal sessions), but run-loop blocks run on the loop's next pass in any common mode.
        __weak W7FrameBorder *weakSelf = self;
        CFRunLoopRef main = CFRunLoopGetMain();
        CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
            W7FrameBorder *s = weakSelf;
            if (s) s->_closing = NO;
        });
        CFRunLoopWakeUp(main);
    } @catch (NSException *e) { os_log_error(W7Log(), "frame border close failed: %{public}@", e.reason ?: @"unknown"); }
}

- (void)w7Hide {
    if (_overlay.parentWindow) [_overlay.parentWindow removeChildWindow:_overlay];
    if (_overlay.isVisible) [_overlay orderOut:nil];
    if (_showing) {
        _showing = NO;
        NSWindow *p = _parent;
        if (p) [W7FrameBorderTitlebar(p) refresh];
    }
}

#pragma mark Corner radius path

/// Logs the path when it is first decided (the radius path once it has outlived a run-loop turn) and when the
/// radius path falls back to the wedges.
- (void)w7LogPath:(NSString *)why {
    NSWindow *p = _parent;
    os_log(W7Log(), "frame corners: %{public}s path for window %{public}@ '%{public}@' (%{public}@)",
           _cornerPath == W7FrameCornerPathRadius ? "radius" : "wedge", NSStringFromClass(p.class), p.title ?: @"", why);
}

- (void)w7UseWedges:(NSString *)why {
    NSWindow *p = _parent;
    if (_radiusApplied) {
        _radiusApplied = NO;
        if (p) W7RestoreWindowCornerRadii(p);
    }
    if (_cornerPath == W7FrameCornerPathWedges) return;
    _cornerPath = W7FrameCornerPathWedges;
    [self w7LogPath:why];
}

/// Gives the window Windows 7 radii (W7FrameOuterRadius top, square bottom) while `wanted`, AppKit's own while
/// not (closing, full screen). A window whose radii cannot be set, or are put back by AppKit, keeps the wedges.
- (void)w7ApplyRadius:(BOOL)wanted {
    NSWindow *p = _parent;
    if (!p) return;
    if (!wanted) {
        if (_radiusApplied) { _radiusApplied = NO; W7RestoreWindowCornerRadii(p); }
        return;
    }
    if (_radiusApplied || _cornerPath == W7FrameCornerPathWedges) return;
    if (W7CornerRadiusHookDisabled()) { [self w7UseWedges:@"W7CornerRadiusHookDisabled"]; return; }
    if (!W7CornerRadiusSetterAvailable()) { [self w7UseWedges:@"no corner radius setter with the expected types"]; return; }
    if (!W7SetWindowCornerRadii(p, W7FrameOuterRadius, 0)) {
        W7RestoreWindowCornerRadii(p);
        [self w7UseWedges:@"the radius could not be set or did not read back"];
        return;
    }
    _radiusApplied = YES;
    _cornerPath = W7FrameCornerPathRadius;
    if (_radiusChecked || _radiusCheckPending) return;   // applied again after a close or full screen
    // AppKit could put its radius back on its next pass: check after one run-loop turn, then log.
    _radiusCheckPending = YES;
    __weak W7FrameBorder *weakSelf = self;
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
        @try { [weakSelf w7CheckRadius]; }
        @catch (NSException *e) { os_log_error(W7Log(), "frame corners check failed: %{public}@", e.reason ?: @"unknown"); }
    });
    CFRunLoopWakeUp(main);
}

- (void)w7CheckRadius {
    _radiusCheckPending = NO;
    NSWindow *p = _parent;
    // Closed or full screen before the check: AppKit has its radius back; the next apply checks again.
    if (!p || _cornerPath != W7FrameCornerPathRadius || !_radiusApplied) return;
    if (W7WindowCornerRadiiAre(p, W7FrameOuterRadius, 0)) {
        _radiusChecked = YES;
        [self w7LogPath:@"6 pt top, square bottom; still set after a run-loop turn"];
        return;
    }
    [self w7UseWedges:@"AppKit reset the radius within a run-loop turn"];
    [self sync];
}

#pragma mark Sync

- (void)sync {
    NSWindow *p = _parent;
    if (!p) return;
    BOOL fullScreen = (p.styleMask & NSWindowStyleMaskFullScreen) != 0 || _fullScreenTransition;
    [self w7ApplyRadius:!fullScreen && !_closing];
    BOOL visible = gVisibilityOverride >= 0 ? gVisibilityOverride == 1 : p.isVisible;
    BOOL occluded = gVisibilityOverride >= 0 ? gVisibilityOverride == 0
                                             : (p.occlusionState & NSWindowOcclusionStateVisible) == 0;
    W7FrameBorderMode mode = _closing ? W7FrameBorderModeHidden
                                      : W7FrameBorderModeFor(visible, p.isMiniaturized, fullScreen, occluded, W7FrameBorderIsMaximized(p));
    if (mode == W7FrameBorderModeHidden) { [self w7Hide]; return; }
    W7TitlebarView *bar = W7FrameBorderTitlebar(p);
    {
        W7FrameBorderView *v = (W7FrameBorderView *)_overlay.contentView;
        BOOL active = p.isMainWindow || p.isKeyWindow, maximized = mode == W7FrameBorderModeMaximized;
        CGFloat caption = bar ? bar.w7GlassHeight : W7TitlebarHeight;
        CGFloat top = W7WindowCornerRadius(p, YES), bottom = W7WindowCornerRadius(p, NO);
        if (_radiusApplied && (fabs(top - W7FrameOuterRadius) > 0.01 || fabs(bottom) > 0.01)) {
            [self w7UseWedges:@"AppKit reset the radius"];   // the wedges follow whatever radius the window has now
            top = W7WindowCornerRadius(p, YES);
            bottom = W7WindowCornerRadius(p, NO);
        }
        if (v.active != active || v.maximized != maximized || v.captionHeight != caption || v.topRadius != top
            || v.bottomRadius != bottom) {
            v.active = active;
            v.maximized = maximized;
            v.captionHeight = caption;
            v.topRadius = top;
            v.bottomRadius = bottom;
            v.needsDisplay = YES;
        }
        // No notification announces a level change: a new parent level is picked up on the next move,
        // resize, key/main or occlusion change.
        if (_overlay.level != p.level) _overlay.level = p.level;
        NSRect frame = W7FrameBorderOverlayFrame(p.frame);
        if (!NSEqualRects(_overlay.frame, frame)) [_overlay setFrame:frame display:YES];
        if (_overlay.parentWindow != p) [p addChildWindow:_overlay ordered:NSWindowAbove];
        else if (!_overlay.isVisible) [_overlay orderWindow:NSWindowAbove relativeTo:p.windowNumber];
    }
    if (!_showing) {
        _showing = YES;
        [bar refresh];   // the caption draws its sides itself only without the overlay
    }
}

@end

#pragma mark - Public

BOOL W7FrameBorderAttach(NSWindow *w) {
    @try {
        if (!w || [w isKindOfClass:W7FrameBorderWindow.class]) return NO;
        if (objc_getAssociatedObject(w, kFrameBorderKey)) return YES;
        if (W7FrameBorderDisabled()) return NO;
        W7FrameBorder *b = [[W7FrameBorder alloc] initWithWindow:w];
        objc_setAssociatedObject(w, kFrameBorderKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [b sync];
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "frame border attach failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

NSWindow *W7FrameBorderOverlay(NSWindow *w) {
    W7FrameBorder *b = w ? objc_getAssociatedObject(w, kFrameBorderKey) : nil;
    return b.overlay;
}

BOOL W7FrameBorderIsShowing(NSWindow *w) {
    W7FrameBorder *b = w ? objc_getAssociatedObject(w, kFrameBorderKey) : nil;
    return b.showing;
}

W7FrameCornerPath W7FrameBorderCornerPath(NSWindow *w) {
    W7FrameBorder *b = w ? objc_getAssociatedObject(w, kFrameBorderKey) : nil;
    return b ? b.cornerPath : W7FrameCornerPathUndecided;
}
