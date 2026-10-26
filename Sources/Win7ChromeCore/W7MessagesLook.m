// Messages as Windows Live Messenger.
//
// The Messenger band, chrome only. Messages on macOS 27 is a UIKit (Catalyst) app in a UINSWindow: its
// content (conversation list, transcript, composer) is not AppKit, and nothing in it is touched, read or hooked. In a
// decorated Messages main window the Aero title bar's glass paints, through the stackable band painters (
// identifier W7MessagesBandPainterIdentifier, kept last), the Messenger header band in the space the toolbar band
// gives under the caption: the #DFEFFC->#C4DDF5 background over the whole band and, in the widest span the toolbar's
// items leave free, the picture tile (the user's icons/user.png, else a drawn silhouette), the user's name
// (NSFullUserName), the green "Available" status line and the disabled Messenger toolbar row (W7MessengerDrawing.m);
// 64 pt full when the band is that tall, else the 32 pt compact variant. The glass lies under every AppKit view in the
// title bar, so no toolbar item is covered, moved or hidden; the toolbar look's band and plates take the same
// background (W7ToolbarLookSetBandFill). No text is ever read from the window: everything drawn comes from
// W7MessagesBandStrings, which takes no window.
//
// The diagnostics. With `defaults write -g W7MessagesVerboseLog -bool YES`, once per Messages main window (bundle
// com.apple.MobileSMS), a second after it first becomes key or main: its view tree from the window's root view (class
// names, frames, SwiftUI hosts flagged, split view panes, table/outline/collection views with their counts), the
// toolbar's item identifiers and the window's contentLayoutRect, so one can tell which parts of Messages
// are AppKit views reachable with public API and which are SwiftUI-hosted.
// Names and numbers only: never a string value, title, tool tip, placeholder, accessibility label, identifier, window
// title or any other text (contact names and message text are the user's private data).
// Kill switch: `defaults write -g W7MessagesLookDisabled -bool YES` turns the band off and skips even the dump.
#import "Win7ChromeCore.h"
#import <objc/runtime.h>

NSString *const W7MessagesBundleIdentifier = @"com.apple.MobileSMS";
static const void *kMessagesDumpedKey = &kMessagesDumpedKey;   // on a window: its dump is scheduled or done
static NSInteger gDisabledOverride = -1, gVerboseOverride = -1;
enum { kSiblingCap = 12, kTreeMaxDepth = 30, kTreeMaxViews = 400, kInventoryMaxDepth = 40, kInventoryMaxViews = 2000,
       kInventoryLinesPerKind = 20, kClassNameMax = 160 };

#pragma mark - Switches and decision

static BOOL W7MessagesReadDefault(NSString *key) {
    @try { return [NSUserDefaults.standardUserDefaults boolForKey:key]; }
    @catch (NSException *e) { return NO; }
}

BOOL W7MessagesLookDisabled(void) {
    if (gDisabledOverride >= 0) return gDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ disabled = W7MessagesReadDefault(@"W7MessagesLookDisabled"); });
    return disabled;
}

void W7MessagesLookUseDisabledOverride(NSInteger value) { gDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

BOOL W7MessagesVerboseLog(void) {
    if (gVerboseOverride >= 0) return gVerboseOverride == 1;
    static BOOL verbose;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ verbose = W7MessagesReadDefault(@"W7MessagesVerboseLog"); });
    return verbose;
}

void W7MessagesUseVerboseLogOverride(NSInteger value) { gVerboseOverride = value < 0 ? -1 : (value ? 1 : 0); }

BOOL W7MessagesIsMainWindowShape(NSWindowStyleMask mask, BOOL isPanel, BOOL isSheet) {
    return (mask & NSWindowStyleMaskTitled) && (mask & NSWindowStyleMaskResizable) && !isPanel && !isSheet;
}

BOOL W7MessagesShouldDump(NSString *bundleID, BOOL mainWindowShape, BOOL disabled, BOOL verbose, BOOL alreadyDumped) {
    return [bundleID isKindOfClass:NSString.class] && [bundleID isEqualToString:W7MessagesBundleIdentifier] &&
           mainWindowShape && !disabled && verbose && !alreadyDumped;
}

#pragma mark - Formatting (names and numbers only)

