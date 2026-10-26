// Internet Explorer-style Safari: the diagnostics. Once per themed window, a second after it is
// themed (and again when its tab bar first lays out or its title bar accessories change, at most 3 runs): the gate
// inputs, the hook report, layout call rates, toolbar items, accessories, tabs, safe areas and the title bar tree.
// With `defaults write -g W7SafariVerboseLog -bool YES`, also the title bar z-order and the tab bar lines.
// Never a page title or URL. Split out of W7SafariChrome.m.
#import "W7SafariInternal.h"
#import <QuartzCore/QuartzCore.h>

static CFTimeInterval gStartTime;
void W7SafariDiagnosticsNoteStart(void) { if (!gStartTime) gStartTime = CACurrentMediaTime(); }

static NSString *W7SafariRectString(NSRect r) {
    return [NSString stringWithFormat:@"(%g,%g %gx%g)", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

/// The title bar view tree, at most 6 deep; excluded classes are marked and not descended into.
static void W7SafariTree(NSView *v, NSUInteger depth, NSMutableArray<NSString *> *out) {
    NSString *cls = NSStringFromClass(v.class);
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    BOOL excluded = W7SafariIsExcludedClassName(cls);
    [out addObject:[NSString stringWithFormat:@"%@%@ %@%@%@", pad, cls, W7SafariRectString(v.frame), v.isHidden ? @" hidden" : @"",
                    excluded ? @" EXCLUDED" : @""]];
    if (excluded || [cls hasPrefix:@"W7"] || depth >= 6) return;
    for (NSView *sub in v.subviews) W7SafariTree(sub, depth + 1, out);
}

/// os_log truncates long messages: one entry per ~800 characters.
static void W7SafariLogLines(NSString *title, NSArray<NSString *> *lines) {
    NSMutableString *chunk = [NSMutableString string];
    NSUInteger part = 1;
    for (NSString *line in lines) {
        if (chunk.length && chunk.length + line.length > 800) {
            os_log(W7Log(), "Safari chrome %{public}@ [%lu]: %{public}@", title, (unsigned long)part++, chunk);
            [chunk setString:@""];
        }
        [chunk appendFormat:@"%@%@", chunk.length ? @" | " : @"", line];
    }
    if (chunk.length) os_log(W7Log(), "Safari chrome %{public}@ [%lu]: %{public}@", title, (unsigned long)part, chunk);
}

static void W7SafariCollectSplitViews(NSView *v, NSUInteger depth, NSMutableArray<NSString *> *out) {
    for (NSView *sub in v.subviews) {
        if ([sub isKindOfClass:NSSplitView.class])
            [out addObject:[NSString stringWithFormat:@"%@ safeArea=%@", NSStringFromClass(sub.class), W7SafariInsetsString(sub.safeAreaInsets)]];
        if (depth < 3) W7SafariCollectSplitViews(sub, depth + 1, out);
    }
}

/// `defaults write -g W7SafariVerboseLog -bool YES`: investigation detail (title bar z-order, tab bar lines), off by
/// default. Read once.
static BOOL W7SafariVerboseLog(void) {
    static BOOL verbose;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { verbose = [NSUserDefaults.standardUserDefaults boolForKey:@"W7SafariVerboseLog"]; }
        @catch (NSException *e) { verbose = NO; }
    });
    return verbose;
}

/// A value read through a checked method, or "?" when it could not be read.
static id W7SafariKnown(BOOL known, id value) { return known ? value : @"?"; }

