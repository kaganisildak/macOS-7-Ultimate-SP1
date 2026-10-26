// Explorer command bar: on the left the Windows 7 contextual buttons for Finder's selection (
// W7ExplorerCommandsForItems: Organize ▾, Open / Open ▾ / Open with ▾, Share with, Slide show, Print,
// E-mail, Burn, New folder); on the right the views button (icon cycles, ▾ opens the menu), the
// preview pane toggle and help. Everything performs Finder's own main-menu items (found by key
// equivalent), NSWorkspace (open with an application), NSSharingService (e-mail) or the macOS share
// picker; Organize also holds the Browse folders options (W7ExplorerBrowse.m). Buttons that do not fit
// left of the view buttons are left out. On Finder's Computer location (the Computer view) the left
// buttons are the Computer set instead (W7ExplorerCommandsForComputer, W7ExplorerPerformComputerCommand) and the
// views and preview buttons, which would act on Finder's view under the overlay, are disabled.
#import "W7ExplorerInternal.h"
#import <objc/message.h>

static const CGFloat kButtonHeight = 24;
static const CGFloat kButtonPad = 9;
static const CGFloat kChevronSpace = 11;   // room for a ▾ after a menu button's title
static const CGFloat kEdgeInset = 6;
static const CGFloat kGap = 1;
static const CGFloat kIconButtonWidth = 27;
static const CGFloat kSplitChevronWidth = 14;
static const CGFloat kLeftRightGap = 8;    // the left buttons stop this far from the view buttons
static const NSUInteger kMaxOpenWithApps = 10;

// Hit-test slots: the left buttons use their W7ExplorerCommand value, then these.
enum {
    kSlotOpenChevron = W7ExplorerCommandCount,   // the ▾ half of Open ▾
    kSlotViewsIcon, kSlotViewsMenu, kSlotPreview, kSlotHelp,
    kSlotCount
};

/// One Finder shortcut: title, key equivalent, modifiers. A nil key is a separator.
typedef struct { NSString *__unsafe_unretained title; NSString *__unsafe_unretained key; NSEventModifierFlags mods; } W7CommandEntry;

static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand;
static const NSEventModifierFlags kShiftCmd = NSEventModifierFlagShift | NSEventModifierFlagCommand;
static const NSEventModifierFlags kOptionCmd = NSEventModifierFlagOption | NSEventModifierFlagCommand;

static const W7CommandEntry kOrganizeEntries[] = {
    { @"Cut", @"x", kCmd }, { @"Copy", @"c", kCmd }, { @"Paste", @"v", kCmd }, { @"Undo", @"z", kCmd },
    { @"Select all", @"a", kCmd }, { nil, nil, 0 },
    { @"Delete", @"\x08", kCmd },   // Move to Trash
    { nil, nil, 0 },
    { @"Properties", @"i", kCmd },  // Get Info
};
static const W7CommandEntry kViewEntries[] = {
    { @"Icons", @"1", kCmd }, { @"List", @"2", kCmd }, { @"Columns", @"3", kCmd }, { @"Gallery", @"4", kCmd },
};
static const W7CommandEntry kNewFolderEntry = { @"New folder", @"n", kShiftCmd };
static const W7CommandEntry kPreviewEntry = { @"Preview pane", @"p", kShiftCmd };
static const W7CommandEntry kHelpEntry = { @"Help", @"?", kCmd };
static const W7CommandEntry kOpenEntry = { @"Open", @"o", kCmd };
static const W7CommandEntry kPrintEntry = { @"Print", @"p", kCmd };
static const W7CommandEntry kSlideShowEntry = { @"Slide show", @"y", kOptionCmd };   // File ▸ Slideshow (Option)
static const W7CommandEntry kSelectAllEntry = { @"Select all", @"a", kCmd };
static const W7CommandEntry kDeselectAllEntry = { @"Deselect all", @"a", kOptionCmd };   // Edit ▸ Deselect All
static const W7CommandEntry kGetInfoEntry = { @"Choose default program…", @"i", kCmd };   // Get Info ▸ Open with

#define W7_COUNT(a) (sizeof(a) / sizeof((a)[0]))

static NSColor *W7CommandTextColor(BOOL enabled) {
    if (!enabled) return [NSColor colorWithSRGBRed:0x6D / 255.0 green:0x6D / 255.0 blue:0x6D / 255.0 alpha:1];
    W7RGBA c = W7RGBAFromHex(W7ExplorerTextHex, 1);
    return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:1];
}

#pragma mark - Menus

