#import "Win7ChromeCore.h"
#import <objc/runtime.h>

static const void *kPrevFrameKey = &kPrevFrameKey;
static void *kTitleCtx = &kTitleCtx;
static void W7TitlebarDrawBands(NSView *view, NSWindow *w, CGContextRef ctx);

/// The program name Windows 7 shows for untitled windows: the running app's localized name, else the
/// bundle's display name or name. Read once; it does not change while the app runs.
static NSString *W7AppDisplayName(void) {
    static NSString *name;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        id candidates[] = { NSRunningApplication.currentApplication.localizedName,
                            info[@"CFBundleDisplayName"], info[@"CFBundleName"] };
        name = @"";
        for (size_t i = 0; i < 3; i++) {
            if ([candidates[i] isKindOfClass:NSString.class] && [candidates[i] length]) { name = [candidates[i] copy]; break; }
        }
    });
    return name;
}

static NSFont *W7TitleFont(void) {
    static NSFont *font; static dispatch_once_t once;
    dispatch_once(&once, ^{ font = W7UIFont(12); });
    return font;
}

BOOL W7TitlebarBlurEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7TitlebarBlur"]; }
        @catch (NSException *e) { enabled = NO; }
    });
    return enabled;
}

/// What a caption button looks like for a hover/pressed state, ignoring whether it is enabled.
static W7ControlState W7CaptionVisualState(NSInteger kind, NSInteger hover, NSInteger pressed) {
    if (pressed == kind && hover == kind) return W7StatePressed;
    if (hover == kind && pressed == W7CaptionHitNone) return W7StateHover;
    return W7StateNormal;
}

NSUInteger W7CaptionRedrawMask(NSInteger oldHover, NSInteger oldPressed, NSInteger newHover, NSInteger newPressed) {
    const NSInteger kinds[] = { W7CaptionMinimize, W7CaptionMaximize, W7CaptionClose };
    NSUInteger mask = 0;
    for (size_t i = 0; i < 3; i++) {
        if (W7CaptionVisualState(kinds[i], oldHover, oldPressed) != W7CaptionVisualState(kinds[i], newHover, newPressed))
            mask |= (NSUInteger)1 << kinds[i];
    }
    return mask;
}

/// A layer-backed view that redraws only when told: no redraw on resize or window changes.
static void W7RedrawOnDemand(NSView *v) {
    v.wantsLayer = YES;
    v.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
}

@interface W7TitlebarView ()
- (void)w7DrawGlassIn:(NSView *)view;
- (void)w7DrawButtonKind:(NSInteger)kind in:(NSView *)view;
@end