static void W7SafariLogDiagnostics(NSWindow *w) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    id c = W7SafariControllerForWindow(w);
    BOOL isPrivate = NO, popup = NO, standalone = NO;
    unsigned long long mode = 0;
    NSInteger style = 0;
    BOOL pk = W7SafariReadBool(c, W7SafariSel("isPrivate"), &isPrivate);
    BOOL mk = W7SafariReadUInt64(c, W7SafariSel("browsingMode"), &mode);
    BOOL ok = W7SafariReadBool(c, W7SafariSel("isPopupWindow"), &popup);
    BOOL sk = W7SafariReadBool(c, W7SafariSel("showsStandaloneUnifiedTabBar"), &standalone);
    BOOL lk = W7SafariReadInteger(c, W7SafariSel("unifiedTabBarLayoutStyle"), &style);
    [lines addObject:[NSString stringWithFormat:@"window %@ controller %@ isPrivate=%@ browsingMode=%@ isPopupWindow=%@ "
                      @"showsStandaloneUnifiedTabBar=%@ unifiedTabBarLayoutStyle=%@ toolbar=%@ themed=%d",
                      NSStringFromClass(w.class), c ? NSStringFromClass([c class]) : @"nil",
                      W7SafariKnown(pk, @(isPrivate)), W7SafariKnown(mk, @(mode)), W7SafariKnown(ok, @(popup)),
                      W7SafariKnown(sk, @(standalone)), W7SafariKnown(lk, @(style)), w.toolbar.identifier ?: @"nil", W7SafariWindowIsThemed(w)]];
    [lines addObjectsFromArray:W7SafariHookReport()];
    CFTimeInterval elapsed = MAX(1, CACurrentMediaTime() - gStartTime);
    W7SafariHookCounts counts = W7SafariHookCallCounts();
    // Re-hides: Safari showed a tab bar backdrop again and hook b hid it once more; re-zeros: Safari gave a tab face an
    // alpha again and hook c zeroed it once more (a ping-pong with Safari would show in either).
    [lines addObject:[NSString stringWithFormat:@"calls/s: tab bar layout %.1f, tab button layout %.1f, tab background %.1f, "
                                                @"re-hides %.1f, re-zeros %.1f",
                      counts.tabBarLayout / elapsed, counts.tabButtonLayout / elapsed, counts.tabButtonBackground / elapsed,
                      counts.rehides / elapsed, W7SafariFacsimileRezeroCount() / elapsed]];
    for (NSToolbarItem *item in w.toolbar.items) {
        NSView *v = item.view;
        BOOL bordered = [item respondsToSelector:@selector(isBordered)] && item.isBordered;
        [lines addObject:[NSString stringWithFormat:@"item %@ view=%@ frame=%@ bordered=%d", item.itemIdentifier,
                          v ? NSStringFromClass(v.class) : @"nil", v ? W7SafariRectString(v.frame) : @"-", bordered]];
    }
    for (NSTitlebarAccessoryViewController *vc in w.titlebarAccessoryViewControllers) {
        NSView *v = vc.isViewLoaded ? vc.view : nil;
        [lines addObject:[NSString stringWithFormat:@"accessory %@ attribute=%ld view=%@ frame=%@", NSStringFromClass(vc.class),
                          (long)vc.layoutAttribute, v ? NSStringFromClass(v.class) : @"nil", v ? W7SafariRectString(v.frame) : @"-"]];
    }
    NSView *tabBar = W7SafariTabBarView(w) ?: W7SafariIvarView(c, "_separateUnifiedTabBar");
    id buttons = W7SafariIvar(tabBar, "_visibleTabBarButtons");
    if ([buttons conformsToProtocol:@protocol(NSFastEnumeration)]) {
        for (NSView *b in buttons) {
            if (![b isKindOfClass:NSView.class]) continue;
            NSInteger state = 0;
            BOOL sknown = W7SafariReadInteger(b, W7SafariSel("state"), &state);
            NSMutableArray *faces = [NSMutableArray array];   // each face's alpha (0 under the facsimile)
            for (NSString *name in @[ @"_backgroundView", @"_visualEffectBackground", @"_visualEffectBackgroundHighlight",
                                      @"_contentGlassView", @"_contentView" ]) {
                NSView *v = W7SafariIvarView(b, name.UTF8String);
                if (v) [faces addObject:[NSString stringWithFormat:@"%@%@ %g", name, v.isHidden ? @"(hidden)" : @"", v.alphaValue]];
            }
            NSTextField *title = (NSTextField *)W7SafariIvarView(b, "_titleTextField");
            NSView *icon = W7SafariIvarView(b, "_iconImageView");
            // Never the title's text: page titles are browsing history.
            NSString *titleInfo = [title isKindOfClass:NSTextField.class]
                ? [NSString stringWithFormat:@"color=%@ hidden=%d alpha=%g appearance=%@", title.textColor,
                   title.isHiddenOrHasHiddenAncestor, title.alphaValue, title.effectiveAppearance.name]
                : @"nil";
            [lines addObject:[NSString stringWithFormat:@"tab %@ inWindow=%@ hidden=%d alpha=%g opacity=%g unifiedField=%@ state=%@ "
                                                        @"facsimile=%d faces=[%@] title=%@ icon hidden=%@",
                              W7SafariRectString(b.frame), W7SafariRectString([b convertRect:b.bounds toView:nil]),
                              b.isHiddenOrHasHiddenAncestor, b.alphaValue, b.layer ? b.layer.opacity : -1.0,
                              W7SafariIvar(b, "_unifiedField") ? @"set" : @"nil", W7SafariKnown(sknown, @(state)),
                              W7SafariFacsimileIsStyled(b), [faces componentsJoinedByString:@", "], titleInfo,
                              icon ? @(icon.isHiddenOrHasHiddenAncestor) : @"nil"]];
        }
        if (W7SafariVerboseLog()) {
            // Who is drawn over whom in the title bar view: the Aero bar should be first (lowest), the accessories after.
            NSView *titlebar = W7SafariTitlebarView(w);
            NSView *holder = tabBar;
            while (holder && holder.superview != titlebar) holder = holder.superview;
            NSMutableArray<NSString *> *order = [NSMutableArray array];
            for (NSView *v in titlebar.subviews)
                [order addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(v.class), v == holder ? @"(tab bar)" : @""]];
            [lines addObject:[NSString stringWithFormat:@"titlebar z-order (back to front): %@%@", [order componentsJoinedByString:@", "],
                              holder ? @"" : @" — the tab bar is not under the title bar view"]];
        }
        [lines addObject:W7SafariIETabLayoutDiagnostics(tabBar)];
    } else {
        [lines addObject:@"no visible tab bar (Safari hides it with one tab unless \"Always show tab bar\" is on)"];
    }
    [lines addObjectsFromArray:W7SafariFacsimileDiagnostics(w)];
    NSView *content = w.contentView;
    [lines addObject:[NSString stringWithFormat:@"content safeArea=%@ additional=%@ statusBar=%d", W7SafariInsetsString(content.safeAreaInsets),
                      W7SafariInsetsString(content.additionalSafeAreaInsets), W7SafariStatusBarForWindow(w) != nil]];
    W7SafariCollectSplitViews(content, 1, lines);
    W7SafariLogLines(@"diagnostics", lines);
    NSMutableArray<NSString *> *tree = [NSMutableArray array];
    NSView *titlebar = W7SafariTitlebarView(w);
    if (titlebar) W7SafariTree(titlebar, 0, tree);
    W7SafariLogLines(@"titlebar tree", tree);
    static BOOL dumped;   // The tab bar subtree and its separator ivars, once per process, verbose only
    if (W7SafariVerboseLog() && !dumped && [tabBar isKindOfClass:NSView.class]) {
        dumped = YES;
        W7SafariLogLines(@"tab bar dump", W7SafariTabBarDump(tabBar));
    }
}

