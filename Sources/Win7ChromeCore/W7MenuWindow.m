#import "Win7ChromeCore.h"
#import <objc/runtime.h>

static const CGFloat kTitleLeftPad = 8;        // between the gutter and the title
static const CGFloat kTitleShortcutGap = 40;   // from the title's left pad to the shortcut column
static const CGFloat kRightPad = 24;           // after the shortcut column; holds the submenu arrow
static const CGFloat kVerticalPad = 2;         // above the first row and below the last
static const CGFloat kHighlightInset = 3;
static const CGFloat kSubmenuOverlap = 2;
static const CGFloat kDragThreshold = 4;
static const NSTimeInterval kSubmenuDelay = 0.3;
static const NSTimeInterval kPollInterval = 0.03;

#pragma mark - Pure layout

static CGFloat W7RowHeight(W7MenuNode *n) { return n.isSeparator ? W7MenuSeparatorHeight : W7MenuItemHeight; }

CGFloat W7MenuLayoutWidth(CGFloat widestTitle, CGFloat widestShortcut, CGFloat minWidth) {
    CGFloat content = ceil(W7MenuGutterWidth + widestTitle + kTitleShortcutGap + widestShortcut + kRightPad);
    return MAX(MAX(minWidth, W7MenuMinWidth), content);
}

CGFloat W7MenuRowsHeight(NSArray<W7MenuNode *> *nodes) {
    CGFloat h = 0;
    for (W7MenuNode *n in nodes) h += W7RowHeight(n);
    return h;
}

CGFloat W7MenuRowTop(NSArray<W7MenuNode *> *nodes, NSInteger index) {
    CGFloat y = 0;
    NSInteger end = MIN(MAX(index, 0), (NSInteger)nodes.count);
    for (NSInteger i = 0; i < end; i++) y += W7RowHeight(nodes[(NSUInteger)i]);
    return y;
}

NSInteger W7MenuRowAtOffset(NSArray<W7MenuNode *> *nodes, CGFloat offset) {
    if (offset < 0) return NSNotFound;
    CGFloat y = 0;
    for (NSUInteger i = 0; i < nodes.count; i++) {
        y += W7RowHeight(nodes[i]);
        if (offset < y) return (NSInteger)i;
    }
    return NSNotFound;
}

CGRect W7MenuPopUpFrame(CGPoint topLeft, CGSize size, CGRect vis) {
    CGRect f = CGRectMake(topLeft.x, topLeft.y - size.height, size.width, size.height);
    if (CGRectGetMaxX(f) > CGRectGetMaxX(vis)) f.origin.x = CGRectGetMaxX(vis) - size.width;
    if (f.origin.x < CGRectGetMinX(vis)) f.origin.x = CGRectGetMinX(vis);
    if (f.origin.y < CGRectGetMinY(vis)) {
        // Windows opens a context menu upward when it doesn't fit below the point.
        f.origin.y = (topLeft.y + size.height <= CGRectGetMaxY(vis)) ? topLeft.y : CGRectGetMaxY(vis) - size.height;
    }
    if (CGRectGetMaxY(f) > CGRectGetMaxY(vis)) f.origin.y = CGRectGetMaxY(vis) - size.height;
    return f;
}

CGRect W7MenuSubmenuFrame(CGRect parent, CGFloat rowTop, CGSize size, CGRect vis) {
    CGFloat x = CGRectGetMaxX(parent) - kSubmenuOverlap;
    if (x + size.width > CGRectGetMaxX(vis)) x = CGRectGetMinX(parent) - size.width + kSubmenuOverlap;
    if (x < CGRectGetMinX(vis)) x = CGRectGetMinX(vis);
    CGFloat y = rowTop - size.height;
    if (y < CGRectGetMinY(vis)) y = CGRectGetMinY(vis);
    if (y + size.height > CGRectGetMaxY(vis)) y = CGRectGetMaxY(vis) - size.height;
    return CGRectMake(x, y, size.width, size.height);
}

#pragma mark - Helpers

NSFont *W7MenuWindowFont(void) {
    static NSFont *font; static dispatch_once_t once;
    dispatch_once(&once, ^{ font = W7UIFont(12); });
    return font;
}

static NSFont *W7MenuFont(void) { return W7MenuWindowFont(); }

static NSColor *W7MenuTextColor(BOOL enabled) {
    static NSColor *normal, *disabled; static dispatch_once_t once;
    dispatch_once(&once, ^{
        normal = [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:1];
        disabled = [NSColor colorWithSRGBRed:0x6D / 255.0 green:0x6D / 255.0 blue:0x6D / 255.0 alpha:1];
    });
    return enabled ? normal : disabled;
}