/// A proxy menu for `entries`: each row mirrors its Finder item's enabled state (and checkmark).
static NSMenu *W7EntriesMenu(const W7CommandEntry *entries, NSUInteger count, W7ExplorerController *ex) {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    NSMutableArray<NSMenuItem *> *found = [NSMutableArray array];
    NSMutableArray *matches = [NSMutableArray array];   // NSMenuItem or NSNull, parallel to entries
    for (NSUInteger i = 0; i < count; i++) {
        NSMenuItem *item = entries[i].key ? [ex itemForKey:entries[i].key mods:entries[i].mods] : nil;
        if (item) [found addObject:item];
        [matches addObject:item ?: (id)NSNull.null];
    }
    [ex validateItems:found];
    for (NSUInteger i = 0; i < count; i++) {
        if (!entries[i].key) { [menu addItem:NSMenuItem.separatorItem]; continue; }
        NSMenuItem *proxy = W7ExplorerProxyItem(ex, entries[i].title, entries[i].key, entries[i].mods);
        NSMenuItem *finderItem = [matches[i] isKindOfClass:NSMenuItem.class] ? matches[i] : nil;
        proxy.enabled = finderItem.isEnabled;
        proxy.state = finderItem ? finderItem.state : NSControlStateValueOff;
        [menu addItem:proxy];
    }
    return menu;
}

/// Finder's Organize entries, then the Browse folders options (their own action, no Finder shortcut).
static NSMenu *W7OrganizeMenu(W7ExplorerController *ex) {
    NSMenu *menu = W7EntriesMenu(kOrganizeEntries, W7_COUNT(kOrganizeEntries), ex);
    W7ExplorerAppendBrowseItems(menu);
    return menu;
}

NSMenu *W7ExplorerOrganizeMenu(NSWindow *window) {
    @try {
        W7ExplorerController *ex = W7ExplorerControllerForWindow(window);
        return ex ? W7OrganizeMenu(ex) : nil;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer Organize menu failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

/// The applications that open `url`, the default one first (at most kMaxOpenWithApps).
static NSArray<NSURL *> *W7ApplicationsFor(NSURL *url) {
    NSWorkspace *ws = NSWorkspace.sharedWorkspace;
    NSMutableArray<NSURL *> *apps = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSURL *def = [ws URLForApplicationToOpenURL:url];
    for (NSURL *app in [@[ def ?: (id)NSNull.null ] arrayByAddingObjectsFromArray:[ws URLsForApplicationsToOpenURL:url] ?: @[]]) {
        if (![app isKindOfClass:NSURL.class]) continue;
        NSString *key = app.URLByStandardizingPath.path;
        if (!key.length || [seen containsObject:key]) continue;
        [seen addObject:key];
        [apps addObject:app];
        if (apps.count == kMaxOpenWithApps) break;
    }
    return apps;
}

#pragma mark - Icons

/// "Change your view": a 2×2 grid of small blue tiles.
static void W7DrawViewsIcon(CGContextRef ctx, NSRect r, BOOL enabled) {
    CGFloat s = 5, gap = 2, x0 = floor(NSMidX(r) - s - gap / 2), y0 = floor(NSMidY(r) - s - gap / 2);
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, enabled ? 1 : 0.45);
    for (int i = 0; i < 4; i++) {
        CGRect t = CGRectMake(x0 + (i % 2) * (s + gap), y0 + (i / 2) * (s + gap), s, s);
        CGContextSetRGBFillColor(ctx, 0x6C / 255.0, 0xA2 / 255.0, 0xE4 / 255.0, 1);
        CGContextFillRect(ctx, t);
        CGContextSetRGBStrokeColor(ctx, 0x1F / 255.0, 0x4E / 255.0, 0x8C / 255.0, 1);
        CGContextSetLineWidth(ctx, 1);
        CGContextStrokeRect(ctx, CGRectInset(t, 0.5, 0.5));
    }
    CGContextRestoreGState(ctx);
}

/// "Show the preview pane": a window outline with its right third filled.
static void W7DrawPreviewIcon(CGContextRef ctx, NSRect r, BOOL enabled) {
    CGRect w = CGRectMake(floor(NSMidX(r) - 7) + 0.5, floor(NSMidY(r) - 5.5) + 0.5, 14, 11);
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, enabled ? 1 : 0.45);
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, w);
    CGContextSetRGBFillColor(ctx, 0x6C / 255.0, 0xA2 / 255.0, 0xE4 / 255.0, 1);
    CGContextFillRect(ctx, CGRectMake(CGRectGetMaxX(w) - 5, w.origin.y, 5, w.size.height));
    CGContextSetRGBStrokeColor(ctx, 0x1E / 255.0, 0x39 / 255.0, 0x5B / 255.0, 1);
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokeRect(ctx, w);
    CGContextMoveToPoint(ctx, CGRectGetMaxX(w) - 5, w.origin.y);
    CGContextAddLineToPoint(ctx, CGRectGetMaxX(w) - 5, CGRectGetMaxY(w));
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

