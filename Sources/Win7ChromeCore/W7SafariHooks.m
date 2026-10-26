// Internet Explorer 7-style chrome for Safari, L4: the private hooks into Safari's own classes and
// the restores that undo them. The window side (gate, the rows' band, orb overlay, status bar) is W7SafariChrome.m.
// Every hook checks the exact type encoding of the class's OWN method (an inherited one, or a changed
// encoding, leaves Safari's code alone), calls the original first, acts only for a themed window and runs
// inside @try. A hook that runs for a view whose window is no longer themed (full screen, a torn-off tab)
// takes its look off again. `defaults write -g W7SafariHooksDisabled -bool YES` installs none of them.
//   a. -[BrowserWindowController _needsUncoloredTitlebar] YES, -backgroundColorInTabBarEnabled NO (no tint).
//   b. -[UnifiedTabBar layout] (+ -_updateSeparatorVisibilityForTabBarItem:isHighlighted:): separators at alpha 0
//      and plain backdrops hidden, so the title bar glass shows through; capture-only or grouped backdrops (the glass
//      tabs' backdrop source) and backdrops holding the tabs are kept.
//   c. -[UnifiedTabBarButton updateBackgroundAppearance] / -layout / -setActive: / -viewDidMoveToWindow: the
//      tab's faces at alpha 0 (not hidden: it keeps every click) and the IE8 facsimile view drawn over it
//      (W7SafariTabFacsimile.m), Safari's own _closeButton moved to the tab's right end (
//      W7SafariTabCloseButton.m); with W7SafariFacsimileTabsDisabled, Safari's own tab.
//   d. -[ToolbarController _prepareBackForwardSegmentedControl:]: the orb images in the segments.
//   e. -[BrowserWindowController _setStatusMessage:] / loading / fluid progress: into the status bar.
// Never touched: the address field (UnifiedField*), the tab's title, icon (read for drawing only) and accessories, the
// close button's constraints (only its frame is set, and put back), -_updateViewsForPrivateBrowsing, and every class
// W7SafariIsExcludedClassName names.
#import "W7SafariInternal.h"
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - Runtime helpers

/// `cls`'s own (not inherited) method for `sel`, or NULL.
static Method W7SafariOwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count && !found; i++)
        if (method_getName(methods[i]) == sel) found = methods[i];
    free(methods);
    return found;
}

static NSMutableArray<NSString *> *gHookReport;   // one line per hook attempt, for the diagnostics

void W7SafariReport(NSString *line) {
    if (!gHookReport) gHookReport = [NSMutableArray array];
    [gHookReport addObject:line];
    os_log(W7Log(), "Safari chrome: %{public}@", line);
}

NSArray<NSString *> *W7SafariHookReport(void) { return gHookReport ? [gHookReport copy] : @[]; }

/// The own method of `cls` for `sel` when its encoding is exactly `types`; reports why not otherwise.
Method W7SafariCheckedMethod(Class cls, SEL sel, const char *types) {
    Method m = W7SafariOwnMethod(cls, sel);
    if (!m) {
        W7SafariReport([NSString stringWithFormat:@"%@ -%s: not found", NSStringFromClass(cls), sel_getName(sel)]);
        return NULL;
    }
    const char *actual = method_getTypeEncoding(m);
    if (!actual || strcmp(actual, types) != 0) {
        W7SafariReport([NSString stringWithFormat:@"%@ -%s: types %s, expected %s (not hooked)", NSStringFromClass(cls),
                        sel_getName(sel), actual ?: "(none)", types]);
        return NULL;
    }
    return m;
}

static NSMutableSet<NSString *> *gHooked;   // "<kind>|<class pointer>", main thread only

static BOOL W7SafariIsHooked(NSString *kind, Class cls) {
    return [gHooked containsObject:[NSString stringWithFormat:@"%@|%p", kind, (__bridge const void *)cls]];
}

static void W7SafariMarkHooked(NSString *kind, Class cls, SEL sel) {
    if (!gHooked) gHooked = [NSMutableSet set];
    [gHooked addObject:[NSString stringWithFormat:@"%@|%p", kind, (__bridge const void *)cls]];
    W7SafariReport([NSString stringWithFormat:@"%@ -%s: hooked", NSStringFromClass(cls), sel_getName(sel)]);
}

BOOL W7SafariHasTypes(id obj, SEL sel, const char *types) {
    if (!obj) return NO;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    const char *actual = m ? method_getTypeEncoding(m) : NULL;
    return actual && strcmp(actual, types) == 0;
}

BOOL W7SafariReadBool(id obj, SEL sel, BOOL *out) {
    if (!W7SafariHasTypes(obj, sel, "B16@0:8")) return NO;
    *out = ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
    return YES;
}

BOOL W7SafariReadUInt64(id obj, SEL sel, unsigned long long *out) {
    if (!W7SafariHasTypes(obj, sel, "Q16@0:8")) return NO;
    *out = ((unsigned long long (*)(id, SEL))objc_msgSend)(obj, sel);
    return YES;
}

BOOL W7SafariReadInteger(id obj, SEL sel, NSInteger *out) {
    if (!W7SafariHasTypes(obj, sel, "q16@0:8")) return NO;
    *out = ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel);
    return YES;
}

BOOL W7SafariReadInt(id obj, SEL sel, int *out) {
    if (!W7SafariHasTypes(obj, sel, "i16@0:8")) return NO;
    *out = ((int (*)(id, SEL))objc_msgSend)(obj, sel);
    return YES;
}

