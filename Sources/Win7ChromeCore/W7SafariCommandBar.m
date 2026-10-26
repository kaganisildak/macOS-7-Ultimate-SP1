// Internet Explorer 8 on Windows 7 for Safari (from the user's reference screenshot): the tab row's
// own controls, real buttons wired to Safari's own actions (the lookups and the performing: W7SafariCommandActions.m).
//   Left: "★ Favorites" = IE8's Favorites Center → Safari's Bookmarks sidebar (View ▸ Show Bookmarks Sidebar,
//   `toggleBookmarksSidebar:`, else `safari_toggleSidebar:`, else Bookmarks ▸ Show Bookmarks; the sidebar
//   toolbar item's view is not a control and has no action, so the menu it is). A right-click or a 500 ms press on it
//   opens a small menu of copies of Safari's own items (sidebars, all bookmarks, all history, the favorites bar). "✚"
//   = Safari's Add Bookmark… (`addBookmark:`), drawn disabled, with "Open a page first", whenever Safari's own menu
//   validation disables it (the Start Page, an empty tab); validated again on tab selection, loading changes, key
//   changes and the tab row's layout, at most once per 250 ms per window (the last change is never lost).
//   After the last tab: a blank new-tab stub (Safari's New Tab: the NewTab toolbar item's action, else its menu item).
//   Right-aligned command bar: Home (`goHome:`), Print (`safari_printDocument:`), Page ▾, Safety ▾, Tools ▾, Help ▾.
//   Each runs or lists Safari's OWN main menu items, found by action selector (copies keep Safari's target, action and
//   validation); a command whose items Safari does not have is hidden. Feeds and Mail are not shown (Safari has neither).
// Never a synthesized event: menu items are performed through their menu, controls through their own action, and only
// when Safari's own validation enables them (the ▾ menus are rebuilt and validated each time they open). One log line
// per click (the selector, enabled, sent; no titles). The controls are subviews of the tab bar (hidden with it), hit
// only on their own rects, so Safari's tabs keep their clicks. Themed windows only. Kill switch:
// `defaults write -g W7SafariCommandBarDisabled -bool YES`.
// each glyph is the user's Windows 7 picture when imported (favorites, ie-add-favorite, ie-home, ie-print,
// ie-help: W7IEGlyphIconName, through W7UserIconImage, so sandboxed Safari reads the embedded `__w7icons` section),
// else the drawn glyph.
#import "W7SafariInternal.h"

static const CFTimeInterval kValidationInterval = 0.25;
static const NSTimeInterval kFavoritesPressDelay = 0.5;

static NSMenu *gMainMenuOverride;   // tests
void W7SafariCommandBarSetMainMenu(NSMenu *menu) { gMainMenuOverride = menu; }
static NSMenu *W7SafariCommandMainMenu(void) { return gMainMenuOverride ?: NSApp.mainMenu; }

#pragma mark - Command bar layout (pure)

CGFloat W7SafariCommandButtonWidth(CGFloat textWidth, BOOL glyph, BOOL arrow) {
    CGFloat w = 6 + (glyph ? 16 : 0) + (glyph && textWidth > 0 ? 4 : 0) + ceil(textWidth) + (arrow ? 12 : 0) + 6;
    return MAX(w, 26);
}

CGFloat W7SafariCommandBarLayout(const CGFloat *widths, NSInteger count, CGFloat rightEdge, CGFloat gap, CGFloat *xs) {
    CGFloat x = rightEdge;
    for (NSInteger i = count - 1; i >= 0; i--) {   // right-aligned, in order from the left
        x -= widths[i];
        if (xs) xs[i] = x;
        if (i > 0) x -= gap;
    }
    return x;
}

#pragma mark - The buttons

NSString *W7IEGlyphIconName(W7IEGlyph glyph) {
    switch (glyph) {   // literals: no allocation per draw
        case W7IEGlyphFavorites: return @"favorites";
        case W7IEGlyphAddFavorite: return @"ie-add-favorite";
        case W7IEGlyphHome: return @"ie-home";
        case W7IEGlyphPrint: return @"ie-print";
        case W7IEGlyphHelp: return @"ie-help";
    }
    return nil;
}

@class W7SafariCommandButton;
/// What a click does: YES when Safari's item or action was sent; `enabled` gets Safari's verdict.
typedef BOOL (^W7SafariCommandPerform)(W7SafariCommandButton *button, BOOL *enabled);