/// The glass, the app icon and the title; transparent to events.
@interface W7TitlebarGlass : NSView
@end
@implementation W7TitlebarGlass
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)dirty {
    @try {
        W7_PERF_BEGIN(titlebarGlass);
        [(W7TitlebarView *)self.superview w7DrawGlassIn:self];
        W7_PERF_END(titlebarGlass);
    } @catch (NSException *e) { os_log_error(W7Log(), "titlebar draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

/// One caption button, in its own small layer so a hover change redraws only it.
@interface W7CaptionButtonView : NSView
@property (nonatomic) NSInteger kind;   // W7CaptionMinimize, W7CaptionMaximize or W7CaptionClose
@end
@implementation W7CaptionButtonView
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)dirty {
    @try {
        W7_PERF_BEGIN(captionButton);
        [(W7TitlebarView *)self.superview w7DrawButtonKind:self.kind in:self];
        W7_PERF_END(captionButton);
    } @catch (NSException *e) { os_log_error(W7Log(), "caption button draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

@implementation W7TitlebarView {
    NSVisualEffectView *_effect;   // only with W7TitlebarBlurEnabled
    W7TitlebarGlass *_glass;
    NSArray<W7CaptionButtonView *> *_buttons;
    NSTrackingArea *_tracking;
    NSInteger _hover;   // W7CaptionKind or W7CaptionHitNone
    NSInteger _pressed;
    __weak NSWindow *_observed;
    BOOL _w7DialogCaption;   // close only (maximize too when resizable)
}

- (instancetype)initWithFrame:(NSRect)frame { return [self initWithFrame:frame blur:W7TitlebarBlurEnabled()]; }

- (instancetype)initWithFrame:(NSRect)frame blur:(BOOL)blur {
    if ((self = [super initWithFrame:frame])) {
        _hover = _pressed = W7CaptionHitNone;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        if (blur) {
            _effect = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
            _effect.material = NSVisualEffectMaterialTitlebar;
            _effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            _effect.state = NSVisualEffectStateActive;
            _effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [self addSubview:_effect];
        }
        _glass = [[W7TitlebarGlass alloc] initWithFrame:self.bounds];
        _glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        W7RedrawOnDemand(_glass);
        [self addSubview:_glass];
        const NSInteger kinds[] = { W7CaptionMinimize, W7CaptionMaximize, W7CaptionClose };
        NSMutableArray<W7CaptionButtonView *> *buttons = [NSMutableArray array];
        for (size_t i = 0; i < 3; i++) {
            W7CaptionButtonView *b = [[W7CaptionButtonView alloc] initWithFrame:NSZeroRect];
            b.kind = kinds[i];
            W7RedrawOnDemand(b);
            [self addSubview:b];
            [buttons addObject:b];
        }
        _buttons = [buttons copy];
        [self w7LayoutButtons];
    }
    return self;
}

- (NSArray<NSView *> *)w7CaptionButtonViews { return _buttons; }
- (NSView *)w7GlassView { return _glass; }

- (BOOL)w7DialogCaption { return _w7DialogCaption; }

- (void)setW7DialogCaption:(BOOL)dialog {
    _w7DialogCaption = dialog;
    [self w7LayoutButtons];
    _glass.needsDisplay = YES;
}

/// W7CaptionVisibleButtons for this bar: all three, or a dialog's close (and maximize when resizable).
- (NSUInteger)w7VisibleButtons {
    return W7CaptionVisibleButtons(_w7DialogCaption, self.window.styleMask);
}

- (void)w7LayoutButtons {
    W7CaptionRects r = W7CaptionLayout(self.bounds);
    const NSRect frames[] = { r.minimize, r.maximize, r.close };
    NSUInteger visible = [self w7VisibleButtons];
    for (NSUInteger i = 0; i < _buttons.count && i < 3; i++) {
        if (!NSEqualRects(_buttons[i].frame, frames[i])) _buttons[i].frame = frames[i];
        BOOL hidden = !(visible & ((NSUInteger)1 << _buttons[i].kind));
        if (_buttons[i].isHidden != hidden) _buttons[i].hidden = hidden;
    }
}

- (void)dealloc { [self w7StopObserving]; }

- (void)w7StopObserving {
    NSWindow *o = _observed;
    _observed = nil;
    if (o) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:o];
        @try { [o removeObserver:self forKeyPath:@"title" context:kTitleCtx]; } @catch (NSException *e) {}
    }
}

- (void)viewWillMoveToWindow:(NSWindow *)w {
    [super viewWillMoveToWindow:w];
    [self w7StopObserving];
    if (w) {
        [w addObserver:self forKeyPath:@"title" options:0 context:kTitleCtx];
        _observed = w;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(w7WindowWillClose:)
                                                   name:NSWindowWillCloseNotification object:w];
    }
}

/// In a window's title bar (the caption buttons' container), the Aero bar brings the 8 pt glass frame along
///; a bar placed anywhere else (the render tool's content view) does not.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    @try {
        NSWindow *w = self.window;
        if (w && self.superview && [w standardWindowButton:NSWindowCloseButton].superview == self.superview) W7FrameBorderAttach(w);
    } @catch (NSException *e) { os_log_error(W7Log(), "frame border hookup failed: %{public}@", e.reason ?: @"unknown"); }
}

- (CGFloat)w7GlassHeight {
    NSWindow *w = self.window;
    NSRect b = _glass.bounds;
    if (w && W7IsExplorerWindow(w)) return MAX(NSHeight(b), NSMaxY(b) - NSMinY(W7ExplorerGlassRect(w, _glass)));
    return NSHeight(b);
}

- (void)w7WindowWillClose:(NSNotification *)n {
    @try { [self w7StopObserving]; }
    @catch (NSException *e) { os_log_error(W7Log(), "willClose failed: %{public}@", e.reason ?: @"unknown"); }
}