static NSString *W7MessagesRect(NSRect r) {
    return [NSString stringWithFormat:@"(%g,%g %gx%g)", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

/// The object's class name (`-class`: the original class under a KVO subclass), cut at 160 characters.
static NSString *W7MessagesClassName(id obj) {
    NSString *name = @(class_getName([obj class]));
    return name.length > kClassNameMax ? [[name substringToIndex:kClassNameMax] stringByAppendingString:@"…"] : name;
}

/// A SwiftUI hosting view: SwiftUI's NSHostingView in the class chain (a Swift generic, so its runtime names are
/// mangled, `_TtGC7SwiftUI13NSHostingView…`, or prefixed `SwiftUI.`). Not AppKit's own `_NSCoreHostingView`.
static BOOL W7MessagesIsSwiftUIHost(NSView *v) {
    for (Class c = object_getClass(v); c && c != NSView.class; c = class_getSuperclass(c)) {
        const char *n = class_getName(c);
        if (strstr(n, "CoreHostingView")) continue;
        if (strstr(n, "NSHostingView") || (strstr(n, "HostingView") && strstr(n, "SwiftUI"))) return YES;
    }
    return NO;
}

/// AppKit's internal `_NSCoreHostingView` (seen on macOS 27 inside NSTextField, NSButton, the toolbar's glass and the
/// window widgets): AppKit draws its own controls through it, so the control around it is still an AppKit view.
static BOOL W7MessagesIsCoreHost(NSView *v) {
    for (Class c = object_getClass(v); c && c != NSView.class; c = class_getSuperclass(c))
        if (strstr(class_getName(c), "CoreHostingView")) return YES;
    return NO;
}

static BOOL W7MessagesIsSwiftUIClass(NSView *v) { return strstr(class_getName(object_getClass(v)), "SwiftUI") != NULL; }

static BOOL W7MessagesIsOurs(NSView *v) { return strncmp(class_getName(object_getClass(v)), "W7", 2) == 0; }

static NSInteger W7MessagesCollectionItems(NSCollectionView *cv, NSInteger *sections) {
    NSInteger n = 0, s = cv.numberOfSections;
    for (NSInteger i = 0; i < s; i++) n += [cv numberOfItemsInSection:i];
    *sections = s;
    return n;
}

/// The view's flags: kinds and numbers, never its text.
static NSString *W7MessagesFlags(NSView *v) {
    NSMutableString *f = [NSMutableString string];
    if (v.isHidden) [f appendString:@" hidden"];
    if (v.alphaValue < 1) [f appendFormat:@" alpha=%g", v.alphaValue];
    if (W7MessagesIsSwiftUIHost(v)) [f appendString:@" SwiftUI-host"];
    else if (W7MessagesIsCoreHost(v)) [f appendString:@" AppKit-core-host"];
    else if (W7MessagesIsSwiftUIClass(v)) [f appendString:@" SwiftUI"];
    if ([v isKindOfClass:NSSplitView.class]) {
        NSSplitView *s = (NSSplitView *)v;
        [f appendFormat:@" split vertical=%d panes=%lu divider=%g", s.isVertical, (unsigned long)s.subviews.count, s.dividerThickness];
    } else if ([v isKindOfClass:NSTableView.class]) {
        NSTableView *t = (NSTableView *)v;
        [f appendFormat:@" %@ rows=%ld cols=%ld rowHeight=%g style=%ld", [v isKindOfClass:NSOutlineView.class] ? @"outline" : @"table",
                        (long)t.numberOfRows, (long)t.numberOfColumns, t.rowHeight, (long)t.style];
    } else if ([v isKindOfClass:NSCollectionView.class]) {
        NSInteger sections = 0, items = W7MessagesCollectionItems((NSCollectionView *)v, &sections);
        NSCollectionViewLayout *layout = ((NSCollectionView *)v).collectionViewLayout;
        [f appendFormat:@" collection sections=%ld items=%ld layout=%@", (long)sections, (long)items,
                        layout ? W7MessagesClassName(layout) : @"nil"];
    } else if ([v isKindOfClass:NSTextField.class]) {
        [f appendFormat:@" text-field editable=%d", ((NSTextField *)v).isEditable];   // never its stringValue
    } else if ([v isKindOfClass:NSTextView.class]) {
        [f appendFormat:@" text-view editable=%d", ((NSTextView *)v).isEditable];     // never its string
    } else if ([v isKindOfClass:NSVisualEffectView.class]) {
        NSVisualEffectView *e = (NSVisualEffectView *)v;
        [f appendFormat:@" effect material=%ld blending=%ld", (long)e.material, (long)e.blendingMode];
    }
    if (W7MessagesIsOurs(v)) [f appendString:@" (ours)"];
    return f;
}

static void W7MessagesTree(NSView *v, NSUInteger depth, NSUInteger maxDepth, NSInteger *budget, NSMutableArray<NSString *> *out) {
    if (*budget <= 0) return;
    (*budget)--;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSArray<NSView *> *subs = W7MessagesIsOurs(v) ? @[] : v.subviews;
    BOOL atLimit = depth >= maxDepth && subs.count > 0;
    [out addObject:[NSString stringWithFormat:@"%@%@ %@%@%@", pad, W7MessagesClassName(v), W7MessagesRect(v.frame), W7MessagesFlags(v),
                    atLimit ? [NSString stringWithFormat:@" +%lu subviews not shown (depth)", (unsigned long)subs.count] : @""]];
    if (atLimit) return;
    NSUInteger shown = 0;
    for (NSView *sub in subs) {
        if (shown == kSiblingCap || *budget <= 0) break;
        W7MessagesTree(sub, depth + 1, maxDepth, budget, out);
        shown++;
    }
    if (subs.count > shown && shown == kSiblingCap)
        [out addObject:[NSString stringWithFormat:@"%@  +%lu more subviews", pad, (unsigned long)(subs.count - shown)]];
}

NSArray<NSString *> *W7MessagesViewTreeLines(NSView *root, NSUInteger maxDepth, NSUInteger maxViews) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @try {
        if (![root isKindOfClass:NSView.class]) return lines;
        NSInteger budget = (NSInteger)maxViews;
        W7MessagesTree(root, 0, maxDepth, &budget, lines);
        if (budget <= 0) [lines addObject:[NSString stringWithFormat:@"(stopped at %lu views)", (unsigned long)maxViews]];
    } @catch (NSException *e) {
        [lines addObject:[NSString stringWithFormat:@"tree dump failed: %@", e.reason ?: @"unknown"]];
    }
    return lines;
}

#pragma mark - The window dump

typedef struct {
    NSUInteger views, maxDepth, hosts, coreHosts, splits, tables, outlines, collections, textFields, textViews;
} W7MessagesCounts;

/// Every SwiftUI host, split, table, outline and collection view (frames in window coordinates), without the tree's
/// sibling cap, so none is missed; hosts are not descended into twice (a host inside a host is still listed).
static void W7MessagesInventory(NSView *v, NSUInteger depth, W7MessagesCounts *c, NSMutableDictionary<NSString *, NSMutableArray *> *kinds) {
    if (c->views >= kInventoryMaxViews || depth > kInventoryMaxDepth) return;
    c->views++;
    c->maxDepth = MAX(c->maxDepth, depth);
    NSString *kind = nil, *extra = @"";
    if (W7MessagesIsSwiftUIHost(v)) { c->hosts++; kind = @"host"; }
    else if (W7MessagesIsCoreHost(v)) c->coreHosts++;   // counted only: AppKit's own controls have one each
    if ([v isKindOfClass:NSSplitView.class]) {
        c->splits++;
        kind = @"split";
        NSMutableArray<NSString *> *panes = [NSMutableArray array];
        for (NSView *p in v.subviews) [panes addObject:W7MessagesRect(p.frame)];
        extra = [NSString stringWithFormat:@" vertical=%d panes: %@", ((NSSplitView *)v).isVertical, [panes componentsJoinedByString:@", "]];
    } else if ([v isKindOfClass:NSOutlineView.class]) { c->outlines++; kind = @"outline"; }
    else if ([v isKindOfClass:NSTableView.class]) { c->tables++; kind = @"table"; }
    else if ([v isKindOfClass:NSCollectionView.class]) { c->collections++; kind = @"collection"; }
    else if ([v isKindOfClass:NSTextField.class]) c->textFields++;
    else if ([v isKindOfClass:NSTextView.class]) c->textViews++;
    if (kind) {
        NSMutableArray *list = kinds[kind] ?: (kinds[kind] = [NSMutableArray array]);
        if (list.count < kInventoryLinesPerKind)
            [list addObject:[NSString stringWithFormat:@"%@ %@ inWindow=%@ depth=%lu%@", kind, W7MessagesClassName(v),
                             W7MessagesRect([v convertRect:v.bounds toView:nil]), (unsigned long)depth, extra]];
    }
    if (W7MessagesIsOurs(v)) return;
    for (NSView *sub in v.subviews) W7MessagesInventory(sub, depth + 1, c, kinds);
}

static BOOL W7MessagesHasAeroBar(NSWindow *w) {
    for (NSView *v in [w standardWindowButton:NSWindowCloseButton].superview.subviews)
        if ([v isKindOfClass:W7TitlebarView.class]) return YES;
    return NO;
}

NSArray<NSString *> *W7MessagesWindowDump(NSWindow *w) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @try {
        if (![w isKindOfClass:NSWindow.class]) return lines;
        NSToolbar *tb = w.toolbar;
        // Never w.title: a conversation window's title is a contact's name.
        [lines addObject:[NSString stringWithFormat:@"window %@ frame=%@ contentLayoutRect=%@ styleMask=0x%lx toolbar=%@ "
                                                    @"toolbarStyle=%ld displayMode=%ld accessories=%lu aero=%d contentView=%@",
                          W7MessagesClassName(w), W7MessagesRect(w.frame), W7MessagesRect(w.contentLayoutRect),
                          (unsigned long)w.styleMask, tb ? (tb.identifier ?: @"?") : @"nil", (long)w.toolbarStyle,
                          (long)tb.displayMode, (unsigned long)w.titlebarAccessoryViewControllers.count, W7MessagesHasAeroBar(w),
                          w.contentView ? W7MessagesClassName(w.contentView) : @"nil"]];
        if (tb) {
            NSMutableArray<NSString *> *ids = [NSMutableArray array];
            for (NSToolbarItem *item in tb.items) [ids addObject:item.itemIdentifier ?: @"?"];   // identifiers only, never labels
            [lines addObject:[NSString stringWithFormat:@"toolbar items: %@", ids.count ? [ids componentsJoinedByString:@", "] : @"(none)"]];
        }
        NSView *root = w.contentView.superview ?: w.contentView;
        W7MessagesCounts c = {0};
        NSMutableDictionary<NSString *, NSMutableArray *> *kinds = [NSMutableDictionary dictionary];
        if (root) W7MessagesInventory(root, 0, &c, kinds);
        for (NSString *kind in @[ @"host", @"split", @"table", @"outline", @"collection" ]) [lines addObjectsFromArray:kinds[kind] ?: @[]];
        [lines addObject:[NSString stringWithFormat:@"summary: views %lu%@, depth %lu, SwiftUI hosts %lu, AppKit core hosts %lu, splits %lu, "
                                                    @"tables %lu, outlines %lu, collections %lu, text fields %lu, text views %lu",
                          (unsigned long)c.views, c.views >= kInventoryMaxViews ? @" (capped)" : @"", (unsigned long)c.maxDepth,
                          (unsigned long)c.hosts, (unsigned long)c.coreHosts, (unsigned long)c.splits, (unsigned long)c.tables, (unsigned long)c.outlines,
                          (unsigned long)c.collections, (unsigned long)c.textFields, (unsigned long)c.textViews]];
        [lines addObjectsFromArray:W7MessagesViewTreeLines(root, kTreeMaxDepth, kTreeMaxViews)];
    } @catch (NSException *e) {
        [lines addObject:[NSString stringWithFormat:@"window dump failed: %@", e.reason ?: @"unknown"]];
    }
    return lines;
}

