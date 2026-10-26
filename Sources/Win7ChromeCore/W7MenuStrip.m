#import "Win7ChromeCore.h"

static const CGFloat kStripFontSize = 12;
static const CGFloat kTitlePad = 8;

BOOL W7ShouldShowMenuStrip(NSWindowStyleMask mask, BOOL isModal) {
    return (mask & NSWindowStyleMaskResizable) != 0 && !isModal;
}

static NSArray<NSMenuItem *> *W7VisibleTopItems(NSMenu *mainMenu) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSMenuItem *item in mainMenu.itemArray) {
        if (!item.isHidden) [items addObject:item];
    }
    return items;
}

NSArray<NSString *> *W7MenuStripTitles(NSMenu *mainMenu, NSString *appName) {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSMenuItem *item in W7VisibleTopItems(mainMenu)) {
        [titles addObject:titles.count == 0 ? appName : (item.title ?: @"")];
    }
    return titles;
}

static NSString *W7AppName(void) {
    NSString *n = NSRunningApplication.currentApplication.localizedName;
    return n.length ? n : NSProcessInfo.processInfo.processName;
}

static NSFont *W7StripFont(void) {
    static NSFont *font; static dispatch_once_t once;
    dispatch_once(&once, ^{ font = W7UIFont(kStripFontSize); });
    return font;
}

NSArray<NSValue *> *W7MenuStripTitleRects(NSArray<NSString *> *titles, NSFont *font, CGFloat height) {
    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:titles.count];
    CGFloat x = 0;
    for (NSString *t in titles) {
        CGFloat w = ceil(W7TextSize(t, font).width) + 2 * kTitlePad;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x, 0, w, height)]];
        x += w;
    }
    return rects;
}

#pragma mark - View

@interface W7MenuStripView : NSView
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, copy) NSArray<NSMenuItem *> *items;
@property (nonatomic) NSInteger openIndex;
@end

@implementation W7MenuStripView {
    /// W7MenuStripTitleRects for `titles` at `_rectsHeight`; nil until needed (draws and hit
    /// tests used to measure every title again for each title).
    NSArray<NSValue *> *_titleRects;
    CGFloat _rectsHeight;
}

- (void)setTitles:(NSArray<NSString *> *)titles {
    _titles = [titles copy];
    _titleRects = nil;
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _titles = @[];
        _items = @[];
        _openIndex = NSNotFound;
        self.autoresizingMask = NSViewWidthSizable;
    }
    return self;
}

- (void)setOpenIndex:(NSInteger)i {
    _openIndex = i;
    self.needsDisplay = YES;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (NSRect)rectForTitle:(NSUInteger)i {
    CGFloat h = NSHeight(self.bounds);
    if (!_titleRects || _rectsHeight != h) {
        _titleRects = W7MenuStripTitleRects(self.titles, W7StripFont(), h);
        _rectsHeight = h;
    }
    return i < _titleRects.count ? _titleRects[i].rectValue : NSZeroRect;
}

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        W7DrawMenuStripBackground(ctx, self.bounds);
        NSDictionary *attrs = @{ NSFontAttributeName: W7StripFont(),
                                 NSForegroundColorAttributeName: NSColor.blackColor };
        for (NSUInteger i = 0; i < self.titles.count; i++) {
            NSRect r = [self rectForTitle:i];
            if ((NSInteger)i == self.openIndex) {
                NSBezierPath *hl = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 1.5) xRadius:3 yRadius:3];
                [[NSColor colorWithSRGBRed:0xDC / 255.0 green:0xEB / 255.0 blue:0xFC / 255.0 alpha:1] setFill];
                [hl fill];
                [[NSColor colorWithSRGBRed:0xAE / 255.0 green:0xCF / 255.0 blue:0xF7 / 255.0 alpha:1] setStroke];
                [hl stroke];
            }
            NSSize ts = W7TextSize(self.titles[i], W7StripFont());
            [self.titles[i] drawAtPoint:NSMakePoint(NSMinX(r) + kTitlePad, floor((NSHeight(r) - ts.height) / 2))
                         withAttributes:attrs];
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "menu strip draw failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (NSInteger)titleAtPoint:(NSPoint)p {
    for (NSUInteger i = 0; i < self.titles.count; i++) {
        if (NSPointInRect(p, [self rectForTitle:i])) return (NSInteger)i;
    }
    return NSNotFound;
}

- (NSRect)screenRectForTitle:(NSUInteger)i {
    NSRect inWindow = [self convertRect:[self rectForTitle:i] toView:nil];
    return [self.window convertRectToScreen:inWindow];
}