/// One IE8 command bar / Favorites button: glyph, text and ▾ on the row; a flat 1 px frame under the pointer;
/// greyed, without a frame, while `disabled`.
@interface W7SafariCommandButton : NSView
@property (nonatomic, copy) NSString *name;    // "Favorites", "AddFavorite", "Stub", "Home", "Print", "Page", "Safety", "Tools", "Help"
@property (nonatomic, copy) NSString *label;
@property (nonatomic) BOOL hasGlyph, arrow, stub, disabled;
@property (nonatomic) BOOL followsValidation;            // ✚: drawn disabled when Safari's validation says so
@property (nonatomic) W7IEGlyph glyph;
@property (nonatomic, copy) W7SafariCommandPerform perform;
@property (nonatomic, strong) NSMenuItem *item;          // Safari's item a direct control performs (nil for the stub and the ▾ commands)
@property (nonatomic, copy) NSString *actionName;        // the selector it resolved to (diagnostics)
@property (nonatomic, copy) NSString *commandName;       // a ▾ command: its menu is built from Safari's when it opens
@property (nonatomic, copy) NSString *menuCommandName;   // ★: the menu a right-click or a long press opens
@end

@implementation W7SafariCommandButton {
    W7ControlState _state;
    NSTrackingArea *_tracking;
    CGFloat _width;   // measured once: the labels never change
    NSImage *_userIcon;            // the user's picture for the glyph (shared: drawn, never mutated), or nil
    NSUInteger _userIconGeneration;   // the W7UserIconsGeneration it was asked at
    BOOL _userIconAsked;              // NO until the first draw
}

/// The user's picture for this button's glyph, asked again only after the icon loader resets: a redraw only
/// compares a counter.
- (NSImage *)w7UserIcon {
    NSUInteger now = W7UserIconsGeneration();
    if (!_userIconAsked || now != _userIconGeneration) {
        NSString *name = W7IEGlyphIconName(self.glyph);
        _userIcon = name ? W7UserIconImage(name, 16) : nil;
        _userIconGeneration = now;
        _userIconAsked = YES;
    }
    return _userIcon;
}

static NSDictionary *W7SafariCommandTextAttributes(BOOL disabled) {
    static NSDictionary *attrs, *grey;
    if (!attrs) {
        attrs = @{ NSFontAttributeName: W7UIFont(12), NSForegroundColorAttributeName: NSColor.blackColor };
        grey = @{ NSFontAttributeName: W7UIFont(12), NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0x6D / 255.0 green:0x6D / 255.0 blue:0x6D / 255.0 alpha:1] };
    }
    return disabled ? grey : attrs;
}

- (CGFloat)w7Width {
    if (self.stub) return 28;   // IE8's blank new-tab stub
    if (_width <= 0) {
        CGFloat text = self.label.length ? [self.label sizeWithAttributes:W7SafariCommandTextAttributes(NO)].width : 0;
        _width = W7SafariCommandButtonWidth(text, self.hasGlyph, self.arrow);
    }
    return _width;
}

- (BOOL)isFlipped { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                 NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)w7SetState:(W7ControlState)state {
    if (_state == state) return;
    _state = state;
    if (!self.disabled) self.needsDisplay = YES;   // disabled: no hover or pressed look
}

- (void)setDisabled:(BOOL)disabled {
    if (_disabled == disabled) return;
    _disabled = disabled;
    self.toolTip = disabled ? @"Open a page first" : self.item.title;
    self.needsDisplay = YES;
}

- (void)mouseEntered:(NSEvent *)e { [self w7SetState:W7StateHover]; }
- (void)mouseExited:(NSEvent *)e { [self w7SetState:W7StateNormal]; }

- (void)w7PopUpMenu:(NSString *)command {
    NSMenu *menu = W7SafariBuildCommandMenu(W7SafariCommandMainMenu(), command, [NSMutableArray array]);
    os_log(W7Log(), "Safari command bar: %{public}@ ▾ opened with %ld of Safari's items", command, (long)menu.numberOfItems);
    [menu update];
    if (menu) [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -2) inView:self];
}

