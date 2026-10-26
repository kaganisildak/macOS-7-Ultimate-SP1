// Keeps the Windows 7 navigation pane visible: Finder collapses its sidebar when the toolbar is hidden
// (and a saved window state may hide it too), but Windows 7 Explorer always shows the pane. The
// sidebar is expanded once at adoption and again from the throttled maintenance pass, unless the user
// hid it in that window (a sidebar menu action, a divider drag or a window resize), which is respected
// until the next window. Public API only: NSSplitViewItem first, else the split view's first divider.
#import "W7ExplorerInternal.h"

const NSUInteger W7SidebarMaxForcedExpands = 3;
const NSTimeInterval W7SidebarForcePeriod = 10;
const NSTimeInterval W7SidebarUserActionWindow = 3;
static const CGFloat kSidebarDividerPosition = 200;
static const NSUInteger kMaxViewControllers = 64;

BOOL W7ShouldExpandSidebar(BOOL collapsed, BOOL hiddenByUser, NSUInteger recentForcedExpands) {
    return collapsed && !hiddenByUser && recentForcedExpands < W7SidebarMaxForcedExpands;
}

BOOL W7SidebarCollapseIsUsers(BOOL liveResize, BOOL dividerDrag, NSTimeInterval secondsSinceSidebarAction) {
    // A window narrowed until NSSplitViewController auto-collapses the sidebar is not a hide: the pane
    // comes back once the window is wide enough.
    if (liveResize) return NO;
    return dividerDrag || (secondsSinceSidebarAction >= 0 && secondsSinceSidebarAction <= W7SidebarUserActionWindow);
}