/// os_log truncates long messages: one entry per ~800 characters.
static void W7MessagesLogLines(NSArray<NSString *> *lines) {
    NSMutableString *chunk = [NSMutableString string];
    NSUInteger part = 1;
    for (NSString *line in lines) {
        if (chunk.length && chunk.length + line.length > 800) {
            os_log(W7Log(), "Messages diagnostics [%lu]: %{public}@", (unsigned long)part++, chunk);
            [chunk setString:@""];
        }
        [chunk appendFormat:@"%@%@", chunk.length ? @" | " : @"", line];
    }
    if (chunk.length) os_log(W7Log(), "Messages diagnostics [%lu]: %{public}@", (unsigned long)part, chunk);
}

#pragma mark - Messenger band: decisions

NSString *const W7MessagesBandPainterIdentifier = @"com.win7mac.band.messenger";
static const void *kMessengerBandKey = &kMessengerBandKey;       // on a window: its W7MessengerBandState while the band is on
static const void *kMessengerLogLineKey = &kMessengerLogLineKey; // on a window: the line logged for it (outlives the state)
static const CGFloat kBandSideInset = 2;   // the glass frame's side lines, as the toolbar band (none with the frame overlay)
static const CGFloat kItemClearance = 6;   // the header keeps this far from every toolbar item
enum { kMaxOccupied = 32, kOccupiedMaxDepth = 12 };

