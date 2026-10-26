// Internet Explorer-style Safari: IE's tab row layout (the tabs themselves are drawn by the
// facsimile, W7SafariTabFacsimile.m, at these frames). Safari lays its tabs out equal-width across the whole row; IE7's are left-aligned
// and sized to their titles within 120…220 pt, 2 pt apart, the first 8 pt in. The room a title needs is learnt per
// tab from Safari's own button layout: when it truncates the title, the button's width minus the title's is exactly
// the rest (icon, close button, insets), and the tab grows by what the title lacked (up to the cap). After Safari's own tab bar layout
// (hook b's -layout and -_layoutButtonsAnimated:) each visible tab button is re-framed to that row; pinned tabs stay
// where Safari put them and ours start after them. Fail open to Safari's layout: when the tabs would not fit
// (Safari's overflow and scrolling stay), while a tab is dragged, and for good when Safari keeps putting its frames
// back (more than 30 times in a second without the tab bar changing width: a layout fight; retried 10 s later or
// when the tab bar's width changes). Frames are set only when they differ; the tabs are read into fixed stack arrays
// (the command bar allocates only when it changes; per button, one notes object). Kill switch:
// `defaults write -g W7SafariIETabLayoutDisabled -bool YES` (also off with W7SafariHooksDisabled).
// at window restore the first pass finds every title unsized (the fields empty or not yet sized),
// which froze every tab at the floor with "…" titles until the pointer touched a tab. Now such a pass keeps Safari's
// widths (W7SafariIETabLayoutDecide: titlesUnsized), and hook c's refresh (W7SafariNoteTabTitle) asks for a pass again
// when a title's intrinsic width differs from the one the last pass used, coalesced to one per 100 ms per tab bar and
// once per width. The pass after Safari's -_layoutButtonsAnimated: also re-zeroes the tab separators Safari creates
// there (otherwise one showed at Safari's own tab boundary, inside our second tab, until the next -layout).
#import "W7SafariInternal.h"
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - The IE7 tab row (pure)

const W7SafariIETabMetrics W7SafariIETabDefaultMetrics = { 120, 220, 2, 76, 100 };

enum { kMaxTabs = 64 };   // stack arrays: no allocation per pass

BOOL W7SafariIETabLayout(const CGFloat *titleWidths, NSInteger count, CGFloat startX, CGFloat maxX, W7SafariIETabMetrics m,
                         CGFloat *xs, CGFloat *widths) {
    if (count <= 0 || !titleWidths) return count == 0;
    if (count > kMaxTabs) return NO;
    CGFloat natural[kMaxTabs], w[kMaxTabs], sum = 0;
    BOOL atFloor[kMaxTabs];
    for (NSInteger i = 0; i < count; i++) {
        natural[i] = MAX(m.minWidth, MIN(m.maxWidth, ceil(MAX(0, titleWidths[i]) + m.padding)));
        w[i] = natural[i];
        atFloor[i] = NO;
        sum += natural[i];
    }
    CGFloat available = maxX - startX - m.gap * (count - 1);
    if (sum > available + 0.5) {   // IE shrinks every tab in proportion, none below the floor
        CGFloat floorWidth = MIN(m.floorWidth, m.minWidth);
        if (floorWidth * count > available + 0.5) return NO;   // not even at the floor: Safari's layout and scrolling stay
        for (NSInteger pass = 0; pass <= count; pass++) {
            CGFloat fixed = 0, rest = 0;
            for (NSInteger i = 0; i < count; i++) { if (atFloor[i]) fixed += floorWidth; else rest += natural[i]; }
            CGFloat f = rest > 0 ? (available - fixed) / rest : 0;
            BOOL more = NO;
            for (NSInteger i = 0; i < count; i++) {
                if (atFloor[i]) { w[i] = floorWidth; continue; }
                w[i] = floor(natural[i] * f);
                if (w[i] < floorWidth) { atFloor[i] = YES; more = YES; }
            }
            if (!more) break;
        }
    }
    CGFloat x = startX;
    for (NSInteger i = 0; i < count; i++) {
        if (xs) xs[i] = x;
        if (widths) widths[i] = w[i];
        x += w[i] + m.gap;
    }
    return YES;
}

