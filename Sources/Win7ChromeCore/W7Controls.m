// Windows 7 standard controls inside app windows: installs the drawing hooks for
// push buttons, check boxes, radio buttons and scroll bars.
//
// On macOS 26+ a standard NSButton is drawn by a SwiftUI-hosted subview and never calls its cell's draw
// methods. AppKit only draws through the cell when the cell's class overrides a draw method, which it
// checks through -[NSButtonCell _classForOverrideCheck]. That method is swizzled to answer a marker
// subclass for in-scope cells, so they draw through NSButtonCell, whose draw methods are swizzled here.
// Scrollers are switched (isa) to W7AeroScroller, whose knob and slot overrides make AppKit draw them
// through drawRect:.
#import "Win7ChromeCore.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>

NSString *const W7ControlsDisabledKey = @"W7ControlsDisabled";

static const char *const kClassForOverrideCheckTypes = "#16@0:8";
static const char *const kButtonTypeTypes = "Q16@0:8";

#pragma mark - Decisions (pure)

W7ButtonKind W7ButtonKindFor(NSBezelStyle bezelStyle, BOOL bordered, NSButtonType buttonType) {
    if (buttonType == NSButtonTypeSwitch) return W7ButtonKindCheckBox;
    if (buttonType == NSButtonTypeRadio) return W7ButtonKindRadio;
    // 0 is NSBezelStyleAutomatic (macOS 15 SDK); FlexiblePush is the former RegularSquare (2).
    BOOL pushStyle = bezelStyle == 0 || bezelStyle == NSBezelStylePush || bezelStyle == NSBezelStyleFlexiblePush;
    return bordered && pushStyle ? W7ButtonKindPush : W7ButtonKindNone;
}

BOOL W7ShouldDrawW7Button(NSBezelStyle bezelStyle, BOOL bordered, NSButtonType buttonType, BOOL isDark, BOOL inToolbar) {
    return W7ButtonKindFor(bezelStyle, bordered, buttonType) != W7ButtonKindNone && !isDark && !inToolbar;
}

BOOL W7CellClassOverridesDrawing(Class cls) {
    if (!cls) return NO;
    const SEL drawing[] = { @selector(drawWithFrame:inView:), @selector(drawInteriorWithFrame:inView:),
                            @selector(drawBezelWithFrame:inView:), @selector(drawImage:withFrame:inView:),
                            @selector(drawTitle:withFrame:inView:) };
    for (size_t i = 0; i < sizeof drawing / sizeof drawing[0]; i++) {
        if (class_getMethodImplementation(cls, drawing[i]) != class_getMethodImplementation(NSButtonCell.class, drawing[i])) return YES;
    }
    return NO;
}

BOOL W7CellClassNameEligible(NSString *className, BOOL overridesDrawing) {
    if ([className isEqualToString:@"NSButtonCell"]) return YES;
    // AppKit's NSAlert cells (buttons, suppression check box) are plain button cells inside the message box.
    if ([className isEqualToString:@"_NSAlertButtonCell"] || [className isEqualToString:@"_NSAlertCheckboxButtonCell"]) {
        return !overridesDrawing;
    }
    return NO;
}

BOOL W7IsEligibleCellClass(Class cls) {
    if (!cls) return NO;
    static NSMapTable *cache;   // isa class -> @YES / @NO
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    os_unfair_lock_lock(&lock);
    NSNumber *known = [cache objectForKey:(__bridge id)(__bridge void *)cls];
    os_unfair_lock_unlock(&lock);
    if (known) return known.boolValue;
    Class observed = cls;
    // A KVO-observed cell's isa is NSKVONotifying_<class>; judge the observed class.
    if ([NSStringFromClass(cls) hasPrefix:@"NSKVONotifying_"]) observed = class_getSuperclass(cls);
    BOOL eligible = observed && [observed isSubclassOfClass:NSButtonCell.class] &&
                    W7CellClassNameEligible(NSStringFromClass(observed), W7CellClassOverridesDrawing(observed));
    os_unfair_lock_lock(&lock);
    [cache setObject:@(eligible) forKey:(__bridge id)(__bridge void *)cls];
    os_unfair_lock_unlock(&lock);
    return eligible;
}