BOOL W7SafariReadDouble(id obj, SEL sel, double *out) {
    if (!W7SafariHasTypes(obj, sel, "d16@0:8")) return NO;
    *out = ((double (*)(id, SEL))objc_msgSend)(obj, sel);
    return YES;
}

id W7SafariReadObject(id obj, SEL sel) {
    if (!W7SafariHasTypes(obj, sel, "@16@0:8")) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

id W7SafariIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || type[0] != '@') return nil;
    return object_getIvar(obj, ivar);
}

NSView *W7SafariIvarView(id obj, const char *name) {
    id v = W7SafariIvar(obj, name);
    return [v isKindOfClass:NSView.class] ? v : nil;
}

NSWindow *W7SafariControllerWindow(id controller) {
    if (![controller isKindOfClass:NSWindowController.class]) return nil;
    NSWindowController *wc = controller;
    return wc.isWindowLoaded ? wc.window : nil;
}

#pragma mark - Hook a: no website tint

static BOOL gColorsHooked, gBackForwardHooked;
static uint64_t gTabBarLayoutCalls, gTabButtonLayoutCalls, gTabButtonBackgroundCalls, gRehides;

BOOL W7SafariColorsHookInstalled(void) { return gColorsHooked; }
BOOL W7SafariBackForwardHookInstalled(void) { return gBackForwardHooked; }
W7SafariHookCounts W7SafariHookCallCounts(void) {
    return (W7SafariHookCounts){ gTabBarLayoutCalls, gTabButtonLayoutCalls, gTabButtonBackgroundCalls, gRehides };
}

/// Replaces `cls`'s own BOOL getter `sel` (exactly B16@0:8) so a themed window's controller answers `themedAnswer`.
static BOOL W7SafariHookControllerBool(Class cls, SEL sel, NSString *kind, BOOL themedAnswer) {
    if (W7SafariIsHooked(kind, cls)) return YES;
    Method m = W7SafariCheckedMethod(cls, sel, "B16@0:8");
    if (!m) return NO;
    BOOL (*original)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^BOOL(id me) {
        BOOL r = original(me, sel);
        @try { if (W7SafariWindowIsThemed(W7SafariControllerWindow(me))) return themedAnswer; }
        @catch (NSException *e) { os_log_error(W7Log(), "Safari %{public}s hook failed: %{public}@", sel_getName(sel), e.reason ?: @"unknown"); }
        return r;
    }));
    W7SafariMarkHooked(kind, cls, sel);
    return YES;
}