static NSRect W7VisibleFrameForPoint(NSPoint p) {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    // The second probe catches a point lying exactly on a screen's top edge.
    for (NSScreen *s in screens) if (NSPointInRect(p, s.frame)) return s.visibleFrame;
    for (NSScreen *s in screens) if (NSPointInRect(NSMakePoint(p.x, p.y - 1), s.frame)) return s.visibleFrame;
    NSScreen *s = NSScreen.mainScreen ?: screens.firstObject;
    return s ? s.visibleFrame : NSMakeRect(-1e6, -1e6, 2e6, 2e6);
}

static NSPoint W7EventScreenPoint(NSEvent *e) {
    NSWindow *w = e.window;
    return w ? [w convertPointToScreen:e.locationInWindow] : e.locationInWindow;
}

static BOOL W7Selectable(W7MenuNode *n) { return n.enabled && !n.isSeparator; }

#pragma mark - Window

@interface W7MenuView : NSView
@end

/// Owns the cascade of menu windows for one popUp call. Windows never point back at the tracker.
@interface W7MenuTracker : NSObject
/// The chosen item itself: delegates may rebuild the menu in menuDidClose:, which would stale an index.
@property (nonatomic, readonly, strong, nullable) NSMenuItem *commitItem;
/// Screen rects (NSValue rects) that end tracking when the mouse enters one; nil for none.
@property (nonatomic, copy, nullable) NSArray<NSValue *> *switchRegions;
/// Index of the region that ended tracking, or NSNotFound.
@property (nonatomic, readonly) NSInteger switchIndex;
/// YES once the root menu window has been ordered front.
@property (nonatomic, readonly) BOOL shown;
/// showMenu:: a menu that has a custom-view item once its delegate updated it is not shown.
@property (nonatomic) BOOL refuseCustomViews;
/// showContextMenu:: nil-target items are validated through this view's responder chain, and it hears
/// willOpenMenu:withEvent: when `contextEvent` is set too.
@property (nonatomic, strong, nullable) NSView *contextView;
@property (nonatomic, strong, nullable) NSEvent *contextEvent;
/// Posts NSMenuDidBeginTrackingNotification (and tells the context view) when the root menu is about to appear.
@property (nonatomic) BOOL announces;
/// YES once the opening announcement went out: the caller then owes the closing one.
@property (nonatomic, readonly) BOOL announced;
- (void)runMenu:(NSMenu *)menu topLeft:(NSPoint)topLeft minWidth:(CGFloat)minWidth;
@end


@interface W7MenuWindow ()
@property (nonatomic, readonly, strong) NSMenu *sourceMenu;
@property (nonatomic, readonly, copy) NSArray<W7MenuNode *> *nodes;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic) NSInteger openSubmenuIndex;
@property (nonatomic, readonly) CGFloat shortcutX;
@end

@implementation W7MenuWindow

- (instancetype)initWithMenu:(NSMenu *)menu nodes:(NSArray<W7MenuNode *> *)nodes minWidth:(CGFloat)minWidth {
    CGFloat titleW = 0, keyW = 0;
    for (W7MenuNode *n in nodes) {
        if (n.isSeparator) continue;
        titleW = MAX(titleW, ceil(W7TextSize(n.title, W7MenuFont()).width));
        if (n.shortcut) keyW = MAX(keyW, ceil(W7TextSize(n.shortcut, W7MenuFont()).width));
    }
    CGFloat width = W7MenuLayoutWidth(titleW, keyW, minWidth);
    NSRect rect = NSMakeRect(0, 0, width, W7MenuRowsHeight(nodes) + 2 * kVerticalPad);
    self = [super initWithContentRect:rect
                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:YES];
    if (self) {
        _sourceMenu = menu;
        _nodes = [nodes copy];
        _selectedIndex = NSNotFound;
        _openSubmenuIndex = NSNotFound;
        _shortcutX = width - kRightPad - keyW;
        self.releasedWhenClosed = NO;
        self.level = NSPopUpMenuWindowLevel;
        self.hasShadow = YES;
        self.opaque = YES;
        self.hidesOnDeactivate = NO;
        self.becomesKeyOnlyIfNeeded = YES;
        self.animationBehavior = NSWindowAnimationBehaviorNone;
        self.collectionBehavior = NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle
                                | NSWindowCollectionBehaviorFullScreenAuxiliary;
        self.contentView = [[W7MenuView alloc] initWithFrame:rect];
    }
    return self;
}