BOOL W7IsSidebarMenuAction(SEL action) {
    return action && [NSStringFromSelector(action) rangeOfString:@"sidebar" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

NSArray<NSMenuItem *> *W7SidebarMenuItems(NSMenu *root) {
    NSMutableArray<NSMenuItem *> *found = [NSMutableArray array];
    NSMutableArray<NSMenu *> *queue = root ? [NSMutableArray arrayWithObject:root] : [NSMutableArray array];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 256) {
        NSMenu *menu = queue.firstObject;
        [queue removeObjectAtIndex:0];
        for (NSMenuItem *item in menu.itemArray) {
            if (W7IsSidebarMenuAction(item.action)) [found addObject:item];
            if (item.submenu) [queue addObject:item.submenu];
        }
    }
    return found;
}

NSSplitViewItem *W7SidebarSplitItem(NSView *sidebar) {
    @try {
        for (NSView *v = sidebar; v; v = v.superview) {
            if (![v isKindOfClass:NSSplitView.class]) continue;
            id delegate = ((NSSplitView *)v).delegate;
            if (![delegate isKindOfClass:NSSplitViewController.class]) continue;
            for (NSSplitViewItem *item in ((NSSplitViewController *)delegate).splitViewItems) {
                NSViewController *vc = item.viewController;
                if (vc.isViewLoaded && [sidebar isDescendantOf:vc.view]) return item;
            }
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer sidebar split item lookup failed: %{public}@", e.reason ?: @"unknown");
    }
    return nil;
}

/// The window's sidebar-behaviour split item, for when no sidebar view was found (a collapsed pane may
/// have left the view tree). Breadth-first over the content view controller and its children.
static NSSplitViewItem *W7SidebarBehaviorItem(NSWindow *window) {
    NSViewController *root = window.contentViewController;
    if (!root) return nil;
    NSMutableArray<NSViewController *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (queue.count && visited++ < kMaxViewControllers) {
        NSViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([vc isKindOfClass:NSSplitViewController.class]) {
            for (NSSplitViewItem *item in ((NSSplitViewController *)vc).splitViewItems)
                if (item.behavior == NSSplitViewItemBehaviorSidebar) return item;
        }
        [queue addObjectsFromArray:vc.childViewControllers];
    }
    return nil;
}

/// The innermost split view whose first pane contains `sidebar` (with at least two panes), or nil.
static NSSplitView *W7SidebarFirstPaneSplit(NSView *sidebar, NSView **outPane) {
    for (NSView *v = sidebar.superview; v; v = v.superview) {
        if (![v isKindOfClass:NSSplitView.class]) continue;
        NSSplitView *split = (NSSplitView *)v;
        NSArray<NSView *> *panes = split.arrangedSubviews.count ? split.arrangedSubviews : split.subviews;
        if (panes.count >= 2 && [sidebar isDescendantOf:panes.firstObject]) {
            *outPane = panes.firstObject;
            return split;
        }
    }
    return nil;
}

/// What hosts the sidebar: its split view item (preferred), else the split view whose first pane holds
/// it, else the window's sidebar-behaviour item. NO when none does.
static BOOL W7FindSidebarHost(NSWindow *window, NSView *sidebar, NSSplitViewItem **outItem,
                              NSSplitView **outSplit, NSView **outPane) {
    *outItem = nil; *outSplit = nil; *outPane = nil;
    if (sidebar) {
        *outItem = W7SidebarSplitItem(sidebar);
        if (*outItem) return YES;
        *outSplit = W7SidebarFirstPaneSplit(sidebar, outPane);
        if (*outSplit) return YES;
    }
    if (window) *outItem = W7SidebarBehaviorItem(window);
    return *outItem != nil;
}

static BOOL W7PaneCollapsed(NSSplitView *split, NSView *pane) {
    CGFloat extent = split.isVertical ? NSWidth(pane.frame) : NSHeight(pane.frame);
    return [split isSubviewCollapsed:pane] || extent < 1;
}

BOOL W7SidebarIsCollapsed(NSWindow *window, NSView *sidebar, BOOL *found) {
    if (found) *found = NO;
    @try {
        NSSplitViewItem *item; NSSplitView *split; NSView *pane;
        if (!W7FindSidebarHost(window, sidebar, &item, &split, &pane)) return NO;
        if (found) *found = YES;
        return item ? item.isCollapsed : W7PaneCollapsed(split, pane);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer sidebar state failed: %{public}@", e.reason ?: @"unknown");
        if (found) *found = NO;
        return NO;
    }
}

W7SidebarExpandResult W7ExpandSidebar(NSWindow *window, NSView *sidebar) {
    @try {
        NSSplitViewItem *item; NSSplitView *split; NSView *pane;
        if (!W7FindSidebarHost(window, sidebar, &item, &split, &pane)) return W7SidebarExpandResultNotFound;
        if (item) {
            if (!item.isCollapsed) return W7SidebarExpandResultAlreadyVisible;
            [NSAnimationContext beginGrouping];
            NSAnimationContext.currentContext.duration = 0;
            NSAnimationContext.currentContext.allowsImplicitAnimation = NO;
            item.collapsed = NO;
            [NSAnimationContext endGrouping];
            return W7SidebarExpandResultSplitItem;
        }
        if (!W7PaneCollapsed(split, pane)) return W7SidebarExpandResultAlreadyVisible;
        [split setPosition:kSidebarDividerPosition ofDividerAtIndex:0];
        return W7SidebarExpandResultDivider;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer sidebar expand failed: %{public}@", e.reason ?: @"unknown");
        return W7SidebarExpandResultNotFound;
    }
}

@implementation W7ExplorerSidebarKeeper {
    __weak NSWindow *_window;
    __weak NSView *_sidebar;
    __weak NSSplitView *_observedSplit;
    BOOL _checked, _hiddenByUser, _loggedMissing, _loggedLimit;
    CFAbsoluteTime _lastSidebarAction;   // 0: none yet
    NSMutableArray<NSNumber *> *_forcedTimes;
    // The split view's width when a window resize collapsed the sidebar (0: it didn't). The pane is
    // re-opened, outside the rate limit, only once the split view is wider than that.
    CGFloat _resizeCollapseExtent;
    BOOL _loggedNarrow;
}

- (instancetype)initWithWindow:(NSWindow *)window {
    if ((self = [super init])) {
        _window = window;
        _forcedTimes = [NSMutableArray array];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(w7MenuWillSendAction:)
                                                   name:NSMenuWillSendActionNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// View ▸ Hide/Show Sidebar (menu or its shortcut), aimed at this window: a collapse soon after is the user's.
- (void)w7MenuWillSendAction:(NSNotification *)n {
    @try {
        NSMenuItem *item = n.userInfo[@"MenuItem"];
        if (![item isKindOfClass:NSMenuItem.class] || !W7IsSidebarMenuAction(item.action)) return;
        NSWindow *main = NSApp.mainWindow;
        if (main && main != _window) return;
        _lastSidebarAction = CFAbsoluteTimeGetCurrent();
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer sidebar menu action failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)w7NoteCollapseWithDividerDrag:(BOOL)dividerDrag {
    NSWindow *w = _window;
    if (_hiddenByUser || !w) return;
    NSTimeInterval since = _lastSidebarAction > 0 ? CFAbsoluteTimeGetCurrent() - _lastSidebarAction : -1;
    if (!W7SidebarCollapseIsUsers(w.inLiveResize, dividerDrag, since)) return;
    _hiddenByUser = YES;
    os_log(W7Log(), "Explorer: sidebar hidden by the user; left hidden in this window");
}

- (CGFloat)w7SplitExtent {
    NSSplitView *split = _observedSplit;
    return split ? (split.isVertical ? NSWidth(split.bounds) : NSHeight(split.bounds)) : 0;
}

/// A collapse during a live window resize: remembered so the pane returns once the window is wider.
- (void)w7NoteResizeCollapse {
    if (_resizeCollapseExtent > 0 || _hiddenByUser) return;
    _resizeCollapseExtent = MAX(1, [self w7SplitExtent]);
    _loggedNarrow = NO;
}

/// Catches a collapse as it happens (a divider drag or window resize is over by the next maintenance
/// pass): a divider drag is the user's; a window resize only narrowed the window.
- (void)w7SplitDidResize:(NSNotification *)n {
    @try {
        NSWindow *w = _window;
        if (!w || _hiddenByUser || !_checked) return;
        if (!W7SidebarIsCollapsed(w, _sidebar, NULL)) return;
        if (w.inLiveResize) { [self w7NoteResizeCollapse]; return; }
        NSEvent *e = NSApp.currentEvent;
        [self w7NoteCollapseWithDividerDrag:e.type == NSEventTypeLeftMouseDragged && e.window == w];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer sidebar resize handler failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)w7ObserveSplitFor:(NSView *)sidebar {
    NSSplitViewItem *item; NSSplitView *split; NSView *pane;
    if (!W7FindSidebarHost(_window, sidebar, &item, &split, &pane)) return;
    if (item) {
        id svc = nil;
        for (NSView *v = item.viewController.isViewLoaded ? item.viewController.view : nil; v && !svc; v = v.superview)
            if ([v isKindOfClass:NSSplitView.class] && [((NSSplitView *)v).delegate isKindOfClass:NSSplitViewController.class]) svc = v;
        split = svc;
    }
    if (!split || split == _observedSplit) return;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    NSSplitView *old = _observedSplit;
    if (old) [nc removeObserver:self name:NSSplitViewDidResizeSubviewsNotification object:old];
    _observedSplit = split;
    [nc addObserver:self selector:@selector(w7SplitDidResize:) name:NSSplitViewDidResizeSubviewsNotification object:split];
}

- (void)checkSidebar:(NSView *)sidebar {
    @try {
        NSWindow *w = _window;
        if (!w) return;
        _sidebar = sidebar;
        BOOL first = !_checked;
        _checked = YES;
        BOOL found = NO;
        BOOL collapsed = W7SidebarIsCollapsed(w, sidebar, &found);
        if (!found) {
            if (!_loggedMissing) {
                _loggedMissing = YES;
                os_log(W7Log(), "Explorer: sidebar not found (sidebar view %{public}@); navigation pane visibility not managed",
                       sidebar ? NSStringFromClass(sidebar.class) : @"none");
            }
            return;
        }
        [self w7ObserveSplitFor:sidebar];
        if (first) [self w7LogSidebarMenuItems];
        if (!collapsed) {
            _resizeCollapseExtent = 0;
        } else if (w.inLiveResize) {   // never forced open mid-resize
            [self w7NoteResizeCollapse];
            return;
        } else if (_resizeCollapseExtent > 0 && !_hiddenByUser) {
            [self w7ExpandAfterResize:sidebar];
            return;
        }
        // At adoption a collapsed sidebar is Finder's doing (toolbar hidden, saved state), never the user's.
        if (collapsed && !first) [self w7NoteCollapseWithDividerDrag:NO];
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSIndexSet *old = [_forcedTimes indexesOfObjectsPassingTest:^BOOL(NSNumber *t, __unused NSUInteger i, __unused BOOL *stop) {
            return now - t.doubleValue > W7SidebarForcePeriod;
        }];
        [_forcedTimes removeObjectsAtIndexes:old];
        if (!W7ShouldExpandSidebar(collapsed, _hiddenByUser, _forcedTimes.count)) {
            if (first && !collapsed) {
                os_log(W7Log(), "Explorer: sidebar already visible");
            } else if (collapsed && !_hiddenByUser && !_loggedLimit) {
                _loggedLimit = YES;
                os_log(W7Log(), "Explorer: sidebar keeps collapsing; not forced open again for %.0f s", W7SidebarForcePeriod);
            }
            return;
        }
        W7SidebarExpandResult r = W7ExpandSidebar(w, sidebar);
        if (r != W7SidebarExpandResultSplitItem && r != W7SidebarExpandResultDivider) return;
        [_forcedTimes addObject:@(now)];
        _loggedLimit = NO;
        os_log(W7Log(), "Explorer: sidebar expanded (%{public}s)", r == W7SidebarExpandResultSplitItem ? "split item" : "divider");
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer sidebar check failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// After a resize collapse: re-open once the split view is wider than where it collapsed. Each attempt
/// raises the bar to the current width, so a pane that still doesn't fit is retried only on widening.
- (void)w7ExpandAfterResize:(NSView *)sidebar {
    CGFloat extent = [self w7SplitExtent];
    if (extent <= _resizeCollapseExtent) {
        if (!_loggedNarrow) {
            _loggedNarrow = YES;
            os_log(W7Log(), "Explorer: sidebar collapsed by a narrow window (%.0f pt); reopened when wider", extent);
        }
        return;
    }
    _resizeCollapseExtent = extent;
    W7SidebarExpandResult r = W7ExpandSidebar(_window, sidebar);
    if (r != W7SidebarExpandResultSplitItem && r != W7SidebarExpandResultDivider) return;
    // It fits now: later collapses are ordinary again. Still collapsed: retried when wider still.
    if (!W7SidebarIsCollapsed(_window, sidebar, NULL)) _resizeCollapseExtent = 0;
    os_log(W7Log(), "Explorer: sidebar expanded (%{public}s) after the window widened",
           r == W7SidebarExpandResultSplitItem ? "split item" : "divider");
}

/// Once per process, at the first adoption: the sidebar show/hide menu items whose actions count as
/// the user's (so a verbose log can show whether View ▸ Hide Sidebar is recognised).
- (void)w7LogSidebarMenuItems {
    static BOOL logged;
    if (logged) return;
    logged = YES;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSMenuItem *item in W7SidebarMenuItems(NSApp.mainMenu))
        [names addObject:[NSString stringWithFormat:@"%@ \"%@\" key %@ mods 0x%lx", NSStringFromSelector(item.action),
                          item.title ?: @"", item.keyEquivalent ?: @"", (unsigned long)item.keyEquivalentModifierMask]];
    os_log(W7Log(), "Explorer: sidebar menu items matched: %{public}@",
           names.count ? [names componentsJoinedByString:@"; "] : @"none");
}

@end