W7MessengerBandVariant W7MessengerBandVariantForHeight(CGFloat height) {
    if (height >= W7MessengerBandHeight) return W7MessengerBandVariantFull;
    if (height >= W7MessengerCompactBandHeight) return W7MessengerBandVariantCompact;
    return W7MessengerBandVariantNone;
}

CGFloat W7MessengerBandMinimumContentWidth(BOOL compact) { return compact ? 90 : 140; }

W7MessengerBandGeometry W7MessengerBandGeometryFor(CGRect bounds, CGRect toolbar, CGFloat sideInset, const CGRect *occupied,
                                                  NSUInteger count) {
    W7MessengerBandGeometry g;
    memset(&g, 0, sizeof g);
    if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds) || CGRectIsNull(toolbar) || CGRectIsEmpty(toolbar)) return g;
    CGRect below = bounds;
    below.size.height = MAX(0, bounds.size.height - W7TitlebarHeight);   // never the caption
    CGRect band = CGRectIntersection(toolbar, below);
    if (CGRectIsNull(band) || CGRectIsEmpty(band) || band.size.width <= 2 * sideInset) return g;
    band = CGRectInset(band, sideInset, 0);
    g.band = band;
    g.variant = W7MessengerBandVariantForHeight(band.size.height);
    if (g.variant == W7MessengerBandVariantNone) return g;
    BOOL compact = g.variant == W7MessengerBandVariantCompact;
    CGFloat h = compact ? W7MessengerCompactBandHeight : W7MessengerBandHeight;
    CGFloat y = MAX(CGRectGetMinY(band), MIN(round(CGRectGetMidY(band) - h / 2), CGRectGetMaxY(band) - h));
    g.box = CGRectMake(band.origin.x, y, band.size.width, h);

    // The items over the box, as x intervals widened by the clearance, sorted by their start.
    CGFloat lo[kMaxOccupied], hi[kMaxOccupied];
    NSUInteger n = 0;
    for (NSUInteger i = 0; occupied && i < count && n < kMaxOccupied; i++) {
        CGRect o = occupied[i];
        if (CGRectIsNull(o) || CGRectIsEmpty(o)) continue;
        if (CGRectGetMaxY(o) <= CGRectGetMinY(g.box) || CGRectGetMinY(o) >= CGRectGetMaxY(g.box)) continue;
        CGFloat a = CGRectGetMinX(o) - kItemClearance, b = CGRectGetMaxX(o) + kItemClearance;
        NSUInteger j = n++;
        while (j > 0 && lo[j - 1] > a) { lo[j] = lo[j - 1]; hi[j] = hi[j - 1]; j--; }
        lo[j] = a;
        hi[j] = b;
    }
    // The widest free span (the leftmost of equal ones).
    CGFloat right = CGRectGetMaxX(band), x = CGRectGetMinX(band), bestX = x, bestW = -1;
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat end = MIN(lo[i], right);
        if (end - x > bestW) { bestX = x; bestW = end - x; }
        x = MAX(x, hi[i]);
    }
    if (right - x > bestW) { bestX = x; bestW = right - x; }
    if (bestW >= W7MessengerBandMinimumContentWidth(compact)) g.content = CGRectMake(bestX, y, bestW, h);
    return g;
}

