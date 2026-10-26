// Explorer navigation bar on the Aero glass: the back/forward orbs in their capsule (with the recent-
// pages chevron), the breadcrumb address bar with its refresh button, and the search box.
#import "W7ExplorerInternal.h"

static const CGFloat kCapsuleX = 4;
static const CGFloat kCapsuleWidth = 66;
static const CGFloat kBackSize = 28;
static const CGFloat kForwardSize = 24;
static const CGFloat kAddressX = 76;
static const CGFloat kSearchWidth = 200;
static const CGFloat kSearchInset = 8;
static const CGFloat kSearchGap = 8;
static const CGFloat kBoxHeight = 24;
static const CGFloat kRefreshWidth = 25;
static const CGFloat kDropWidth = 17;
static const CGFloat kSegmentPad = 5;
static const CGFloat kSeparatorWidth = 13;
static const CGFloat kAddressIconX = 4;
static const CGFloat kLeadX = 22;          // the leading ▸ after the folder icon
static const NSUInteger kSubfolderLimit = 60;

// Address-bar parts. Segment i is 2i, the ▸ after segment i is 2i+1.
static const NSInteger kPartLead = -1;
static const NSInteger kPartDrop = -2;
static const NSInteger kPartRefresh = -3;

static NSDictionary *W7NavTextAttrs(void) {
    return @{ NSFontAttributeName: W7ExplorerFont(), NSForegroundColorAttributeName: NSColor.blackColor };
}

static NSString *W7UpArrowKey(void) {
    unichar c = NSUpArrowFunctionKey;
    return [NSString stringWithCharacters:&c length:1];
}

/// A borderless single-line text field in the Explorer font, vertically centred in a 24 pt box.
static NSTextField *W7NavTextField(NSRect boxBounds, CGFloat leftInset, CGFloat rightInset) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.bezeled = NO;
    f.bordered = NO;
    f.drawsBackground = NO;
    f.focusRingType = NSFocusRingTypeNone;
    f.font = W7ExplorerFont();
    f.textColor = NSColor.blackColor;
    f.usesSingleLineMode = YES;
    f.cell.scrollable = YES;
    f.cell.wraps = NO;
    f.lineBreakMode = NSLineBreakByClipping;
    [f sizeToFit];
    CGFloat h = NSHeight(f.frame);
    f.frame = NSMakeRect(leftInset, floor((NSHeight(boxBounds) - h) / 2), MAX(0, NSWidth(boxBounds) - leftInset - rightInset), h);
    f.autoresizingMask = NSViewWidthSizable;
    return f;
}

/// Pops a W7MenuWindow under `rect` (in `view`), unless a menu is already up.
static void W7PopUpUnder(NSMenu *menu, NSView *view, NSRect rect) {
    if (!view.window || menu.numberOfItems == 0 || [W7MenuWindow isTracking]) return;
    NSRect r = [view.window convertRectToScreen:[view convertRect:rect toView:nil]];
    [W7MenuWindow popUpMenu:menu topLeft:NSMakePoint(NSMinX(r), NSMinY(r)) minWidth:0];
}

#pragma mark - Glass

/// Continues the title bar's Aero glass under it: tint plus the frame's side lines. Never hit.
@interface W7ExplorerGlassView : NSView
@property (nonatomic) BOOL active;
@end

@implementation W7ExplorerGlassView
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)setActive:(BOOL)active { if (_active != active) { _active = active; self.needsDisplay = YES; } }
- (void)drawRect:(NSRect)dirty {
    @try {
        NSRect b = self.bounds;
        // The same glass rect as the title bar draws, so the gradient is continuous.
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, b);
        W7DrawGlassFill(ctx, self.window ? W7ExplorerGlassRect(self.window, self) : b, self.active);
        CGContextRestoreGState(ctx);
        [[NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0.55] setFill];
        NSRectFillUsingOperation(NSMakeRect(NSMinX(b), NSMinY(b), 1, NSHeight(b)), NSCompositingOperationSourceOver);
        NSRectFillUsingOperation(NSMakeRect(NSMaxX(b) - 1, NSMinY(b), 1, NSHeight(b)), NSCompositingOperationSourceOver);
        [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.45] setFill];
        NSRectFillUsingOperation(NSMakeRect(NSMinX(b) + 1, NSMinY(b), 1, NSHeight(b)), NSCompositingOperationSourceOver);
        NSRectFillUsingOperation(NSMakeRect(NSMaxX(b) - 2, NSMinY(b), 1, NSHeight(b)), NSCompositingOperationSourceOver);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer glass draw failed: %{public}@", e.reason ?: @"unknown");
    }
}
@end