- (void)mouseDown:(NSEvent *)event {
    // An action (File > Close) may release the window and this view; keep self alive to the end.
    W7MenuStripView *keep = self;
    @try {
        NSInteger idx = [self titleAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
        while (idx != NSNotFound && self.window) {
            NSMenu *sub = (NSUInteger)idx < self.items.count ? self.items[(NSUInteger)idx].submenu : nil;
            if (!sub) break;
            NSRect r = [self screenRectForTitle:(NSUInteger)idx];
            // Other titles become switch regions; a map from region index back to title index.
            NSMutableArray<NSValue *> *regions = [NSMutableArray array];
            NSMutableArray<NSNumber *> *map = [NSMutableArray array];
            for (NSUInteger i = 0; i < self.titles.count; i++) {
                if ((NSInteger)i == idx || i >= self.items.count || !self.items[i].submenu) continue;
                [regions addObject:[NSValue valueWithRect:[self screenRectForTitle:i]]];
                [map addObject:@(i)];
            }
            self.openIndex = idx;
            [self displayIfNeeded];
            NSInteger sw = [W7MenuWindow popUpMenu:sub topLeft:NSMakePoint(NSMinX(r), NSMinY(r)) minWidth:0
                                     switchRegions:regions];
            idx = (sw != NSNotFound && (NSUInteger)sw < map.count) ? map[(NSUInteger)sw].integerValue : NSNotFound;
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "menu strip click failed: %{public}@", e.reason ?: @"unknown");
    }
    keep.openIndex = NSNotFound;
}

@end

#pragma mark - Controller

@interface W7MenuStripController ()
- (void)rebuild;
@end

/// Every live strip controller, and one set of menu observers for all of them: each strip
/// used to observe the three notifications itself, walking up to the main menu once per window for
/// every notification. Main thread only.
static NSHashTable<W7MenuStripController *> *W7LiveStrips(void) {
    static NSHashTable *strips;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ strips = [NSHashTable weakObjectsHashTable]; });
    return strips;
}

static BOOL gStripRebuildScheduled;

/// One rebuild pass for every strip, on the main run loop's next turn in the common modes
/// (notifications come in bursts). A run-loop block rather than the main dispatch queue, so it also runs
/// inside nested run loops (menu tracking, modal sessions).
static void W7ScheduleStripRebuilds(void) {
    if (gStripRebuildScheduled) return;
    gStripRebuildScheduled = YES;
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
        gStripRebuildScheduled = NO;
        @try {
            for (W7MenuStripController *c in W7LiveStrips().allObjects) [c rebuild];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "menu strip rebuild pass failed: %{public}@", e.reason ?: @"unknown");
        }
    });
    CFRunLoopWakeUp(main);
}

static void W7InstallSharedMenuObservers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *name in @[NSMenuDidAddItemNotification, NSMenuDidRemoveItemNotification,
                                 NSMenuDidChangeItemNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *n) {
                @try {
                    if (W7LiveStrips().count == 0) return;
                    NSMenu *m = n.object;
                    NSMenu *main = NSApp.mainMenu;
                    while (m && m != main) m = m.supermenu;
                    if (m) W7ScheduleStripRebuilds();
                } @catch (NSException *e) {
                    os_log_error(W7Log(), "menu strip notification failed: %{public}@", e.reason ?: @"unknown");
                }
            }];
        }
    });
}

@implementation W7MenuStripController {
    BOOL _observingMainMenu;
}

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        // Bottom, not Top: Windows 7 puts the menu bar above the toolbar, but AppKit raises
        // NSInternalInconsistencyException ("NSLayoutAttributeTop requires NSWindowStyleMaskFullSizeContentView")
        // for a Top accessory on a window without FullSizeContentView, and decorated windows never have it
        // (converted ones give it up). So with an NSToolbar the strip sits directly under the toolbar.
        self.layoutAttribute = NSLayoutAttributeBottom;
        // Before the view is set: otherwise AppKit resizes bottom accessories to its standard height (36 pt).
        self.automaticallyAdjustsSize = NO;
        W7MenuStripView *v = [[W7MenuStripView alloc] initWithFrame:NSMakeRect(0, 0, 400, W7MenuStripHeight)];
        self.view = v;
        self.fullScreenMinHeight = W7MenuStripHeight;
        [self rebuild];

        W7InstallSharedMenuObservers();
        [W7LiveStrips() addObject:self];
        [NSApp addObserver:self forKeyPath:@"mainMenu" options:0 context:NULL];
        _observingMainMenu = YES;
    }
    return self;
}

- (void)dealloc {
    if (_observingMainMenu) [NSApp removeObserver:self forKeyPath:@"mainMenu"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)ctx {
    W7ScheduleStripRebuilds();
}

/// Re-reads the main menu's top items; redraws only when they or their titles changed (apps post
/// NSMenuDidChangeItemNotification on every validation pass and state change).
- (void)rebuild {
    @try {
        NSMenu *main = NSApp.mainMenu;
        W7MenuStripView *v = (W7MenuStripView *)self.view;
        NSArray<NSMenuItem *> *items = W7VisibleTopItems(main);
        NSArray<NSString *> *titles = W7MenuStripTitles(main, W7AppName());
        if ([items isEqualToArray:v.items] && [titles isEqualToArray:v.titles]) return;
        v.items = items;
        v.titles = titles;
        v.needsDisplay = YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "menu strip rebuild failed: %{public}@", e.reason ?: @"unknown");
    }
}

@end