BOOL W7ShouldForceCellDrawing(Class cellClass, NSBezelStyle bezelStyle, BOOL bordered, NSButtonType buttonType, BOOL inToolbar) {
    return W7IsEligibleCellClass(cellClass) && !inToolbar && W7ButtonKindFor(bezelStyle, bordered, buttonType) != W7ButtonKindNone;
}

BOOL W7ShouldDrawW7Scroller(BOOL isDark) { return !isDark; }

BOOL W7ShouldAdoptScroller(Class instanceClass, BOOL isDark) {
    return instanceClass == NSScroller.class && W7ShouldDrawW7Scroller(isDark);
}

BOOL W7IsDarkAppearanceName(NSAppearanceName name) {
    return [name isEqualToString:NSAppearanceNameDarkAqua];
}

BOOL W7ControlHookSignaturesOK(const char *classForOverrideCheckTypes, const char *buttonTypeTypes) {
    return classForOverrideCheckTypes && buttonTypeTypes &&
           strcmp(classForOverrideCheckTypes, kClassForOverrideCheckTypes) == 0 &&
           strcmp(buttonTypeTypes, kButtonTypeTypes) == 0;
}

CGRect W7ScrollerThumbRect(CGRect bounds, CGRect knobRect, BOOL vertical) {
    if (vertical) return CGRectMake(bounds.origin.x, knobRect.origin.y, bounds.size.width, knobRect.size.height);
    return CGRectMake(knobRect.origin.x, bounds.origin.y, knobRect.size.width, bounds.size.height);
}

/// System colours are catalog colours ("System" list); an app's own colours are anything else.
static BOOL W7IsSystemColor(NSColor *c) {
    @try {
        return c.type == NSColorTypeCatalog && [c.catalogNameComponent isEqualToString:@"System"];
    } @catch (NSException *e) {
        return NO;
    }
}

NSAttributedString *W7ControlTitle(NSAttributedString *title, BOOL enabled) {
    static NSColor *black, *grey;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        black = [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:1];
        grey = [NSColor colorWithSRGBRed:0x83 / 255.0 green:0x83 / 255.0 blue:0x83 / 255.0 alpha:1];
    });
    NSColor *colour = enabled ? black : grey;
    __block NSMutableAttributedString *out;   // copied only when a range changes
    [title enumerateAttribute:NSForegroundColorAttributeName inRange:NSMakeRange(0, title.length) options:0
                   usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (value == colour) return;
        if (!value || ([value isKindOfClass:NSColor.class] && W7IsSystemColor(value))) {
            if (!out) out = [title mutableCopy];
            [out addAttribute:NSForegroundColorAttributeName value:colour range:range];
        }
    }];
    return out ?: title;
}

static const void *kTitleCacheKey = &kTitleCacheKey;

/// The last title a cell recoloured, so an unchanged title is not copied again on every draw.
@interface W7TitleCache : NSObject {
@public
    NSAttributedString *input, *output;
    BOOL enabled;
}
@end
@implementation W7TitleCache
@end