#pragma mark - The verbose tab bar dump

enum { kDumpMaxDepth = 14, kDumpMaxViews = 120 };

/// "ivar" / "ivar[]" for each separator-class view reachable from the object ivars of `obj` (a view, or a collection
/// of them), into `holders` (view → the holders' names). One-time diagnostics: allocation is fine here.
static void W7SafariNoteSeparatorHolders(id obj, NSString *suffix, NSMapTable<NSView *, NSMutableString *> *holders) {
    void (^note)(id, NSString *) = ^(id v, NSString *name) {
        if (![v isKindOfClass:NSView.class] || !strcasestr(class_getName(object_getClass(v)), "separator")) return;
        NSMutableString *s = [holders objectForKey:v];
        if (!s) { s = [NSMutableString string]; [holders setObject:s forKey:v]; }
        [s appendFormat:@"%@%@", s.length ? @", " : @"", name];
    };
    for (Class c = object_getClass(obj); c && c != NSView.class && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            NSString *name = [NSString stringWithFormat:@"%s%@", ivar_getName(ivars[i]), suffix];
            NSString *each = [NSString stringWithFormat:@"%s[]%@", ivar_getName(ivars[i]), suffix];
            id value = object_getIvar(obj, ivars[i]);
            if ([value isKindOfClass:NSView.class]) note(value, name);
            else if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSSet.class]) { for (id v in value) note(v, each); }
            else if ([value isKindOfClass:NSDictionary.class]) { for (id k in value) note(((NSDictionary *)value)[k], each); }
            else if ([value isKindOfClass:NSMapTable.class]) { for (id k in value) note([(NSMapTable *)value objectForKey:k], each); }
        }
        free(ivars);
    }
}