static BOOL sTracking = NO;

static char kLeftClosesRootKey;

void W7MenuSetLeftClosesRoot(NSMenu *menu, BOOL closes) {
    if (!menu) return;
    objc_setAssociatedObject(menu, &kLeftClosesRootKey, closes ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL W7MenuLeftClosesRoot(NSMenu *menu) {
    return menu && [objc_getAssociatedObject(menu, &kLeftClosesRootKey) boolValue];
}

+ (BOOL)isTracking { return sTracking; }

+ (instancetype)previewWindowForMenu:(NSMenu *)menu highlightedRow:(NSInteger)highlightedRow minWidth:(CGFloat)minWidth {
    W7MenuWindow *w = [[self alloc] initWithMenu:menu nodes:W7MenuNodes(menu) minWidth:minWidth];
    w.selectedIndex = highlightedRow;
    return w;
}

+ (void)popUpMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth {
    [self popUpMenu:menu topLeft:screenPoint minWidth:minWidth switchRegions:nil];
}

+ (BOOL)showMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth {
    return [self showMenu:menu topLeft:screenPoint minWidth:minWidth chose:NULL];
}

+ (BOOL)showMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth chose:(BOOL *)chose {
    return [self showContextMenu:menu topLeft:screenPoint minWidth:minWidth forView:nil event:nil chose:chose];
}

+ (BOOL)showContextMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth
                forView:(NSView *)view event:(NSEvent *)event chose:(BOOL *)chose {
    if (chose) *chose = NO;
    // everything W7MenuWindow cannot or must not draw returns NO before anything appears, so the
    // caller's native menu runs instead.
    if (!menu || !NSApp || !NSThread.isMainThread || sTracking) return NO;
    if (NSApp.modalWindow || W7MenuHasCustomViewItem(menu)) return NO;
    BOOL shown = NO;
    [self popUpMenu:menu topLeft:screenPoint minWidth:minWidth switchRegions:nil shown:&shown chose:chose strict:YES
            forView:view event:event];
    return shown;
}

+ (NSInteger)popUpMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth
         switchRegions:(NSArray<NSValue *> *)regions {
    return [self popUpMenu:menu topLeft:screenPoint minWidth:minWidth switchRegions:regions shown:NULL chose:NULL strict:NO
                   forView:nil event:nil];
}

/// Tells the context view, then the world, that the menu is gone (AppKit's protocol). After the action:
/// a table view clears its clicked row in didCloseMenu:withEvent:, and the action may still read it.
+ (void)w7AnnounceClose:(NSMenu *)menu tracker:(W7MenuTracker *)tracker {
    if (!tracker.announced) return;
    @try {
        [NSNotificationCenter.defaultCenter postNotificationName:NSMenuDidEndTrackingNotification object:menu];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "menu end-tracking notification failed: %{public}@", e.reason ?: @"unknown");
    }
    @try {
        NSView *view = tracker.contextView;
        if (tracker.contextEvent && [view respondsToSelector:@selector(didCloseMenu:withEvent:)])
            [view didCloseMenu:menu withEvent:tracker.contextEvent];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "didCloseMenu failed: %{public}@", e.reason ?: @"unknown");
    }
}

+ (NSInteger)popUpMenu:(NSMenu *)menu topLeft:(NSPoint)screenPoint minWidth:(CGFloat)minWidth
         switchRegions:(NSArray<NSValue *> *)regions shown:(BOOL *)shownOut chose:(BOOL *)choseOut
                strict:(BOOL)strict forView:(NSView *)view event:(NSEvent *)event {
    if (shownOut) *shownOut = NO;
    if (choseOut) *choseOut = NO;
    if (!menu || !NSApp) return NSNotFound;
    if (!NSThread.isMainThread) {
        os_log_error(W7Log(), "W7MenuWindow popUp called off the main thread; ignored");
        return NSNotFound;
    }
    if (sTracking) {
        os_log_error(W7Log(), "W7MenuWindow popUp called while a menu is tracking; ignored");
        return NSNotFound;
    }
    NSMenuItem *commitItem = nil;
    NSInteger switchIndex = NSNotFound;
    sTracking = YES;
    W7MenuTracker *tracker = [[W7MenuTracker alloc] init];
    @try {
        tracker.switchRegions = regions;
        tracker.refuseCustomViews = strict;
        tracker.announces = strict;
        tracker.contextView = view;
        tracker.contextEvent = event;
        [tracker runMenu:menu topLeft:screenPoint minWidth:minWidth];
        commitItem = tracker.commitItem;
        switchIndex = tracker.switchIndex;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "menu tracking failed: %{public}@", e.reason ?: @"unknown");
    } @finally {
        sTracking = NO;
        if (shownOut) *shownOut = tracker.shown;
    }
    // Resolve the index only now, after every menuDidClose: has run. An item the delegate removed
    // from its menu is dropped rather than running whatever item took its place.
    NSMenu *owner = commitItem.menu;
    NSInteger index = owner ? [owner indexOfItem:commitItem] : -1;
    if (owner && index >= 0) {
        if (choseOut) *choseOut = YES;
        // a nil-target item of a context menu goes where AppKit's would, up the clicked view's chain;
        // the item carries that target only for this send.
        id target = nil;
        @try {
            target = W7ContextMenuItemTarget(commitItem, view);
            if (target) commitItem.target = target;
            [owner performActionForItemAtIndex:index];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "menu action failed: %{public}@", e.reason ?: @"unknown");
        } @finally {
            if (target && commitItem.target == target) commitItem.target = nil;
        }
    }
    [self w7AnnounceClose:menu tracker:tracker];
    return commitItem ? NSNotFound : switchIndex;
}

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }

- (void)setSelectedIndex:(NSInteger)i {
    if (_selectedIndex == i) return;
    NSInteger old = _selectedIndex;
    _selectedIndex = i;
    [self w7RedrawRow:old];
    [self w7RedrawRow:i];
}

- (void)setOpenSubmenuIndex:(NSInteger)i {
    if (_openSubmenuIndex == i) return;
    NSInteger old = _openSubmenuIndex;
    _openSubmenuIndex = i;
    [self w7RedrawRow:old];
    [self w7RedrawRow:i];
}

/// a highlight change redraws the rows it moves between, not the whole menu.
- (void)w7RedrawRow:(NSInteger)i {
    if (i == NSNotFound || i < 0 || (NSUInteger)i >= self.nodes.count) return;
    [self.contentView setNeedsDisplayInRect:[self rectForRow:i]];
}

/// Row rect in the (non-flipped) content view.
- (NSRect)rectForRow:(NSInteger)i {
    CGFloat h = W7RowHeight(self.nodes[(NSUInteger)i]);
    CGFloat top = kVerticalPad + W7MenuRowTop(self.nodes, i);
    return NSMakeRect(0, NSHeight(self.contentView.bounds) - top - h, NSWidth(self.contentView.bounds), h);
}

- (NSInteger)rowAtScreenPoint:(NSPoint)p {
    if (!NSPointInRect(p, self.frame)) return NSNotFound;
    return W7MenuRowAtOffset(self.nodes, NSMaxY(self.frame) - p.y - kVerticalPad);
}

- (CGFloat)screenTopOfRow:(NSInteger)i {
    return NSMaxY(self.frame) - kVerticalPad - W7MenuRowTop(self.nodes, i);
}

@end

@implementation W7MenuView

- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (void)drawRect:(NSRect)dirty {
    @try {
        W7MenuWindow *w = (W7MenuWindow *)self.window;
        if (![w isKindOfClass:[W7MenuWindow class]]) return;
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        W7DrawMenuBackground(ctx, self.bounds, W7MenuGutterWidth);
        NSArray<W7MenuNode *> *nodes = w.nodes;
        for (NSUInteger i = 0; i < nodes.count; i++) {
            NSRect row = [w rectForRow:(NSInteger)i];
            if (!NSIntersectsRect(row, dirty)) continue;
            [self drawNode:nodes[i] inRect:row
               highlighted:((NSInteger)i == w.selectedIndex || (NSInteger)i == w.openSubmenuIndex)
                 shortcutX:w.shortcutX context:ctx];
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "menu draw failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)drawNode:(W7MenuNode *)n inRect:(NSRect)row highlighted:(BOOL)highlighted
       shortcutX:(CGFloat)shortcutX context:(CGContextRef)ctx {
    if (n.isSeparator) {
        CGFloat y = floor(NSMidY(row));
        NSRect line = NSMakeRect(W7MenuGutterWidth + 2, y, NSWidth(row) - W7MenuGutterWidth - 4, 1);
        [[NSColor colorWithSRGBRed:0xE2 / 255.0 green:0xE3 / 255.0 blue:0xE3 / 255.0 alpha:1] setFill];
        NSRectFill(line);
        [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1] setFill];
        NSRectFill(NSOffsetRect(line, 0, -1));
        return;
    }
    if (highlighted) W7DrawMenuHighlight(ctx, NSInsetRect(row, kHighlightInset, 0));

    NSColor *color = W7MenuTextColor(n.enabled);
    CGFloat cx = W7MenuGutterWidth / 2, cy = NSMidY(row);
    if (n.state == NSControlStateValueOn || n.state == NSControlStateValueMixed) {
        NSBezierPath *mark = [NSBezierPath bezierPath];
        if (n.state == NSControlStateValueOn) {
            [mark moveToPoint:NSMakePoint(cx - 4, cy)];
            [mark lineToPoint:NSMakePoint(cx - 1.5, cy - 3)];
            [mark lineToPoint:NSMakePoint(cx + 4, cy + 3.5)];
        } else {
            [mark moveToPoint:NSMakePoint(cx - 3.5, cy)];
            [mark lineToPoint:NSMakePoint(cx + 3.5, cy)];
        }
        mark.lineWidth = 1.6;
        mark.lineCapStyle = NSLineCapStyleRound;
        mark.lineJoinStyle = NSLineJoinStyleRound;
        [color setStroke];
        [mark stroke];
    } else if (n.image) {
        [n.image drawInRect:NSMakeRect(cx - 8, cy - 8, 16, 16) fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver fraction:(n.enabled ? 1 : 0.4)
             respectFlipped:YES hints:nil];
    }

    NSDictionary *attrs = @{ NSFontAttributeName: W7MenuFont(), NSForegroundColorAttributeName: color };
    NSSize ts = W7TextSize(n.title, W7MenuFont());
    [n.title drawAtPoint:NSMakePoint(W7MenuGutterWidth + kTitleLeftPad, NSMinY(row) + floor((NSHeight(row) - ts.height) / 2))
          withAttributes:attrs];
    if (n.shortcut) {
        NSSize ks = W7TextSize(n.shortcut, W7MenuFont());
        [n.shortcut drawAtPoint:NSMakePoint(shortcutX, NSMinY(row) + floor((NSHeight(row) - ks.height) / 2))
                 withAttributes:attrs];
    }
    if (n.hasSubmenu) {
        CGFloat x = NSWidth(row) - 14;
        NSBezierPath *arrow = [NSBezierPath bezierPath];
        [arrow moveToPoint:NSMakePoint(x, cy - 3.5)];
        [arrow lineToPoint:NSMakePoint(x, cy + 3.5)];
        [arrow lineToPoint:NSMakePoint(x + 4, cy)];
        [arrow closePath];
        [color setFill];
        [arrow fill];
    }
}

@end

#pragma mark - Tracking

@implementation W7MenuTracker {
    NSMutableArray<W7MenuWindow *> *_levels;
    BOOL _done;
    BOOL _wasActive;
    BOOL _moved;
    NSPoint _startPoint, _lastMouse;
    NSUInteger _heldButtons;   // pressed buttons we know about (the opening press, or presses inside a menu)
    NSUInteger _downsSeen;     // buttons whose mouse-down this loop received
    NSInteger _pendingLevel, _pendingIndex;
    NSTimeInterval _pendingDeadline;
}

- (instancetype)init {
    if ((self = [super init])) {
        _levels = [NSMutableArray array];
        _pendingLevel = NSNotFound;
        _switchIndex = NSNotFound;
    }
    return self;
}

- (void)runMenu:(NSMenu *)menu topLeft:(NSPoint)topLeft minWidth:(CGFloat)minWidth {
    NSArray<W7MenuNode *> *nodes = W7MenuNodesForView(menu, _contextView);
    if (nodes.count == 0) return;
    if (_refuseCustomViews && W7MenuHasCustomViewItem(menu)) return;   // its delegate added one in menuNeedsUpdate:
    W7MenuWindow *root = [[W7MenuWindow alloc] initWithMenu:menu nodes:nodes minWidth:minWidth];
    [root setFrame:W7MenuPopUpFrame(topLeft, root.frame.size, W7VisibleFrameForPoint(topLeft)) display:NO];
    [self announceOpen:menu];

    _startPoint = _lastMouse = NSEvent.mouseLocation;
    _heldButtons = NSEvent.pressedMouseButtons;
    _wasActive = NSApp.isActive;
    @try {
        [self pushLevel:root];
        [[NSCursor arrowCursor] set];
        while (!_done) {
            @autoreleasepool {
                NSTimeInterval wait = kPollInterval;
                if (_pendingLevel != NSNotFound) {
                    wait = MIN(wait, MAX(0, _pendingDeadline - NSDate.timeIntervalSinceReferenceDate));
                }
                NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate dateWithTimeIntervalSinceNow:wait]
                                                   inMode:NSEventTrackingRunLoopMode
                                                  dequeue:YES];
                if (e) [self handleEvent:e];
                if (!_done) [self checkEnvironment];
                if (!_done) [self trackMouse:NSEvent.mouseLocation];
                if (!_done) [self firePendingIfDue];
                for (W7MenuWindow *w in _levels) [w displayIfNeeded];
            }
        }
    } @finally {
        [self closeLevelsFrom:0];
    }
}