/// The click itself (also what W7SafariCommandControlClick runs): Safari's item or action, and one log line. Never
/// refused on the cached `disabled` flag (up to 250 ms old, and the key window's verdict): the item is validated afresh
/// by Safari in W7SafariPerformMenuItem, and the drawing then follows that verdict.
- (BOOL)w7Click {
    BOOL enabled = NO, sent = NO;
    if (self.perform) sent = self.perform(self, &enabled);
    if (self.followsValidation) self.disabled = !enabled;
    os_log(W7Log(), "Safari command bar: %{public}@ → %{public}@ (enabled %{public}s, sent %{public}s)", self.name,
           self.actionName ?: @"(none)", enabled ? "yes" : "no", sent ? "yes" : "no");
    return sent;
}

- (void)mouseDown:(NSEvent *)e {
    @try {
        [self w7SetState:W7StatePressed];
        if (self.commandName) {   // IE's ▾ commands open their menu at once, under the button, from Safari's menus now
            [self w7PopUpMenu:self.commandName];
            [self w7SetState:W7StateNormal];
            return;
        }
        NSEvent *up;
        if (self.menuCommandName) {   // ★: a press held 500 ms opens the Favorites menu instead of a click
            up = [self.window nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:[NSDate dateWithTimeIntervalSinceNow:kFavoritesPressDelay]
                                             inMode:NSEventTrackingRunLoopMode dequeue:YES];
            if (!up) {
                [self w7PopUpMenu:self.menuCommandName];
                [self w7SetState:W7StateNormal];
                return;
            }
        } else up = [self.window nextEventMatchingMask:NSEventMaskLeftMouseUp];   // the click's own mouse-up
        BOOL inside = NSPointInRect([self convertPoint:up.locationInWindow fromView:nil], self.bounds);
        [self w7SetState:inside ? W7StateHover : W7StateNormal];
        if (inside) [self w7Click];
    } @catch (NSException *ex) { os_log_error(W7Log(), "Safari command button failed: %{public}@", ex.reason ?: @"unknown"); }
}

- (void)rightMouseDown:(NSEvent *)e {
    @try {
        if (!self.menuCommandName || self.disabled) { [super rightMouseDown:e]; return; }
        [self w7PopUpMenu:self.menuCommandName];
    } @catch (NSException *ex) { os_log_error(W7Log(), "Safari command button menu failed: %{public}@", ex.reason ?: @"unknown"); }
}

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        if (!ctx) return;
        NSRect b = self.bounds;
        if (self.stub) { W7DrawIENewTabStub(ctx, b, _state != W7StateNormal); return; }
        BOOL disabled = self.disabled;
        W7DrawIECommandButtonFace(ctx, b, disabled ? W7StateDisabled : _state);
        CGFloat x = 6;
        if (self.hasGlyph) {
            CGRect r = CGRectMake(x, floor((b.size.height - 16) / 2), 16, 16);
            NSImage *icon = [self w7UserIcon];   // the user's Windows 7 picture when imported
            if (icon) {
                [icon drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:disabled ? 0.4 : 1
                  respectFlipped:YES hints:nil];
            } else if (disabled) {
                W7DrawIEGlyphDisabled(ctx, r, self.glyph);
            } else {
                W7DrawIEGlyph(ctx, r, self.glyph);
            }
            x += 16 + (self.label.length ? 4 : 0);
        }
        if (self.label.length) {
            NSDictionary *attrs = W7SafariCommandTextAttributes(disabled);
            NSSize s = [self.label sizeWithAttributes:attrs];
            [self.label drawAtPoint:NSMakePoint(x, floor((b.size.height - s.height) / 2)) withAttributes:attrs];
        }
        if (self.arrow) W7DrawIEDropArrow(ctx, CGPointMake(NSMaxX(b) - 10, NSMidY(b)));
    } @catch (NSException *ex) { os_log_error(W7Log(), "Safari command button draw failed: %{public}@", ex.reason ?: @"unknown"); }
}
@end

#pragma mark - The bar

/// Each of the bar's controls (the group, the commands, the stub), without building an array.
#define W7SafariForEachControl(bar, v, body) do { \
    for (W7SafariCommandButton *v in (bar).group) { body; } \
    for (W7SafariCommandButton *v in (bar).commands) { body; } \
    if ((bar).stub) { W7SafariCommandButton *v = (bar).stub; body; } } while (0)

static const void *kCommandBarKey = &kCommandBarKey;   // on a tab bar: its W7SafariCommandBar
static BOOL gCommandBarEnabled;
void W7SafariCommandBarSetEnabled(BOOL enabled) { gCommandBarEnabled = enabled; }