static void W7SafariDumpSubtree(NSView *v, NSUInteger depth, NSMapTable<NSView *, NSMutableString *> *holders,
                                NSMutableArray<NSString *> *out, NSInteger *budget) {
    if (--(*budget) < 0) return;
    const char *cname = class_getName(object_getClass(v));
    NSString *cls = @(cname);
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    BOOL excluded = W7SafariIsExcludedCName(cname);
    CALayer *layer = v.layer;
    BOOL bg = layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) > 0;
    NSString *held = [holders objectForKey:v];
    [out addObject:[NSString stringWithFormat:@"%@%@ %@ alpha=%g%@%@%@%@%@%@", pad, cls, W7SafariRectString(v.frame), v.alphaValue,
                    v.isHidden ? @" hidden" : @"", bg ? [NSString stringWithFormat:@" layer-bg(a=%.2f)", CGColorGetAlpha(layer.backgroundColor)] : @"",
                    layer.borderWidth > 0 ? [NSString stringWithFormat:@" layer-border=%g", layer.borderWidth] : @"",
                    strcasestr(cname, "separator") ? (held ? [NSString stringWithFormat:@" held by %@", held] : @" held by (no ivar found)") : @"",
                    excluded ? @" EXCLUDED" : @"", [cls hasPrefix:@"W7"] ? @" (ours)" : @""]];
    if (excluded || [cls hasPrefix:@"W7"] || depth >= kDumpMaxDepth) return;
    for (NSView *sub in v.subviews) W7SafariDumpSubtree(sub, depth + 1, holders, out, budget);
}

/// The separator / divider / line ivars of `cls`'s chain: name, type and (read from `instance`) the value's class.
static void W7SafariDumpIvars(Class cls, id instance, NSMutableArray<NSString *> *out) {
    static const char *const words[] = { "separator", "divider", "line" };
    for (Class c = cls; c && c != NSView.class && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]), *type = ivar_getTypeEncoding(ivars[i]);
            if (!name || !type) continue;
            BOOL match = NO;
            for (size_t k = 0; k < sizeof words / sizeof *words && !match; k++) match = strcasestr(name, words[k]) != NULL;
            if (!match) continue;
            id value = type[0] == '@' && instance ? object_getIvar(instance, ivars[i]) : nil;
            [out addObject:[NSString stringWithFormat:@"%s ivar %s (%s): %@", class_getName(c), name, type,
                            type[0] != '@' ? @"(not an object)" : value ? NSStringFromClass([value class]) : @"nil"]];
        }
        free(ivars);
    }
}

#pragma mark - Hover geometry investigation