static BOOL W7MessagesIsDark(NSAppearance *a) {
    static NSArray<NSAppearanceName> *names;
    if (!names) names = @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ];
    return a && [[a bestMatchFromAppearancesWithNames:names] isEqualToString:NSAppearanceNameDarkAqua];
}

static BOOL W7MessagesNameHasSuffix(const char *name, const char *suffix) {
    size_t n = strlen(name), s = strlen(suffix);
    return n >= s && strcmp(name + n - s, suffix) == 0;
}

/// AppKit's toolbar view: a direct child of the title bar view whose class name ends in "ToolbarView".
static NSView *W7MessagesToolbarView(NSWindow *w) {
    for (NSView *v in [w standardWindowButton:NSWindowCloseButton].superview.subviews)
        if (W7MessagesNameHasSuffix(class_getName(object_getClass(v)), "ToolbarView")) return v;
    return nil;
}

/// The toolbar's visible items under `v` as rects in `target`: controls (buttons, image views, search fields, label
/// text fields), Liquid Glass platters and label stacks, not descended into; containers (item viewers, spaces) are
/// looked through. At most kMaxOccupied, kOccupiedMaxDepth deep. Frames only: nothing about an item is read.
static void W7MessagesCollectOccupied(NSView *v, NSView *target, NSUInteger depth, CGRect *out, NSUInteger *n) {
    if (!v || depth > kOccupiedMaxDepth) return;
    for (NSView *sub in v.subviews) {
        if (*n >= kMaxOccupied) return;
        if (sub.isHidden || NSIsEmptyRect(sub.frame) || W7MessagesIsOurs(sub)) continue;
        const char *name = class_getName(object_getClass(sub));
        if ([sub isKindOfClass:NSControl.class] || strstr(name, "Platter") || W7MessagesNameHasSuffix(name, "LabelStack")) {
            out[(*n)++] = NSRectToCGRect([target convertRect:sub.bounds fromView:sub]);
            continue;
        }
        W7MessagesCollectOccupied(sub, target, depth + 1, out, n);
    }
}