/// The tab bar's own controls.
@interface W7SafariCommandBar : NSObject
@property (nonatomic, strong) NSArray<W7SafariCommandButton *> *group, *commands;
@property (nonatomic, strong) W7SafariCommandButton *stub, *addFavorite, *favorites;
@property (nonatomic, weak) NSWindow *window;   // the bar's own window: only its key-window verdict is this bar's
@property (nonatomic) BOOL suppressed;   // Safari's layout kept overlapping them: hidden for this window
@property (nonatomic) CFTimeInterval lastValidation;   // ✚'s, CACurrentMediaTime
@property (nonatomic) BOOL validationPending;          // one deferred validation queued for the end of the interval
@end
@implementation W7SafariCommandBar
@end

static W7SafariCommandButton *W7SafariMakeButton(NSString *name, NSString *label, BOOL glyph, W7IEGlyph kind, BOOL arrow) {
    W7SafariCommandButton *b = [[W7SafariCommandButton alloc] initWithFrame:NSZeroRect];
    b.name = name;
    b.label = label;
    b.hasGlyph = glyph;
    b.glyph = kind;
    b.arrow = arrow;
    b.wantsLayer = YES;
    return b;
}

/// A direct control performing Safari's `item` through its menu (validated first).
static W7SafariCommandButton *W7SafariMakeItemButton(NSString *name, NSString *label, W7IEGlyph glyph, NSMenuItem *item) {
    W7SafariCommandButton *b = W7SafariMakeButton(name, label, YES, glyph, NO);
    b.item = item;
    b.actionName = NSStringFromSelector(item.action);
    b.toolTip = item.title;
    b.perform = ^BOOL(W7SafariCommandButton *sender, BOOL *enabled) { return W7SafariPerformMenuItem(item, enabled); };
    return b;
}

/// Builds the controls once per tab bar, resolving each against Safari's main menu and toolbar; one log line.
static W7SafariCommandBar *W7SafariMakeCommandBar(NSWindow *w) {
    NSMenu *main = W7SafariCommandMainMenu();
    NSMutableArray<NSString *> *log = [NSMutableArray array];
    W7SafariCommandBar *bar = [W7SafariCommandBar new];
    bar.window = w;
    __weak NSWindow *weakWindow = w;

    NSMutableArray *group = [NSMutableArray array];
    NSMenuItem *favoritesItem = W7SafariFindMenuItem(main, W7SafariFavoritesActions());
    if (favoritesItem) {
        W7SafariCommandButton *favorites = W7SafariMakeItemButton(@"Favorites", @"Favorites", W7IEGlyphFavorites, favoritesItem);
        favorites.menuCommandName = @"Favorites";
        [group addObject:favorites];
        bar.favorites = favorites;
    }
    [log addObject:[NSString stringWithFormat:@"★ Favorites → %@", favoritesItem ? NSStringFromSelector(favoritesItem.action)
                    : [NSString stringWithFormat:@"(hidden: none of %@)", [W7SafariFavoritesActions() componentsJoinedByString:@"/"]]]];
    NSMenuItem *addBookmark = W7SafariFindMenuItem(main, @[ @"addBookmark:" ]);
    if (addBookmark) {
        W7SafariCommandButton *add = W7SafariMakeItemButton(@"AddFavorite", @"", W7IEGlyphAddFavorite, addBookmark);
        add.followsValidation = YES;
        [group addObject:add];
        bar.addFavorite = add;
    }
    [log addObject:[NSString stringWithFormat:@"✚ → %@", addBookmark ? @"addBookmark: (follows Safari's validation)" : @"(hidden: no addBookmark: item)"]];
    bar.group = group;

    W7SafariCommandButton *stub = W7SafariMakeButton(@"Stub", @"", NO, W7IEGlyphHome, NO);
    stub.stub = YES;
    NSMenuItem *newTab = W7SafariFindMenuItem(main, @[ @"newTabFromFileMenu:", @"newTab:", @"newTabWithinWindow:" ]);
    stub.actionName = [NSString stringWithFormat:@"NewTabToolbarIdentifier (else %@)", newTab ? NSStringFromSelector(newTab.action) : @"no menu item"];
    stub.perform = ^BOOL(W7SafariCommandButton *sender, BOOL *enabled) {
        if (W7SafariPerformToolbarItem(weakWindow, @"NewTabToolbarIdentifier")) { *enabled = YES; return YES; }
        return newTab ? W7SafariPerformMenuItem(newTab, enabled) : NO;   // the item's view is no control: the menu
    };
    bar.stub = stub;
    [log addObject:[NSString stringWithFormat:@"new-tab stub → %@", stub.actionName]];

    NSMutableArray<W7SafariCommandButton *> *commands = [NSMutableArray array];
    struct { NSString *label; W7IEGlyph glyph; NSArray<NSString *> *actions; } direct[] = {
        { @"Home", W7IEGlyphHome, @[ @"goHome:" ] },
        { @"Print", W7IEGlyphPrint, W7SafariPrintActions() },
    };
    for (size_t i = 0; i < 2; i++) {
        NSMenuItem *item = W7SafariFindMenuItem(main, direct[i].actions);
        [log addObject:[NSString stringWithFormat:@"%@ → %@", direct[i].label, item ? NSStringFromSelector(item.action) : @"(hidden)"]];
        if (item) [commands addObject:W7SafariMakeItemButton(direct[i].label, @"", direct[i].glyph, item)];
    }
    for (NSString *command in @[ @"Page", @"Safety", @"Tools", @"Help" ]) {
        NSMutableArray<NSString *> *found = [NSMutableArray array];
        NSMenu *menu = W7SafariBuildCommandMenu(main, command, found);
        [log addObject:[NSString stringWithFormat:@"%@ ▾ → %@", command, menu ? [found componentsJoinedByString:@","] : @"(hidden: none found)"]];
        if (!menu) continue;
        BOOL help = [command isEqualToString:@"Help"];
        W7SafariCommandButton *b = W7SafariMakeButton(command, help ? @"" : command, help, W7IEGlyphHelp, YES);
        b.commandName = command;
        [commands addObject:b];
    }
    bar.commands = commands;
    os_log(W7Log(), "Safari command bar: %{public}@ (Feeds and Mail hidden: Safari has neither)", [log componentsJoinedByString:@" | "]);
    return bar;
}

