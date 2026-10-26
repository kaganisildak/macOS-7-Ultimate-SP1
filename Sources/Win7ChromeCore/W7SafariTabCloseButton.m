// Safari's tab close button at the tab's right end. Safari puts `_closeButton` at the LEFT end of
// every tab, over the favicon (the × replaces the favicon under the pointer); IE8 has the × at the RIGHT end of the
// selected tab. While hook c styles a tab (W7SafariTabFacsimile.m), Safari's own button (never a copy) is moved: its
// frame, in its superview's coordinates, set so that its right edge is 6 pt from the tab's right edge, vertically
// centred, at Safari's size. AppKit hit-tests the frame, so the click reaches it there; the facsimile draws its × at
// the button's frame, so the glyph follows.
//   - Nothing is set when it is already there (a CGRect compare within 0.5 pt; no allocation per pass).
//   - Safari's frame is saved the first time, and again whenever Safari changed it since (the frame found is not
//     ours, beyond 0.5 pt), and put back exactly on unstyle (un-theme, window close, the kill switch, a failed pass),
//     unless Safari set a frame of its own after our last pass: that one is kept.
//   - Safari hosts the button in an NSStackView (Auto Layout; live: 8 constraints) and lays it out at the left again
//     whenever the stack runs, in particular when it un-hides the × on pointer entry, with no hook-c pass after (the ×
//     was drawn and hit at the left over the favicon until the pointer moved again). So while a tab
//     is styled the close button's frame is observed (NSViewFrameDidChangeNotification, postsFrameChangedNotifications
//     forced on and put back on unstyle): a frame that is not ours is put right at once and the facsimile refreshed;
//     our own set is not a re-entry. Safari's constraints are never touched.
//   - If Safari keeps putting the button back (more than W7SafariCloseButtonMaxResetsPerSecond re-sets in one second
//     at an unchanged geometry: a layout fight), the move backs off for that button, Safari's frame is left, and one
//     line per window is logged; the back-off is lifted 10 s later, when the tab's width changes (as the tab row's,
//     W7SafariTabRowFight), or when the pointer enters that tab (the × never stays at the left while the user
//     looks at it). The facsimile then keeps the title (W7IETabFacsimileLayoutFor's left case) and draws the × where
//     Safari has it.
//   - A re-set counts towards the fight only when the tab's width, the stack view's (the superview's) bounds AND the
//     close button's own size are all unchanged since the previous set: Safari's own animations
//     (closing a tab widens the others frame by frame, each frame's stack layout putting the × back) are not a fight;
//     a stack layout at constant size that undoes ours nine times in a second still is.
#import "W7SafariInternal.h"

const CGFloat W7SafariCloseButtonRightInset = 6;
const NSInteger W7SafariCloseButtonMaxResetsPerSecond = 8;
static const CFTimeInterval kBackOffRetryAfter = 10;

CGRect W7SafariCloseButtonFrameFor(CGRect tab, CGSize size) {
    return CGRectMake(round(CGRectGetMaxX(tab) - W7SafariCloseButtonRightInset - size.width),
                      round(CGRectGetMidY(tab) - size.height / 2), size.width, size.height);
}

@interface W7SafariCloseButtonState : NSObject
@property (nonatomic) CGRect saved, ours;   // Safari's frame (its newest), the frame we set last
@property (nonatomic) BOOL moved, backedOff, settingOurs, postedBefore;
@property (nonatomic) CFTimeInterval window;   // the second the re-sets are counted in
@property (nonatomic) CFTimeInterval backedOffAt;
@property (nonatomic) NSInteger resets;
@property (nonatomic) CGFloat lastWidth;        // the tab's width at the last set (or the back-off)
@property (nonatomic) CGSize lastRoom, lastSize;   // the superview's bounds and the close button's size at the last set
@property (nonatomic, weak) NSView *observed;   // the close button whose frame changes we listen to
@property (nonatomic, strong) id observer;      // its NSNotificationCenter token
@end
@implementation W7SafariCloseButtonState
@end

static const void *kCloseStateKey = &kCloseStateKey;   // on a tab button

static NSView *W7SafariCloseButtonOf(NSView *button) {
    NSView *close = W7SafariIvarView(button, "_closeButton");
    return close && close != button && close.superview && [close isDescendantOf:button] ? close : nil;
}

static BOOL W7SafariRectsWithin(CGRect a, CGRect b, CGFloat tolerance) {
    return fabs(a.origin.x - b.origin.x) < tolerance && fabs(a.origin.y - b.origin.y) < tolerance &&
           fabs(a.size.width - b.size.width) < tolerance && fabs(a.size.height - b.size.height) < tolerance;
}

static BOOL W7SafariSizesWithin(CGSize a, CGSize b, CGFloat tolerance) {
    return fabs(a.width - b.width) < tolerance && fabs(a.height - b.height) < tolerance;
}

void W7SafariCloseButtonLiftBackOff(NSView *button) {
    W7SafariCloseButtonState *s = objc_getAssociatedObject(button, kCloseStateKey);
    if (!s || !s.backedOff) return;
    s.backedOff = NO, s.resets = 0;   // the pointer is on this tab: the × belongs at the right now; a true fight backs off again
}

/// Sets the close button's frame as ours: the frame-change notification it posts is not a re-entry.
static void W7SafariSetCloseFrame(W7SafariCloseButtonState *s, NSView *close, CGRect frame) {
    s.settingOurs = YES;
    @try { close.frame = frame; }
    @finally { s.settingOurs = NO; }
}

static void W7SafariCloseButtonUnobserve(W7SafariCloseButtonState *s) {
    if (s.observer) [NSNotificationCenter.defaultCenter removeObserver:s.observer];
    s.observer = nil;
    NSView *close = s.observed;
    if (close) close.postsFrameChangedNotifications = s.postedBefore;
    s.observed = nil;
}