const CFTimeInterval W7SafariIETabRelayoutInterval = 0.1;

W7SafariIETabLayoutResult W7SafariIETabLayoutDecide(const CGFloat *titleWidths, NSInteger count, CGFloat startX, CGFloat maxX,
                                                    W7SafariIETabMetrics m, CGFloat *xs, CGFloat *widths) {
    if (count > 0 && titleWidths) {
        BOOL sized = NO;
        for (NSInteger i = 0; i < count && !sized; i++) sized = titleWidths[i] > 0;
        if (!sized) return W7SafariIETabLayoutTitlesUnsized;   // nothing to size the tabs by yet: Safari's widths for now
    }
    return W7SafariIETabLayout(titleWidths, count, startX, maxX, m, xs, widths) ? W7SafariIETabLayoutApplied : W7SafariIETabLayoutOverflow;
}

#pragma mark - Applying it to Safari's tab bar

static BOOL gTabLayoutEnabled;
void W7SafariIETabLayoutSetEnabled(BOOL enabled) { gTabLayoutEnabled = enabled; }

static const NSInteger kMaxFightsPerSecond = 30, kMaxLayoutLines = 10;
static const CGFloat kFirstTabX = 8;

/// Per tab bar: the layout fight guard, the scroll view frame reserved for Safari's own layout, and what was logged.
@interface W7SafariTabRowState : NSObject
@property (nonatomic) CFTimeInterval fightWindow;
@property (nonatomic) NSInteger fights, loggedCount, lines;
@property (nonatomic) CGFloat lastWidth, backedOffWidth;
@property (nonatomic) CFTimeInterval backedOffAt;
@property (nonatomic) BOOL backedOff, applied, reserving, inSafariLayout, loggedReserve, loggedUnsized, relayoutPending;
@property (nonatomic) CGRect safariScroll, reservedScroll;   // the scroll view's frame in its superview: Safari's, ours
@property (nonatomic) NSInteger passes, deferred, requested, relayouts;   // applied / left to Safari (titles unsized) / asked by titles / asked passes run
@property (nonatomic) CFTimeInterval lastRelayout;             // when the last requested pass ran (the coalescing interval)
@property (nonatomic) NSInteger hoverByFrames, hoverBySafari;  // -_tabBarButtonAtPoint: answered from our frames / by Safari
@property (nonatomic) BOOL updatingHighlight;                  // inside Safari's -_updateHighlightedTabBarButton we asked for
@end
@implementation W7SafariTabRowState
@end

static NSMutableSet<NSValue *> *gHoverHooked;   // classes whose -_tabBarButtonAtPoint: is ours
static BOOL W7SafariHoverHooked(Class cls) { return cls && [gHoverHooked containsObject:[NSValue valueWithPointer:(__bridge const void *)cls]]; }

/// Per tab button (one object, made once): the chrome learnt around its title, the title width the last IE7 pass used
/// (0: unsized), and the width a pass was last asked for (so each width asks once).
@interface W7SafariTabNotes : NSObject
@property (nonatomic) CGFloat padding, usedTitleWidth, requestedTitleWidth;
@end
@implementation W7SafariTabNotes
@end

static const void *kTabRowKey = &kTabRowKey;
static const void *kTabLayoutNotesKey = &kTabLayoutNotesKey;   // on a tab button: its W7SafariTabNotes
static const CGFloat kTitleWidthDropped = -1;   // requestedTitleWidth: the pass asked for could not run; ask again