// Safari decides which tab is hovered from its own layout geometry, not from the buttons' frames after the IE7 pass
// (live: the × shows on the tab whose SAFARI frame is under the pointer). What is needed next: the names of the
// methods (hover, highlight, mouse, point, track, closeButton, visible, under, location, hit) and the geometry ivars
// (name and type encoding) of the tab bar and tab button classes, and every tracking area in play. Names only: no
// values, no text.
static const char *const kHoverMethodWords[] = { "hover", "highlight", "mouse", "point", "track", "closeButton", "visible", "under", "location", "hit" };
static const char *const kHoverIvarWords[] = { "frame", "rect", "layout", "hover", "highlight", "track", "mouse", "point", "button" };
enum { kDumpMaxMethodsPerClass = 200 };

static BOOL W7SafariNameHasAny(const char *name, const char *const *words, size_t count) {
    for (size_t k = 0; k < count; k++) if (strcasestr(name, words[k])) return YES;
    return NO;
}

/// One line per class of `cls`'s chain up to NSView: its own instance method names containing one of the words
/// (class_copyMethodList: the class's own methods, not inherited ones), sorted, at most 200.
static void W7SafariDumpMethodNames(Class cls, NSMutableArray<NSString *> *out) {
    for (Class c = cls; c && c != NSView.class && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        BOOL capped = NO;
        for (unsigned int i = 0; i < count; i++) {
            const char *name = sel_getName(method_getName(methods[i]));
            if (!name || !W7SafariNameHasAny(name, kHoverMethodWords, sizeof kHoverMethodWords / sizeof *kHoverMethodWords)) continue;
            if (names.count >= kDumpMaxMethodsPerClass) { capped = YES; break; }
            [names addObject:@(name)];
        }
        free(methods);
        [names sortUsingSelector:@selector(compare:)];
        [out addObject:[NSString stringWithFormat:@"methods of %s (hover/highlight/mouse/point/track/closeButton/visible/under/location/hit): %@%@",
                        class_getName(c), names.count ? [names componentsJoinedByString:@","] : @"(none)", capped ? @" (capped at 200)" : @""]];
    }
}

/// The ivars of `cls`'s chain whose name contains frame, rect, layout, hover, highlight, track, mouse, point or button:
/// name and type encoding only.
static void W7SafariDumpGeometryIvars(Class cls, NSMutableArray<NSString *> *out) {
    for (Class c = cls; c && c != NSView.class && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]), *type = ivar_getTypeEncoding(ivars[i]);
            if (!name || !W7SafariNameHasAny(name, kHoverIvarWords, sizeof kHoverIvarWords / sizeof *kHoverIvarWords)) continue;
            [out addObject:[NSString stringWithFormat:@"%s geometry ivar %s (%s)", class_getName(c), name, type ?: "?"]];
        }
        free(ivars);
    }
}

static NSString *W7SafariTrackingOptionsString(NSTrackingAreaOptions o) {
    static const struct { NSTrackingAreaOptions flag; const char *name; } flags[] = {
        { NSTrackingMouseEnteredAndExited, "enteredAndExited" }, { NSTrackingMouseMoved, "mouseMoved" }, { NSTrackingCursorUpdate, "cursorUpdate" },
        { NSTrackingActiveWhenFirstResponder, "activeWhenFirstResponder" }, { NSTrackingActiveInKeyWindow, "activeInKeyWindow" },
        { NSTrackingActiveInActiveApp, "activeInActiveApp" }, { NSTrackingActiveAlways, "activeAlways" }, { NSTrackingAssumeInside, "assumeInside" },
        { NSTrackingInVisibleRect, "inVisibleRect" }, { NSTrackingEnabledDuringMouseDrag, "enabledDuringMouseDrag" },
    };
    NSMutableString *s = [NSMutableString stringWithFormat:@"0x%lx", (unsigned long)o];
    for (size_t i = 0; i < sizeof flags / sizeof *flags; i++) if (o & flags[i].flag) [s appendFormat:@" %s", flags[i].name];
    return s;
}