static NSAttributedString *W7CachedControlTitle(NSButtonCell *cell, NSAttributedString *title, BOOL enabled) {
    W7TitleCache *c = objc_getAssociatedObject(cell, kTitleCacheKey);
    if (c && c->enabled == enabled && (c->input == title || [c->input isEqualToAttributedString:title])) return c->output;
    if (!c) {
        c = [W7TitleCache new];
        objc_setAssociatedObject(cell, kTitleCacheKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    c->input = [title copy];
    c->enabled = enabled;
    c->output = W7ControlTitle(c->input, enabled);
    return c->output;
}

#pragma mark - Shared helpers

/// Runs `block` on the main run loop's next turn (common modes, so also during live resize and tracking):
/// never inside the draw or view move that asked for it. Unlike the main dispatch queue, a run loop block is
/// also serviced by a nested run loop started from code already running on the main queue.
static void W7RunOnNextTurn(dispatch_block_t block) {
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(main);
}

static BOOL gInstalled;

static BOOL W7ViewIsDark(NSView *view) {
    NSAppearance *a = view ? view.effectiveAppearance : NSApp.effectiveAppearance;
    return W7IsDarkAppearanceName([a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]);
}

/// Toolbar items keep AppKit's own look (Windows 7 toolbar buttons are flat, not push buttons). A view in a
/// window without a toolbar is never in one; otherwise its superviews are matched against AppKit's toolbar
/// view classes, resolved once (isKindOfClass: also matches their KVO subclasses).
static BOOL W7ViewIsInToolbar(NSView *view) {
    NSWindow *window = view.window;
    if (window && !window.toolbar) return NO;
    static NSArray<Class> *toolbarClasses;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<Class> *found = [NSMutableArray array];
        for (NSString *name in @[@"NSToolbarView", @"NSToolbarItemViewer", @"NSToolbarPlatterView"]) {
            Class c = NSClassFromString(name);
            if (c) [found addObject:c];
        }
        toolbarClasses = [found copy];
    });
    for (NSView *v = view.superview; v; v = v.superview) {
        if (toolbarClasses.count == 0) {   // AppKit renamed them: fall back to the class name
            NSString *name = NSStringFromClass(v.class);
            if ([name hasPrefix:@"NSToolbar"] || [name hasPrefix:@"_NSToolbar"]) return YES;
            continue;
        }
        for (Class c in toolbarClasses) if ([v isKindOfClass:c]) return YES;
    }
    return NO;
}