#pragma mark - Back / forward capsule

typedef NS_ENUM(NSInteger, W7NavPart) { W7NavPartNone = -1, W7NavPartBack = 0, W7NavPartForward = 1, W7NavPartChevron = 2 };

/// Back (larger) and forward orbs joined in one recessed capsule, with the recent-pages chevron.
@interface W7NavCapsule : NSView
- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer;
@property (nonatomic) BOOL backEnabled;
@property (nonatomic) BOOL forwardEnabled;
@end

@implementation W7NavCapsule {
    __weak W7ExplorerController *_explorer;
    W7NavPart _hover, _pressed;
    NSTrackingArea *_tracking;
}

- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer {
    if ((self = [super initWithFrame:frame])) {
        _explorer = explorer;
        _hover = _pressed = W7NavPartNone;
    }
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setBackEnabled:(BOOL)v { if (_backEnabled != v) { _backEnabled = v; self.needsDisplay = YES; } }
- (void)setForwardEnabled:(BOOL)v { if (_forwardEnabled != v) { _forwardEnabled = v; self.needsDisplay = YES; } }

- (NSRect)w7RectFor:(W7NavPart)part {
    CGFloat h = NSHeight(self.bounds);
    switch (part) {
        case W7NavPartBack: return NSMakeRect(0, floor((h - kBackSize) / 2), kBackSize, kBackSize);
        case W7NavPartForward: return NSMakeRect(kBackSize - 1, floor((h - kForwardSize) / 2), kForwardSize, kForwardSize);
        case W7NavPartChevron: return NSMakeRect(kBackSize + kForwardSize - 1, floor((h - 16) / 2), 13, 16);
        default: return NSZeroRect;
    }
}

- (BOOL)w7Enabled:(W7NavPart)part {
    if (part == W7NavPartBack) return _backEnabled;
    if (part == W7NavPartForward) return _forwardEnabled;
    return part == W7NavPartChevron;
}

- (W7NavPart)w7PartAt:(NSPoint)p {
    // The back orb overlaps the forward orb's edge and wins there, as it is drawn on top.
    for (W7NavPart part = W7NavPartBack; part <= W7NavPartForward; part++) {
        NSRect r = [self w7RectFor:part];
        if (hypot(p.x - NSMidX(r), p.y - NSMidY(r)) <= NSWidth(r) / 2) return part;
    }
    if (NSPointInRect(p, NSInsetRect([self w7RectFor:W7NavPartChevron], -1, -3))) return W7NavPartChevron;
    return W7NavPartNone;
}

- (W7ControlState)w7StateFor:(W7NavPart)part {
    if (![self w7Enabled:part]) return W7StateDisabled;
    if (_pressed == part && _hover == part) return W7StatePressed;
    if (_hover == part && _pressed == W7NavPartNone) return W7StateHover;
    return W7StateNormal;
}

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        CGFloat h = NSHeight(self.bounds);
        NSRect chevron = [self w7RectFor:W7NavPartChevron];
        W7DrawNavTrough(ctx, NSMakeRect(2, floor((h - 22) / 2), NSMaxX(chevron) - 1, 22));
        W7ControlState cs = [self w7StateFor:W7NavPartChevron];
        if (cs == W7StateHover || cs == W7StatePressed) {
            NSRect hr = NSInsetRect(chevron, 1, 2);
            [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:cs == W7StatePressed ? 0.25 : 0.45] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:hr xRadius:3 yRadius:3] fill];
        }
        W7DrawChevron(ctx, NSMakePoint(NSMidX(chevron) - 0.5, NSMidY(chevron)), W7ChevronDown, 0x1E395B, 0.9);
        W7DrawNavButton(ctx, [self w7RectFor:W7NavPartForward], YES, [self w7StateFor:W7NavPartForward]);
        W7DrawNavButton(ctx, [self w7RectFor:W7NavPartBack], NO, [self w7StateFor:W7NavPartBack]);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer nav capsule draw failed: %{public}@", e.reason ?: @"unknown");
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

- (W7NavPart)w7PartForEvent:(NSEvent *)e { return [self w7PartAt:[self convertPoint:e.locationInWindow fromView:nil]]; }