BOOL W7SafariHookWindowControllerColors(Class cls) {
    @try {
        if (!cls) return NO;
        BOOL uncolored = W7SafariHookControllerBool(cls, W7SafariSel("_needsUncoloredTitlebar"), @"uncolored", YES);
        BOOL tint = W7SafariHookControllerBool(cls, W7SafariSel("backgroundColorInTabBarEnabled"), @"tint", NO);
        return uncolored || tint;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari colour hooks failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Hiding and showing Safari's views

static const void *kHiddenViewsKey = &kHiddenViewsKey;

/// Hides `v` and remembers it on `owner` for the restore; never a view holding `keep` (or `keep` itself).
static void W7SafariHide(NSView *owner, NSView *v, NSView *keep) {
    if (!v || v.isHidden || (keep && [keep isDescendantOf:v])) return;
    NSHashTable *hidden = objc_getAssociatedObject(owner, kHiddenViewsKey);
    if (!hidden) {
        hidden = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(owner, kHiddenViewsKey, hidden, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([hidden containsObject:v]) gRehides++;   // Safari showed it again since we hid it
    v.hidden = YES;
    [hidden addObject:v];
}

static void W7SafariUnhideAll(NSView *owner) {
    NSHashTable *hidden = objc_getAssociatedObject(owner, kHiddenViewsKey);
    if (!hidden) return;
    objc_setAssociatedObject(owner, kHiddenViewsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (NSView *v in hidden.allObjects) v.hidden = NO;
}

#pragma mark - Hook b: tab bar

static const void *kTabBarStyledKey = &kTabBarStyledKey;
static void W7SafariStyleTabButton(NSView *button);   // hook c's pass (below), also run from the tab bar's

/// Tab buttons under `v` (at most 3 deep) that are not in `skip` (already done), through hook c's pass.
static void W7SafariStyleTabButtonsUnder(NSView *v, int depth, id skip) {
    static Class buttonClass;
    if (!buttonClass) buttonClass = objc_getClass("UnifiedTabBarButton");
    if (!v || !buttonClass || depth > 3) return;
    for (NSView *sub in v.subviews) {
        if ([sub isKindOfClass:buttonClass]) { if (![skip containsObject:sub]) W7SafariStyleTabButton(sub); }
        else W7SafariStyleTabButtonsUnder(sub, depth + 1, skip);
    }
}

/// Calls `body` with each tab separator (the values of _tabBarItemsToTabBarButtonSeparators) that answers
/// -setSeparatorAlphaValue: with exactly v24@0:8d16. Enumerates the map's keys (no enumerator object).
static void W7SafariForEachSeparator(NSView *tabBar, void (^body)(NSView *separator, SEL setter)) {
    NSMapTable *map = W7SafariIvar(tabBar, "_tabBarItemsToTabBarButtonSeparators");
    if (![map isKindOfClass:NSMapTable.class]) return;
    SEL setter = W7SafariSel("setSeparatorAlphaValue:");
    static Class checkedClass;
    static BOOL checkedOK;
    for (id key in map) {
        NSView *s = [map objectForKey:key];
        if (![s isKindOfClass:NSView.class]) continue;
        Class c = object_getClass(s);
        if (c != checkedClass) { checkedClass = c; checkedOK = W7SafariHasTypes(s, setter, "v24@0:8d16"); }
        if (checkedOK) body(s, setter);
    }
}

/// Shows the backdrops again and lets Safari decide every separator anew: its own
/// -_updateSeparatorVisibilityForTabBarItem:isHighlighted: per item (the highlighted one as such), or, when
/// that is not there with the expected encoding, alpha 1. The styled mark goes first, so the re-run (which
/// passes through hook b) finds nothing to undo.
static void W7SafariRestoreZeroedSeparators(NSView *tabBar);

static void W7SafariUnstyleTabBar(NSView *tabBar, BOOL relayout) {
    objc_setAssociatedObject(tabBar, kTabBarStyledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    W7SafariUnhideAll(tabBar);
    W7SafariRestoreZeroedSeparators(tabBar);
    SEL update = W7SafariSel("_updateSeparatorVisibilityForTabBarItem:isHighlighted:");
    NSMapTable *map = W7SafariIvar(tabBar, "_tabBarItemsToTabBarButtonSeparators");
    if ([map isKindOfClass:NSMapTable.class] && W7SafariHasTypes(tabBar, update, "v28@0:8@16B24")) {
        id highlighted = W7SafariIvar(tabBar, "_highlightedTabBarViewItem");
        for (id item in map.keyEnumerator.allObjects)
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(tabBar, update, item, item == highlighted);
    } else {
        W7SafariForEachSeparator(tabBar, ^(NSView *s, SEL setter) { ((void (*)(id, SEL, double))objc_msgSend)(s, setter, 1.0); });
    }
    if (relayout) tabBar.needsLayout = YES;
}

static const char *const kTabBarBackdropIvars[] = { "_backdropView", "_pinnedTabRegionBackdropView" };

/// Hides one of the tab bar's backdrops, unless it is a capture-only BackdropView (-captureOnly YES or a
/// -groupName: the source the tab buttons' glass samples through their backdrop group, so hiding it blanks every
/// tab) or it holds the tabs (_tabContainer, _scrollView). The first trip per ivar is logged.
static const void *kKeptBackdropKey = &kKeptBackdropKey;

static void W7SafariHideTabBarBackdrop(NSView *tabBar, size_t index) {
    const char *ivar = kTabBarBackdropIvars[index];
    NSView *v = W7SafariIvarView(tabBar, ivar);
    if (!v || v.isHidden || objc_getAssociatedObject(v, kKeptBackdropKey)) return;   // kept once, kept for good
    BOOL captureOnly = NO, holdsTabs = NO;
    id group = nil;
    W7SafariReadBool(v, W7SafariSel("captureOnly"), &captureOnly);
    if (!captureOnly) group = W7SafariReadObject(v, W7SafariSel("groupName"));
    if (!captureOnly && !group) {
        NSView *container = W7SafariIvarView(tabBar, "_tabContainer"), *scroll = W7SafariIvarView(tabBar, "_scrollView");
        holdsTabs = (container && [container isDescendantOf:v]) || (scroll && [scroll isDescendantOf:v]);
    }
    if (captureOnly || group || holdsTabs) {
        objc_setAssociatedObject(v, kKeptBackdropKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static uint32_t logged;
        if (!(logged & (1u << index))) {
            logged |= 1u << index;
            os_log(W7Log(), "Safari chrome: tab bar %{public}s (%{public}@) kept visible (captureOnly %d, group %d, holds tabs %d)",
                   ivar, NSStringFromClass(v.class), captureOnly, group != nil, holdsTabs);
        }
        return;
    }
    W7SafariHide(tabBar, v, nil);
}

#pragma mark - Separators outside hook b's table

/// Whether a C class name contains "separator" (any case).
static BOOL W7SafariCNameIsSeparator(const char *name) { return name && strcasestr(name, "separator") != NULL; }

/// The object ivars (type '@') of `cls` and its superclasses up to NSView whose name contains `word` (any case), found
/// once per class (class_copyIvarList allocates) and kept in a table: nothing allocated on a later pass.
NSArray<NSString *> *W7SafariIvarNamesContaining(Class cls, const char *word) {
    enum { kMaxClasses = 16 };   // a plain table (class, word, names): no key object per lookup
    static struct { __unsafe_unretained Class cls; const char *word; NSArray<NSString *> *names; } table[kMaxClasses];
    static int used;
    if (!cls || !word) return @[];
    for (int i = 0; i < used; i++) if (table[i].cls == cls && strcmp(table[i].word, word) == 0) return table[i].names;
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (Class c = cls; c && c != NSView.class && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]), *type = ivar_getTypeEncoding(ivars[i]);
            if (name && type && type[0] == '@' && strcasestr(name, word)) [found addObject:@(name)];
        }
        free(ivars);
    }
    if (used < kMaxClasses) table[used++] = (typeof(table[0])){ cls, word, found };   // `word` is a literal at every call site
    return found;
}

static const void *kZeroedSeparatorsKey = &kZeroedSeparatorsKey;   // on a tab bar: separator (weak) → the alpha it had

/// A separator-class view to alpha 0. Safari's own -setSeparatorAlphaValue: (exactly v24@0:8d16) is called when the
/// view has it, but it fades only a 1×16 sliver inside UnifiedTabBarSeparator (the live dump); the separator itself
/// and its full-height opaque backdrop keep alpha 1 and showed as a line at Safari's own tab boundary. So the view's
/// own alphaValue goes to 0 as well, the alpha found saved on the tab bar (Safari's newest, when it changed it since)
/// for the restore. Never a view of another class.
static void W7SafariZeroSeparatorView(NSView *tabBar, id v) {
    if (![v isKindOfClass:NSView.class]) return;
    const char *cls = class_getName(object_getClass(v));
    if (!W7SafariCNameIsSeparator(cls) || W7SafariIsExcludedCName(cls)) return;
    NSView *view = v;
    SEL setter = W7SafariSel("setSeparatorAlphaValue:");
    if (W7SafariHasTypes(view, setter, "v24@0:8d16")) ((void (*)(id, SEL, double))objc_msgSend)(view, setter, 0.0);
    if (view.alphaValue == 0) return;
    NSMapTable<NSView *, NSNumber *> *zeroed = objc_getAssociatedObject(tabBar, kZeroedSeparatorsKey);
    if (!zeroed) {
        zeroed = [NSMapTable weakToStrongObjectsMapTable];
        objc_setAssociatedObject(tabBar, kZeroedSeparatorsKey, zeroed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [zeroed setObject:@(view.alphaValue) forKey:view];   // allocates only when Safari gave it an alpha again
    view.alphaValue = 0;
}

/// A separator held by an ivar: the view itself, or each of an array / set / dictionary / map table of them.
static void W7SafariZeroSeparatorsIn(NSView *tabBar, id value) {
    if ([value isKindOfClass:NSView.class]) W7SafariZeroSeparatorView(tabBar, value);
    else if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSSet.class]) { for (id v in value) W7SafariZeroSeparatorView(tabBar, v); }
    else if ([value isKindOfClass:NSDictionary.class]) { for (id k in value) W7SafariZeroSeparatorView(tabBar, ((NSDictionary *)value)[k]); }
    else if ([value isKindOfClass:NSMapTable.class]) { for (id k in value) W7SafariZeroSeparatorView(tabBar, [(NSMapTable *)value objectForKey:k]); }
}

/// Every separator-named ivar of `obj` (its class chain), zeroed.
static void W7SafariZeroSeparatorIvars(NSView *tabBar, id obj) {
    for (NSString *name in W7SafariIvarNamesContaining(object_getClass(obj), "separator")) W7SafariZeroSeparatorsIn(tabBar, W7SafariIvar(obj, name.UTF8String));
}

void W7SafariZeroTabSeparators(NSView *tabBar) {
    if (!tabBar) return;
    W7SafariForEachSeparator(tabBar, ^(NSView *s, SEL setter) { ((void (*)(id, SEL, double))objc_msgSend)(s, setter, 0.0); });
    // Beyond the table: separators held by any
    // separator-named ivar of the tab bar or a visible button, or placed in the tab container / the scroll document view.
    W7SafariZeroSeparatorIvars(tabBar, tabBar);
    id buttons = W7SafariIvar(tabBar, "_visibleTabBarButtons");
    if ([buttons conformsToProtocol:@protocol(NSFastEnumeration)])
        for (id b in buttons) if ([b isKindOfClass:NSView.class]) W7SafariZeroSeparatorIvars(tabBar, b);
    NSView *scroll = W7SafariIvarView(tabBar, "_scrollView");
    NSView *document = [scroll isKindOfClass:NSScrollView.class] ? ((NSScrollView *)scroll).documentView : nil;
    for (NSView *v in W7SafariIvarView(tabBar, "_tabContainer").subviews) W7SafariZeroSeparatorView(tabBar, v);
    for (NSView *v in document.subviews) W7SafariZeroSeparatorView(tabBar, v);
}

/// Every separator's own alpha back to the one found (where still 0: ours); Safari's setter is the caller's to undo.
static void W7SafariRestoreZeroedSeparators(NSView *tabBar) {
    NSMapTable<NSView *, NSNumber *> *zeroed = objc_getAssociatedObject(tabBar, kZeroedSeparatorsKey);
    if (!zeroed) return;
    objc_setAssociatedObject(tabBar, kZeroedSeparatorsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (NSView *v in zeroed.keyEnumerator.allObjects) if (v.alphaValue == 0) v.alphaValue = [zeroed objectForKey:v].doubleValue;
}

static void W7SafariStyleTabBar(NSView *tabBar) {
    NSWindow *w = tabBar.window;
    if (!W7SafariWindowIsThemed(w)) {
        if (objc_getAssociatedObject(tabBar, kTabBarStyledKey)) W7SafariUnstyleTabBar(tabBar, NO);
        W7SafariRestoreIETabLayout(tabBar);   // Safari's own equal-width row back
        W7SafariNoteTabBarFrame(tabBar, w);
        W7SafariObserveTabBarLayout(tabBar, w);
        return;
    }
    if (!objc_getAssociatedObject(tabBar, kTabBarStyledKey))
        objc_setAssociatedObject(tabBar, kTabBarStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    W7SafariHideTabBarBackdrop(tabBar, 0);
    W7SafariHideTabBarBackdrop(tabBar, 1);
    W7SafariZeroTabSeparators(tabBar);
    W7SafariTrackStyled(w, tabBar, YES);
    // Every visible tab again (a no-op pass sets nothing): a tab Safari showed, moved or reset without its own layout
    // pass afterwards (the selected tab's glass after a selection change) gets its look back here. The selected tab may
    // sit in the tab bar's backdrop layer rather than among the visible buttons: those are walked too.
    id buttons = W7SafariIvar(tabBar, "_visibleTabBarButtons");
    if ([buttons conformsToProtocol:@protocol(NSFastEnumeration)])
        for (NSView *b in buttons) if ([b isKindOfClass:NSView.class]) W7SafariStyleTabButton(b);
    W7SafariStyleTabButtonsUnder(W7SafariIvarView(tabBar, "_backdropView"), 0, buttons);
    W7SafariApplyIETabLayout(tabBar);   // IE7's left-aligned, title-sized tabs
    W7SafariNoteTabBarFrame(tabBar, w);
    W7SafariObserveTabBarLayout(tabBar, w);
}

void W7SafariRestoreTabBar(NSView *tabBar) {
    @try {
        if (tabBar) W7SafariUnstyleTabBar(tabBar, YES), W7SafariRestoreIETabLayout(tabBar);
    } @catch (NSException *e) { os_log_error(W7Log(), "tab bar restore failed: %{public}@", e.reason ?: @"unknown"); }
}

BOOL W7SafariHookTabBar(Class cls) {
    @try {
        if (!cls) return NO;
        if (W7SafariIsHooked(@"tabbar", cls)) return YES;
        SEL layout = @selector(layout);
        Method m = W7SafariCheckedMethod(cls, layout, "v16@0:8");
        if (!m) return NO;
        void (*original)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(NSView *me) {
            original(me, layout);
            gTabBarLayoutCalls++;
            @try { W7SafariStyleTabBar(me); }
            @catch (NSException *e) { os_log_error(W7Log(), "tab bar restyle failed: %{public}@", e.reason ?: @"unknown"); }
        }));
        W7SafariMarkHooked(@"tabbar", cls, layout);
        // Hover shows separators again without a layout pass: re-zero them after Safari's update too.
        SEL separators = W7SafariSel("_updateSeparatorVisibilityForTabBarItem:isHighlighted:");
        Method s = W7SafariCheckedMethod(cls, separators, "v28@0:8@16B24");
        if (s) {
            void (*originalS)(id, SEL, id, BOOL) = (void (*)(id, SEL, id, BOOL))method_getImplementation(s);
            method_setImplementation(s, imp_implementationWithBlock(^(NSView *me, id item, BOOL highlighted) {
                originalS(me, separators, item, highlighted);
                @try { W7SafariStyleTabBar(me); }
                @catch (NSException *e) { os_log_error(W7Log(), "tab separator restyle failed: %{public}@", e.reason ?: @"unknown"); }
            }));
            W7SafariReport([NSString stringWithFormat:@"%@ -%s: hooked", NSStringFromClass(cls), sel_getName(separators)]);
        }
        W7SafariHookTabBarButtonLayout(cls);   // the IE7 tab row after Safari's own button layout too
        W7SafariHookTabBarButtonAtPoint(cls);  // the hovered tab from our frames while that row is in force
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "tab bar hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Hook c: tab buttons

W7IETabState W7SafariTabButtonState(NSView *button) {
    BOOL active = NO, selected = NO, highlighted = NO, pinned = NO;
    NSInteger state = 0;
    W7SafariReadBool(button, W7SafariSel("isActive"), &active);
    W7SafariReadBool(button, W7SafariSel("isSelected"), &selected);
    W7SafariReadBool(button, W7SafariSel("isHighlighted"), &highlighted);
    W7SafariReadBool(button, W7SafariSel("isPinned"), &pinned);
    W7SafariReadInteger(button, W7SafariSel("state"), &state);
    return W7SafariTabState(active, selected, highlighted, pinned, state);
}

/// Takes the facsimile off (Safari's faces back at their own alphas); with `refresh`, lets Safari settle its own
/// background views again at once (its -updateBackgroundAppearance: a hover alpha saved while styled may be stale). That
/// pass re-enters hook c, which finds the button unstyled and leaves it.
static void W7SafariUnstyleTabButton(NSView *button, BOOL refresh) {
    W7SafariFacsimileUnstyleButton(button);
    static BOOL refreshing;
    SEL update = W7SafariSel("updateBackgroundAppearance");
    if (!refresh || refreshing || !W7SafariHasTypes(button, update, "v16@0:8")) return;
    refreshing = YES;
    @try { ((void (*)(id, SEL))objc_msgSend)(button, update); }
    @finally { refreshing = NO; }
}

void W7SafariRestoreTabButton(NSView *button) {
    @try {
        if (button) W7SafariUnstyleTabButton(button, YES);
    } @catch (NSException *e) { os_log_error(W7Log(), "tab button restore failed: %{public}@", e.reason ?: @"unknown"); }
}

static const void *kTabNotesKey = &kTabNotesKey;   // on a tab button: the notes logged for it (bit mask, NSNumber)

BOOL W7SafariTabNoted(NSView *button, W7SafariTabNote note) {
    return ([objc_getAssociatedObject(button, kTabNotesKey) unsignedIntegerValue] & ((NSUInteger)1 << note)) != 0;
}

void W7SafariNoteTab(NSView *button, W7SafariTabNote note, NSString *detail) {
    static NSInteger lines;
    NSUInteger mask = [objc_getAssociatedObject(button, kTabNotesKey) unsignedIntegerValue], bit = (NSUInteger)1 << note;
    if ((mask & bit) || lines >= 80) return;   // no allocation once a reason is logged for the button
    lines++;
    objc_setAssociatedObject(button, kTabNotesKey, @(mask | bit), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static const char *const names[] = { "", "window nil (out of any window: deferred)", "window not themed", "hidden and never styled",
        "_unifiedField set (Compact layout)", "_contentView nil or outside the button", "facsimile tabs off (Safari's own tab)",
        "facsimile failed (Safari's own tab)", "exception", "facsimile drawn" };
    BOOL active = NO;
    W7SafariReadBool(button, W7SafariSel("isActive"), &active);
    NSRect f = [button convertRect:button.bounds toView:nil];
    os_log(W7Log(), "Safari tabs: tab (%g,%g %gx%g)%{public}s in %{public}@: %{public}s%{public}s%{public}@", f.origin.x, f.origin.y,
           f.size.width, f.size.height, active ? " (selected)" : "", button.superview ? NSStringFromClass(button.superview.class) : @"nil",
           note < (NSInteger)(sizeof names / sizeof *names) ? names[note] : "?", detail ? " " : "", detail ?: @"");
}

static void W7SafariStyleTabButton(NSView *button) {
    NSWindow *w = button.window;
    if (!w) { W7SafariNoteTab(button, W7SafariTabNoteWindowNil, nil); return; }   // decided once it is back in a window
    BOOL styled = W7SafariFacsimileIsStyled(button);
    if (!W7SafariWindowIsThemed(w)) {
        if (styled) W7SafariUnstyleTabButton(button, NO);
        return;
    }
    if (!W7SafariFacsimileEnabled()) {   // kill switch: Safari's own tabs
        W7SafariNoteTab(button, W7SafariTabNoteFacsimileOff, nil);
        if (styled) W7SafariUnstyleTabButton(button, YES);
        return;
    }
    // Hidden buttons (the toolbar's own tab bar, unused in the Separate layout) are left until they show.
    if (!styled && button.isHiddenOrHasHiddenAncestor) { W7SafariNoteTab(button, W7SafariTabNoteHiddenNeverStyled, nil); return; }
    if (W7SafariIvar(button, "_unifiedField")) {   // the address field lives in this tab (Compact layout)
        W7SafariNoteTab(button, W7SafariTabNoteUnifiedField, nil);
        if (styled) W7SafariUnstyleTabButton(button, YES);
        return;
    }
    NSView *content = W7SafariIvarView(button, "_contentView");
    if (!content || ![content isDescendantOf:button]) {   // Safari restructured it: its own tab, nothing stale of ours
        W7SafariNoteTab(button, W7SafariTabNoteNoContent, nil);
        if (styled) W7SafariUnstyleTabButton(button, YES);
        return;
    }
    W7SafariCloseButtonPlace(button, w);   // Safari's × to the tab's right end, before the facsimile reads it
    if (!W7SafariFacsimileStyleButton(button)) { W7SafariNoteTab(button, W7SafariTabNoteFacsimileFailed, nil); return; }
    W7SafariTrackStyled(w, button, NO);   // also in a new window when Safari moved it (no allocation once tracked)
    if (styled) return;
    if (!W7SafariTabNoted(button, W7SafariTabNoteStyled)) {   // formatted once per button
        BOOL closeShown = NO;
        W7SafariFacsimileCloseRect(button, button, &closeShown);
        static NSString *const placements[] = { @"not found", @"found, left where Safari put it", @"moved to the right end",
                                                @"left where Safari put it (backed off)" };
        W7SafariCloseButtonPlacement placement = W7SafariCloseButtonPlacementOf(button);
        NSView *glass = W7SafariIvarView(button, "_contentGlassView");
        NSImageView *iconView = (NSImageView *)W7SafariIvarView(button, "_iconImageView");
        NSImage *icon = [iconView isKindOfClass:NSImageView.class] ? iconView.image : nil;   // only whether it is a template
        // How Safari positions the close button (frames or Auto Layout): what a diagnostic run needs to read.
        NSView *close = W7SafariIvarView(button, "_closeButton");
        NSString *positioning = close ? [NSString stringWithFormat:@", in %@, autoresizing-translated %d, %lu constraints",
                                         close.superview ? NSStringFromClass(close.superview.class) : @"nil",
                                         close.translatesAutoresizingMaskIntoConstraints, (unsigned long)close.constraints.count] : @"";
        W7SafariNoteTab(button, W7SafariTabNoteStyled, [NSString stringWithFormat:@"(glass %@, content in %@, _closeButton %@%@%@, icon %@)",
                        glass ? NSStringFromClass(glass.class) : @"nil", NSStringFromClass(content.superview.class),
                        placements[MAX(0, MIN(placement, 3))], placement == W7SafariCloseButtonNotFound ? @"" : closeShown ? @", shown" : @", not shown",
                        positioning, !icon ? @"none" : icon.isTemplate ? @"template (drawn as IE's page icon)" : @"image"]);
    }
}

BOOL W7SafariHookTabButton(Class cls) {
    @try {
        if (!cls) return NO;
        if (W7SafariIsHooked(@"tabbutton", cls)) return YES;
        SEL background = W7SafariSel("updateBackgroundAppearance"), layout = @selector(layout);
        Method mb = W7SafariCheckedMethod(cls, background, "v16@0:8");
        Method ml = W7SafariCheckedMethod(cls, layout, "v16@0:8");
        if (!mb || !ml) return NO;   // both or neither
        void (*originalB)(id, SEL) = (void (*)(id, SEL))method_getImplementation(mb);
        void (*originalL)(id, SEL) = (void (*)(id, SEL))method_getImplementation(ml);
        method_setImplementation(mb, imp_implementationWithBlock(^(NSView *me) {
            originalB(me, background);
            gTabButtonBackgroundCalls++;
            @try { W7SafariStyleTabButton(me); }
            @catch (NSException *e) { W7SafariNoteTab(me, W7SafariTabNoteException, e.reason); }
        }));
        method_setImplementation(ml, imp_implementationWithBlock(^(NSView *me) {
            originalL(me, layout);
            gTabButtonLayoutCalls++;
            @try { W7SafariStyleTabButton(me); }
            @catch (NSException *e) { W7SafariNoteTab(me, W7SafariTabNoteException, e.reason); }
        }));
        W7SafariMarkHooked(@"tabbutton", cls, background);
        W7SafariReport([NSString stringWithFormat:@"%@ -layout: hooked", NSStringFromClass(cls)]);
        // Selecting a tab (-setActive:, v20@0:8B16) changes its look without always a layout pass after.
        SEL active = W7SafariSel("setActive:");
        Method ma = W7SafariCheckedMethod(cls, active, "v20@0:8B16");
        if (ma) {
            void (*originalA)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))method_getImplementation(ma);
            method_setImplementation(ma, imp_implementationWithBlock(^(NSView *me, BOOL flag) {
                originalA(me, active, flag);
                @try {
                    W7SafariStyleTabButton(me);
                    if (flag) W7SafariCommandBarRevalidate(me.window, NO);   // ✚ for the newly selected tab (throttled)
                } @catch (NSException *e) { os_log_error(W7Log(), "tab selection restyle failed: %{public}@", e.reason ?: @"unknown"); }
            }));
            W7SafariReport([NSString stringWithFormat:@"%@ -setActive:: hooked", NSStringFromClass(cls)]);
        }
        // Safari moves the selected tab between containers (scroll view ↔ the tab bar's backdrop layer): restyle after.
        SEL moved = @selector(viewDidMoveToWindow);
        Method mm = W7SafariCheckedMethod(cls, moved, "v16@0:8");
        if (mm) {
            void (*originalM)(id, SEL) = (void (*)(id, SEL))method_getImplementation(mm);
            method_setImplementation(mm, imp_implementationWithBlock(^(NSView *me) {
                originalM(me, moved);
                @try { W7SafariStyleTabButton(me); }
                @catch (NSException *e) { W7SafariNoteTab(me, W7SafariTabNoteException, e.reason); }
            }));
            W7SafariReport([NSString stringWithFormat:@"%@ -viewDidMoveToWindow: hooked", NSStringFromClass(cls)]);
        }
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "tab button hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Hook d: back/forward orbs

static const void *kOriginalImagesKey = &kOriginalImagesKey;

NSImage *W7SafariOrbImage(BOOL forward) {
    static NSImage *images[2];
    NSInteger i = forward ? 1 : 0;
    if (!images[i]) {
        CGFloat side = forward ? W7IEForwardOrbSize : W7IEBackOrbSize;
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(side, side)];
        for (CGFloat scale = 1; scale <= 2; scale++) {
            CGImageRef cg = W7CreateIENavOrbImage(forward, scale);
            if (!cg) continue;
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
            rep.size = NSMakeSize(side, side);
            [image addRepresentation:rep];
            CGImageRelease(cg);
        }
        image.template = NO;
        image.accessibilityDescription = forward ? @"Forward" : @"Back";
        images[i] = image;
    }
    return images[i];
}

void W7SafariApplyBackForward(NSSegmentedControl *control) {
    @try {
        if (!control) return;
        NSInteger n = MIN(control.segmentCount, 2);
        if (n <= 0) return;
        if (!objc_getAssociatedObject(control, kOriginalImagesKey)) {
            NSMutableArray *originals = [NSMutableArray array];
            for (NSInteger i = 0; i < n; i++) [originals addObject:[control imageForSegment:i] ?: (id)NSNull.null];
            objc_setAssociatedObject(control, kOriginalImagesKey, originals, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        for (NSInteger i = 0; i < n; i++) {
            NSImage *orb = W7SafariOrbImage(i == 1);
            if ([control imageForSegment:i] != orb) [control setImage:orb forSegment:i];
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "orb images failed: %{public}@", e.reason ?: @"unknown"); }
}

void W7SafariRestoreBackForward(NSSegmentedControl *control) {
    @try {
        NSArray *originals = objc_getAssociatedObject(control, kOriginalImagesKey);
        if (!originals) return;
        objc_setAssociatedObject(control, kOriginalImagesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSInteger i = 0; i < (NSInteger)originals.count && i < control.segmentCount; i++) {
            id image = originals[i];
            [control setImage:[image isKindOfClass:NSImage.class] ? image : nil forSegment:i];
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "orb restore failed: %{public}@", e.reason ?: @"unknown"); }
}

/// The orbs for a themed window; Safari's images back for a window no longer themed.
static void W7SafariSyncBackForward(NSSegmentedControl *c) {
    if (W7SafariWindowIsThemed(c.window)) W7SafariApplyBackForward(c);
    else W7SafariRestoreBackForward(c);
}

BOOL W7SafariHookBackForward(Class cls) {
    @try {
        if (!cls) return NO;
        if (W7SafariIsHooked(@"backforward", cls)) return YES;
        SEL sel = W7SafariSel("_prepareBackForwardSegmentedControl:");
        Method m = W7SafariCheckedMethod(cls, sel, "v24@0:8@16");
        if (!m) return NO;
        void (*original)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id me, id control) {
            original(me, sel, control);
            @try {
                if (![control isKindOfClass:NSSegmentedControl.class]) return;
                NSSegmentedControl *c = control;
                if (c.window) { W7SafariSyncBackForward(c); return; }
                // Prepared before it is in a window: decide once it is in one.
                __weak NSSegmentedControl *weakControl = c;
                CFRunLoopRef main = CFRunLoopGetMain();
                CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
                    @try {
                        NSSegmentedControl *later = weakControl;
                        if (later.window) W7SafariSyncBackForward(later);
                    } @catch (NSException *e) { os_log_error(W7Log(), "deferred orbs failed: %{public}@", e.reason ?: @"unknown"); }
                });
                CFRunLoopWakeUp(main);
            } @catch (NSException *e) { os_log_error(W7Log(), "back/forward hook failed: %{public}@", e.reason ?: @"unknown"); }
        }));
        W7SafariMarkHooked(@"backforward", cls, sel);
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "back/forward hook install failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Hook e: status message and loading

void W7SafariFeedLoading(id controller, BOOL titlesMayHaveChanged) {
    NSWindow *w = W7SafariControllerWindow(controller);
    W7StatusBarView *bar = W7SafariStatusBarForWindow(w);
    if (!bar) return;
    int status = 0;
    if (!W7SafariReadInt(controller, W7SafariSel("currentTabLoadingStatus"), &status)) return;
    double estimated = 0;
    W7SafariReadDouble(W7SafariReadObject(controller, W7SafariSel("currentBrowserViewController")),
                       W7SafariSel("estimatedProgress"), &estimated);
    [bar w7SetLoading:W7SafariLoadingStatusIsLoading(status) progress:estimated];
    // A new title or favicon comes with loading: once, unthrottled, on a status change; progress ticks 4/s.
    W7SafariFacsimileRefreshWindow(w, titlesMayHaveChanged);
    if (titlesMayHaveChanged) W7SafariCommandBarRevalidate(w, NO);   // ✚ follows Add Bookmark…'s validation (throttled)
}

static NSString *W7SafariStringValue(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSURL.class]) return ((NSURL *)value).absoluteString;
    return nil;
}

/// Replaces `cls`'s own `sel` (exactly v24@0:8@16) with original-then-`after`.
static BOOL W7SafariHookObjectSetter(Class cls, SEL sel, NSString *kind, void (^after)(id me, id arg)) {
    if (W7SafariIsHooked(kind, cls)) return YES;
    Method m = W7SafariCheckedMethod(cls, sel, "v24@0:8@16");
    if (!m) return NO;
    void (*original)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id me, id arg) {
        original(me, sel, arg);
        @try { after(me, arg); }
        @catch (NSException *e) { os_log_error(W7Log(), "Safari %{public}s hook failed: %{public}@", sel_getName(sel), e.reason ?: @"unknown"); }
    }));
    W7SafariMarkHooked(kind, cls, sel);
    return YES;
}

