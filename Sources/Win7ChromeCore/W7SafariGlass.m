// IE7-style Safari, pass 2: Safari's Liquid Glass toolbar buttons through NSGlassEffectView's public API
// (tintColor, style, cornerRadius; respondsToSelector + exact encodings). Allow-listed platters without excluded views
// get .clear and the IE7 face; a guarded platter -layout hook keeps it. Originals saved per glass view, restored exactly
// (un-theme, close, dark). The tabs are no longer tinted (they are drawn by the facsimile over Safari's
// invisible glass, W7SafariTabFacsimile.m). Kill switch: `defaults write -g W7SafariGlassTintDisabled -bool YES` (also
// off with W7SafariHooksDisabled).
#import "W7SafariInternal.h"
#import <objc/message.h>

#pragma mark - State

static BOOL gGlassEnabled;
void W7SafariGlassSetEnabled(BOOL enabled) { gGlassEnabled = enabled; }
BOOL W7SafariGlassEnabled(void) { return gGlassEnabled; }
static Class W7SafariGlassClass(void) {   // looked up by name: the dylib also loads on macOS 15
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"NSGlassEffectView"); });
    return cls;
}

/// What a glass view had before it was styled (put back on restore), and what was applied (for re-applying).
@interface W7SafariGlassSnapshot : NSObject
@property (nonatomic) BOOL styleKnown, radiusKnown, styleSet, radiusSet, appliedClear;
@property (nonatomic) NSInteger style;
@property (nonatomic) double radius, appliedRadius;
@property (nonatomic) W7SafariGlassTint appliedTint;
@property (nonatomic, strong) NSColor *tint;
@end
@implementation W7SafariGlassSnapshot
@end
/// Per window: the glass views styled in it (weak), what was logged, and what the last full update saw.
@interface W7SafariGlassWindowState : NSObject
@property (nonatomic, strong) NSHashTable<NSView *> *styled, *logged;
@property (nonatomic) NSInteger lines, seen;   // seen: 0 none, else 1 | key << 1 | tab bar shown << 2
@end
@implementation W7SafariGlassWindowState
@end