/// Always the hit view inside our bounds, so subviews never decide window-drag behaviour.
- (NSView *)hitTest:(NSPoint)p {
    NSPoint local = [self convertPoint:p fromView:self.superview];
    return NSPointInRect(local, self.bounds) ? self : nil;
}

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx {
    if (ctx == kTitleCtx) { [self refresh]; return; }
    [super observeValueForKeyPath:kp ofObject:o change:c context:ctx];
}

- (void)refresh {
    if (_w7DialogCaption) [self w7LayoutButtons];   // the dialog may have become resizable or not
    _glass.needsDisplay = YES;
    for (W7CaptionButtonView *b in _buttons) b.needsDisplay = YES;
}

- (void)w7SetHover:(NSInteger)hover pressed:(NSInteger)pressed {
    NSUInteger mask = W7CaptionRedrawMask(_hover, _pressed, hover, pressed);
    _hover = hover;
    _pressed = pressed;
    if (!mask) return;
    for (W7CaptionButtonView *b in _buttons) {
        if (mask & ((NSUInteger)1 << b.kind)) b.needsDisplay = YES;
    }
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    @try { [self refresh]; }
    @catch (NSException *e) { os_log_error(W7Log(), "titlebar backing change failed: %{public}@", e.reason ?: @"unknown"); }
}
- (BOOL)isFlipped { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

#pragma mark Drawing

- (W7ControlState)stateForKind:(W7CaptionKind)k enabled:(BOOL)enabled {
    if (!enabled) return W7StateDisabled;
    return W7CaptionVisualState(k == W7CaptionRestore ? W7CaptionMaximize : k, _hover, _pressed);
}

- (BOOL)w7IsMaximized {
    NSWindow *w = self.window;
    NSScreen *s = w.screen;
    if (!s) return NO;
    return NSEqualRects(w.frame, W7MaximizedFrame(s.frame, W7TaskbarHeight, s == NSScreen.screens.firstObject));
}

/// The glass, icon and title, drawn by the glass view (its bounds are the title bar's).
- (void)w7DrawGlassIn:(NSView *)view {
    NSWindow *w = self.window;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx || !w) return;
    NSRect b = view.bounds;
    BOOL active = w.isMainWindow || w.isKeyWindow;
    // Windows 7 Explorer shows neither an icon nor a title in its caption, and its glass runs on into
    // the navigation bar: both draw the same glass rect (title bar plus nav bar), so the gradient is
    // continuous, and the frame's bottom edge ends up hidden under the opaque command bar.
    BOOL explorer = W7IsExplorerWindow(w);
    CGRect glassRect = explorer ? W7ExplorerGlassRect(w, view) : b;
    // With the frame overlay the caption is one piece with the side glass: square, no side lines.
    // The overlay paints the window's corners with the same slice of the same glass.
    if (W7FrameBorderIsShowing(w)) W7DrawCaptionGlassSlice(ctx, b, glassRect, active);
    else W7DrawGlassFrame(ctx, glassRect, active);
    W7TitlebarDrawBands(view, w, ctx);

    if (!explorer) {
        NSImage *icon = NSApp.applicationIconImage;
        CGFloat iconY = round(NSMaxY(b) - W7TitlebarHeight / 2 - 8);
        [icon drawInRect:NSMakeRect(8, iconY, 16, 16) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                fraction:active ? 1.0 : 0.7 respectFlipped:YES hints:nil];
    }

    W7CaptionRects r = W7CaptionLayout(b);
    NSString *title = explorer ? @"" : W7CaptionTitle(w.title, W7AppDisplayName());
    if (title.length) {
        NSShadow *glow = [NSShadow new];
        glow.shadowColor = [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.7];
        glow.shadowBlurRadius = 8;
        glow.shadowOffset = NSZeroSize;
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary *attrs = @{ NSFontAttributeName: W7TitleFont(),
                                 NSForegroundColorAttributeName: NSColor.blackColor,
                                 NSShadowAttributeName: glow,
                                 NSParagraphStyleAttributeName: ps };
        CGFloat h = ceil(W7TitleFont().ascender - W7TitleFont().descender);
        CGFloat x = 30, maxX = W7CaptionTitleMaxX(r, [self w7VisibleButtons]) - 6;
        NSRect tr = NSMakeRect(x, NSMaxY(b) - W7TitlebarHeight / 2 - h / 2, MAX(0, maxX - x), h);
        [title drawInRect:tr withAttributes:attrs];
    }
}