BOOL W7SafariHookStatus(Class cls) {
    @try {
        if (!cls) return NO;
        BOOL message = W7SafariHookObjectSetter(cls, W7SafariSel("_setStatusMessage:"), @"status", ^(id me, id msg) {
            W7StatusBarView *bar = W7SafariStatusBarForWindow(W7SafariControllerWindow(me));
            if (!bar) return;
            [bar w7SetMessage:W7SafariStringValue(W7SafariReadObject(msg, W7SafariSel("string")))
                          url:W7SafariStringValue(W7SafariReadObject(msg, W7SafariSel("url")))];
        });
        BOOL loading = W7SafariHookObjectSetter(cls, W7SafariSel("loadingStatusDidChangeInBrowserViewController:"), @"loading",
                                                ^(id me, id bvc) { W7SafariFeedLoading(me, YES); });
        BOOL progress = W7SafariHookObjectSetter(cls, W7SafariSel("updateFluidProgressForBrowserViewController:"), @"progress",
                                                 ^(id me, id bvc) { W7SafariFeedLoading(me, NO); });
        return message || loading || progress;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "status hooks failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Installation

void W7SafariInstallHooks(void) {
    static BOOL installed;
    if (installed) return;
    installed = YES;
    struct { const char *cls; BOOL (*hook)(Class); const char *what; } hooks[] = {
        { "BrowserWindowController", W7SafariHookWindowControllerColors, "a (tint)" },
        { "UnifiedTabBar", W7SafariHookTabBar, "b (tab bar)" },
        { "UnifiedTabBarButton", W7SafariHookTabButton, "c (tabs)" },
        { "ToolbarController", W7SafariHookBackForward, "d (orbs)" },
        { "BrowserWindowController", W7SafariHookStatus, "e (status)" },
    };
    for (size_t i = 0; i < sizeof hooks / sizeof *hooks; i++) {
        @try {
            Class cls = objc_getClass(hooks[i].cls);
            if (!cls) { W7SafariReport([NSString stringWithFormat:@"%s: class %s not found", hooks[i].what, hooks[i].cls]); continue; }
            BOOL ok = hooks[i].hook(cls);
            if (hooks[i].hook == W7SafariHookBackForward) gBackForwardHooked = ok;
            if (hooks[i].hook == W7SafariHookWindowControllerColors) gColorsHooked = ok;
            W7SafariReport([NSString stringWithFormat:@"%s: %@", hooks[i].what, ok ? @"installed" : @"not installed"]);
        } @catch (NSException *e) {
            os_log_error(W7Log(), "Safari hook %{public}s failed: %{public}@", hooks[i].what, e.reason ?: @"unknown");
        }
    }
}