static const void *kGlassSnapshotKey = &kGlassSnapshotKey;   // on a glass view: its W7SafariGlassSnapshot
static const void *kGlassWindowKey = &kGlassWindowKey;       // on a window: its W7SafariGlassWindowState
static const void *kPlatterGlassKey = &kPlatterGlassKey;     // on a platter: the glass styled for it
static W7SafariGlassSnapshot *W7SafariSnap(NSView *glass) { return glass ? objc_getAssociatedObject(glass, kGlassSnapshotKey) : nil; }
static W7SafariGlassWindowState *W7SafariGlassState(NSWindow *w, BOOL create) {
    W7SafariGlassWindowState *s = w ? objc_getAssociatedObject(w, kGlassWindowKey) : nil;
    if (!s && w && create) {
        s = [W7SafariGlassWindowState new];
        s.styled = [NSHashTable weakObjectsHashTable];
        s.logged = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(w, kGlassWindowKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

static void W7SafariGlassTrack(NSWindow *w, NSView *glass) {
    if (glass && ![W7SafariGlassState(w, YES).styled containsObject:glass]) [W7SafariGlassState(w, YES).styled addObject:glass];
}

static BOOL W7SafariIsDark(NSAppearance *a) {
    static NSArray<NSAppearanceName> *names;
    if (!names) names = @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ];
    return a && [[a bestMatchFromAppearancesWithNames:names] isEqualToString:NSAppearanceNameDarkAqua];
}

/// One NSColor per tint, made once (a handful of tints exist); the key is a tagged NSNumber, so no allocation.
static NSColor *W7SafariGlassColor(W7SafariGlassTint t) {
    static NSMutableDictionary<NSNumber *, NSColor *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSNumber *key = @(((uint64_t)t.rgb << 12) | (uint64_t)lround(t.alpha * 1000));
    NSColor *c = cache[key];
    if (!c) cache[key] = c = [NSColor colorWithSRGBRed:((t.rgb >> 16) & 0xFF) / 255.0 green:((t.rgb >> 8) & 0xFF) / 255.0
                                                  blue:(t.rgb & 0xFF) / 255.0 alpha:t.alpha];
    return c;
}

/// Whether `c` already is `t` (the glass may hand back a converted copy of what was set).
static BOOL W7SafariGlassColorMatches(NSColor *c, W7SafariGlassTint t, NSColor *want) {
    if (!c || c == want || [c isEqual:want]) return c != nil;
    @try {
        if (c.type != NSColorTypeComponentBased || c.colorSpace.colorSpaceModel != NSColorSpaceModelRGB) return NO;
        CGFloat r, g, b, a;
        [c getRed:&r green:&g blue:&b alpha:&a];
        return fabs(r * 255 - ((t.rgb >> 16) & 0xFF)) < 1 && fabs(g * 255 - ((t.rgb >> 8) & 0xFF)) < 1 &&
               fabs(b * 255 - (t.rgb & 0xFF)) < 1 && fabs(a - t.alpha) < 0.01;
    } @catch (NSException *e) { return NO; }
}

static NSString *W7SafariColorString(NSColor *c) {
    NSColor *s = nil;
    @try { s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace]; } @catch (NSException *e) {}
    if (!s) return c ? NSStringFromClass(c.class) : @"nil";
    return [NSString stringWithFormat:@"#%02X%02X%02X@%.2f", (int)lround(s.redComponent * 255),
            (int)lround(s.greenComponent * 255), (int)lround(s.blueComponent * 255), s.alphaComponent];
}

#pragma mark - One glass view

/// The glass API on `cls`: getter and setter answered, each with exactly the header's type encoding.
static BOOL W7SafariGlassCan(Class cls, const char *getter, const char *getTypes, const char *setter, const char *setTypes) {
    SEL g = sel_registerName(getter), s = sel_registerName(setter);
    if (!cls || ![cls instancesRespondToSelector:g] || ![cls instancesRespondToSelector:s]) return NO;
    Method mg = class_getInstanceMethod(cls, g), ms = class_getInstanceMethod(cls, s);
    const char *tg = mg ? method_getTypeEncoding(mg) : NULL, *ts = ms ? method_getTypeEncoding(ms) : NULL;
    return tg && ts && strcmp(tg, getTypes) == 0 && strcmp(ts, setTypes) == 0;
}

static BOOL W7SafariCanTint(Class c) { return W7SafariGlassCan(c, "tintColor", "@16@0:8", "setTintColor:", "v24@0:8@16"); }
static BOOL W7SafariCanStyle(Class c) { return W7SafariGlassCan(c, "style", "q16@0:8", "setStyle:", "v24@0:8q16"); }
static BOOL W7SafariCanRadius(Class c) { return W7SafariGlassCan(c, "cornerRadius", "d16@0:8", "setCornerRadius:", "v24@0:8d16"); }
static const NSInteger kGlassStyleClear = 1;   // NSGlassEffectViewStyleClear
BOOL W7SafariGlassApply(NSView *glass, W7SafariGlassTint tint, BOOL clearStyle, CGFloat cornerRadius) {
    @try {
        Class cls = glass ? object_getClass(glass) : Nil;
        if (!W7SafariCanTint(cls)) return NO;   // the tint is the point: nothing without it
        W7SafariGlassSnapshot *snap = W7SafariSnap(glass);
        if (!snap) {
            snap = [W7SafariGlassSnapshot new];
            NSInteger style = 0; double radius = 0;
            snap.tint = W7SafariReadObject(glass, W7SafariSel("tintColor"));   // nil (Safari's own) is a value too
            snap.styleKnown = W7SafariCanStyle(cls) && W7SafariReadInteger(glass, W7SafariSel("style"), &style);
            snap.radiusKnown = W7SafariCanRadius(cls) && W7SafariReadDouble(glass, W7SafariSel("cornerRadius"), &radius);
            snap.style = style, snap.radius = radius;
            objc_setAssociatedObject(glass, kGlassSnapshotKey, snap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        snap.appliedTint = tint, snap.appliedClear = clearStyle, snap.appliedRadius = cornerRadius;   // for re-applying
        NSColor *want = W7SafariGlassColor(tint);
        if (!W7SafariGlassColorMatches(W7SafariReadObject(glass, W7SafariSel("tintColor")), tint, want))
            ((void (*)(id, SEL, id))objc_msgSend)(glass, W7SafariSel("setTintColor:"), want);
        NSInteger style = 0;
        if (clearStyle && snap.styleKnown && W7SafariReadInteger(glass, W7SafariSel("style"), &style) && style != kGlassStyleClear) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(glass, W7SafariSel("setStyle:"), kGlassStyleClear);
            snap.styleSet = YES;
        }
        double radius = 0;
        if (cornerRadius >= 0 && snap.radiusKnown && W7SafariReadDouble(glass, W7SafariSel("cornerRadius"), &radius) &&
            fabs(radius - cornerRadius) > 0.01) {
            ((void (*)(id, SEL, double))objc_msgSend)(glass, W7SafariSel("setCornerRadius:"), cornerRadius);
            snap.radiusSet = YES;
        }
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari glass tint failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

BOOL W7SafariGlassIsStyled(NSView *glass) { return W7SafariSnap(glass) != nil; }
BOOL W7SafariGlassReapply(NSView *glass) {
    W7SafariGlassSnapshot *snap = W7SafariSnap(glass);
    return snap && W7SafariGlassApply(glass, snap.appliedTint, snap.appliedClear, snap.appliedRadius);
}
void W7SafariGlassRestore(NSView *glass) {
    @try {
        W7SafariGlassSnapshot *snap = W7SafariSnap(glass);
        if (!snap) return;
        objc_setAssociatedObject(glass, kGlassSnapshotKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Class cls = object_getClass(glass);
        if (W7SafariCanTint(cls)) ((void (*)(id, SEL, id))objc_msgSend)(glass, W7SafariSel("setTintColor:"), snap.tint);
        if (snap.styleSet && W7SafariCanStyle(cls))
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(glass, W7SafariSel("setStyle:"), snap.style);
        if (snap.radiusSet && W7SafariCanRadius(cls))
            ((void (*)(id, SEL, double))objc_msgSend)(glass, W7SafariSel("setCornerRadius:"), snap.radius);
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari glass restore failed: %{public}@", e.reason ?: @"unknown"); }
}

/// One line per glass view per window (styled or skipped, and why): at most 40 per window. No page titles or URLs,
/// only item identifiers and class names.
static void W7SafariGlassLog(NSWindow *w, NSView *key, NSString *(^line)(void)) {
    W7SafariGlassWindowState *s = W7SafariGlassState(w, YES);
    if (!s || [s.logged containsObject:key] || s.lines >= 40) return;
    [s.logged addObject:key];
    s.lines++;
    os_log(W7Log(), "Safari glass: %{public}@", line());
}

/// "style 0→1 tint nil→#F7F9FC@0.75 radius 18→18": the saved originals and what the glass has now.
static NSString *W7SafariSnapString(NSView *glass) {
    W7SafariGlassSnapshot *snap = W7SafariSnap(glass);
    NSInteger style = -1;
    double radius = -1;   // "-1" when unreadable
    W7SafariReadInteger(glass, W7SafariSel("style"), &style);
    W7SafariReadDouble(glass, W7SafariSel("cornerRadius"), &radius);
    return [NSString stringWithFormat:@"style %@→%ld tint %@→%@ radius %@→%g", snap.styleKnown ? @(snap.style) : @"?", (long)style,
            W7SafariColorString(snap.tint), W7SafariColorString(W7SafariReadObject(glass, W7SafariSel("tintColor"))),
            snap.radiusKnown ? @(snap.radius) : @"?", radius];
}

#pragma mark - Toolbar platters and tab bar controls

/// The identifiers of the items in `platter` (its -containedItems viewers' -item, else the toolbar items whose
/// view is inside it); a subitem of an allowed group counts as that group. `allAllowed` NO when there is none.
static NSArray<NSString *> *W7SafariPlatterOwners(NSView *platter, NSWindow *w, BOOL *allAllowed) {
    NSMutableArray<NSToolbarItem *> *items = [NSMutableArray array];
    id viewers = W7SafariReadObject(platter, W7SafariSel("containedItems"));
    for (id viewer in [viewers isKindOfClass:NSArray.class] ? viewers : @[]) {
        id item = W7SafariReadObject(viewer, W7SafariSel("item"));
        if ([item isKindOfClass:NSToolbarItem.class]) [items addObject:item];
    }
    if (!items.count)
        for (NSToolbarItem *item in w.toolbar.items) if (item.view && [item.view isDescendantOf:platter]) [items addObject:item];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    *allAllowed = items.count > 0;
    for (NSToolbarItem *item in items) {
        NSString *identifier = item.itemIdentifier ?: @"nil";
        BOOL ok = W7SafariGlassItemAllowed(identifier);
        for (NSToolbarItem *top in w.toolbar.items)
            if (!ok && [top isKindOfClass:NSToolbarItemGroup.class] && [((NSToolbarItemGroup *)top).subitems containsObject:item] &&
                W7SafariGlassItemAllowed(top.itemIdentifier)) { ok = YES; identifier = top.itemIdentifier; }
        *allAllowed = *allAllowed && ok;
        [ids addObject:identifier];
    }
    return ids;
}

/// The glass of a platter: its _glassView ivar, else a direct child that is an NSGlassEffectView.
static NSView *W7SafariPlatterGlass(NSView *platter) {
    Class glassClass = W7SafariGlassClass();
    NSView *glass = W7SafariIvarView(platter, "_glassView");
    if (glassClass && [glass isKindOfClass:glassClass]) return glass;
    for (NSView *sub in platter.subviews) if (glassClass && [sub isKindOfClass:glassClass]) return sub;
    return nil;
}

/// Takes a platter's styling off (its glass back to AppKit's values) and forgets it.
static void W7SafariUnstylePlatter(NSView *platter) {
    NSView *glass = objc_getAssociatedObject(platter, kPlatterGlassKey);
    objc_setAssociatedObject(platter, kPlatterGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    W7SafariGlassRestore(glass);
}

NSString *W7SafariGlassStylePlatter(NSView *platter, NSView *stop) {
    @try {
        NSWindow *w = platter.window;
        NSView *glass = W7SafariPlatterGlass(platter);
        BOOL allowed = NO;
        NSArray<NSString *> *owners = W7SafariPlatterOwners(platter, w, &allowed);
        NSString *owner = owners.count ? [owners componentsJoinedByString:@"+"] : @"(no item)";
        NSString *excluded = W7SafariGlassExclusionIn(platter, stop);
        NSString *reason = !gGlassEnabled ? @"disabled" : !W7SafariWindowIsThemed(w) ? @"window not themed"
                         : platter.isHiddenOrHasHiddenAncestor ? @"hidden" : !glass ? @"no NSGlassEffectView"
                         : excluded ? [@"excluded view " stringByAppendingString:excluded]
                         : !allowed ? @"item not on the allow-list" : W7SafariIsDark(w.effectiveAppearance) ? @"dark appearance" : nil;
        if (!reason && !W7SafariGlassApply(glass, W7SafariToolbarGlassTint([owners containsObject:@"BackForwardToolbarIdentifier"]), YES, -1))
            reason = @"no tintColor API";
        if (reason) {
            W7SafariUnstylePlatter(platter);
            W7SafariGlassLog(w, platter, ^{ return [NSString stringWithFormat:@"skipped %@: %@", owner, reason]; });
            return reason;
        }
        objc_setAssociatedObject(platter, kPlatterGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        W7SafariGlassTrack(w, glass);
        W7SafariGlassLog(w, platter, ^{ return [NSString stringWithFormat:@"styled %@: %@", owner, W7SafariSnapString(glass)]; });
        return nil;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari platter glass failed: %{public}@", e.reason ?: @"unknown");
        return @"exception";
    }
}

/// Views of `cls` under `v` (at most `maxDepth` deep), never inside an excluded view, a match or a `skip` view.
static void W7SafariCollect(NSView *v, int depth, int maxDepth, Class cls, Class skip, NSMutableArray<NSView *> *out) {
    if (!v || !cls || depth > maxDepth || out.count >= 32 || W7SafariIsGlassExcludedCName(class_getName([v class]))) return;
    if (skip && [v isKindOfClass:skip]) return;
    if ([v isKindOfClass:cls]) { [out addObject:v]; return; }
    for (NSView *sub in v.subviews) W7SafariCollect(sub, depth + 1, maxDepth, cls, skip, out);
}

/// Glass controls in the tab bar outside the tab buttons (new-tab or overflow controls, when they are glass).
static void W7SafariGlassStyleTabBarControls(NSWindow *w, NSView *tabBar) {
    NSMutableArray<NSView *> *glasses = [NSMutableArray array];
    W7SafariCollect(tabBar, 0, 4, W7SafariGlassClass(), objc_getClass("UnifiedTabBarButton"), glasses);
    if (!glasses.count) W7SafariGlassLog(w, tabBar, ^{ return @"tab bar: no glass controls outside the tabs"; });
    for (NSView *glass in glasses) {
        NSString *owner = [NSString stringWithFormat:@"tab bar control in %@", NSStringFromClass(glass.superview.class)];
        NSString *skip = W7SafariGlassExclusionIn(glass, tabBar) ?: (glass.isHiddenOrHasHiddenAncestor ? @"hidden" : nil);
        if (skip || !W7SafariGlassApply(glass, W7SafariToolbarGlassTint(NO), YES, -1)) {
            W7SafariGlassRestore(glass);
            W7SafariGlassLog(w, glass, ^{ return [NSString stringWithFormat:@"skipped %@: %@", owner, skip ?: @"no tintColor API"]; });
            continue;
        }
        W7SafariGlassTrack(w, glass);
        W7SafariGlassLog(w, glass, ^{ return [NSString stringWithFormat:@"styled %@: %@", owner, W7SafariSnapString(glass)]; });
    }
}

#pragma mark - Window path
void W7SafariGlassRemoveWindow(NSWindow *w) {
    @try {
        W7SafariGlassWindowState *s = W7SafariGlassState(w, NO);
        for (NSView *glass in s.styled.allObjects) W7SafariGlassRestore(glass);
        [s.styled removeAllObjects];
        s.seen = 0;
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari glass removal failed: %{public}@", e.reason ?: @"unknown"); }
}

NSUInteger W7SafariGlassStyledCount(NSWindow *w) {
    NSUInteger n = 0;
    for (NSView *glass in W7SafariGlassState(w, NO).styled.allObjects) n += W7SafariGlassIsStyled(glass);
    return n;
}
/// `force` NO: nothing when the key state and the tab bar's visibility are what the last update (which found
/// platters) saw, as when the gate re-runs on every frame of a window resize. Item additions and appearance
/// changes force it.
static void W7SafariGlassUpdate(NSWindow *w, BOOL force) {
    @try {
        if (!w) return;
        if (!gGlassEnabled || !W7SafariWindowIsThemed(w) || W7SafariIsDark(w.effectiveAppearance)) {
            W7SafariGlassRemoveWindow(w);
            return;
        }
        BOOL key = w.isKeyWindow || w.isMainWindow;
        NSView *toolbar = W7SafariToolbarView(w), *tabBar = W7SafariTabBarView(w);
        BOOL tabs = tabBar && !tabBar.isHiddenOrHasHiddenAncestor;
        W7SafariGlassWindowState *s = W7SafariGlassState(w, YES);
        NSInteger seen = 1 | key << 1 | tabs << 2;
        if (!force && s.seen == seen) return;
        NSMutableArray<NSView *> *platters = [NSMutableArray array];
        W7SafariCollect(toolbar, 0, 4, objc_getClass("NSToolbarPlatterView"), Nil, platters);
        for (NSView *platter in platters) W7SafariGlassStylePlatter(platter, toolbar);
        if (tabs) W7SafariGlassStyleTabBarControls(w, tabBar);
        s.seen = platters.count ? seen : 0;   // no platters yet (toolbar not built): look again next time
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari glass update failed: %{public}@", e.reason ?: @"unknown"); }
}

void W7SafariGlassUpdateWindow(NSWindow *w) { W7SafariGlassUpdate(w, NO); }
#pragma mark - Hooks and start
BOOL W7SafariHookPlatterLayout(Class cls) {
    static __unsafe_unretained Class hooked[8];   // classes live as long as the process
    static int hookedCount;
    @try {
        if (!cls) return NO;
        for (int i = 0; i < hookedCount; i++) if (hooked[i] == cls) return YES;
        SEL layout = @selector(layout);
        Method m = hookedCount < 8 ? W7SafariCheckedMethod(cls, layout, "v16@0:8") : NULL;
        if (!m) return NO;
        void (*original)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(NSView *me) {
            original(me, layout);
            @try {
                NSView *glass = objc_getAssociatedObject(me, kPlatterGlassKey);   // nil for every platter not styled here
                if (!glass) return;
                W7SafariGlassSnapshot *snap = W7SafariSnap(glass);
                NSWindow *w = me.window;
                if (snap && gGlassEnabled && W7SafariWindowIsThemed(w) && !W7SafariIsDark(w.effectiveAppearance))
                    W7SafariGlassApply(glass, snap.appliedTint, snap.appliedClear, snap.appliedRadius);
                else W7SafariUnstylePlatter(me);
            } @catch (NSException *e) { os_log_error(W7Log(), "Safari platter re-style failed: %{public}@", e.reason ?: @"unknown"); }
        }));
        hooked[hookedCount++] = cls;
        W7SafariReport([NSString stringWithFormat:@"%@ -layout: hooked (glass style)", NSStringFromClass(cls)]);
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari platter hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

void W7SafariGlassStart(BOOL enabled) {
    static BOOL observing;
    gGlassEnabled = enabled;
    @try {
        Class glass = W7SafariGlassClass();
        W7SafariReport([NSString stringWithFormat:@"glass tint %@: NSGlassEffectView %d, tintColor %d, style %d, cornerRadius %d",
                        enabled ? @"on" : @"off (W7SafariGlassTintDisabled or W7SafariHooksDisabled)", glass != Nil,
                        W7SafariCanTint(glass), W7SafariCanStyle(glass), W7SafariCanRadius(glass)]);
        if (!enabled || observing) return;
        observing = YES;
        W7SafariReport(W7SafariHookPlatterLayout(objc_getClass("NSToolbarPlatterView")) ? @"glass platter hook: installed" : @"glass platter hook: not installed");
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        NSOperationQueue *main = NSOperationQueue.mainQueue;
        [nc addObserverForName:NSWindowWillCloseNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            NSWindow *w = n.object;
            if (![w isKindOfClass:NSWindow.class] || !W7SafariGlassState(w, NO)) return;
            W7SafariGlassRemoveWindow(w);
            objc_setAssociatedObject(w, kGlassWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }];
        [nc addObserverForName:NSToolbarWillAddItemNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            for (NSWindow *w in NSApp.windows) {   // styled once the item is in (the next main-queue pass)
                if (w.toolbar != n.object || !W7SafariWindowIsThemed(w)) continue;
                __weak NSWindow *weakWindow = w;
                dispatch_async(dispatch_get_main_queue(), ^{ W7SafariGlassUpdate(weakWindow, YES); });
            }
        }];
        [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"AppleInterfaceThemeChangedNotification" object:nil
                                                                    queue:main usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                @try { for (NSWindow *w in NSApp.windows) if (W7SafariGlassState(w, NO)) W7SafariGlassUpdate(w, YES); }
                @catch (NSException *e) { os_log_error(W7Log(), "Safari glass appearance update failed: %{public}@", e.reason ?: @"unknown"); }
            });
        }];
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari glass start failed: %{public}@", e.reason ?: @"unknown"); }
}