static W7SafariTabNotes *W7SafariTabNotesOf(NSView *button, BOOL create) {
    W7SafariTabNotes *n = objc_getAssociatedObject(button, kTabLayoutNotesKey);
    if (!n && create) {
        n = [W7SafariTabNotes new];
        objc_setAssociatedObject(button, kTabLayoutNotesKey, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return n;
}

/// The title's intrinsic width as the IE7 pass sizes by it: 0 when there is no field, it is hidden, its string is empty
/// or AppKit gives it no width yet (the empty label of a tab being restored).
static CGFloat W7SafariTabTitleWidth(NSTextField *field) {
    if (![field isKindOfClass:NSTextField.class] || field.isHidden || field.stringValue.length == 0) return 0;
    return MAX(0, field.intrinsicContentSize.width);
}

/// When Safari's layout of `button` (now `width` wide) truncated its title, the rest of the button (icon, close button,
/// insets) is exactly its width minus the title's: remembered for the tab, YES when that changed and the tab can grow.
static BOOL W7SafariLearnTabPadding(NSView *button, CGFloat width, CGFloat maxWidth) {
    NSView *title = W7SafariIvarView(button, "_titleTextField");
    CGFloat shown = title.frame.size.width, needed = title.intrinsicContentSize.width;
    if (!title || title.isHidden || shown <= 0 || shown + 0.5 >= needed || width >= maxWidth - 0.5) return NO;
    CGFloat padding = ceil(button.frame.size.width - shown);
    W7SafariTabNotes *notes = W7SafariTabNotesOf(button, YES);
    if (padding <= 0 || (notes.padding > 0 && fabs(notes.padding - padding) < 0.5)) return NO;
    notes.padding = padding;
    return YES;
}

static void W7SafariTabRowLog(W7SafariTabRowState *s, NSString *(^line)(void)) {
    if (s.lines >= kMaxLayoutLines) return;
    s.lines++;
    os_log(W7Log(), "Safari tabs: %{public}@", line());
}

/// Lets Safari lay its tab buttons out again (its own -_layoutButtonsAnimated: NO, v20@0:8B16, else a layout pass);
/// our hook on it passes straight through meanwhile.
static void W7SafariLetSafariLayOutTabs(NSView *tabBar, W7SafariTabRowState *s) {
    if (s.inSafariLayout) return;
    SEL sel = W7SafariSel("_layoutButtonsAnimated:");
    s.inSafariLayout = YES;
    @try {
        if (W7SafariHasTypes(tabBar, sel, "v20@0:8B16")) ((void (*)(id, SEL, BOOL))objc_msgSend)(tabBar, sel, NO);
        else tabBar.needsLayout = YES;
    } @finally { s.inSafariLayout = NO; }
}

/// Gives the tab scroll view Safari's own frame back and lets Safari lay out again (the kept frame may be stale
/// after a resize while reserved; Safari's own pass sets the right one).
static void W7SafariReleaseScrollView(NSView *tabBar, W7SafariTabRowState *s) {
    if (!s.reserving) return;
    s.reserving = NO;
    NSView *scroll = W7SafariIvarView(tabBar, "_scrollView");
    if (scroll && NSEqualRects(scroll.frame, s.reservedScroll)) scroll.frame = s.safariScroll;
    W7SafariLetSafariLayOutTabs(tabBar, s);
}

/// Backs off for this tab bar (Safari keeps undoing ours); W7SafariMayRetry lifts it 10 s later or on a new width.
static void W7SafariBackOff(NSView *tabBar, W7SafariTabRowState *s) {
    s.backedOff = YES;
    s.backedOffAt = CACurrentMediaTime();
    s.backedOffWidth = tabBar.bounds.size.width;
    s.fights = 0;
}

static BOOL W7SafariMayRetry(NSView *tabBar, W7SafariTabRowState *s) {
    if (!s.backedOff) return YES;
    if (CACurrentMediaTime() - s.backedOffAt < 10 && fabs(tabBar.bounds.size.width - s.backedOffWidth) < 0.5) return NO;
    s.backedOff = NO;
    W7SafariSetCommandBarSuppressed(tabBar, NO);
    return YES;
}

void W7SafariRestoreIETabLayout(NSView *tabBar) {
    @try {
        W7SafariRemoveCommandBar(tabBar);
        W7SafariTabRowState *s = tabBar ? objc_getAssociatedObject(tabBar, kTabRowKey) : nil;
        if (!s) return;
        W7SafariReleaseScrollView(tabBar, s);
        if (!s.applied) return;
        s.applied = NO;
        W7SafariLetSafariLayOutTabs(tabBar, s);
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari tab layout restore failed: %{public}@", e.reason ?: @"unknown"); }
}

/// Counts a pass that had to set frames again although the tab bar kept its width; YES once that happens more than
/// kMaxFightsPerSecond times in a second (Safari keeps undoing ours).
static BOOL W7SafariTabRowFight(NSView *tabBar, W7SafariTabRowState *s) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - s.fightWindow > 1) s.fightWindow = now, s.fights = 0;
    if (fabs(tabBar.bounds.size.width - s.lastWidth) < 0.5) s.fights++;
    s.lastWidth = tabBar.bounds.size.width;
    return s.fights > kMaxFightsPerSecond;
}

/// More tabs than fit even at the floor: Safari lays them out (and scrolls them) inside the room left between our
/// group and command bar. The tab scroll view is narrowed to that room (Safari's frame kept for the restore) and
/// Safari's layout runs once more inside it; if Safari keeps widening it, our controls hide instead of overlapping.
static void W7SafariFallBackToSafari(NSView *tabBar, W7SafariTabRowState *s, NSInteger n, CGFloat startX, CGFloat maxX) {
    if (s.applied) { s.applied = NO; W7SafariLetSafariLayOutTabs(tabBar, s); }
    NSView *scroll = W7SafariIvarView(tabBar, "_scrollView");
    if (!scroll.superview) return;
    CGRect inBar = [tabBar convertRect:s.safariScroll fromView:scroll.superview];
    CGRect room = CGRectMake(startX, inBar.origin.y, MAX(0, maxX - startX), inBar.size.height);
    CGRect reserved = [scroll.superview convertRect:room fromView:tabBar];
    if (!s.loggedReserve) {
        s.loggedReserve = YES;
        W7SafariTabRowLog(s, ^{ return [NSString stringWithFormat:@"%ld tabs do not fit at the 100 pt floor: Safari's layout inside the reserved "
                                        @"room x %g…%g (its scroll view %@)", (long)n, CGRectGetMinX(room), CGRectGetMaxX(room),
                                        NSStringFromRect(inBar)]; });
    }
    if (NSEqualRects(scroll.frame, reserved)) return;
    if (s.reserving && W7SafariTabRowFight(tabBar, s)) {   // Safari widens it every pass: hide ours, never overlap
        W7SafariBackOff(tabBar, s);
        W7SafariReleaseScrollView(tabBar, s);
        W7SafariSetCommandBarSuppressed(tabBar, YES);
        os_log(W7Log(), "Safari tabs: reserved room backed off (Safari widened its tab scroll view %ld times in a second); "
                        "the Favorites group and command bar are hidden in this window", (long)s.fights);
        return;
    }
    s.reserving = YES;
    s.reservedScroll = reserved;
    scroll.frame = reserved;
    W7SafariLetSafariLayOutTabs(tabBar, s);   // Safari's own layout, now inside the room
}

/// Safari's own -_updateHighlightedTabBarButton (when it exists as v16@0:8) once after a pass moved buttons: with
/// -_tabBarButtonAtPoint: answering from our frames, a pointer already inside the bar gets the right tab
/// at once. Never re-entrantly, never from inside the layout Safari runs for us.
static void W7SafariRefreshHoveredTab(NSView *tabBar, W7SafariTabRowState *s) {
    if (s.updatingHighlight || s.inSafariLayout) return;
    SEL sel = W7SafariSel("_updateHighlightedTabBarButton");
    if (!W7SafariHasTypes(tabBar, sel, "v16@0:8")) return;
    s.updatingHighlight = YES;
    @try { ((void (*)(id, SEL))objc_msgSend)(tabBar, sel); }
    @finally { s.updatingHighlight = NO; }
}

void W7SafariApplyIETabLayout(NSView *tabBar) {
    @try {
        if (!gTabLayoutEnabled || !tabBar) return;
        W7SafariTabRowState *s = objc_getAssociatedObject(tabBar, kTabRowKey);
        if (!s) {
            s = [W7SafariTabRowState new];
            s.loggedCount = -1;
            objc_setAssociatedObject(tabBar, kTabRowKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (s.inSafariLayout || !W7SafariMayRetry(tabBar, s) || W7SafariIvar(tabBar, "_draggedTabButton")) return;   // Safari's layout
        id visible = W7SafariIvar(tabBar, "_visibleTabBarButtons");
        if (![visible conformsToProtocol:@protocol(NSFastEnumeration)]) return;
        NSView *scroll = W7SafariIvarView(tabBar, "_scrollView");
        if (scroll && !(s.reserving && NSEqualRects(scroll.frame, s.reservedScroll))) s.safariScroll = scroll.frame;   // Safari's own
        __unsafe_unretained NSView *buttons[kMaxTabs];
        CGRect frames[kMaxTabs];
        NSInteger n = 0;
        CGFloat pinnedMaxX = 0;
        for (NSView *b in visible) {
            if (![b isKindOfClass:NSView.class] || b.isHiddenOrHasHiddenAncestor || !b.superview) continue;
            CGRect f = [tabBar convertRect:b.frame fromView:b.superview];
            BOOL pinned = NO;
            if (W7SafariReadBool(b, W7SafariSel("isPinned"), &pinned) && pinned) { pinnedMaxX = MAX(pinnedMaxX, CGRectGetMaxX(f)); continue; }
            if (n == kMaxTabs) return;   // more than we track: Safari's layout
            NSInteger i = n++;   // insertion sort by Safari's order (x)
            while (i > 0 && CGRectGetMinX(frames[i - 1]) > CGRectGetMinX(f)) { buttons[i] = buttons[i - 1]; frames[i] = frames[i - 1]; i--; }
            buttons[i] = b;
            frames[i] = f;
        }
        if (n == 0) { W7SafariPlaceNewTabStub(tabBar, CGRectZero, NO); return; }
        CGFloat titles[kMaxTabs], xs[kMaxTabs], widths[kMaxTabs];
        W7SafariIETabMetrics m = W7SafariIETabDefaultMetrics;
        CGFloat startX = pinnedMaxX > 0 ? pinnedMaxX + m.gap : kFirstTabX;
        CGRect row = scroll && scroll.superview ? [tabBar convertRect:s.safariScroll fromView:scroll.superview] : tabBar.bounds;
        CGFloat maxX = scroll && scroll.superview ? CGRectGetMaxX(row) : CGRectGetMaxX(tabBar.bounds) - kFirstTabX;
        W7SafariLayoutCommandBar(tabBar, row, &startX, &maxX);   // ★/✚ at the left, the command bar (and stub room) at the right
        NSInteger changed = 0;
        BOOL shrunk = NO;
        // Round 2 only when round 1 learnt that Safari truncated a title at the width we gave it.
        for (int round = 0; round < 2; round++) {
            CGFloat natural = 0;
            NSInteger unsized = 0;
            for (NSInteger i = 0; i < n; i++) {   // the title's room plus this tab's own chrome (learnt, else the default)
                CGFloat width = W7SafariTabTitleWidth((NSTextField *)W7SafariIvarView(buttons[i], "_titleTextField"));
                W7SafariTabNotes *notes = W7SafariTabNotesOf(buttons[i], YES);
                notes.usedTitleWidth = width;   // what hook c's refresh compares a later width against
                unsized += width <= 0;
                titles[i] = width + (notes.padding > 0 ? notes.padding - m.padding : 0);
                natural += MAX(m.minWidth, MIN(m.maxWidth, ceil(titles[i] + m.padding)));
            }
            W7SafariIETabLayoutResult result = W7SafariIETabLayoutDecide(titles, n, startX, maxX, m, xs, widths);
            if (result == W7SafariIETabLayoutTitlesUnsized) {   // not the floor for every tab; Safari's widths until the titles come
                s.deferred++;
                if (!s.loggedUnsized) {
                    s.loggedUnsized = YES;
                    W7SafariTabRowLog(s, ^{ return [NSString stringWithFormat:@"IE7 layout left to Safari for this pass: titles not sized yet "
                                                    @"(titles unsized: %ld of %ld); laid out again when they arrive", (long)unsized, (long)n]; });
                }
                W7SafariPlaceNewTabStub(tabBar, CGRectZero, NO);
                W7SafariReleaseScrollView(tabBar, s);   // Safari's own row, in its own scroll view (after an overflow)
                W7SafariHideOverlaysOverTabs(tabBar);
                return;
            }
            if (result == W7SafariIETabLayoutOverflow) {
                W7SafariPlaceNewTabStub(tabBar, CGRectZero, NO);
                W7SafariFallBackToSafari(tabBar, s, n, startX, maxX);
                W7SafariHideOverlaysOverTabs(tabBar);
                return;
            }
            shrunk = natural + m.gap * (n - 1) > maxX - startX + 0.5;
            if (s.reserving) {   // they fit again: Safari's scroll view back, and the tabs read again in its geometry
                W7SafariReleaseScrollView(tabBar, s);
                s.loggedReserve = NO;
                for (NSInteger i = 0; i < n; i++) frames[i] = [tabBar convertRect:buttons[i].frame fromView:buttons[i].superview];
            }
            BOOL learnt = NO;
            for (NSInteger i = 0; i < n; i++) {
                CGRect target = CGRectMake(xs[i], frames[i].origin.y, widths[i], frames[i].size.height);
                NSView *b = buttons[i];
                if (fabs(CGRectGetMinX(target) - CGRectGetMinX(frames[i])) >= 0.5 || fabs(target.size.width - frames[i].size.width) >= 0.5) {
                    b.frame = [b.superview convertRect:target fromView:tabBar];
                    frames[i] = target;
                    changed++;
                    [b layoutSubtreeIfNeeded];   // Safari's own button layout at our width, read back just below
                }
                if (!shrunk) learnt |= W7SafariLearnTabPadding(b, widths[i], m.maxWidth);   // a shrunk tab may truncate
            }
            if (!learnt) break;
        }
        s.applied = YES;
        s.passes++;
        W7SafariPlaceNewTabStub(tabBar, frames[n - 1], YES);   // the blank new-tab stub after the last tab
        W7SafariHideOverlaysOverTabs(tabBar);                  // never over a tab
        if (changed && W7SafariTabRowFight(tabBar, s)) {       // Safari put its frames back: a resize is fine, a fight is not
            W7SafariBackOff(tabBar, s);
            os_log(W7Log(), "Safari tabs: IE7 layout backed off (Safari re-laid the tabs out %ld times in a second)", (long)s.fights);
            W7SafariRestoreIETabLayout(tabBar);
            return;
        }
        if (changed) W7SafariRefreshHoveredTab(tabBar, s);     // Safari's highlight from our frames at once
        NSInteger logKey = n * 2 + shrunk;
        if (logKey != s.loggedCount) {
            s.loggedCount = logKey;
            CGFloat first = widths[0], last = widths[n - 1], x0 = xs[0], x1 = xs[n - 1] + last;
            W7SafariTabRowLog(s, ^{ return [NSString stringWithFormat:@"IE7 layout applied to %ld tabs%@ (x %g…%g, widths %g…%g, room to %g, pinned up to %g)",
                                            (long)n, shrunk ? @", shrunk to fit" : @"", x0, x1, first, last, maxX, pinnedMaxX]; });
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari tab layout failed: %{public}@", e.reason ?: @"unknown"); }
}

#pragma mark - A pass asked for by a title

/// The tab bar our pass ran on, from one of its buttons: the superview holding the row state (at most 8 up).
static NSView *W7SafariTabBarOfButton(NSView *button) {
    NSView *v = button.superview;
    for (int depth = 0; v && depth < 8; v = v.superview, depth++)
        if (objc_getAssociatedObject(v, kTabRowKey)) return v;
    return nil;
}

/// One pass from a main run-loop timer (common modes, so it fires during tracking and resizing too), coalesced: a
/// request while one is pending joins it; at most one per W7SafariIETabRelayoutInterval per tab bar. The pass runs
/// only when the tab bar is still in a themed window.
static void W7SafariRequestIETabLayout(NSView *tabBar) {
    W7SafariTabRowState *s = tabBar ? objc_getAssociatedObject(tabBar, kTabRowKey) : nil;
    if (!gTabLayoutEnabled || !s || s.relayoutPending) return;
    s.relayoutPending = YES;
    CFTimeInterval now = CACurrentMediaTime(), wait = MAX(0.001, W7SafariIETabRelayoutInterval - (now - s.lastRelayout));
    __weak NSView *weakBar = tabBar;
    NSTimer *timer = [NSTimer timerWithTimeInterval:wait repeats:NO block:^(NSTimer *t) {
        @try {
            NSView *bar = weakBar;
            W7SafariTabRowState *st = bar ? objc_getAssociatedObject(bar, kTabRowKey) : nil;
            if (!st) return;
            st.relayoutPending = NO;
            st.lastRelayout = CACurrentMediaTime();
            st.relayouts++;
            NSInteger before = st.passes + st.deferred;
            if (W7SafariWindowIsThemed(bar.window)) W7SafariApplyIETabLayout(bar);
            if (st.passes + st.deferred == before) {   // could not run (a drag, Safari's own layout, a back-off): not lost
                id visible = W7SafariIvar(bar, "_visibleTabBarButtons");
                if ([visible conformsToProtocol:@protocol(NSFastEnumeration)])
                    for (id b in visible) {
                        W7SafariTabNotes *notes = [b isKindOfClass:NSView.class] ? W7SafariTabNotesOf(b, NO) : nil;
                        if (notes && notes.requestedTitleWidth > 0) notes.requestedTitleWidth = kTitleWidthDropped;
                    }
            }
        } @catch (NSException *e) { os_log_error(W7Log(), "Safari tab re-layout failed: %{public}@", e.reason ?: @"unknown"); }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

void W7SafariNoteTabTitle(NSView *button, NSTextField *field, BOOL titleChanged) {
    if (!gTabLayoutEnabled || !button) return;
    W7SafariTabNotes *notes = W7SafariTabNotesOf(button, YES);
    // Measured only when the title changed, when the pass asked for could not run (asked again at the next refresh,
    // coalesced as before), or while the last pass saw the title unsized and nothing was asked for since (the launch
    // window: the only per-event text measurement, until the title is sized). Nothing measured on a pass with nothing new.
    BOOL dropped = notes.requestedTitleWidth == kTitleWidthDropped;
    if (!titleChanged && !dropped && !(notes.usedTitleWidth <= 0 && notes.requestedTitleWidth <= 0)) return;
    CGFloat width = W7SafariTabTitleWidth(field);
    if (fabs(width - notes.usedTitleWidth) < 0.5) { notes.requestedTitleWidth = width; return; }   // laid out at this width already
    if (!dropped && fabs(width - notes.requestedTitleWidth) < 0.5) return;   // asked for this width already
    notes.requestedTitleWidth = width;
    NSView *tabBar = W7SafariTabBarOfButton(button);
    W7SafariTabRowState *s = tabBar ? objc_getAssociatedObject(tabBar, kTabRowKey) : nil;
    if (!s) return;   // no pass has run on this row yet: Safari's own layout pass will bring ours
    s.requested++;
    W7SafariRequestIETabLayout(tabBar);
}

W7SafariIETabLayoutCounts W7SafariIETabLayoutCountsFor(NSView *tabBar) {
    W7SafariTabRowState *s = tabBar ? objc_getAssociatedObject(tabBar, kTabRowKey) : nil;
    return (W7SafariIETabLayoutCounts){ s.passes, s.deferred, s.requested, s.relayouts };
}

NSString *W7SafariIETabLayoutDiagnostics(NSView *tabBar) {
    W7SafariTabRowState *s = tabBar ? objc_getAssociatedObject(tabBar, kTabRowKey) : nil;
    NSString *hover = W7SafariHoverHooked(object_getClass(tabBar))
        ? [NSString stringWithFormat:@"hooked (%ld answered by frames, %ld passed to Safari)", (long)s.hoverByFrames, (long)s.hoverBySafari]
        : @"not hooked";
    if (!s) return [NSString stringWithFormat:@"IE7 tab layout: no pass on this tab bar yet, hover: _tabBarButtonAtPoint: %@", hover];
    return [NSString stringWithFormat:@"IE7 tab layout: %ld passes applied, %ld left to Safari (titles unsized), %ld re-layouts requested by "
                                      @"title changes (%ld coalesced passes run), backed off %d, applied now %d, hover: _tabBarButtonAtPoint: %@",
                                      (long)s.passes, (long)s.deferred, (long)s.requested, (long)s.relayouts, s.backedOff, s.applied, hover];
}

#pragma mark - The hovered tab from our frames

// Safari's UnifiedTabBar has one tracking area (the whole bar) and resolves the pointer with its own
// -_tabBarButtonAtPoint: from its layout model (_currentLayout), which keeps SAFARI's frames after the IE7 pass: the
// × and the highlight went to the tab whose Safari frame held the point. While our layout is in force the answer comes
// from the buttons' real frames; otherwise (Safari's layout, a drag, a back-off, an un-themed window) Safari's own.

static BOOL W7SafariIETabLayoutInForce(NSView *tabBar, W7SafariTabRowState *s) {
    return s.applied && !s.reserving && !s.backedOff && !s.inSafariLayout && !W7SafariIvar(tabBar, "_draggedTabButton");
}

/// The visible, unhidden tab button whose real frame (in the tab bar's coordinates) holds `p`; the selected tab (kept
/// by Safari in the backdrop container, above the scroll view) wins when two overlap. Called on every mouse move: the
/// set is enumerated in place, nothing is allocated.
static NSView *W7SafariTabButtonAtPointByFrames(NSView *tabBar, CGPoint p) {
    id visible = W7SafariIvar(tabBar, "_visibleTabBarButtons");
    if (![visible conformsToProtocol:@protocol(NSFastEnumeration)]) return nil;
    NSView *found = nil;
    for (NSView *b in visible) {
        if (![b isKindOfClass:NSView.class] || !b.superview || b.isHiddenOrHasHiddenAncestor) continue;
        if (!CGRectContainsPoint([tabBar convertRect:b.frame fromView:b.superview], p)) continue;
        BOOL active = NO;
        if (!found || (W7SafariReadBool(b, W7SafariSel("isActive"), &active) && active)) found = b;
    }
    return found;
}

BOOL W7SafariHookTabBarButtonAtPoint(Class cls) {
    @try {
        if (!cls) return NO;
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cls];
        if ([gHoverHooked containsObject:key]) return YES;
        SEL sel = W7SafariSel("_tabBarButtonAtPoint:");
        Method m = W7SafariCheckedMethod(cls, sel, "@32@0:8{CGPoint=dd}16");   // own method, exact encoding; reported once otherwise
        if (!m) return NO;
        id (*original)(id, SEL, CGPoint) = (id (*)(id, SEL, CGPoint))method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^id(NSView *me, CGPoint p) {
            @try {
                W7SafariTabRowState *s = objc_getAssociatedObject(me, kTabRowKey);
                if (s && gTabLayoutEnabled && W7SafariWindowIsThemed(me.window) && W7SafariIETabLayoutInForce(me, s)) {
                    s.hoverByFrames++;
                    return W7SafariTabButtonAtPointByFrames(me, p);
                }
                if (s) s.hoverBySafari++;
            } @catch (NSException *e) { os_log_error(W7Log(), "Safari hovered tab hook failed: %{public}@", e.reason ?: @"unknown"); }
            return original(me, sel, p);   // fail open: Safari's answer
        }));
        if (!gHoverHooked) gHoverHooked = [NSMutableSet set];
        [gHoverHooked addObject:key];
        W7SafariReport([NSString stringWithFormat:@"%@ -_tabBarButtonAtPoint: hooked (hovered tab from our frames)", NSStringFromClass(cls)]);
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari hovered tab hook install failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

BOOL W7SafariHookTabBarButtonLayout(Class cls) {
    @try {
        static NSMutableSet<NSValue *> *hooked;   // per class (classes are immortal), as the other hooks
        if (!cls) return NO;
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cls];
        if ([hooked containsObject:key]) return YES;
        SEL sel = W7SafariSel("_layoutButtonsAnimated:");
        Method m = W7SafariCheckedMethod(cls, sel, "v20@0:8B16");
        if (!m) return NO;
        void (*original)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(NSView *me, BOOL animated) {
            original(me, sel, animated);
            @try {
                if (!W7SafariWindowIsThemed(me.window)) return;
                W7SafariZeroTabSeparators(me);   // a separator Safari made here stays invisible (it sat at Safari's own boundary)
                W7SafariApplyIETabLayout(me);
            } @catch (NSException *e) { os_log_error(W7Log(), "Safari tab layout hook failed: %{public}@", e.reason ?: @"unknown"); }
        }));
        if (!hooked) hooked = [NSMutableSet set];
        [hooked addObject:key];
        W7SafariReport([NSString stringWithFormat:@"%@ -_layoutButtonsAnimated: hooked (IE7 tab row)", NSStringFromClass(cls)]);
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari tab layout hook install failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}