/// One caption button, filling `view` (its frame is the button's W7CaptionLayout rect).
- (void)w7DrawButtonKind:(NSInteger)kind in:(NSView *)view {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx || !self.window) return;
    W7CaptionKind drawn = (W7CaptionKind)kind;
    if (kind == W7CaptionMaximize && [self w7IsMaximized]) drawn = W7CaptionRestore;
    W7DrawCaptionButton(ctx, view.bounds, drawn, [self stateForKind:(W7CaptionKind)kind enabled:[self w7EnabledKind:kind]]);
}

#pragma mark Events

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
          owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (NSInteger)w7HitForEvent:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    return W7CaptionHitTestVisible(W7CaptionLayout(self.bounds), p, [self w7VisibleButtons]);
}

- (BOOL)w7EnabledKind:(NSInteger)k {
    NSWindow *w = self.window;
    if (k == W7CaptionMinimize) return (w.styleMask & NSWindowStyleMaskMiniaturizable) != 0;
    if (k == W7CaptionMaximize) return (w.styleMask & NSWindowStyleMaskResizable) != 0;
    return k == W7CaptionClose;
}

- (void)mouseMoved:(NSEvent *)e {
    @try {
        NSInteger h = [self w7HitForEvent:e];
        if (h != _hover) [self w7SetHover:h pressed:_pressed];
    } @catch (NSException *x) { os_log_error(W7Log(), "mouseMoved failed: %{public}@", x.reason ?: @"unknown"); }
}
- (void)mouseExited:(NSEvent *)e {
    @try { [self w7SetHover:W7CaptionHitNone pressed:_pressed]; }
    @catch (NSException *x) { os_log_error(W7Log(), "mouseExited failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseDown:(NSEvent *)e {
    @try {
        NSInteger h = [self w7HitForEvent:e];
        if (h != W7CaptionHitNone) {
            if ([self w7EnabledKind:h]) [self w7SetHover:h pressed:h];
            return;
        }
        if (e.clickCount >= 2) { [self w7ToggleMaximize]; return; }
        [self.window performWindowDragWithEvent:e];
    } @catch (NSException *x) { os_log_error(W7Log(), "mouseDown failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseDragged:(NSEvent *)e {
    @try {
        if (_pressed == W7CaptionHitNone) return;
        NSInteger h = [self w7HitForEvent:e];
        if (h != _hover) [self w7SetHover:h pressed:_pressed];
    } @catch (NSException *x) { os_log_error(W7Log(), "mouseDragged failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseUp:(NSEvent *)e {
    @try {
        NSInteger pressed = _pressed;
        NSInteger h = [self w7HitForEvent:e];
        [self w7SetHover:h pressed:W7CaptionHitNone];
        if (pressed == W7CaptionHitNone || h != pressed) return;
        NSWindow *w = self.window;
        switch (pressed) {
            case W7CaptionMinimize: [w miniaturize:self]; break;
            case W7CaptionMaximize: [self w7ToggleMaximize]; break;
            case W7CaptionClose: [w performClose:self]; break;
        }
    } @catch (NSException *x) { os_log_error(W7Log(), "mouseUp failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)w7ToggleMaximize {
    NSWindow *w = self.window;
    if (!w || !(w.styleMask & NSWindowStyleMaskResizable)) return;
    NSScreen *s = w.screen ?: NSScreen.mainScreen;
    if (!s) return;
    NSRect max = W7MaximizedFrame(s.frame, W7TaskbarHeight, s == NSScreen.screens.firstObject);
    NSValue *prev = objc_getAssociatedObject(w, kPrevFrameKey);
    if (NSEqualRects(w.frame, max) && prev) {
        [w setFrame:prev.rectValue display:YES animate:YES];
        objc_setAssociatedObject(w, kPrevFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(w, kPrevFrameKey, [NSValue valueWithRect:w.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [w setFrame:max display:YES animate:YES];
    }
    [self refresh];
}

/// A resize redraws the glass (its width and the title's truncation) and the maximize button (it may
/// have turned into restore); the other buttons' layers just move.
- (void)setFrameSize:(NSSize)s {
    [super setFrameSize:s];   // outside the @try: AppKit's own resize must not be swallowed
    @try {
        [self w7LayoutButtons];
        _glass.needsDisplay = YES;
        for (W7CaptionButtonView *b in _buttons) if (b.kind == W7CaptionMaximize) b.needsDisplay = YES;
    } @catch (NSException *e) { os_log_error(W7Log(), "titlebar resize failed: %{public}@", e.reason ?: @"unknown"); }
}

@end

#pragma mark - Band painter hook point

static const void *kBandPaintersKey = &kBandPaintersKey;   // on a window: NSMutableArray<W7BandPainterEntry *>
static const NSUInteger kMaxBandPainters = 8;
NSString *const W7TitlebarBandPainterDefaultIdentifier = @"com.win7mac.band.default";

@interface W7BandPainterEntry : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) id<W7TitlebarBandPainter> painter;
@end
@implementation W7BandPainterEntry
@end

static NSMutableArray<W7BandPainterEntry *> *W7BandEntries(NSWindow *w, BOOL create) {
    NSMutableArray<W7BandPainterEntry *> *list = w ? objc_getAssociatedObject(w, kBandPaintersKey) : nil;
    if (!list && w && create) {
        list = [NSMutableArray array];
        objc_setAssociatedObject(w, kBandPaintersKey, list, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return list;
}

static void W7TitlebarDrawBands(NSView *view, NSWindow *w, CGContextRef ctx) {
    NSArray<W7BandPainterEntry *> *list = W7BandEntries(w, NO);
    if (!list.count) return;
    for (W7BandPainterEntry *e in [list copy]) {   // a painter may change the list while drawing
        CGContextSaveGState(ctx);
        @try { [e.painter w7DrawBandsInTitlebarView:view window:w context:ctx]; }
        @catch (NSException *ex) { os_log_error(W7Log(), "band painter failed: %{public}@", ex.reason ?: @"unknown"); }
        CGContextRestoreGState(ctx);
    }
}

id<W7TitlebarBandPainter> W7TitlebarBandPainterForIdentifier(NSWindow *w, NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    for (W7BandPainterEntry *e in W7BandEntries(w, NO)) if ([e.identifier isEqualToString:identifier]) return e.painter;
    return nil;
}

NSArray<NSString *> *W7TitlebarBandPainterIdentifiers(NSWindow *w) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (W7BandPainterEntry *e in W7BandEntries(w, NO)) [ids addObject:e.identifier];
    return ids;
}

void W7SetTitlebarBandPainterForIdentifier(NSWindow *w, NSString *identifier, id<W7TitlebarBandPainter> painter) {
    @try {
        if (!w || ![identifier isKindOfClass:NSString.class]) return;
        NSMutableArray<W7BandPainterEntry *> *list = W7BandEntries(w, painter != nil);
        W7BandPainterEntry *found = nil;
        for (W7BandPainterEntry *e in list) if ([e.identifier isEqualToString:identifier]) { found = e; break; }
        if (painter) {
            if (found.painter == painter) return;
            if (found) found.painter = painter;
            else if (list.count >= kMaxBandPainters) {
                os_log_error(W7Log(), "band painter refused: %lu painters already", (unsigned long)list.count);
                return;
            } else {
                W7BandPainterEntry *e = [W7BandPainterEntry new];
                e.identifier = identifier;
                e.painter = painter;
                [list addObject:e];
            }
        } else {
            if (!found) return;
            [list removeObjectIdenticalTo:found];
            if (!list.count) objc_setAssociatedObject(w, kBandPaintersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        W7TitlebarBandsNeedDisplay(w);
    } @catch (NSException *e) { os_log_error(W7Log(), "band painter update failed: %{public}@", e.reason ?: @"unknown"); }
}

id<W7TitlebarBandPainter> W7TitlebarBandPainterForWindow(NSWindow *w) {
    return W7TitlebarBandPainterForIdentifier(w, W7TitlebarBandPainterDefaultIdentifier);
}

void W7TitlebarBandsNeedDisplay(NSWindow *w) {
    @try {
        for (NSView *v in [w standardWindowButton:NSWindowCloseButton].superview.subviews) {
            if ([v isKindOfClass:W7TitlebarView.class]) ((W7TitlebarView *)v).w7GlassView.needsDisplay = YES;
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "band redraw failed: %{public}@", e.reason ?: @"unknown"); }
}

void W7SetTitlebarBandPainter(NSWindow *w, id<W7TitlebarBandPainter> painter) {
    W7SetTitlebarBandPainterForIdentifier(w, W7TitlebarBandPainterDefaultIdentifier, painter);
}