- (void)mouseMoved:(NSEvent *)e {
    @try {
        W7NavPart p = [self w7PartForEvent:e];
        if (p != _hover) { _hover = p; self.needsDisplay = YES; }
    } @catch (NSException *x) { os_log_error(W7Log(), "Explorer nav mouseMoved failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseExited:(NSEvent *)e {
    @try { _hover = W7NavPartNone; self.needsDisplay = YES; }
    @catch (NSException *x) { os_log_error(W7Log(), "Explorer nav mouseExited failed: %{public}@", x.reason ?: @"unknown"); }
}

/// Back, Forward and Up one level, mirroring Finder's Go menu items.
- (NSMenu *)w7RecentMenu {
    W7ExplorerController *ex = _explorer;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    NSArray<NSArray<NSString *> *> *spec = @[ @[ @"Back", @"[" ], @[ @"Forward", @"]" ], @[ @"Up one level", W7UpArrowKey() ] ];
    NSMutableArray<NSMenuItem *> *found = [NSMutableArray array];
    for (NSArray<NSString *> *s in spec) {
        NSMenuItem *item = [ex itemForKey:s[1] mods:NSEventModifierFlagCommand];
        if (item) [found addObject:item];
    }
    [ex validateItems:found];
    for (NSUInteger i = 0; i < spec.count; i++) {
        if (i == 2) [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *finder = [ex itemForKey:spec[i][1] mods:NSEventModifierFlagCommand];
        NSMenuItem *proxy = W7ExplorerProxyItem(ex, spec[i][0], spec[i][1], NSEventModifierFlagCommand);
        proxy.enabled = finder.isEnabled;
        [menu addItem:proxy];
    }
    return menu;
}

- (void)mouseDown:(NSEvent *)e {
    W7NavCapsule *keep = self;   // the action may tear the window down
    @try {
        W7NavPart p = [self w7PartForEvent:e];
        if (p == W7NavPartNone || ![self w7Enabled:p]) return;
        _hover = p;
        _pressed = p;
        self.needsDisplay = YES;
        if (p == W7NavPartChevron) {
            [self displayIfNeeded];
            NSRect r = [self w7RectFor:W7NavPartBack];
            W7PopUpUnder([self w7RecentMenu], self, NSMakeRect(NSMinX(r), NSMinY(r) - 2, 1, 1));
            keep->_pressed = W7NavPartNone;
            keep.needsDisplay = YES;
        }
    } @catch (NSException *x) { os_log_error(W7Log(), "Explorer nav mouseDown failed: %{public}@", x.reason ?: @"unknown"); }
    (void)keep;
}

- (void)mouseDragged:(NSEvent *)e {
    @try {
        if (_pressed == W7NavPartNone) return;
        W7NavPart p = [self w7PartForEvent:e];
        if (p != _hover) { _hover = p; self.needsDisplay = YES; }
    } @catch (NSException *x) { os_log_error(W7Log(), "Explorer nav mouseDragged failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseUp:(NSEvent *)e {
    W7NavCapsule *keep = self;
    @try {
        W7NavPart pressed = _pressed;
        _pressed = W7NavPartNone;
        _hover = [self w7PartForEvent:e];
        self.needsDisplay = YES;
        if (pressed == W7NavPartNone || pressed == W7NavPartChevron || _hover != pressed || ![self w7Enabled:pressed]) return;
        [_explorer performKey:pressed == W7NavPartBack ? @"[" : @"]" mods:NSEventModifierFlagCommand];
    } @catch (NSException *x) { os_log_error(W7Log(), "Explorer nav mouseUp failed: %{public}@", x.reason ?: @"unknown"); }
    (void)keep;
}

@end

#pragma mark - Address bar

@interface W7AddressView : NSView <NSTextFieldDelegate>
- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer;
- (void)setLocation:(nullable W7ExplorerLocation *)location;
@end

@implementation W7AddressView {
    __weak W7ExplorerController *_explorer;
    W7ExplorerLocation *_location;
    NSTextField *_editor;
    BOOL _editing, _ending;
    __weak NSResponder *_previousResponder;
    NSInteger _hover, _open;
    NSTrackingArea *_tracking;
}

- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer {
    if ((self = [super initWithFrame:frame])) {
        _explorer = explorer;
        _hover = _open = NSNotFound;
        _editor = W7NavTextField(NSMakeRect(0, 0, NSWidth(frame) - kRefreshWidth, kBoxHeight), 6, 6);
        _editor.delegate = self;
        _editor.hidden = YES;
        [self addSubview:_editor];
    }
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setLocation:(W7ExplorerLocation *)location {
    _location = location;
    _hover = NSNotFound;
    self.needsDisplay = YES;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)w7Segments { return _location.segments ?: @[]; }
- (BOOL)w7Navigable { return _location.path.length > 0; }

- (NSRect)w7BoxRect { return NSMakeRect(0, 0, MAX(0, NSWidth(self.bounds) - kRefreshWidth + 1), NSHeight(self.bounds)); }
- (NSRect)w7RefreshRect { return NSMakeRect(NSWidth(self.bounds) - kRefreshWidth, 0, kRefreshWidth, NSHeight(self.bounds)); }
- (NSRect)w7DropRect { NSRect b = [self w7BoxRect]; return NSMakeRect(NSMaxX(b) - kDropWidth - 1, 1, kDropWidth, NSHeight(b) - 2); }
- (NSRect)w7LeadRect { return NSMakeRect(kLeadX, 1, kSeparatorWidth, NSHeight(self.bounds) - 2); }

/// Segment and separator rects that fit, keeping the newest; earlier segments are dropped first and
/// the leading ▸ turns into «. Keys are part numbers (segment i = 2i, its ▸ = 2i+1).
- (NSDictionary<NSNumber *, NSValue *> *)w7PartRects:(NSInteger *)firstShown {
    NSDictionary *attrs = W7NavTextAttrs();
    NSArray<NSDictionary<NSString *, NSString *> *> *segs = [self w7Segments];
    NSInteger n = (NSInteger)segs.count;
    CGFloat x0 = kLeadX + kSeparatorWidth;
    CGFloat avail = NSMinX([self w7DropRect]) - x0;
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    for (NSDictionary *s in segs) [widths addObject:@(ceil([s[@"title"] sizeWithAttributes:attrs].width) + 2 * kSegmentPad)];
    BOOL navigable = [self w7Navigable];
    CGFloat sepW = navigable ? kSeparatorWidth : 0;
    NSInteger start = n;
    CGFloat total = 0;
    while (start > 0) {
        CGFloat add = widths[(NSUInteger)start - 1].doubleValue + sepW;
        if (total + add > avail && start < n) break;
        total += add;
        start--;
    }
    *firstShown = start;
    NSMutableDictionary<NSNumber *, NSValue *> *rects = [NSMutableDictionary dictionary];
    CGFloat x = x0, h = NSHeight(self.bounds);
    for (NSInteger i = start; i < n; i++) {
        CGFloat w = widths[(NSUInteger)i].doubleValue;
        rects[@(2 * i)] = [NSValue valueWithRect:NSMakeRect(x, 1, w, h - 2)];
        x += w;
        if (navigable) {
            rects[@(2 * i + 1)] = [NSValue valueWithRect:NSMakeRect(x, 1, sepW, h - 2)];
            x += sepW;
        }
    }
    return rects;
}

- (NSInteger)w7PartAt:(NSPoint)p {
    if (NSPointInRect(p, [self w7RefreshRect])) return kPartRefresh;
    if (_editing) return NSNotFound;
    if (NSPointInRect(p, [self w7DropRect])) return kPartDrop;
    if (NSPointInRect(p, [self w7LeadRect]) && [self w7Navigable]) return kPartLead;
    NSInteger first = 0;
    NSDictionary<NSNumber *, NSValue *> *rects = [self w7PartRects:&first];
    for (NSNumber *k in rects) if (NSPointInRect(p, rects[k].rectValue)) return k.integerValue;
    return NSNotFound;
}

- (W7ControlState)w7StateFor:(NSInteger)part {
    if (part == _open) return W7StatePressed;
    if (part == _hover && _open == NSNotFound) return W7StateHover;
    return W7StateNormal;
}

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        NSRect box = [self w7BoxRect], refresh = [self w7RefreshRect];
        W7DrawAddressBar(ctx, refresh, NO);
        W7DrawAddressButton(ctx, refresh, [self w7StateFor:kPartRefresh]);
        W7DrawRefreshGlyph(ctx, refresh, YES);
        W7DrawAddressBar(ctx, box, _editing);
        if (_editing) return;

        NSRect drop = [self w7DropRect];
        W7DrawAddressButton(ctx, drop, [self w7StateFor:kPartDrop]);
        W7DrawChevron(ctx, NSMakePoint(NSMidX(drop), NSMidY(drop)), W7ChevronDown, 0x000000, 0.75);

        [_location.icon drawInRect:NSMakeRect(kAddressIconX, floor((NSHeight(box) - 16) / 2), 16, 16) fromRect:NSZeroRect
                         operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];

        NSDictionary *attrs = W7NavTextAttrs();
        CGFloat textH = ceil([@"Ag" sizeWithAttributes:attrs].height);
        CGFloat ty = floor((NSHeight(box) - textH) / 2);
        NSInteger first = 0;
        NSDictionary<NSNumber *, NSValue *> *rects = [self w7PartRects:&first];
        NSGraphicsContext *gc = NSGraphicsContext.currentContext;
        [gc saveGraphicsState];
        NSRectClip(NSMakeRect(1, 1, NSMinX(drop) - 1, NSHeight(box) - 2));
        BOOL navigable = [self w7Navigable];
        NSRect lead = [self w7LeadRect];
        if (navigable) W7DrawAddressButton(ctx, lead, [self w7StateFor:kPartLead]);
        if (first > 0) {
            NSSize s = [@"«" sizeWithAttributes:attrs];
            [@"«" drawAtPoint:NSMakePoint(NSMidX(lead) - s.width / 2, ty) withAttributes:attrs];
        } else {
            W7DrawChevron(ctx, NSMakePoint(NSMidX(lead), NSMidY(lead)), _open == kPartLead ? W7ChevronDown : W7ChevronRight, 0x000000, navigable ? 0.8 : 0.4);
        }
        NSArray<NSDictionary<NSString *, NSString *> *> *segs = [self w7Segments];
        for (NSInteger i = first; i < (NSInteger)segs.count; i++) {
            NSValue *sv = rects[@(2 * i)], *pv = rects[@(2 * i + 1)];
            if (!sv) continue;
            NSRect r = sv.rectValue;
            W7ControlState segState = [self w7StateFor:2 * i];
            W7ControlState sepState = [self w7StateFor:2 * i + 1];
            // Hovering either half lights the segment and its ▸ together, as Windows 7 does.
            if (navigable && (segState != W7StateNormal || sepState != W7StateNormal)) {
                W7DrawAddressButton(ctx, r, segState == W7StateNormal ? W7StateHover : segState);
                if (pv) W7DrawAddressButton(ctx, pv.rectValue, sepState == W7StateNormal ? W7StateHover : sepState);
            }
            [segs[(NSUInteger)i][@"title"] drawAtPoint:NSMakePoint(NSMinX(r) + kSegmentPad, ty) withAttributes:attrs];
            if (pv) {
                NSRect p = pv.rectValue;
                W7DrawChevron(ctx, NSMakePoint(NSMidX(p), NSMidY(p)), _open == 2 * i + 1 ? W7ChevronDown : W7ChevronRight, 0x000000, 0.8);
            }
        }
        [gc restoreGraphicsState];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer address draw failed: %{public}@", e.reason ?: @"unknown");
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
        NSInteger h = [self w7PartAt:[self convertPoint:e.locationInWindow fromView:nil]];
        if (h != _hover) { _hover = h; self.needsDisplay = YES; }
    } @catch (NSException *x) { os_log_error(W7Log(), "Explorer address mouseMoved failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseExited:(NSEvent *)e {
    @try { if (_hover != NSNotFound) { _hover = NSNotFound; self.needsDisplay = YES; } }
    @catch (NSException *x) { os_log_error(W7Log(), "Explorer address mouseExited failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseDown:(NSEvent *)e {
    @try {
        NSInteger part = [self w7PartAt:[self convertPoint:e.locationInWindow fromView:nil]];
        if (part == kPartRefresh) { [_explorer refreshFolder]; return; }
        if (_editing) return;
        NSArray<NSDictionary<NSString *, NSString *> *> *segs = [self w7Segments];
        if (part == kPartLead) { [self w7ShowLeadMenu]; return; }
        if (part == NSNotFound || part < 0 || (NSUInteger)(part / 2) >= segs.count) { [self w7BeginEditing]; return; }
        NSString *path = segs[(NSUInteger)(part / 2)][@"path"];
        if (part % 2 == 1) [self w7ShowSubfoldersOf:path part:part];
        else if (path.length) [_explorer navigateToPath:path];
        else [self w7BeginEditing];
    } @catch (NSException *x) { os_log_error(W7Log(), "Explorer address click failed: %{public}@", x.reason ?: @"unknown"); }
}

- (NSRect)w7RectForPart:(NSInteger)part {
    if (part == kPartLead) return [self w7LeadRect];
    NSInteger first = 0;
    NSValue *v = [self w7PartRects:&first][@(part)];
    return v ? v.rectValue : NSZeroRect;
}

- (NSMenu *)w7MenuForEntries:(NSArray<NSDictionary<NSString *, NSString *> *> *)entries {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    for (NSDictionary<NSString *, NSString *> *entry in entries) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[@"title"] ?: @"" action:@selector(w7MenuNavigate:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = entry[@"path"];
        // The Windows 7 folder of the entry's kind (no file-system access), else the macOS folder.
        item.image = W7ExplorerMenuIconForPath(entry[@"path"] ?: @"");
        [menu addItem:item];
    }
    return menu;
}

/// Shows `entries` under `part`, drawn pressed (its ▸ turned ▾) while the menu is up.
- (void)w7PopUp:(NSArray<NSDictionary<NSString *, NSString *> *> *)entries part:(NSInteger)part {
    if (!self.window) return;
    if (entries.count == 0) { NSBeep(); return; }
    NSRect r = [self w7RectForPart:part];
    if (NSIsEmptyRect(r)) return;
    W7AddressView *keep = self;
    _open = part;
    self.needsDisplay = YES;
    [self displayIfNeeded];
    W7PopUpUnder([self w7MenuForEntries:entries], self, NSMakeRect(NSMinX(r), NSMinY(r) - 1, 1, 1));
    keep->_open = NSNotFound;
    keep.needsDisplay = YES;
}

/// The ▸ after a segment lists that folder's subfolders (read off the main thread).
- (void)w7ShowSubfoldersOf:(NSString *)path part:(NSInteger)part {
    if (path.length == 0 || [W7MenuWindow isTracking]) return;
    __weak W7AddressView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *entries = @[];
        @try { entries = W7SubfolderEntries(path, kSubfolderLimit); }
        @catch (NSException *e) { os_log_error(W7Log(), "Explorer subfolders failed: %{public}@", e.reason ?: @"unknown"); }
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { [weakSelf w7PopUp:entries part:part]; }
            @catch (NSException *e) { os_log_error(W7Log(), "Explorer subfolder menu failed: %{public}@", e.reason ?: @"unknown"); }
        });
    });
}

/// The leading ▸ lists the dropped segments when the path is truncated, else the home folder and Computer.
- (void)w7ShowLeadMenu {
    NSInteger first = 0;
    [self w7PartRects:&first];
    NSArray<NSDictionary<NSString *, NSString *> *> *segs = [self w7Segments];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries = [NSMutableArray array];
    if (first > 0) {
        for (NSInteger i = first - 1; i >= 0; i--) [entries addObject:segs[(NSUInteger)i]];
    } else {
        NSString *home = NSHomeDirectory();
        [entries addObject:@{ @"title": home.lastPathComponent ?: @"Home", @"path": home }];
        [entries addObject:@{ @"title": @"Computer", @"path": @"/" }];
    }
    [self w7PopUp:entries part:kPartLead];
}

- (void)w7MenuNavigate:(NSMenuItem *)sender {
    @try {
        NSString *path = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
        if (path.length) [_explorer navigateToPath:path];
    } @catch (NSException *e) { os_log_error(W7Log(), "Explorer menu navigate failed: %{public}@", e.reason ?: @"unknown"); }
}

- (void)w7BeginEditing {
    NSWindow *w = self.window;
    if (!w) return;
    NSResponder *prev = w.firstResponder;
    if ([prev isKindOfClass:NSTextView.class] && ((NSTextView *)prev).isFieldEditor) prev = nil;
    _previousResponder = prev;
    _editing = YES;
    _hover = NSNotFound;
    _editor.stringValue = _location.path ?: @"";
    _editor.hidden = NO;
    self.needsDisplay = YES;
    if ([w makeFirstResponder:_editor]) [_editor.currentEditor selectAll:nil];
}

/// `restoreFocus` hands the keyboard back to what had it before (Return / Esc); when focus already
/// moved elsewhere, it stays there.
- (void)w7EndEditingRestoringFocus:(BOOL)restoreFocus {
    if (!_editing || _ending) return;
    _ending = YES;
    _editing = NO;
    NSWindow *w = self.window;
    if (restoreFocus && w) {
        NSResponder *prev = _previousResponder;
        BOOL valid = [prev isKindOfClass:NSView.class] && ((NSView *)prev).window == w;
        [w makeFirstResponder:valid ? prev : nil];
    }
    _editor.hidden = YES;
    _ending = NO;
    self.needsDisplay = YES;
}

- (void)w7CommitEditing {
    NSString *typed = [_editor.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *path = typed.stringByExpandingTildeInPath;
    if (path.length == 0) { [self w7EndEditingRestoringFocus:YES]; return; }
    BOOL isDir = NO;
    if (![path hasPrefix:@"/"] || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        NSBeep();
        return;
    }
    [self w7EndEditingRestoringFocus:YES];
    [_explorer navigateToPath:path];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)sel {
    @try {
        if (sel == @selector(insertNewline:)) { [self w7CommitEditing]; return YES; }
        if (sel == @selector(cancelOperation:)) { [self w7EndEditingRestoringFocus:YES]; return YES; }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer address command failed: %{public}@", e.reason ?: @"unknown");
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)n {
    @try { [self w7EndEditingRestoringFocus:NO]; }
    @catch (NSException *e) { os_log_error(W7Log(), "Explorer address end editing failed: %{public}@", e.reason ?: @"unknown"); }
}

@end

#pragma mark - Search box

@interface W7SearchBox : NSView <NSTextFieldDelegate>
- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer;
@property (nonatomic, copy) NSString *placeholder;
@end

@implementation W7SearchBox {
    __weak W7ExplorerController *_explorer;
    NSTextField *_field;
    BOOL _focused;
}

- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer {
    if ((self = [super initWithFrame:frame])) {
        _explorer = explorer;
        _field = W7NavTextField(NSMakeRect(0, 0, NSWidth(frame), kBoxHeight), 6, 22);
        _field.delegate = self;
        [self addSubview:_field];
    }
    return self;
}

- (void)setPlaceholder:(NSString *)placeholder {
    if ([_placeholder isEqualToString:placeholder]) return;
    _placeholder = [placeholder copy];
    // Windows 7's search hint: grey italic.
    NSFont *font = W7ExplorerFont();
    NSFont *italic = [NSFontManager.sharedFontManager convertFont:font toHaveTrait:NSItalicFontMask] ?: font;
    NSColor *grey = [NSColor colorWithSRGBRed:0x6D / 255.0 green:0x6D / 255.0 blue:0x6D / 255.0 alpha:1];
    _field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:placeholder ?: @""
        attributes:@{ NSFontAttributeName: italic, NSForegroundColorAttributeName: grey }];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        W7DrawSearchBox(ctx, self.bounds, _focused, NO);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer search draw failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)mouseDown:(NSEvent *)e {
    @try { [self.window makeFirstResponder:_field]; }
    @catch (NSException *x) { os_log_error(W7Log(), "Explorer search click failed: %{public}@", x.reason ?: @"unknown"); }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)sel {
    @try {
        if (sel == @selector(insertNewline:)) { [_explorer searchFor:_field.stringValue]; return YES; }
        if (sel == @selector(cancelOperation:)) { _field.stringValue = @""; return YES; }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer search command failed: %{public}@", e.reason ?: @"unknown");
    }
    return NO;
}

- (void)controlTextDidBeginEditing:(NSNotification *)n {
    @try { _focused = YES; self.needsDisplay = YES; }
    @catch (NSException *e) { os_log_error(W7Log(), "Explorer search begin editing failed: %{public}@", e.reason ?: @"unknown"); }
}
- (void)controlTextDidEndEditing:(NSNotification *)n {
    @try { _focused = NO; self.needsDisplay = YES; }
    @catch (NSException *e) { os_log_error(W7Log(), "Explorer search end editing failed: %{public}@", e.reason ?: @"unknown"); }
}

@end

#pragma mark - Bar view

@interface W7ExplorerNavBarView : NSView
- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer;
@property (nonatomic, readonly) W7NavCapsule *capsule;
@property (nonatomic, readonly) W7AddressView *address;
@property (nonatomic, readonly) W7SearchBox *search;
@property (nonatomic, readonly) W7ExplorerGlassView *glass;
@end

@implementation W7ExplorerNavBarView {
    NSVisualEffectView *_effect;
}

- (instancetype)initWithFrame:(NSRect)frame explorer:(W7ExplorerController *)explorer {
    if ((self = [super initWithFrame:frame])) {
        self.autoresizingMask = NSViewWidthSizable;
        // Behind-window blur only with W7TitlebarBlur, as the title bar it continues: by
        // default both are static glass, so the gradient stays continuous across them.
        if (W7TitlebarBlurEnabled()) {
            _effect = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
            _effect.material = NSVisualEffectMaterialTitlebar;
            _effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            _effect.state = NSVisualEffectStateActive;
            _effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [self addSubview:_effect];
        }
        _glass = [[W7ExplorerGlassView alloc] initWithFrame:self.bounds];
        _glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_glass];
        _capsule = [[W7NavCapsule alloc] initWithFrame:NSZeroRect explorer:explorer];
        _address = [[W7AddressView alloc] initWithFrame:NSMakeRect(0, 0, 400, kBoxHeight) explorer:explorer];
        _search = [[W7SearchBox alloc] initWithFrame:NSMakeRect(0, 0, kSearchWidth, kBoxHeight) explorer:explorer];
        for (NSView *v in @[_capsule, _address, _search]) [self addSubview:v];
        [self w7Layout];
    }
    return self;
}

- (void)w7Layout {
    CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    CGFloat y = floor((h - kBoxHeight) / 2);
    _capsule.frame = NSMakeRect(kCapsuleX, 0, kCapsuleWidth, h);
    CGFloat searchX = w - kSearchInset - kSearchWidth;
    _address.frame = NSMakeRect(kAddressX, y, MAX(kRefreshWidth + 40, searchX - kSearchGap - kAddressX), kBoxHeight);
    _search.frame = NSMakeRect(searchX, y, kSearchWidth, kBoxHeight);
}

- (void)resizeSubviewsWithOldSize:(NSSize)old {
    [super resizeSubviewsWithOldSize:old];
    [self w7Layout];
}

/// Empty glass belongs to the bar, which drags the window like the title bar does.
- (NSView *)hitTest:(NSPoint)p {
    NSView *v = [super hitTest:p];
    return (v == _effect || v == _glass) ? self : v;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)mouseDown:(NSEvent *)e {
    @try { [self.window performWindowDragWithEvent:e]; }
    @catch (NSException *x) { os_log_error(W7Log(), "Explorer nav bar drag failed: %{public}@", x.reason ?: @"unknown"); }
}

@end

#pragma mark - Controller

@implementation W7ExplorerNavBarController {
    __weak W7ExplorerController *_explorer;
}

- (instancetype)initWithExplorer:(W7ExplorerController *)explorer {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _explorer = explorer;
        self.layoutAttribute = NSLayoutAttributeBottom;
        // Before the view is set: otherwise AppKit resizes bottom accessories to its standard height (36 pt).
        self.automaticallyAdjustsSize = NO;
        self.view = [[W7ExplorerNavBarView alloc] initWithFrame:NSMakeRect(0, 0, 800, W7ExplorerNavBarHeight)
                                                       explorer:explorer];
        self.fullScreenMinHeight = W7ExplorerNavBarHeight;
    }
    return self;
}

- (W7ExplorerNavBarView *)w7Bar { return (W7ExplorerNavBarView *)self.view; }

- (void)refreshNavigation {
    @try {
        W7ExplorerController *ex = _explorer;
        if (!ex) return;
        NSMenuItem *back = [ex itemForKey:@"[" mods:NSEventModifierFlagCommand];
        NSMenuItem *forward = [ex itemForKey:@"]" mods:NSEventModifierFlagCommand];
        NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
        if (back) [items addObject:back];
        if (forward) [items addObject:forward];
        [ex validateItems:items];
        self.w7Bar.capsule.backEnabled = back.isEnabled;
        self.w7Bar.capsule.forwardEnabled = forward.isEnabled;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer navigation refresh failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)refreshLocation {
    @try {
        W7ExplorerController *ex = _explorer;
        W7ExplorerLocation *location = ex.location;
        [self.w7Bar.address setLocation:location];
        NSString *name = location.segments.lastObject[@"title"];
        if (name.length == 0) name = ex.window.title ?: @"";
        self.w7Bar.search.placeholder = [NSString stringWithFormat:@"Search %@", name];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer location refresh failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)refreshActive {
    @try {
        NSWindow *w = _explorer.window;
        self.w7Bar.glass.active = w.isMainWindow || w.isKeyWindow;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer active refresh failed: %{public}@", e.reason ?: @"unknown");
    }
}

@end