#pragma mark - ✚ follows Safari's validation

static void W7SafariCommandBarValidate(W7SafariCommandBar *bar, BOOL force);

/// Safari's verdict on one item, asked as its menu would ask it (the target AppKit would send the action to, then
/// `validateMenuItem:` / `validateUserInterfaceItem:`; enabled when it implements neither) — without `[menu update]`
/// on the whole Bookmarks menu, which Safari may rebuild on every update. `known` NO when no target answers (the app
/// in the background): the last state is kept then.
static BOOL W7SafariItemEnabled(NSMenuItem *item, BOOL *known) {
    id target = [NSApp targetForAction:item.action to:item.target from:item];
    *known = target != nil;
    if (!target) return NO;
    if ([target respondsToSelector:@selector(validateMenuItem:)]) return [target validateMenuItem:item];
    if ([target respondsToSelector:@selector(validateUserInterfaceItem:)]) return [target validateUserInterfaceItem:item];
    return YES;
}

/// The timer's validation: only for the key window's own bar (another window's verdict is not this window's; a bar
/// whose window is not key keeps its last state), ★'s tooltip from the live item title (Show / Hide …), ✚ from
/// Safari's verdict on Add Bookmark….
static void W7SafariCommandBarValidateNow(W7SafariCommandBar *bar) {
    NSWindow *key = NSApp.keyWindow, *own = bar.window;
    if (key && own && key != own) return;
    NSMenuItem *favoritesItem = bar.favorites.item;
    if (favoritesItem) {   // Safari retitles Show/Hide … inside its validation of that item: ask first, then read the title
        BOOL known = NO;
        W7SafariItemEnabled(favoritesItem, &known);
        if (![bar.favorites.toolTip isEqualToString:favoritesItem.title]) bar.favorites.toolTip = favoritesItem.title;
    }
    W7SafariCommandButton *add = bar.addFavorite;
    NSMenuItem *item = add.item;
    if (!add || !item) return;
    BOOL known = NO, enabled = W7SafariItemEnabled(item, &known);
    if (known) add.disabled = !enabled;
}