/// `view`'s tracking areas: rect (the view's coordinates), options and the owner's class; "none" when it has none.
static void W7SafariDumpTrackingAreas(NSView *view, NSString *label, NSMutableArray<NSString *> *out) {
    if (![view isKindOfClass:NSView.class]) return;
    const char *cls = class_getName(object_getClass(view));
    NSArray<NSTrackingArea *> *areas = view.trackingAreas;
    if (!areas.count) { [out addObject:[NSString stringWithFormat:@"tracking areas of %@ (%s): none", label, cls]]; return; }
    for (NSTrackingArea *a in areas)
        [out addObject:[NSString stringWithFormat:@"tracking area of %@ (%s): rect %@ options %@ owner %s", label, cls, W7SafariRectString(a.rect),
                        W7SafariTrackingOptionsString(a.options), a.owner ? class_getName(object_getClass(a.owner)) : "nil"]];
}

NSArray<NSString *> *W7SafariTabBarDump(NSView *tabBar) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @try {
        if (![tabBar isKindOfClass:NSView.class]) return lines;
        NSMapTable<NSView *, NSMutableString *> *holders = [NSMapTable weakToStrongObjectsMapTable];
        W7SafariNoteSeparatorHolders(tabBar, @"", holders);
        id buttons = W7SafariIvar(tabBar, "_visibleTabBarButtons");
        NSView *firstButton = nil;
        if ([buttons conformsToProtocol:@protocol(NSFastEnumeration)])
            for (id b in buttons) if ([b isKindOfClass:NSView.class]) {
                if (!firstButton) firstButton = b;
                W7SafariNoteSeparatorHolders(b, @" (of a tab button)", holders);
            }
        NSInteger budget = kDumpMaxViews;
        W7SafariDumpSubtree(tabBar, 0, holders, lines, &budget);
        if (budget < 0) [lines addObject:[NSString stringWithFormat:@"(stopped at %d views)", kDumpMaxViews]];
        W7SafariDumpIvars(object_getClass(tabBar), tabBar, lines);
        Class buttonClass = firstButton ? object_getClass(firstButton) : objc_getClass("UnifiedTabBarButton");   // no visible button: the class alone
        if (firstButton) W7SafariDumpIvars(buttonClass, firstButton, lines);
        else if (buttonClass) W7SafariDumpIvars(buttonClass, nil, lines);
        // The hover geometry investigation (names only).
        W7SafariDumpMethodNames(object_getClass(tabBar), lines);
        if (buttonClass) W7SafariDumpMethodNames(buttonClass, lines);
        W7SafariDumpGeometryIvars(object_getClass(tabBar), lines);
        W7SafariDumpTrackingAreas(tabBar, @"the tab bar", lines);
        NSView *scroll = W7SafariIvarView(tabBar, "_scrollView");
        if (scroll) {
            W7SafariDumpTrackingAreas(scroll, @"the tab scroll view", lines);
            if ([scroll isKindOfClass:NSScrollView.class]) W7SafariDumpTrackingAreas(((NSScrollView *)scroll).documentView, @"the scroll document view", lines);
        }
        NSInteger n = 0;
        if ([buttons conformsToProtocol:@protocol(NSFastEnumeration)])
            for (id b in buttons) if ([b isKindOfClass:NSView.class]) W7SafariDumpTrackingAreas(b, [NSString stringWithFormat:@"tab button %ld", (long)n++], lines);
    } @catch (NSException *e) { [lines addObject:[NSString stringWithFormat:@"tab bar dump failed: %@", e.reason]]; }
    return lines;
}

/// Runs the window's diagnostics a second from now (when it is still themed), counting the run.
void W7SafariScheduleDiagnostics(NSWindow *w, W7SafariWindowState *st) {
    st.diagnosticsRuns++;
    __weak NSWindow *weakWindow = w;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @try {
            NSWindow *win = weakWindow;
            if (!win || !W7SafariWindowIsThemed(win)) return;
            W7SafariState(win, YES).lastAccessoryCount = win.titlebarAccessoryViewControllers.count;
            W7SafariLogDiagnostics(win);
        } @catch (NSException *e) { os_log_error(W7Log(), "Safari diagnostics failed: %{public}@", e.reason ?: @"unknown"); }
    });
}