static NSButtonType W7CellButtonType(NSButtonCell *cell) {
    return (NSButtonType)((NSUInteger (*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"_buttonType"));
}

/// Whether a check box or radio cell shows AppKit's stock images (none, or the shared images of a stock cell of
/// the same type and control size). An app-set image (a star toggle) keeps the app's look.
static BOOL W7CellHasStockImages(NSButtonCell *cell, NSButtonType type) {
    NSImage *image = cell.image, *alternate = cell.alternateImage;
    if (!image && !alternate) return YES;
    static NSMutableDictionary<NSNumber *, NSArray *> *stock;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSNumber *key = @(type * 16 + (NSInteger)cell.controlSize);
    os_unfair_lock_lock(&lock);
    if (!stock) stock = [NSMutableDictionary dictionary];
    NSArray *pair = stock[key];
    os_unfair_lock_unlock(&lock);
    if (!pair) {
        NSButtonCell *reference = [[NSButtonCell alloc] initTextCell:@""];
        [reference setButtonType:type];
        reference.controlSize = cell.controlSize;
        pair = @[reference.image ?: NSNull.null, reference.alternateImage ?: NSNull.null];
        os_unfair_lock_lock(&lock);
        stock[key] = pair;
        os_unfair_lock_unlock(&lock);
    }
    return (!image || image == pair[0]) && (!alternate || alternate == pair[1]);
}

/// The Windows 7 kind to draw for `cell` in `view` now, or None for the original drawing. Only the cell
/// classes AppKit is told to draw through the cell (W7IsEligibleCellClass) are drawn: pop-up cells, app
/// subclasses that override drawing and call super, and the like keep their own drawing.
static W7ButtonKind W7ActiveKind(NSButtonCell *cell, NSView *view) {
    if (!W7IsEligibleCellClass(object_getClass(cell))) return W7ButtonKindNone;
    NSButtonType type = W7CellButtonType(cell);
    if (!W7ShouldDrawW7Button(cell.bezelStyle, cell.isBordered, type, W7ViewIsDark(view), W7ViewIsInToolbar(view))) {
        return W7ButtonKindNone;
    }
    W7ButtonKind kind = W7ButtonKindFor(cell.bezelStyle, cell.isBordered, type);
    if ((kind == W7ButtonKindCheckBox || kind == W7ButtonKindRadio) && !W7CellHasStockImages(cell, type)) return W7ButtonKindNone;
    return kind;
}

/// Runs `draw` in the current context with a bottom-left origin over `rect` (AppKit controls are
/// flipped; the Win7Theme primitives expect an unflipped context).
static void W7DrawUnflipped(CGRect rect, void (^draw)(CGContextRef ctx)) {
    NSGraphicsContext *gc = NSGraphicsContext.currentContext;
    CGContextRef ctx = gc.CGContext;
    if (!ctx) return;
    CGContextSaveGState(ctx);
    if (gc.isFlipped) {
        CGContextTranslateCTM(ctx, 0, CGRectGetMinY(rect) + CGRectGetMaxY(rect));
        CGContextScaleCTM(ctx, 1, -1);
    }
    draw(ctx);
    CGContextRestoreGState(ctx);
}

#pragma mark - Hover tracking

/// Owner of one control's mouse-inside tracking area; for scrollers it also tracks whether the mouse is
/// over the knob. Retained by the control (associated object); the tracking area holds it weakly.
@interface W7HoverTracker : NSObject
@property (nonatomic, weak) NSView *view;
@property (nonatomic) BOOL inside;
@property (nonatomic) BOOL overKnob;
@end

@implementation W7HoverTracker
- (void)updateKnobWithEvent:(NSEvent *)event {
    NSView *v = self.view;
    if (![v isKindOfClass:NSScroller.class]) return;
    NSPoint p = [v convertPoint:event.locationInWindow fromView:nil];
    BOOL over = self.inside && NSPointInRect(p, [(NSScroller *)v rectForPart:NSScrollerKnob]);
    if (over != self.overKnob) { self.overKnob = over; v.needsDisplay = YES; }
}
- (void)mouseEntered:(NSEvent *)event {
    @try { self.inside = YES; [self updateKnobWithEvent:event]; self.view.needsDisplay = YES; }
    @catch (NSException *e) { os_log_error(W7Log(), "hover enter failed: %{public}@", e.reason ?: @"unknown"); }
}
- (void)mouseExited:(NSEvent *)event {
    @try { self.inside = NO; self.overKnob = NO; self.view.needsDisplay = YES; }
    @catch (NSException *e) { os_log_error(W7Log(), "hover exit failed: %{public}@", e.reason ?: @"unknown"); }
}
- (void)mouseMoved:(NSEvent *)event {
    @try { [self updateKnobWithEvent:event]; }
    @catch (NSException *e) { os_log_error(W7Log(), "hover move failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

static const void *kHoverKey = &kHoverKey;

/// The view's tracker, created on first use. The tracking area is added on the next run loop turn,
/// not while the view is drawing.
static W7HoverTracker *W7Hover(NSView *view) {
    W7HoverTracker *t = objc_getAssociatedObject(view, kHoverKey);
    if (t) return t;
    t = [W7HoverTracker new];
    t.view = view;
    objc_setAssociatedObject(view, kHoverKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak NSView *weakView = view;
    __weak W7HoverTracker *weakTracker = t;
    W7RunOnNextTurn(^{
        @try {
            NSView *v = weakView;
            W7HoverTracker *tracker = weakTracker;
            if (!v || !tracker) return;
            NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect;
            if ([v isKindOfClass:NSScroller.class]) opts |= NSTrackingMouseMoved;
            [v addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:opts owner:tracker userInfo:nil]];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "hover tracking failed: %{public}@", e.reason ?: @"unknown");
        }
    });
    return t;
}

/// Hover is tracked only for a button that owns its cell. A cell drawn by a multi-cell view (NSMatrix radios,
/// a cell-based table's check box column) gets no tracker: the view's mouse-inside is not the cell's.
static W7ControlState W7ButtonState(NSButtonCell *cell, NSView *view) {
    if (!cell.isEnabled) return W7StateDisabled;
    if (cell.isHighlighted) return W7StatePressed;
    BOOL ownsCell = [view isKindOfClass:NSButton.class] && ((NSButton *)view).cell == cell;
    if (!ownsCell) return W7StateNormal;
    return W7Hover(view).inside ? W7StateHover : W7StateNormal;
}

#pragma mark - Buttons

/// Never instantiated: -_classForOverrideCheck answers it so AppKit sees draw-method overrides and
/// draws the cell itself. Its overrides only call super.
@interface W7ClassicDrawingButtonCell : NSButtonCell
@end

@implementation W7ClassicDrawingButtonCell
- (void)drawBezelWithFrame:(NSRect)frame inView:(NSView *)view { [super drawBezelWithFrame:frame inView:view]; }
- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view { [super drawInteriorWithFrame:frame inView:view]; }
- (void)drawImage:(NSImage *)image withFrame:(NSRect)frame inView:(NSView *)view { [super drawImage:image withFrame:frame inView:view]; }
- (NSRect)drawTitle:(NSAttributedString *)title withFrame:(NSRect)frame inView:(NSView *)view {
    return [super drawTitle:title withFrame:frame inView:view];
}
@end

/// The 13×13 box centred (on whole points) in the cell's image rect.
static CGRect W7CheckBoxRect(NSButtonCell *cell, NSRect frame) {
    NSRect image = [cell imageRectForBounds:frame];
    return CGRectMake(round(NSMidX(image) - W7CheckBoxSize / 2), round(NSMidY(image) - W7CheckBoxSize / 2),
                      W7CheckBoxSize, W7CheckBoxSize);
}

@interface NSButtonCell (W7Controls)
@end

@implementation NSButtonCell (W7Controls)
// After the swizzle, the w7_ selectors hold the ORIGINAL implementations.

- (Class)w7_classForOverrideCheck {
    Class original = [self w7_classForOverrideCheck];
    static BOOL busy;   // the getters below may ask again
    if (busy || !NSThread.isMainThread) return original;
    busy = YES;
    @try {
        NSView *view = self.controlView;
        if (W7ShouldForceCellDrawing(object_getClass(self), self.bezelStyle, self.isBordered, W7CellButtonType(self),
                                     view && W7ViewIsInToolbar(view))) {
            original = W7ClassicDrawingButtonCell.class;
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "override check hook failed: %{public}@", e.reason ?: @"unknown");
    }
    busy = NO;
    return original;
}

- (void)w7_drawBezelWithFrame:(NSRect)frame inView:(NSView *)view {
    @try {
        if (W7ActiveKind(self, view) == W7ButtonKindPush) {
            NSEdgeInsets ins = view.alignmentRectInsets;
            BOOL flipped = view.isFlipped;
            NSRect r = NSMakeRect(frame.origin.x + ins.left, frame.origin.y + (flipped ? ins.top : ins.bottom),
                                  frame.size.width - ins.left - ins.right, frame.size.height - ins.top - ins.bottom);
            r = [view backingAlignedRect:r options:NSAlignAllEdgesNearest];
            W7ControlState state = W7ButtonState(self, view);
            BOOL isDefault = [self.keyEquivalent isEqualToString:@"\r"];
            W7DrawUnflipped(r, ^(CGContextRef ctx) { W7DrawPushButton(ctx, r, state, isDefault); });
            return;
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "push button drawing failed: %{public}@", e.reason ?: @"unknown");
    }
    [self w7_drawBezelWithFrame:frame inView:view];
}

- (void)w7_drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view {
    @try {
        W7ButtonKind kind = W7ActiveKind(self, view);
        if (kind == W7ButtonKindCheckBox || kind == W7ButtonKindRadio) {
            CGRect box = W7CheckBoxRect(self, frame);
            W7ControlState state = W7ButtonState(self, view);
            NSControlStateValue value = self.state;
            W7DrawUnflipped(box, ^(CGContextRef ctx) {
                if (kind == W7ButtonKindRadio) {
                    W7DrawRadioButton(ctx, box, state, value == NSControlStateValueOn);
                } else {
                    W7CheckValue v = value == NSControlStateValueOn ? W7CheckOn
                                   : value == NSControlStateValueMixed ? W7CheckMixed : W7CheckOff;
                    W7DrawCheckBox(ctx, box, state, v);
                }
            });
            NSAttributedString *title = self.attributedTitle;
            if (title.length > 0) [self drawTitle:title withFrame:[self titleRectForBounds:frame] inView:view];
            return;
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "check box drawing failed: %{public}@", e.reason ?: @"unknown");
    }
    [self w7_drawInteriorWithFrame:frame inView:view];
}

- (NSRect)w7_drawTitle:(NSAttributedString *)title withFrame:(NSRect)frame inView:(NSView *)view {
    NSAttributedString *drawn = title;
    @try {
        if (title.length > 0 && W7ActiveKind(self, view) != W7ButtonKindNone) drawn = W7CachedControlTitle(self, title, self.isEnabled);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "control title failed: %{public}@", e.reason ?: @"unknown");
    }
    return [self w7_drawTitle:drawn withFrame:frame inView:view];
}
@end

#pragma mark - Scrollers

@interface W7AeroScroller : NSScroller
@end

// -class is deliberately NOT overridden to answer NSScroller: AppKit decides whether a scroller
// subclass overrides the knob drawing from its class, and with NSScroller it keeps its layer-backed
// drawing and never calls the overrides below (seen in testing). The class stays an NSScroller
// for isKindOfClass:, KVO subclasses it normally, and an already KVO-observed scroller is never switched.
@implementation W7AeroScroller
- (BOOL)w7_drawsAero { return W7ShouldDrawW7Scroller(W7ViewIsDark(self)); }

- (BOOL)w7_vertical { return self.bounds.size.height >= self.bounds.size.width; }

- (void)drawKnobSlotInRect:(NSRect)slotRect highlight:(BOOL)flag {
    @try {
        if ([self w7_drawsAero]) {
            CGRect b = self.bounds;
            BOOL vertical = [self w7_vertical];
            W7Hover(self);
            W7DrawUnflipped(b, ^(CGContextRef ctx) { W7DrawScrollerTrack(ctx, b, vertical); });
            return;
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "scroller track drawing failed: %{public}@", e.reason ?: @"unknown");
    }
    [super drawKnobSlotInRect:slotRect highlight:flag];
}

- (void)drawKnob {
    @try {
        if ([self w7_drawsAero]) {
            CGRect knob = [self rectForPart:NSScrollerKnob];
            if (CGRectIsEmpty(knob)) return;
            BOOL vertical = [self w7_vertical];
            CGRect thumb = W7ScrollerThumbRect(self.bounds, knob, vertical);
            BOOL dragging = self.hitPart == NSScrollerKnob && (NSEvent.pressedMouseButtons & 1);
            W7ControlState state = dragging ? W7StatePressed : W7Hover(self).overKnob ? W7StateHover : W7StateNormal;
            W7DrawUnflipped(thumb, ^(CGContextRef ctx) { W7DrawScrollerThumb(ctx, thumb, vertical, state); });
            return;
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "scroller thumb drawing failed: %{public}@", e.reason ?: @"unknown");
    }
    [super drawKnob];
}
@end

/// Legacy style for a scroll view that has a Windows 7 scroller, light appearance only.
static BOOL W7ScrollViewWantsLegacy(NSScrollView *sv) {
    // isKindOfClass:, not an exact class match: KVO may have subclassed a switched scroller.
    BOOL aero = [sv.verticalScroller isKindOfClass:W7AeroScroller.class] ||
                [sv.horizontalScroller isKindOfClass:W7AeroScroller.class];
    return aero && !W7ViewIsDark(sv);
}

static void W7AdoptScroller(NSScroller *s) {
    if (!gInstalled || !s.window) return;
    if (!W7ShouldAdoptScroller(object_getClass(s), W7ViewIsDark(s))) return;
    object_setClass(s, W7AeroScroller.class);
    s.needsDisplay = YES;
    NSScrollView *sv = [s.superview isKindOfClass:NSScrollView.class] ? (NSScrollView *)s.superview : nil;
    if (sv && sv.scrollerStyle != NSScrollerStyleLegacy) {
        // Not while the view is moving to its window: the style change re-tiles the scroll view.
        __weak NSScrollView *weakSV = sv;
        W7RunOnNextTurn(^{
            @try {
                NSScrollView *strong = weakSV;
                if (strong && W7ScrollViewWantsLegacy(strong)) strong.scrollerStyle = NSScrollerStyleLegacy;
            } @catch (NSException *e) {
                os_log_error(W7Log(), "legacy scroller style failed: %{public}@", e.reason ?: @"unknown");
            }
        });
    }
}

void W7AdoptScrollersInView(NSView *view) {
    @try {
        if (!gInstalled || !view) return;
        if ([view isKindOfClass:NSScroller.class]) W7AdoptScroller((NSScroller *)view);
        for (NSView *sub in [view.subviews copy]) W7AdoptScrollersInView(sub);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "scroller adoption failed: %{public}@", e.reason ?: @"unknown");
    }
}

@interface NSScroller (W7Controls)
@end

@implementation NSScroller (W7Controls)
- (void)w7_viewDidMoveToWindow {
    [self w7_viewDidMoveToWindow];
    @try { W7AdoptScroller(self); }
    @catch (NSException *e) { os_log_error(W7Log(), "scroller adoption failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

@interface NSScrollView (W7Controls)
@end

@implementation NSScrollView (W7Controls)
// The system's scroll bar preference (and apps) set Overlay again; Windows 7 always shows scroll bars.
- (void)w7_setScrollerStyle:(NSScrollerStyle)style {
    NSScrollerStyle wanted = style;
    @try {
        if (style == NSScrollerStyleOverlay && W7ScrollViewWantsLegacy(self)) wanted = NSScrollerStyleLegacy;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "scroller style guard failed: %{public}@", e.reason ?: @"unknown");
    }
    [self w7_setScrollerStyle:wanted];
}
@end

#pragma mark - Install

BOOL W7InstallControlHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            if ([NSUserDefaults.standardUserDefaults boolForKey:W7ControlsDisabledKey]) {
                os_log(W7Log(), "W7ControlsDisabled set: standard controls keep their own look");
                return;
            }
            SEL overrideSel = NSSelectorFromString(@"_classForOverrideCheck");
            SEL typeSel = NSSelectorFromString(@"_buttonType");
            Method overrideMethod = class_getInstanceMethod(NSButtonCell.class, overrideSel);
            Method typeMethod = class_getInstanceMethod(NSButtonCell.class, typeSel);
            if (![NSButtonCell instancesRespondToSelector:overrideSel] || ![NSButtonCell instancesRespondToSelector:typeSel] ||
                !W7ControlHookSignaturesOK(overrideMethod ? method_getTypeEncoding(overrideMethod) : NULL,
                                           typeMethod ? method_getTypeEncoding(typeMethod) : NULL)) {
                os_log_error(W7Log(), "control hooks not installed: NSButtonCell private methods missing or changed");
                return;
            }
            struct { Class cls; SEL original, replacement; } hooks[] = {
                { NSButtonCell.class, @selector(drawBezelWithFrame:inView:), @selector(w7_drawBezelWithFrame:inView:) },
                { NSButtonCell.class, @selector(drawInteriorWithFrame:inView:), @selector(w7_drawInteriorWithFrame:inView:) },
                { NSButtonCell.class, @selector(drawTitle:withFrame:inView:), @selector(w7_drawTitle:withFrame:inView:) },
                { NSScroller.class, @selector(viewDidMoveToWindow), @selector(w7_viewDidMoveToWindow) },
                { NSScrollView.class, @selector(setScrollerStyle:), @selector(w7_setScrollerStyle:) },
            };
            for (size_t i = 0; i < sizeof hooks / sizeof hooks[0]; i++) {
                if (!W7SwizzleInstanceMethod(hooks[i].cls, hooks[i].original, hooks[i].replacement)) {
                    // Each hook falls back to the original drawing by itself, so the ones already in are
                    // harmless; without all of them, AppKit is never told to draw through the cells.
                    os_log_error(W7Log(), "swizzle of %{public}@ failed: control hooks stay off",
                                 NSStringFromSelector(hooks[i].original));
                    return;
                }
            }
            // Last: only with the drawing hooks in place does AppKit start drawing through the cells.
            if (!W7SwizzleInstanceMethod(NSButtonCell.class, overrideSel, @selector(w7_classForOverrideCheck))) {
                os_log_error(W7Log(), "swizzle of _classForOverrideCheck failed: buttons keep their own look");
            }
            gInstalled = YES;
        } @catch (NSException *e) {
            os_log_error(W7Log(), "control hook install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
    return gInstalled;
}