/// Listens to `close`'s frame changes for `button` (once per close button; a new close button replaces the old one).
/// Main thread only (AppKit posts on the thread that set the frame). The block holds the button weakly.
static void W7SafariCloseButtonObserve(NSView *button, NSView *close, W7SafariCloseButtonState *s) {
    if (s.observer && s.observed == close) return;
    W7SafariCloseButtonUnobserve(s);
    s.observed = close;
    s.postedBefore = close.postsFrameChangedNotifications;
    close.postsFrameChangedNotifications = YES;
    __weak NSView *weakButton = button;
    s.observer = [NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification object:close queue:nil
                                                             usingBlock:^(NSNotification *n) {
        @try {
            NSView *b = weakButton;
            W7SafariCloseButtonState *st = b ? objc_getAssociatedObject(b, kCloseStateKey) : nil;
            if (!st || st.settingOurs || !W7SafariFacsimileIsStyled(b) || !W7SafariWindowIsThemed(b.window)) return;
            if (W7SafariCloseButtonPlace(b, b.window)) W7SafariFacsimileRefreshButton(b);   // Safari moved it: back at once
        } @catch (NSException *e) { os_log_error(W7Log(), "Safari close button follow failed: %{public}@", e.reason ?: @"unknown"); }
    }];
}

BOOL W7SafariCloseButtonPlace(NSView *button, NSWindow *w) {
    NSView *close = W7SafariCloseButtonOf(button);
    if (!close) return NO;
    W7SafariCloseButtonState *s = objc_getAssociatedObject(button, kCloseStateKey);
    if (!s) {
        s = [W7SafariCloseButtonState new];
        objc_setAssociatedObject(button, kCloseStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    W7SafariCloseButtonObserve(button, close, s);
    CGFloat width = button.bounds.size.width;
    if (s.backedOff) {   // lifted after a while, or when the tab is another width (a resize, not the fight)
        if (CACurrentMediaTime() - s.backedOffAt < kBackOffRetryAfter && fabs(width - s.lastWidth) < 0.5) return NO;
        s.backedOff = NO, s.resets = 0;
    }
    CGRect current = close.frame;
    if (current.size.width <= 0 || current.size.height <= 0) return NO;
    NSView *super = close.superview;
    CGRect tab = [super convertRect:button.bounds fromView:button];
    CGRect room = CGRectIntersection(tab, super.bounds);   // inside its superview, where AppKit hit-tests it
    if (CGRectIsNull(room) || CGRectIsEmpty(room)) room = tab;
    CGRect target = W7SafariCloseButtonFrameFor(room, current.size);
    if (W7SafariRectsWithin(current, target, 0.5)) return NO;   // already there: no work
    if (!s.moved || !W7SafariRectsWithin(current, s.ours, 0.5)) s.saved = current;   // Safari's (newest) frame, for the restore
    if (s.moved) {   // a re-set: Safari (or a geometry change) undid ours
        CFTimeInterval now = CACurrentMediaTime();
        if (now - s.window > 1) s.window = now, s.resets = 0;
        // Counted only at an unchanged geometry (tab width, superview bounds, the ×'s size): an animation is not a fight.
        if (fabs(width - s.lastWidth) < 0.5 && W7SafariSizesWithin(super.bounds.size, s.lastRoom, 0.5) &&
            W7SafariSizesWithin(current.size, s.lastSize, 0.5)) s.resets++;
        if (s.resets > W7SafariCloseButtonMaxResetsPerSecond) {   // a fight: Safari's position for now
            s.backedOff = YES, s.moved = NO;
            s.backedOffAt = now, s.lastWidth = width;
            if (!CGRectEqualToRect(close.frame, s.saved)) W7SafariSetCloseFrame(s, close, s.saved);
            W7SafariWindowState *st = W7SafariState(w, NO);
            if (st && !st.closeButtonFightLogged) {
                st.closeButtonFightLogged = YES;
                os_log(W7Log(), "Safari tabs: close button left where Safari puts it (Safari moved it back %ld times in a second at one size); "
                                "the × stays at the left of that tab for 10 s, until the tab is resized or until the pointer enters it", (long)s.resets);
            }
            return NO;
        }
    }
    s.lastWidth = width, s.lastRoom = super.bounds.size, s.lastSize = current.size;
    W7SafariSetCloseFrame(s, close, target);
    s.ours = target, s.moved = YES;
    return YES;
}

void W7SafariCloseButtonRestore(NSView *button) {
    W7SafariCloseButtonState *s = objc_getAssociatedObject(button, kCloseStateKey);
    if (!s) return;
    objc_setAssociatedObject(button, kCloseStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    W7SafariCloseButtonUnobserve(s);
    NSView *close = s.moved ? W7SafariCloseButtonOf(button) : nil;
    if (close && W7SafariRectsWithin(close.frame, s.ours, 0.5)) close.frame = s.saved;   // still ours: Safari's frame back exactly
}

NSInteger W7SafariCloseButtonResets(NSView *button) {
    W7SafariCloseButtonState *s = objc_getAssociatedObject(button, kCloseStateKey);
    return s.resets;
}

W7SafariCloseButtonPlacement W7SafariCloseButtonPlacementOf(NSView *button) {
    if (!W7SafariCloseButtonOf(button)) return W7SafariCloseButtonNotFound;
    W7SafariCloseButtonState *s = objc_getAssociatedObject(button, kCloseStateKey);
    if (s.backedOff) return W7SafariCloseButtonBackedOff;
    return s.moved ? W7SafariCloseButtonMoved : W7SafariCloseButtonUntouched;
}