/// Forced (tests): now. Otherwise coalesced on one non-repeating main-run-loop timer (as the tab row's coalescing; the
/// bar held weakly) that fires once Safari's own pass is over (the callers sit inside its tab selection, loading and
/// layout code, where the window's state may be half updated) and at most once per interval per window, so the state
/// after the last change is always the one shown. No timer while nothing changes. Main thread only (every caller is).
static void W7SafariCommandBarValidate(W7SafariCommandBar *bar, BOOL force) {
    CFTimeInterval now = CACurrentMediaTime();
    if (force) {
        bar.lastValidation = now;
        W7SafariCommandBarValidateNow(bar);
        return;
    }
    if (bar.validationPending) return;
    bar.validationPending = YES;
    CFTimeInterval wait = MAX(0, kValidationInterval - (now - bar.lastValidation));
    __weak W7SafariCommandBar *weakBar = bar;
    NSTimer *timer = [NSTimer timerWithTimeInterval:wait repeats:NO block:^(NSTimer *t) {
        W7SafariCommandBar *b = weakBar;
        if (!b) return;
        b.validationPending = NO;
        @try { W7SafariCommandBarValidate(b, YES); }
        @catch (NSException *e) { os_log_error(W7Log(), "Safari command bar validation failed: %{public}@", e.reason ?: @"unknown"); }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

void W7SafariCommandBarRevalidate(NSWindow *w, BOOL force) {
    @try {
        if (!gCommandBarEnabled || ![w isKindOfClass:NSWindow.class]) return;
        W7SafariCommandBar *bar = W7SafariState(w, NO).commandBar;
        if (bar && !bar.suppressed) W7SafariCommandBarValidate(bar, force);
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari command bar validation failed: %{public}@", e.reason ?: @"unknown"); }
}

#pragma mark - Layout

static void W7SafariSetFrame(NSView *v, NSRect f) {
    if (!NSEqualRects(v.frame, f)) v.frame = f;
}

void W7SafariLayoutCommandBar(NSView *tabBar, CGRect row, CGFloat *tabsStartX, CGFloat *tabsMaxX) {
    @try {
        NSWindow *w = tabBar.window;
        if (!gCommandBarEnabled || !w || CGRectIsEmpty(row)) return;
        W7SafariCommandBar *bar = objc_getAssociatedObject(tabBar, kCommandBarKey);
        if (!bar) {
            bar = W7SafariMakeCommandBar(w);
            objc_setAssociatedObject(tabBar, kCommandBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            W7SafariState(w, NO).commandBar = bar;   // for the window-side revalidation (weak)
        }
        if (bar.suppressed) return;   // hidden for this window: the tabs get the whole row
        CGFloat h = MIN(row.size.height, 24), y = CGRectGetMidY(row) - h / 2;
        // Commands: right-aligned in the tab row.
        CGFloat widths[8], xs[8];
        NSInteger n = MIN((NSInteger)bar.commands.count, 8);
        for (NSInteger i = 0; i < n; i++) widths[i] = [bar.commands[i] w7Width];
        CGFloat left = W7SafariCommandBarLayout(widths, n, CGRectGetMaxX(tabBar.bounds) - 8, 2, xs);
        for (NSInteger i = 0; i < n; i++) {
            W7SafariCommandButton *b = bar.commands[i];
            if (b.superview != tabBar) [tabBar addSubview:b];
            W7SafariSetFrame(b, NSMakeRect(xs[i], y, widths[i], h));
        }
        if (tabsMaxX && n) *tabsMaxX = MIN(*tabsMaxX, left - 8);
        if (tabsMaxX) *tabsMaxX -= 30;   // room for the 28 pt new-tab stub after the last tab
        // ★ / ✚ at the tab row's left; the tabs start after them.
        CGFloat x = 8;
        for (W7SafariCommandButton *b in bar.group) {
            if (b.superview != tabBar) [tabBar addSubview:b];
            W7SafariSetFrame(b, NSMakeRect(x, y, [b w7Width], h));
            x += [b w7Width] + 2;
        }
        if (tabsStartX) *tabsStartX = MAX(*tabsStartX, x + 4);
        W7SafariCommandBarValidate(bar, NO);   // a tab row layout follows tab changes; throttled
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari command bar layout failed: %{public}@", e.reason ?: @"unknown"); }
}

void W7SafariPlaceNewTabStub(NSView *tabBar, CGRect afterTab, BOOL show) {
    W7SafariCommandBar *bar = tabBar ? objc_getAssociatedObject(tabBar, kCommandBarKey) : nil;
    W7SafariCommandButton *stub = bar.stub;
    if (!stub) return;
    if (!show || CGRectIsEmpty(afterTab)) { stub.hidden = YES; return; }
    if (stub.superview != tabBar) [tabBar addSubview:stub];
    stub.hidden = NO;
    W7SafariSetFrame(stub, NSMakeRect(CGRectGetMaxX(afterTab) + 2, afterTab.origin.y, 28, afterTab.size.height));
}

void W7SafariSetCommandBarSuppressed(NSView *tabBar, BOOL suppressed) {
    W7SafariCommandBar *bar = tabBar ? objc_getAssociatedObject(tabBar, kCommandBarKey) : nil;
    if (!bar || bar.suppressed == suppressed) return;
    bar.suppressed = suppressed;
    W7SafariForEachControl(bar, v, v.hidden = suppressed);
}

void W7SafariHideOverlaysOverTabs(NSView *tabBar) {
    @try {
        W7SafariCommandBar *bar = tabBar ? objc_getAssociatedObject(tabBar, kCommandBarKey) : nil;
        id visible = W7SafariIvar(tabBar, "_visibleTabBarButtons");
        if (!bar || bar.suppressed || ![visible conformsToProtocol:@protocol(NSFastEnumeration)]) return;
        CGRect tabs[64];
        NSInteger n = 0;
        for (NSView *b in visible)
            if ([b isKindOfClass:NSView.class] && !b.isHiddenOrHasHiddenAncestor && b.superview && n < 64)
                tabs[n++] = CGRectInset([tabBar convertRect:b.frame fromView:b.superview], 1, 1);
        __block NSInteger hidden = 0;
        W7SafariForEachControl(bar, v, {
            if (v.superview != tabBar) continue;
            BOOL over = NO;
            for (NSInteger i = 0; i < n && !over; i++) over = CGRectIntersectsRect(v.frame, tabs[i]);
            if (over && v == bar.stub) { v.hidden = YES; continue; }   // the stub just has no room
            if (v.isHidden != over) v.hidden = over;
            hidden += over;
        });
        static NSInteger logged;
        if (hidden && logged < 5) {
            logged++;
            os_log(W7Log(), "Safari command bar: %ld control(s) hidden where Safari's tabs lie under them", (long)hidden);
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari command bar overlap check failed: %{public}@", e.reason ?: @"unknown"); }
}

void W7SafariRemoveCommandBar(NSView *tabBar) {
    @try {
        W7SafariCommandBar *bar = tabBar ? objc_getAssociatedObject(tabBar, kCommandBarKey) : nil;
        if (!bar) return;
        objc_setAssociatedObject(tabBar, kCommandBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        W7SafariWindowState *st = W7SafariState(tabBar.window, NO);
        if (st.commandBar == bar) st.commandBar = nil;
        W7SafariForEachControl(bar, v, [v removeFromSuperview]);
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari command bar removal failed: %{public}@", e.reason ?: @"unknown"); }
}

#pragma mark - Tests' view of the controls

NSView *W7SafariCommandBarControl(NSView *tabBar, NSString *name) {
    W7SafariCommandBar *bar = tabBar ? objc_getAssociatedObject(tabBar, kCommandBarKey) : nil;
    __block W7SafariCommandButton *found = nil;
    if (bar) W7SafariForEachControl(bar, v, { if (!found && [v.name isEqualToString:name]) found = v; });
    return found;
}

static W7SafariCommandButton *W7SafariCommandButtonOf(NSView *control) {
    return [control isKindOfClass:W7SafariCommandButton.class] ? (W7SafariCommandButton *)control : nil;
}

NSString *W7SafariCommandControlAction(NSView *control) { return W7SafariCommandButtonOf(control).actionName; }
BOOL W7SafariCommandControlIsDisabled(NSView *control) { return W7SafariCommandButtonOf(control).disabled; }
BOOL W7SafariCommandControlClick(NSView *control) { return [W7SafariCommandButtonOf(control) w7Click]; }

NSMenu *W7SafariCommandControlMenu(NSView *control) {
    W7SafariCommandButton *b = W7SafariCommandButtonOf(control);
    NSString *command = b.commandName ?: b.menuCommandName;
    return command ? W7SafariBuildCommandMenu(W7SafariCommandMainMenu(), command, [NSMutableArray array]) : nil;
}