/// The diagnostics again when the accessory count moved since the last run (or `firstTabBar`), within the cap.
void W7SafariMaybeRerunDiagnostics(NSWindow *w, W7SafariWindowState *st, BOOL firstTabBar) {
    if (!st.themed || st.diagnosticsRuns == 0) return;   // the first run is scheduled when the window is themed
    NSUInteger count = w.titlebarAccessoryViewControllers.count;
    BOOL changed = st.lastAccessoryCount != NSNotFound && count != st.lastAccessoryCount;
    if (!W7SafariShouldRerunDiagnostics(st.diagnosticsRuns, changed, firstTabBar)) return;
    st.lastAccessoryCount = count;   // a later change counts from here, not from the pending run
    W7SafariScheduleDiagnostics(w, st);
}

/// "under NSTitlebarView / an accessory / the toolbar" and the class names from the tab bar up to the window.
static NSString *W7SafariSuperviewChain(NSView *tabBar, NSWindow *w) {
    NSView *titlebar = W7SafariTitlebarView(w);
    NSMutableSet<NSView *> *accessories = [NSMutableSet set];
    for (NSTitlebarAccessoryViewController *vc in w.titlebarAccessoryViewControllers)
        if (vc.isViewLoaded) [accessories addObject:vc.view];
    BOOL underTitlebar = NO, underAccessory = NO, underToolbar = NO;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSView *v = tabBar.superview; v; v = v.superview) {
        const char *cls = class_getName(object_getClass(v));
        [names addObject:@(cls)];
        if (v == titlebar) underTitlebar = YES;
        if ([accessories containsObject:v]) underAccessory = YES;
        if ([@(cls) hasSuffix:@"ToolbarView"]) underToolbar = YES;
    }
    if ([accessories containsObject:tabBar]) underAccessory = YES;   // the accessory's own view
    return [NSString stringWithFormat:@"underTitlebarView=%d underAccessory=%d underToolbar=%d chain=%@", underTitlebar,
            underAccessory, underToolbar, [names componentsJoinedByString:@" < "]];
}

void W7SafariObserveTabBarLayout(NSView *tabBar, NSWindow *w) {
    @try {
        W7SafariWindowState *st = W7SafariState(w, NO);
        if (!st || st.privateWindow || !tabBar) return;
        BOOL first = !st.sawTabBar;
        st.sawTabBar = YES;
        CFTimeInterval now = CACurrentMediaTime();
        if (!first && !W7SafariThrottleAllows(now, st.lastTabBarLog, 1)) return;   // nothing allocated on the fast path
        st.lastTabBarLog = now;
        W7SafariScheduleMenuStripCheck(w, st);   // at most once a second, after this layout pass
        if (W7SafariVerboseLog() && W7SafariTabBarLogAllows(st.tabBarLines, now, -1)) {   // investigation detail
            st.tabBarLines++;
            NSRect f = tabBar.frame, inWindow = [tabBar convertRect:tabBar.bounds toView:nil];
            id buttons = W7SafariIvar(tabBar, "_visibleTabBarButtons");
            NSUInteger count = [buttons respondsToSelector:@selector(count)] ? [buttons count] : 0;
            // No window title: page titles are browsing history.
            os_log(W7Log(), "Safari chrome tab bar%{public}s [%ld/%ld]: frame (%g,%g %gx%g) in window (%g,%g %gx%g) hidden=%d "
                            "effectiveHidden=%d alpha=%g buttons=%lu themed=%d %{public}@",
                   first ? " (first layout)" : "", (long)st.tabBarLines, (long)10, f.origin.x, f.origin.y, f.size.width,
                   f.size.height, inWindow.origin.x, inWindow.origin.y, inWindow.size.width, inWindow.size.height, tabBar.isHidden,
                   tabBar.isHiddenOrHasHiddenAncestor, tabBar.alphaValue, (unsigned long)count, st.themed,
                   W7SafariSuperviewChain(tabBar, w));
        }
        W7SafariMaybeRerunDiagnostics(w, st, first);
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari tab bar log failed: %{public}@", e.reason ?: @"unknown"); }
}