/// The user's Help icon, kept per loader generation so a redraw only compares a counter.
NSImage *W7ExplorerCommandHelpIcon(void) {
    static NSImage *icon;
    static NSUInteger generation = NSUIntegerMax;
    @try {
        NSUInteger now = W7UserIconsGeneration();
        if (now != generation) {
            icon = W7UserIconImage(@"help", 16);   // shared: drawn, never mutated
            generation = now;
        }
        return icon;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer help icon failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

#pragma mark - View

@interface W7ExplorerCommandBarView : NSView
- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer;
/// The left buttons (NSNumber-wrapped W7ExplorerCommand), in order.
@property (nonatomic, copy) NSArray<NSNumber *> *commands;
- (void)setEnabled:(BOOL)enabled forSlot:(NSInteger)slot;
@end

@implementation W7ExplorerCommandBarView {
    __weak W7ExplorerController *_explorer;
    BOOL _enabled[kSlotCount];
    NSInteger _hover, _pressed, _open;
    NSTrackingArea *_tracking;
    NSTimer *_slideShowTimer;   // watches the Quick Look panel to restore an empty selection
}

- (void)dealloc { [_slideShowTimer invalidate]; }

- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer {
    if ((self = [super initWithFrame:frame])) {
        _explorer = explorer;
        for (int i = 0; i < kSlotCount; i++) _enabled[i] = YES;
        _enabled[W7ExplorerCommandBurn] = NO;
        _hover = _pressed = _open = NSNotFound;
        _commands = W7ExplorerCommandsForItems(@[], NO);
        self.autoresizingMask = NSViewWidthSizable;
    }
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setCommands:(NSArray<NSNumber *> *)commands {
    if ([_commands isEqualToArray:commands ?: @[]]) return;
    _commands = [commands copy] ?: @[];
    _hover = _pressed = NSNotFound;
    self.needsDisplay = YES;
}

- (void)setEnabled:(BOOL)enabled forSlot:(NSInteger)slot {
    if (slot < 0 || slot >= kSlotCount) return;
    if (slot == W7ExplorerCommandBurn) enabled = NO;   // nothing to burn to on a Mac
    if (_enabled[slot] == enabled) return;
    _enabled[slot] = enabled;
    self.needsDisplay = YES;
}

- (CGFloat)w7TextWidth:(NSString *)title {
    return ceil([title sizeWithAttributes:@{ NSFontAttributeName: W7ExplorerFont() }].width);
}

- (CGFloat)w7Y { return floor((NSHeight(self.bounds) - kButtonHeight) / 2) + 0.5; }   // above the bottom line

- (NSRect)w7RightRect:(NSInteger)slot {
    CGFloat y = [self w7Y], right = NSWidth(self.bounds) - kEdgeInset;
    NSRect help = NSMakeRect(right - kIconButtonWidth, y, kIconButtonWidth, kButtonHeight);
    NSRect preview = NSMakeRect(NSMinX(help) - kGap - kIconButtonWidth, y, kIconButtonWidth, kButtonHeight);
    NSRect menu = NSMakeRect(NSMinX(preview) - kGap - kSplitChevronWidth, y, kSplitChevronWidth, kButtonHeight);
    NSRect icon = NSMakeRect(NSMinX(menu) - kIconButtonWidth, y, kIconButtonWidth, kButtonHeight);
    switch (slot) {
        case kSlotViewsIcon: return icon;
        case kSlotViewsMenu: return menu;
        case kSlotPreview: return preview;
        case kSlotHelp: return help;
        default: return NSZeroRect;
    }
}

/// Each left button's whole rect, parallel to `commands`; NSZeroRect for the ones that do not fit.
- (NSArray<NSValue *> *)w7LeftFrames {
    CGFloat y = [self w7Y], x = kEdgeInset, limit = NSMinX([self w7RightRect:kSlotViewsIcon]) - kLeftRightGap;
    NSMutableArray<NSValue *> *frames = [NSMutableArray arrayWithCapacity:_commands.count];
    BOOL full = NO;
    for (NSNumber *n in _commands) {
        W7ExplorerCommand cmd = n.integerValue;
        CGFloat w = [self w7TextWidth:W7ExplorerCommandTitle(cmd)] + 2 * kButtonPad;
        if (cmd == W7ExplorerCommandOpenMenu) w += kSplitChevronWidth;
        else if (W7ExplorerCommandHasMenu(cmd)) w += kChevronSpace;
        full = full || x + w > limit;
        [frames addObject:[NSValue valueWithRect:full ? NSZeroRect : NSMakeRect(x, y, w, kButtonHeight)]];
        x += w + kGap;
    }
    return frames;
}

/// A slot's hit rect (for Open ▾: the title half, or its ▾ half).
- (NSRect)w7RectForSlot:(NSInteger)slot {
    if (slot >= kSlotViewsIcon) return [self w7RightRect:slot];
    NSArray<NSValue *> *frames = [self w7LeftFrames];
    for (NSUInteger i = 0; i < _commands.count; i++) {
        NSInteger cmd = _commands[i].integerValue;
        NSRect r = frames[i].rectValue;
        if (slot == kSlotOpenChevron && cmd == W7ExplorerCommandOpenMenu)
            return NSIsEmptyRect(r) ? NSZeroRect : NSMakeRect(NSMaxX(r) - kSplitChevronWidth, NSMinY(r), kSplitChevronWidth, NSHeight(r));
        if (cmd != slot) continue;
        if (cmd == W7ExplorerCommandOpenMenu && !NSIsEmptyRect(r)) r.size.width -= kSplitChevronWidth;
        return r;
    }
    return NSZeroRect;
}

- (NSInteger)w7SlotAt:(NSPoint)p {
    NSArray<NSValue *> *frames = [self w7LeftFrames];
    for (NSUInteger i = 0; i < _commands.count; i++) {
        NSRect r = frames[i].rectValue;
        if (!NSPointInRect(p, r)) continue;
        NSInteger cmd = _commands[i].integerValue;
        if (cmd == W7ExplorerCommandOpenMenu && p.x >= NSMaxX(r) - kSplitChevronWidth) return kSlotOpenChevron;
        return cmd;
    }
    for (NSInteger s = kSlotViewsIcon; s <= kSlotHelp; s++) if (NSPointInRect(p, [self w7RightRect:s])) return s;
    return NSNotFound;
}

- (W7ControlState)w7StateFor:(NSInteger)k {
    if (!_enabled[k]) return W7StateDisabled;
    if (k == _open || (k == _pressed && k == _hover)) return W7StatePressed;
    if (k == _hover && _pressed == NSNotFound && _open == NSNotFound) return W7StateHover;
    return W7StateNormal;
}

/// A split button lights as one when either half is hovered or pressed.
- (W7ControlState)w7StateForSplit:(NSInteger)a and:(NSInteger)b {
    W7ControlState sa = [self w7StateFor:a], sb = [self w7StateFor:b];
    if (sa == W7StatePressed || sb == W7StatePressed) return W7StatePressed;
    if (sa == W7StateHover || sb == W7StateHover) return W7StateHover;
    return sa;
}

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        W7DrawCommandBar(ctx, self.bounds);
        NSFont *font = W7ExplorerFont();
        NSArray<NSValue *> *frames = [self w7LeftFrames];
        for (NSUInteger i = 0; i < _commands.count; i++) {
            NSRect r = frames[i].rectValue;
            if (NSIsEmptyRect(r)) continue;
            W7ExplorerCommand cmd = _commands[i].integerValue;
            BOOL split = cmd == W7ExplorerCommandOpenMenu;
            W7ControlState st = split ? [self w7StateForSplit:cmd and:kSlotOpenChevron] : [self w7StateFor:cmd];
            W7DrawCommandButton(ctx, r, st);
            BOOL enabled = _enabled[cmd];
            NSString *title = W7ExplorerCommandTitle(cmd);
            NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: W7CommandTextColor(enabled) };
            NSSize ts = [title sizeWithAttributes:attrs];
            [title drawAtPoint:NSMakePoint(NSMinX(r) + kButtonPad, floor(NSMidY(r) - ts.height / 2)) withAttributes:attrs];
            if (!W7ExplorerCommandHasMenu(cmd)) continue;
            uint32_t hex = (split ? _enabled[kSlotOpenChevron] : enabled) ? W7ExplorerTextHex : 0x6D6D6D;
            CGFloat cx = split ? NSMaxX(r) - kSplitChevronWidth / 2 - 1 : NSMinX(r) + kButtonPad + ts.width + 6.5;
            W7DrawChevron(ctx, NSMakePoint(cx, NSMidY(r) - 0.5), W7ChevronDown, hex, 1);
        }
        W7ControlState views = [self w7StateForSplit:kSlotViewsIcon and:kSlotViewsMenu];
        for (NSInteger s = kSlotViewsIcon; s <= kSlotHelp; s++) {
            NSRect r = [self w7RightRect:s];
            BOOL enabled = _enabled[s];
            W7ControlState st = [self w7StateFor:s];
            if ((s == kSlotViewsIcon || s == kSlotViewsMenu) && st == W7StateNormal && views == W7StateHover) st = W7StateHover;
            W7DrawCommandButton(ctx, r, st);
            switch (s) {
                case kSlotViewsIcon: W7DrawViewsIcon(ctx, r, enabled); break;
                case kSlotViewsMenu:
                    W7DrawChevron(ctx, NSMakePoint(NSMidX(r) - 1, NSMidY(r) - 0.5), W7ChevronDown, enabled ? W7ExplorerTextHex : 0x6D6D6D, 1);
                    break;
                case kSlotPreview: W7DrawPreviewIcon(ctx, r, enabled); break;
                case kSlotHelp: {
                    NSRect glyph = NSInsetRect(r, (NSWidth(r) - 16) / 2, (NSHeight(r) - 16) / 2);
                    NSImage *help = W7ExplorerCommandHelpIcon();
                    if (help) {
                        [help drawInRect:glyph fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
                          respectFlipped:YES hints:nil];
                    } else {
                        W7DrawHelpButton(ctx, glyph);
                    }
                    break;
                }
                default: break;
            }
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer command bar draw failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
          owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)e {
    @try {
        NSInteger h = [self w7SlotAt:[self convertPoint:e.locationInWindow fromView:nil]];
        if (h != _hover) { _hover = h; self.needsDisplay = YES; }
    } @catch (NSException *x) { os_log_error(W7Log(), "Explorer command mouseMoved failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseExited:(NSEvent *)e {
    @try { if (_hover != NSNotFound) { _hover = NSNotFound; self.needsDisplay = YES; } }
    @catch (NSException *x) { os_log_error(W7Log(), "Explorer command mouseExited failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)w7OpenMenu:(NSMenu *)menu forSlot:(NSInteger)slot {
    NSRect br = [self w7RectForSlot:slot];
    if (slot == kSlotViewsMenu) br = NSUnionRect(br, [self w7RectForSlot:kSlotViewsIcon]);
    if (slot == kSlotOpenChevron) br = NSUnionRect(br, [self w7RectForSlot:W7ExplorerCommandOpenMenu]);
    NSRect r = [self.window convertRectToScreen:[self convertRect:br toView:nil]];
    _open = slot;
    self.needsDisplay = YES;
    [self displayIfNeeded];
    [W7MenuWindow popUpMenu:menu topLeft:NSMakePoint(NSMinX(r), NSMinY(r)) minWidth:0];
}

/// Icons → List → Columns → Gallery → Icons, from the view Finder marks as current.
- (void)w7CycleViews:(W7ExplorerController *)ex {
    NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < W7_COUNT(kViewEntries); i++) {
        NSMenuItem *item = [ex itemForKey:kViewEntries[i].key mods:kViewEntries[i].mods];
        if (item) [items addObject:item];
    }
    [ex validateItems:items];
    NSUInteger current = NSNotFound;
    for (NSUInteger i = 0; i < W7_COUNT(kViewEntries); i++) {
        NSMenuItem *item = [ex itemForKey:kViewEntries[i].key mods:kViewEntries[i].mods];
        if (item.state == NSControlStateValueOn) { current = i; break; }
    }
    NSUInteger next = current == NSNotFound ? 1 : (current + 1) % W7_COUNT(kViewEntries);
    for (NSUInteger tries = 0; tries < W7_COUNT(kViewEntries); tries++, next = (next + 1) % W7_COUNT(kViewEntries)) {
        if ([ex performKey:kViewEntries[next].key mods:kViewEntries[next].mods]) return;
    }
}

/// Open ▾ / Open with ▾: the applications for the selected file (the default one first), then
/// "Choose default program…" (Finder's Get Info, whose Open with section changes the default).
- (NSMenu *)w7OpenWithMenu:(W7ExplorerController *)ex {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    NSURL *url = ex.selection.urls.firstObject;
    if (url) {
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSURL *app in W7ApplicationsFor(url)) {
            NSString *name = [[fm displayNameAtPath:app.path] stringByDeletingPathExtension] ?: app.lastPathComponent;
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name ?: @"" action:@selector(w7OpenWithApp:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = app;
            NSImage *icon = [[NSWorkspace.sharedWorkspace iconForFile:app.path] copy];
            icon.size = NSMakeSize(16, 16);
            item.image = icon;
            [menu addItem:item];
        }
        if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
    }
    NSMenuItem *getInfo = [ex itemForKey:kGetInfoEntry.key mods:kGetInfoEntry.mods];
    if (getInfo) [ex validateItems:@[ getInfo ]];
    NSMenuItem *choose = W7ExplorerProxyItem(ex, kGetInfoEntry.title, kGetInfoEntry.key, kGetInfoEntry.mods);
    choose.enabled = getInfo.isEnabled;
    [menu addItem:choose];
    return menu;
}

- (void)w7OpenWithApp:(NSMenuItem *)sender {
    @try {
        NSURL *app = [sender.representedObject isKindOfClass:NSURL.class] ? sender.representedObject : nil;
        NSArray<NSURL *> *urls = _explorer.selection.urls;
        if (!app || urls.count == 0) return;
        [NSWorkspace.sharedWorkspace openURLs:urls withApplicationAtURL:app configuration:[NSWorkspaceOpenConfiguration configuration]
                            completionHandler:^(NSRunningApplication *running, NSError *error) {
            if (error) os_log_error(W7Log(), "Explorer: open with %{public}@ failed: %{public}@", app.lastPathComponent, error.localizedDescription);
        }];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer open with failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// E-mail: a new message with the selected files attached.
- (void)w7Email:(W7ExplorerController *)ex {
    NSArray<NSURL *> *urls = ex.selection.urls;
    NSSharingService *mail = [NSSharingService sharingServiceNamed:NSSharingServiceNameComposeEmail];
    if (urls.count && [mail canPerformWithItems:urls]) [mail performWithItems:urls];
    else NSBeep();
}

/// Whether Quick Look's shared panel is on screen (QLPreviewPanel is looked up at run time).
static BOOL W7QuickLookPanelVisible(Class panelClass) {
    if (!((BOOL (*)(id, SEL))objc_msgSend)(panelClass, sel_registerName("sharedPreviewPanelExists"))) return NO;
    NSWindow *panel = ((id (*)(id, SEL))objc_msgSend)(panelClass, sel_registerName("sharedPreviewPanel"));
    return [panel isKindOfClass:NSWindow.class] && panel.isVisible;
}

/// Slide show: Finder's Quick Look slideshow (File ▸ Slideshow, ⌥⌘Y) of the selection. Only for a
/// selection known to be empty (W7ExplorerSlideShowPlanFor: the snapshot and Finder's live count both
/// say 0, Deselect All exists and the Quick Look panel can be watched) is everything selected first;
/// the empty selection comes back (⌥⌘A) when the panel closes. Folders are part of that slideshow, as
/// in Finder's own. In every other case only ⌥⌘Y is sent, so a selection never seen is never replaced.
- (void)w7SlideShow:(W7ExplorerController *)ex {
    Class panelClass = NSClassFromString(@"QLPreviewPanel");
    BOOL canWatch = panelClass && [panelClass respondsToSelector:sel_registerName("sharedPreviewPanelExists")] &&
                    [panelClass respondsToSelector:sel_registerName("sharedPreviewPanel")];
    BOOL canRestore = canWatch && [ex itemForKey:kDeselectAllEntry.key mods:kDeselectAllEntry.mods] != nil;
    W7ExplorerSlideShowPlan plan = W7ExplorerSlideShowPlanFor(ex.selection, [ex.selectionTracker liveSelectedCount], canRestore);
    if (plan == W7ExplorerSlideShowSelection) {
        if (![ex performKey:kSlideShowEntry.key mods:kSlideShowEntry.mods]) NSBeep();
        return;
    }
    if (![ex performKey:kSelectAllEntry.key mods:kSelectAllEntry.mods]) { NSBeep(); return; }
    if (![ex performKey:kSlideShowEntry.key mods:kSlideShowEntry.mods]) {
        [ex performKey:kDeselectAllEntry.key mods:kDeselectAllEntry.mods];
        NSBeep();
        return;
    }
    [_slideShowTimer invalidate];
    __weak W7ExplorerController *weakEx = ex;
    __block BOOL seen = NO;
    __block NSUInteger ticks = 0;
    __block NSInteger allCount = -1;   // the select-all count, once the tracker has read it
    _slideShowTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        @try {
            W7ExplorerController *e = weakEx;
            ticks++;
            if (!e || ticks > 4 * 3600) { [t invalidate]; return; }   // window gone, or two hours: give up
            if (allCount <= 0) allCount = e.selection.selectedCount;   // until the tracker has read the select-all
            BOOL visible = W7QuickLookPanelVisible(panelClass);
            seen = seen || visible;
            if (visible || (!seen && ticks < 6)) return;   // running, or still opening (3 s grace)
            [t invalidate];
            // Only when the user has not picked something else meanwhile.
            if (allCount > 0 && e.selection.selectedCount == allCount) [e performKey:kDeselectAllEntry.key mods:kDeselectAllEntry.mods];
        } @catch (NSException *x) {
            [t invalidate];
            os_log_error(W7Log(), "Explorer slide show restore failed: %{public}@", x.reason ?: @"unknown");
        }
    }];
}

- (void)mouseDown:(NSEvent *)e {
    // The chosen action may close the window and release this view; keep it alive to the end.
    W7ExplorerCommandBarView *keep = self;
    @try {
        NSInteger k = [self w7SlotAt:[self convertPoint:e.locationInWindow fromView:nil]];
        W7ExplorerController *ex = _explorer;
        if (k == NSNotFound || !_enabled[k] || !ex) return;
        switch (k) {
            case W7ExplorerCommandOrganize:
                [self w7OpenMenu:W7OrganizeMenu(ex) forSlot:k];
                break;
            case W7ExplorerCommandOpenWith:
            case kSlotOpenChevron:
                [self w7OpenMenu:[self w7OpenWithMenu:ex] forSlot:k];
                break;
            case kSlotViewsMenu:
                [self w7OpenMenu:W7EntriesMenu(kViewEntries, W7_COUNT(kViewEntries), ex) forSlot:k];
                break;
            default:
                _pressed = k;
                _hover = k;
                self.needsDisplay = YES;
                return;
        }
    } @catch (NSException *x) {
        os_log_error(W7Log(), "Explorer command click failed: %{public}@", x.reason ?: @"unknown");
    }
    keep->_open = NSNotFound;
    keep.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent *)e {
    @try {
        if (_pressed == NSNotFound) return;
        NSInteger h = [self w7SlotAt:[self convertPoint:e.locationInWindow fromView:nil]];
        if (h != _hover) { _hover = h; self.needsDisplay = YES; }
    } @catch (NSException *x) { os_log_error(W7Log(), "Explorer command mouseDragged failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseUp:(NSEvent *)e {
    W7ExplorerCommandBarView *keep = self;
    @try {
        NSInteger pressed = _pressed;
        _pressed = NSNotFound;
        self.needsDisplay = YES;
        W7ExplorerController *ex = _explorer;
        if (pressed == NSNotFound || !ex) return;
        if ([self w7SlotAt:[self convertPoint:e.locationInWindow fromView:nil]] != pressed) return;
        switch (pressed) {
            case W7ExplorerCommandOpen:
            case W7ExplorerCommandOpenMenu: [ex performKey:kOpenEntry.key mods:kOpenEntry.mods]; break;
            case W7ExplorerCommandShare: [ex shareFromView:self rect:[self w7RectForSlot:W7ExplorerCommandShare]]; break;
            case W7ExplorerCommandSlideShow: [self w7SlideShow:ex]; break;
            case W7ExplorerCommandPrint: [ex performKey:kPrintEntry.key mods:kPrintEntry.mods]; break;
            case W7ExplorerCommandEmail: [self w7Email:ex]; break;
            case W7ExplorerCommandNewFolder: [ex performKey:kNewFolderEntry.key mods:kNewFolderEntry.mods]; break;
            case kSlotViewsIcon: [self w7CycleViews:ex]; break;
            case kSlotPreview: [ex performKey:kPreviewEntry.key mods:kPreviewEntry.mods]; break;
            case kSlotHelp:
                if (![ex performKey:kHelpEntry.key mods:kHelpEntry.mods]) [NSApp showHelp:nil];
                break;
            case W7ExplorerCommandSystemProperties:
            case W7ExplorerCommandUninstallProgram:
            case W7ExplorerCommandMapNetworkDrive:
            case W7ExplorerCommandOpenControlPanel:
                W7ExplorerPerformComputerCommand(ex, (W7ExplorerCommand)pressed);
                break;
            default: break;
        }
    } @catch (NSException *x) {
        os_log_error(W7Log(), "Explorer command mouseUp failed: %{public}@", x.reason ?: @"unknown");
    }
    (void)keep;
}

@end

#pragma mark - Controller

@implementation W7ExplorerCommandBarController {
    __weak W7ExplorerController *_explorer;
}

- (instancetype)initWithExplorer:(W7ExplorerController *)explorer {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _explorer = explorer;
        self.layoutAttribute = NSLayoutAttributeBottom;
        // Before the view is set: otherwise AppKit resizes bottom accessories to its standard height (36 pt).
        self.automaticallyAdjustsSize = NO;
        self.view = [[W7ExplorerCommandBarView alloc] initWithFrame:NSMakeRect(0, 0, 800, W7ExplorerCommandBarHeight)
                                                           explorer:explorer];
        self.fullScreenMinHeight = W7ExplorerCommandBarHeight;
    }
    return self;
}

- (void)selectionChanged {
    @try {
        W7ExplorerSelectionSnapshot *s = _explorer.selection;
        W7ExplorerCommandBarView *v = (W7ExplorerCommandBarView *)self.view;
        if (_explorer.computer.shown) {
            v.commands = W7ExplorerCommandsForComputer();
            [self w7ValidateComputerCommands];
            return;
        }
        v.commands = s.unread ? W7ExplorerCommandsForUnreadSelection() : W7ExplorerCommandsForItems(s.items ?: @[], s.folderHasImages);
        [self validateSelectionCommands];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer command selection update failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// The buttons that depend on the selection follow Finder's items (Open, Print, Slide show), the
/// selection (Open with) and the compose service (E-mail). Menu validation follows the key window's
/// responder chain, so it runs only while key: on a selection change and when the window becomes key.
/// The Computer set follows Finder's Go items (found once, cached); the view buttons are off over the Computer view.
- (void)w7ValidateComputerCommands {
    W7ExplorerController *ex = _explorer;
    W7ExplorerCommandBarView *v = (W7ExplorerCommandBarView *)self.view;
    if (!ex) return;
    for (NSNumber *n in W7ExplorerCommandsForComputer())
        [v setEnabled:W7ExplorerComputerCommandAvailable(ex, n.integerValue) forSlot:n.integerValue];
    [v setEnabled:NO forSlot:kSlotViewsIcon];
    [v setEnabled:NO forSlot:kSlotViewsMenu];
    [v setEnabled:NO forSlot:kSlotPreview];
}

- (void)validateSelectionCommands {
    @try {
        W7ExplorerController *ex = _explorer;
        W7ExplorerCommandBarView *v = (W7ExplorerCommandBarView *)self.view;
        if (ex.computer.shown) { [self w7ValidateComputerCommands]; return; }
        if (!ex || !ex.window.isKeyWindow) return;
        NSMenuItem *open = [ex itemForKey:kOpenEntry.key mods:kOpenEntry.mods];
        NSMenuItem *print = [ex itemForKey:kPrintEntry.key mods:kPrintEntry.mods];
        NSMenuItem *slideShow = [ex itemForKey:kSlideShowEntry.key mods:kSlideShowEntry.mods];
        NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
        if (open) [items addObject:open];
        if (print) [items addObject:print];
        [ex validateItems:items];
        BOOL hasFile = ex.selection.urls.count > 0;
        [v setEnabled:open.isEnabled forSlot:W7ExplorerCommandOpen];
        [v setEnabled:open.isEnabled forSlot:W7ExplorerCommandOpenMenu];
        [v setEnabled:hasFile forSlot:kSlotOpenChevron];
        [v setEnabled:hasFile forSlot:W7ExplorerCommandOpenWith];
        [v setEnabled:slideShow != nil forSlot:W7ExplorerCommandSlideShow];
        [v setEnabled:print.isEnabled forSlot:W7ExplorerCommandPrint];
        static BOOL mailAvailable;   // looked up once
        static dispatch_once_t once;
        dispatch_once(&once, ^{ mailAvailable = [NSSharingService sharingServiceNamed:NSSharingServiceNameComposeEmail] != nil; });
        [v setEnabled:hasFile && mailAvailable forSlot:W7ExplorerCommandEmail];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer command validation failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// The 10 Hz refresh (key window only): Organize, New folder, the view buttons and the preview pane,
/// as before . The selection-dependent buttons are left to -validateSelectionCommands.
- (void)refresh {
    @try {
        W7ExplorerController *ex = _explorer;
        W7ExplorerCommandBarView *v = (W7ExplorerCommandBarView *)self.view;
        if (!ex || ex.computer.shown) return;   // the Computer set is validated when it is shown and on key changes
        BOOL anyOrganize = NO, anyView = NO;
        for (NSUInteger i = 0; i < W7_COUNT(kOrganizeEntries); i++)
            if (kOrganizeEntries[i].key && [ex itemForKey:kOrganizeEntries[i].key mods:kOrganizeEntries[i].mods]) anyOrganize = YES;
        for (NSUInteger i = 0; i < W7_COUNT(kViewEntries); i++)
            if ([ex itemForKey:kViewEntries[i].key mods:kViewEntries[i].mods]) anyView = YES;
        NSMenuItem *newFolder = [ex itemForKey:kNewFolderEntry.key mods:kNewFolderEntry.mods];
        NSMenuItem *preview = [ex itemForKey:kPreviewEntry.key mods:kPreviewEntry.mods];
        NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
        if (newFolder) [items addObject:newFolder];
        if (preview) [items addObject:preview];
        [ex validateItems:items];
        [v setEnabled:anyOrganize forSlot:W7ExplorerCommandOrganize];
        [v setEnabled:newFolder.isEnabled forSlot:W7ExplorerCommandNewFolder];
        [v setEnabled:anyView forSlot:kSlotViewsIcon];
        [v setEnabled:anyView forSlot:kSlotViewsMenu];
        [v setEnabled:preview.isEnabled forSlot:kSlotPreview];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer command refresh failed: %{public}@", e.reason ?: @"unknown");
    }
}

@end