W7MessengerBandGeometry W7MessagesBandGeometryForWindow(NSWindow *w, NSView *view) {
    W7MessengerBandGeometry none;
    memset(&none, 0, sizeof none);
    @try {
        if (!w || !view) return none;
        NSToolbar *t = w.toolbar;
        NSView *tv = W7MessagesToolbarView(w);
        if (!t || !t.isVisible || !tv || tv.isHiddenOrHasHiddenAncestor) return none;
        CGRect occupied[kMaxOccupied];
        NSUInteger n = 0;
        W7MessagesCollectOccupied(tv, view, 0, occupied, &n);
        return W7MessengerBandGeometryFor(NSRectToCGRect(view.bounds), NSRectToCGRect([view convertRect:tv.bounds fromView:tv]),
                                         W7FrameBorderIsShowing(w) ? 0 : kBandSideInset, occupied, n);
    } @catch (NSException *e) {
        return none;
    }
}

NSString *W7MessagesDisplayName(void) {
    static NSString *name;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *full = NSFullUserName();
        name = full.length ? [full copy] : ([NSUserName() copy] ?: @"");
    });
    return name;
}

NSArray<NSString *> *W7MessagesBandStrings(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithObjects:W7MessagesDisplayName(),
                                                                       W7MessengerStatusTitle(W7MessengerStatusAvailable), nil];
    [out addObjectsFromArray:W7MessengerToolbarLabels()];
    return out;
}