/// AppKit's order: the menu has been updated (menuNeedsUpdate:, validation), then the view's willOpenMenu:withEvent:
/// and NSMenuDidBeginTrackingNotification, then menuWillOpen: as the window appears.
- (void)announceOpen:(NSMenu *)menu {
    if (!_announces) return;
    _announced = YES;
    @try {
        if (_contextEvent && [_contextView respondsToSelector:@selector(willOpenMenu:withEvent:)])
            [_contextView willOpenMenu:menu withEvent:_contextEvent];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "willOpenMenu failed: %{public}@", e.reason ?: @"unknown");
    }
    @try {
        [NSNotificationCenter.defaultCenter postNotificationName:NSMenuDidBeginTrackingNotification object:menu];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "menu begin-tracking notification failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark Levels

- (void)pushLevel:(W7MenuWindow *)w {
    [_levels addObject:w];
    @try {
        id<NSMenuDelegate> d = w.sourceMenu.delegate;
        if ([d respondsToSelector:@selector(menuWillOpen:)]) [d menuWillOpen:w.sourceMenu];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "menuWillOpen failed: %{public}@", e.reason ?: @"unknown");
    }
    [w orderFrontRegardless];
    _shown = YES;
}

/// Closes level `k` and everything deeper. Windows are ordered out before any delegate runs.
- (void)closeLevelsFrom:(NSUInteger)k {
    NSMutableArray<W7MenuWindow *> *closed = [NSMutableArray array];
    while (_levels.count > k) {
        W7MenuWindow *w = _levels.lastObject;
        [_levels removeLastObject];
        [w orderOut:nil];
        [closed addObject:w];
    }
    if (k > 0 && k <= _levels.count) _levels[k - 1].openSubmenuIndex = NSNotFound;
    for (W7MenuWindow *w in closed) {
        @try {
            id<NSMenuDelegate> d = w.sourceMenu.delegate;
            if ([d respondsToSelector:@selector(menuDidClose:)]) [d menuDidClose:w.sourceMenu];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "menuDidClose failed: %{public}@", e.reason ?: @"unknown");
        }
    }
}

- (NSInteger)levelAtPoint:(NSPoint)p {
    for (NSInteger i = (NSInteger)_levels.count - 1; i >= 0; i--) {
        if (NSPointInRect(p, _levels[(NSUInteger)i].frame)) return i;
    }
    return NSNotFound;
}

- (void)openSubmenuAtLevel:(NSInteger)level row:(NSInteger)row selectFirst:(BOOL)selectFirst {
    if (level < 0 || level >= (NSInteger)_levels.count) return;
    W7MenuWindow *parent = _levels[(NSUInteger)level];
    if (row < 0 || row >= (NSInteger)parent.nodes.count) return;
    W7MenuNode *node = parent.nodes[(NSUInteger)row];
    [self closeLevelsFrom:(NSUInteger)level + 1];
    if (!node.hasSubmenu || !node.enabled || node.sourceIndex >= parent.sourceMenu.numberOfItems) return;
    NSMenu *sub = [parent.sourceMenu itemAtIndex:node.sourceIndex].submenu;
    NSArray<W7MenuNode *> *nodes = sub ? W7MenuNodesForView(sub, _contextView) : @[];
    if (nodes.count == 0) return;

    W7MenuWindow *child = [[W7MenuWindow alloc] initWithMenu:sub nodes:nodes minWidth:0];
    CGFloat top = [parent screenTopOfRow:row] + kVerticalPad;  // first child row lines up with the parent row
    NSRect vis = parent.screen ? parent.screen.visibleFrame
                               : W7VisibleFrameForPoint(NSMakePoint(NSMidX(parent.frame), NSMidY(parent.frame)));
    [child setFrame:W7MenuSubmenuFrame(parent.frame, top, child.frame.size, vis) display:NO];
    parent.selectedIndex = row;
    parent.openSubmenuIndex = row;
    [self pushLevel:child];
    if (selectFirst) child.selectedIndex = W7NextSelectableIndex(nodes, NSNotFound, 1);
}

#pragma mark Pending submenu open/close

- (void)schedulePendingLevel:(NSInteger)level index:(NSInteger)index {
    _pendingLevel = level;
    _pendingIndex = index;
    _pendingDeadline = NSDate.timeIntervalSinceReferenceDate + kSubmenuDelay;
}

- (void)cancelPending { _pendingLevel = NSNotFound; }

- (void)firePendingIfDue {
    if (_pendingLevel == NSNotFound || NSDate.timeIntervalSinceReferenceDate < _pendingDeadline) return;
    NSInteger level = _pendingLevel, row = _pendingIndex;
    [self cancelPending];
    if (level >= (NSInteger)_levels.count) return;
    W7MenuWindow *w = _levels[(NSUInteger)level];
    if (row != NSNotFound && row == w.selectedIndex && w.nodes[(NSUInteger)row].hasSubmenu) {
        [self openSubmenuAtLevel:level row:row selectFirst:NO];
    } else {
        [self closeLevelsFrom:(NSUInteger)level + 1];
    }
}

#pragma mark Mouse

- (void)noteMouse:(NSPoint)p {
    if (!_moved && hypot(p.x - _startPoint.x, p.y - _startPoint.y) >= kDragThreshold) _moved = YES;
}

/// Ends tracking with a switch result when `p` (outside every menu) is inside a switch region.
- (BOOL)checkSwitchRegionsAt:(NSPoint)p {
    for (NSUInteger i = 0; i < _switchRegions.count; i++) {
        if (NSPointInRect(p, _switchRegions[i].rectValue)) {
            _switchIndex = (NSInteger)i;
            _done = YES;
            return YES;
        }
    }
    return NO;
}

- (void)trackMouse:(NSPoint)p {
    if (NSEqualPoints(p, _lastMouse)) return;
    _lastMouse = p;
    [self noteMouse:p];

    NSInteger level = [self levelAtPoint:p];
    if (level == NSNotFound) {
        if ([self checkSwitchRegionsAt:p]) return;
        W7MenuWindow *deepest = _levels.lastObject;
        deepest.selectedIndex = NSNotFound;
        if (_pendingLevel == (NSInteger)_levels.count - 1) [self cancelPending];
        return;
    }
    [[NSCursor arrowCursor] set];
    // Reaching a deeper level confirms the path: ancestors highlight the rows that own their child.
    for (NSInteger i = 0; i < level; i++) {
        W7MenuWindow *a = _levels[(NSUInteger)i];
        a.selectedIndex = a.openSubmenuIndex;
    }
    if (_pendingLevel != NSNotFound && _pendingLevel < level) [self cancelPending];

    W7MenuWindow *w = _levels[(NSUInteger)level];
    NSInteger row = [w rowAtScreenPoint:p];
    NSInteger sel = (row != NSNotFound && W7Selectable(w.nodes[(NSUInteger)row])) ? row : NSNotFound;
    if (sel == w.selectedIndex) return;
    w.selectedIndex = sel;
    if (w.openSubmenuIndex != NSNotFound && w.openSubmenuIndex == sel) {
        [self cancelPending];
    } else if ((sel != NSNotFound && w.nodes[(NSUInteger)sel].hasSubmenu) || w.openSubmenuIndex != NSNotFound) {
        [self schedulePendingLevel:level index:sel];
    } else {
        [self cancelPending];
    }
}

- (void)mouseDownAt:(NSPoint)p button:(NSUInteger)bit {
    _heldButtons |= bit;
    _downsSeen |= bit;
    if ([self levelAtPoint:p] == NSNotFound) _done = YES;  // click outside every menu window
}

- (void)mouseUpAt:(NSPoint)p button:(NSUInteger)bit {
    // A release whose press we never saw ends the press that opened the menu.
    BOOL openingPress = (_downsSeen & bit) == 0;
    _downsSeen &= ~bit;
    _heldButtons &= ~bit;
    [self noteMouse:p];

    NSInteger level = [self levelAtPoint:p];
    if (level == NSNotFound) {
        if (openingPress && _moved) _done = YES;  // press-drag-release away from the menu
        return;
    }
    if (openingPress && !_moved) return;  // plain click that opened the menu: stay open
    W7MenuWindow *w = _levels[(NSUInteger)level];
    NSInteger row = [w rowAtScreenPoint:p];
    if (row == NSNotFound || !W7Selectable(w.nodes[(NSUInteger)row])) return;
    [self activateRow:row atLevel:level];
}