BOOL W7MessagesBandApplies(NSString *bundleID, NSWindow *w, BOOL disabled) {
    @try {
        if (disabled || !w || ![bundleID isKindOfClass:NSString.class] || ![bundleID isEqualToString:W7MessagesBundleIdentifier]) return NO;
        if (!W7MessagesIsMainWindowShape(w.styleMask, [w isKindOfClass:NSPanel.class], w.sheetParent != nil)) return NO;
        return W7MessagesHasAeroBar(w) && !W7MessagesIsDark(w.effectiveAppearance);
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - Messenger band: the painter

/// Per window while the band is on: the picture tile's image (cached per size, scale and icon generation), whether a
/// move-to-last is scheduled, and the window's close observer.
@interface W7MessengerBandState : NSObject
@property (nonatomic, strong) id picture;   // CGImageRef
@property (nonatomic) CGFloat picturePoints, pictureScale;
@property (nonatomic) NSUInteger pictureGeneration;
@property (nonatomic) BOOL pictureLooked, reorderPending;
@property (nonatomic, strong) id closeToken;
@end
@implementation W7MessengerBandState
- (void)dealloc {
    if (_closeToken) [NSNotificationCenter.defaultCenter removeObserver:_closeToken];
}
@end

static W7MessengerBandState *W7MessengerState(NSWindow *w, BOOL create) {
    W7MessengerBandState *s = w ? objc_getAssociatedObject(w, kMessengerBandKey) : nil;
    if (!s && w && create) {
        s = [W7MessengerBandState new];
        __weak NSWindow *weak = w;
        s.closeToken = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:w queue:nil
                                                                   usingBlock:^(NSNotification *n) {
            @try { W7MessagesBandRestore(weak); } @catch (NSException *e) {}
        }];
        objc_setAssociatedObject(w, kMessengerBandKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

BOOL W7MessagesBandIsApplied(NSWindow *w) { return W7MessengerState(w, NO) != nil; }

NSString *W7MessagesBandLogLine(NSWindow *w) { return w ? objc_getAssociatedObject(w, kMessengerLogLineKey) : nil; }

/// The user's picture for a `points` tile (W7UserIconImageSized "user"), nil without one; looked up again only when
/// the size, the scale or the icon generation changes.
static CGImageRef W7MessagesPicture(W7MessengerBandState *s, CGFloat points, CGFloat scale) {
    NSUInteger generation = W7UserIconsGeneration();
    if (!s.pictureLooked || s.picturePoints != points || s.pictureScale != scale || s.pictureGeneration != generation) {
        s.pictureLooked = YES;
        s.picturePoints = points;
        s.pictureScale = scale;
        s.pictureGeneration = generation;
        s.picture = nil;
        NSImage *image = W7UserIconImageSized(@"user", NSMakeSize(points, points));
        if (image) {
            NSRect r = NSMakeRect(0, 0, points * scale, points * scale);
            CGImageRef cg = [image CGImageForProposedRect:&r context:nil hints:nil];
            if (cg) s.picture = (__bridge id)cg;
        }
    }
    return (__bridge CGImageRef)s.picture;
}

/// Once per window, the first time the toolbar band is laid out: which variant, and whether the header had room.
static void W7MessagesBandLogOnce(NSWindow *w, W7MessengerBandGeometry g) {
    if (CGRectIsEmpty(g.band) || W7MessagesBandLogLine(w)) return;
    NSString *line;
    if (g.variant == W7MessengerBandVariantFull) line = @"Messenger band: full";
    else if (g.variant == W7MessengerBandVariantCompact)
        line = [NSString stringWithFormat:@"Messenger band: compact (toolbar band %g pt, under %g)", g.band.size.height, W7MessengerBandHeight];
    else line = [NSString stringWithFormat:@"Messenger band: none (toolbar band %g pt, under %g)", g.band.size.height,
                                           W7MessengerCompactBandHeight];
    if (g.variant != W7MessengerBandVariantNone && CGRectIsEmpty(g.content))
        line = [line stringByAppendingString:@", header left out: no free span"];
    objc_setAssociatedObject(w, kMessengerLogLineKey, line, OBJC_ASSOCIATION_COPY_NONATOMIC);
    os_log(W7Log(), "%{public}@", line);
}

@interface W7MessengerBandPainter : NSObject <W7TitlebarBandPainter>
@end

static W7MessengerBandPainter *W7MessengerSharedPainter(void) {
    static W7MessengerBandPainter *painter;
    if (!painter) painter = [W7MessengerBandPainter new];
    return painter;
}

/// Our painter last among the window's band painters (added when missing): the toolbar band, which takes the same
/// background, never paints over the header.
static void W7MessagesBandMoveLast(NSWindow *w) {
    W7MessengerBandPainter *painter = W7MessengerSharedPainter();
    if ([W7TitlebarBandPainterIdentifiers(w).lastObject isEqualToString:W7MessagesBandPainterIdentifier] &&
        W7TitlebarBandPainterForIdentifier(w, W7MessagesBandPainterIdentifier) == painter) return;
    W7SetTitlebarBandPainterForIdentifier(w, W7MessagesBandPainterIdentifier, nil);
    W7SetTitlebarBandPainterForIdentifier(w, W7MessagesBandPainterIdentifier, painter);   // appended; redraws the glass
}

/// A painter added after ours (the toolbar look re-applying after a dark -> light switch): ours goes last again on the
/// next run-loop pass (never while the glass is drawing).
static void W7MessagesBandKeepLast(NSWindow *w, W7MessengerBandState *s) {
    if (s.reorderPending || [W7TitlebarBandPainterIdentifiers(w).lastObject isEqualToString:W7MessagesBandPainterIdentifier]) return;
    s.reorderPending = YES;
    __weak NSWindow *weak = w;
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
        @try {
            NSWindow *win = weak;
            W7MessengerBandState *st = W7MessengerState(win, NO);
            if (!st) return;
            st.reorderPending = NO;
            W7MessagesBandMoveLast(win);
        } @catch (NSException *e) { os_log_error(W7Log(), "Messenger band reorder failed: %{public}@", e.reason ?: @"unknown"); }
    });
    CFRunLoopWakeUp(main);
}

@implementation W7MessengerBandPainter
- (void)w7DrawBandsInTitlebarView:(NSView *)view window:(NSWindow *)w context:(CGContextRef)ctx {
    W7MessengerBandState *s = W7MessengerState(w, NO);
    if (!s || !ctx || W7MessagesIsDark(view.effectiveAppearance)) return;
    W7MessengerBandGeometry g = W7MessagesBandGeometryForWindow(w, view);
    W7MessagesBandLogOnce(w, g);
    if (g.variant != W7MessengerBandVariantNone) {
        W7DrawMessengerBandBackground(ctx, g.band);
        if (!CGRectIsEmpty(g.content)) {
            BOOL compact = g.variant == W7MessengerBandVariantCompact;
            CGFloat scale = MAX(1, w.backingScaleFactor);
            CGImageRef picture = W7MessagesPicture(s, compact ? W7MessengerCompactTileSide : W7MessengerTileSide, scale);
            W7DrawMessengerHeader(ctx, g.content, compact, picture, W7MessagesDisplayName(), W7MessengerStatusAvailable);
        }
    }
    W7MessagesBandKeepLast(w, s);
}
@end

#pragma mark - Messenger band: apply and restore

void W7MessagesBandRestore(NSWindow *w) {
    @try {
        W7MessengerBandState *s = W7MessengerState(w, NO);
        if (!s) return;
        objc_setAssociatedObject(w, kMessengerBandKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (s.closeToken) [NSNotificationCenter.defaultCenter removeObserver:s.closeToken];
        s.closeToken = nil;
        if (W7TitlebarBandPainterForIdentifier(w, W7MessagesBandPainterIdentifier) == W7MessengerSharedPainter())
            W7SetTitlebarBandPainterForIdentifier(w, W7MessagesBandPainterIdentifier, nil);
        if (W7ToolbarLookBandFill(w) == W7DrawMessengerBandBackground) W7ToolbarLookSetBandFill(w, NULL);
    } @catch (NSException *e) { os_log_error(W7Log(), "Messenger band restore failed: %{public}@", e.reason ?: @"unknown"); }
}

void W7MessagesBandApply(NSWindow *w) {
    @try {
        if (!w) return;
        W7MessengerState(w, YES);
        W7MessagesBandMoveLast(w);
        W7ToolbarLookSetBandFill(w, W7DrawMessengerBandBackground);   // a no-op when already set
        NSView *bar = [w standardWindowButton:NSWindowCloseButton].superview;
        if (bar) W7MessagesBandLogOnce(w, W7MessagesBandGeometryForWindow(w, bar));
        W7TitlebarBandsNeedDisplay(w);   // the toolbar may have changed since the last draw
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Messenger band failed: %{public}@", e.reason ?: @"unknown");
        W7MessagesBandRestore(w);
    }
}

BOOL W7MessagesBandUpdateForBundle(NSWindow *w, NSString *bundleID) {
    @try {
        if (![w isKindOfClass:NSWindow.class]) return NO;
        if (W7MessagesBandApplies(bundleID, w, W7MessagesLookDisabled())) {
            W7MessagesBandApply(w);
            return W7MessagesBandIsApplied(w);
        }
        W7MessagesBandRestore(w);
    } @catch (NSException *e) { os_log_error(W7Log(), "Messenger band update failed: %{public}@", e.reason ?: @"unknown"); }
    return NO;
}

#pragma mark - The window path

BOOL W7MessagesLookUpdateForBundle(NSWindow *w, NSString *bundleID) {
    @try {
        if (![w isKindOfClass:NSWindow.class]) return NO;
        BOOL shape = W7MessagesIsMainWindowShape(w.styleMask, [w isKindOfClass:NSPanel.class], w.sheetParent != nil);
        if (!W7MessagesShouldDump(bundleID, shape, W7MessagesLookDisabled(), W7MessagesVerboseLog(),
                                  objc_getAssociatedObject(w, kMessagesDumpedKey) != nil)) return NO;
        objc_setAssociatedObject(w, kMessagesDumpedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak NSWindow *weakWindow = w;
        // A second later: SwiftUI builds its hierarchy and toolbar after the window first shows.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            @try {
                NSWindow *win = weakWindow;
                if (!win || W7MessagesLookDisabled()) return;
                W7MessagesLogLines(W7MessagesWindowDump(win));
            } @catch (NSException *e) { os_log_error(W7Log(), "Messages diagnostics failed: %{public}@", e.reason ?: @"unknown"); }
        });
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Messages look update failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

void W7MessagesLookUpdate(NSWindow *w) {
    static NSString *bundleID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bundleID = [NSBundle.mainBundle.bundleIdentifier copy]; });
    if (![bundleID isEqualToString:W7MessagesBundleIdentifier]) return;   // every other app: one string compare
    W7MessagesLookUpdateForBundle(w, bundleID);
    W7MessagesBandUpdateForBundle(w, bundleID);
}

void W7MessagesLookInstall(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    @try {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:W7MessagesBundleIdentifier]) return;
        os_log(W7Log(), "Messages look: %{public}s", W7MessagesLookDisabled() ? "off (W7MessagesLookDisabled)"
                                                     : W7MessagesVerboseLog() ? "Messenger band on, diagnostics on (W7MessagesVerboseLog)"
                                                                              : "Messenger band on, diagnostics off");
    } @catch (NSException *e) { os_log_error(W7Log(), "Messages look install failed: %{public}@", e.reason ?: @"unknown"); }
}