/// Return or a click on a row: opens its submenu, or commits the item.
- (void)activateRow:(NSInteger)row atLevel:(NSInteger)level {
    W7MenuWindow *w = _levels[(NSUInteger)level];
    W7MenuNode *node = w.nodes[(NSUInteger)row];
    w.selectedIndex = row;
    [self cancelPending];
    if (node.hasSubmenu) {
        if (w.openSubmenuIndex != row) [self openSubmenuAtLevel:level row:row selectFirst:NO];
        return;
    }
    if (node.sourceIndex < 0 || node.sourceIndex >= w.sourceMenu.numberOfItems) return;
    _commitItem = [w.sourceMenu itemAtIndex:node.sourceIndex];
    _done = YES;
}

/// Ends tracking when the app is deactivated, the menu was hidden from outside, or a mouse
/// button went down somewhere we get no events for (another app, while this app is inactive).
- (void)checkEnvironment {
    BOOL active = NSApp.isActive;
    if (_wasActive && !active) { _done = YES; return; }
    _wasActive = _wasActive || active;
    if (!_levels.firstObject.isVisible) { _done = YES; return; }

    NSUInteger pressed = NSEvent.pressedMouseButtons;
    NSUInteger unknown = pressed & ~_heldButtons;
    _heldButtons &= pressed;
    // Presses over a menu window always reach us as events; only presses elsewhere count here.
    if (unknown && [self levelAtPoint:NSEvent.mouseLocation] == NSNotFound) _done = YES;
}

#pragma mark Keyboard

- (void)keyDown:(NSEvent *)e {
    NSString *chars = e.charactersIgnoringModifiers;
    unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    if (e.keyCode == 53) c = 0x1b;  // Esc
    NSInteger level = (NSInteger)_levels.count - 1;
    W7MenuWindow *w = _levels.lastObject;
    switch (c) {
        case NSUpArrowFunctionKey:
        case NSDownArrowFunctionKey:
            [self cancelPending];
            w.selectedIndex = W7NextSelectableIndex(w.nodes, w.selectedIndex, c == NSDownArrowFunctionKey ? 1 : -1);
            break;
        case NSRightArrowFunctionKey:
            if (w.selectedIndex != NSNotFound && W7Selectable(w.nodes[(NSUInteger)w.selectedIndex])
                && w.nodes[(NSUInteger)w.selectedIndex].hasSubmenu) {
                [self cancelPending];
                [self openSubmenuAtLevel:level row:w.selectedIndex selectFirst:YES];
            }
            break;
        case NSLeftArrowFunctionKey:
        case 0x1b:
            [self cancelPending];
            if (level > 0) [self closeLevelsFrom:(NSUInteger)level];
            else if (c == 0x1b || W7MenuLeftClosesRoot(w.sourceMenu)) _done = YES;
            break;
        case '\r':
        case NSEnterCharacter:
            if (w.selectedIndex != NSNotFound && W7Selectable(w.nodes[(NSUInteger)w.selectedIndex])) {
                BOOL submenu = w.nodes[(NSUInteger)w.selectedIndex].hasSubmenu;
                if (submenu) {
                    [self cancelPending];
                    [self openSubmenuAtLevel:level row:w.selectedIndex selectFirst:YES];
                } else {
                    [self activateRow:w.selectedIndex atLevel:level];
                }
            }
            break;
        default:
            break;
    }
}

#pragma mark Events

- (void)handleEvent:(NSEvent *)e {
    switch (e.type) {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeRightMouseDown:
        case NSEventTypeOtherMouseDown:
            [self mouseDownAt:W7EventScreenPoint(e) button:(NSUInteger)1 << MIN(e.buttonNumber, 63)];
            break;
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseUp:
            [self mouseUpAt:W7EventScreenPoint(e) button:(NSUInteger)1 << MIN(e.buttonNumber, 63)];
            break;
        case NSEventTypeKeyDown:
            [self keyDown:e];
            break;
        case NSEventTypeMouseMoved: {
            // Selection follows the polled cursor position; moves are only used for switch regions.
            NSPoint p = W7EventScreenPoint(e);
            if ([self levelAtPoint:p] == NSNotFound) [self checkSwitchRegionsAt:p];
            break;
        }
        case NSEventTypeAppKitDefined:
        case NSEventTypeSystemDefined:
        case NSEventTypeApplicationDefined:
            // Activation changes, screen changes and app-posted events keep flowing to the app.
            [NSApp sendEvent:e];
            break;
        default:
            // Movement is polled; key-ups, scrolling and gestures are swallowed while the menu is up.
            break;
    }
}

@end
