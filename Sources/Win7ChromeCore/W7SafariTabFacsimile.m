// Internet Explorer 8 facsimile tabs for Safari. Tinting Safari's Liquid Glass can never give flat tabs (the
// material always renders a pill with its own sheen), so Safari's tab faces go invisible and win7mac draws each tab:
//   - Safari's tab buttons stay where they are for everything they do (click, drag, close, context menu, hover
//     tracking). Their faces (_contentGlassView, _backgroundView, _visualEffectBackground, _visualEffectBackgroundHighlight,
//     _contentView) go to alpha 0: NOT hidden, so hit testing and layout keep working (AppKit's hit testing ignores
//     alpha). Every alpha is saved first (Safari's newest value when it changes one) and put back on un-theming,
//     window close, the kill switch and whenever hook c stops styling the button.
//   - One facsimile view per tab button, the button's topmost subview at its exact bounds (so it follows Safari's frames,
//     the IE layout pass, scrolling, drags and the selected tab's backdrop container on its own), draws the IE8 tab
//     (W7DrawIETabFacsimile): shape by state, the favicon and title READ from Safari's button for drawing only (never
//     logged, never kept beyond the drawing; a template icon, Safari's symbol placeholder, drawn as IE's page icon:
//     the user's ie-page.png when imported, the W7IETabIconFor, else Theme's drawn page),
//     the close glyph at Safari's _closeButton frame whenever Safari shows it (hook c moves that button to the tab's
//     right end first, W7SafariTabCloseButton.m; it is put back on unstyle here), and a glyph at each of Safari's other
//     visible in-tab controls (a speaker for the audio button), which would otherwise be invisible yet clickable.
//     Click-through everywhere (hitTest nil); hover from Safari's state or the view's own tracking area (mouse moved,
//     entered and exited only, nothing swallowed).
//   - Refreshed (compare only; a redraw of that one tab only on a change; no allocation when nothing changed) from
//     hook c's passes, the tab bar pass, Safari's loading updates and window updates (at most 4 per second per window).
// Kill switch: `defaults write -g W7SafariFacsimileTabsDisabled -bool YES` (also off with W7SafariHooksDisabled): the
// tabs are then simply Safari's.
#import "W7SafariInternal.h"
#import <QuartzCore/QuartzCore.h>

static BOOL gFacsimileEnabled;
void W7SafariFacsimileSetEnabled(BOOL enabled) { gFacsimileEnabled = enabled; }
BOOL W7SafariFacsimileEnabled(void) { return gFacsimileEnabled; }
BOOL W7SafariFacsimileShouldStart(BOOL hooksEnabled, BOOL disabled) { return hooksEnabled && !disabled; }

/// Safari's faces made invisible (alpha 0) under the facsimile.
static const char *const kFaceIvars[] = {
    "_contentGlassView", "_backgroundView", "_visualEffectBackground", "_visualEffectBackgroundHighlight", "_contentView",
};
enum { kFaceCount = sizeof kFaceIvars / sizeof *kFaceIvars };

#pragma mark - Close button geometry (pure enough to test on a fake button)

CGRect W7SafariFacsimileCloseRect(NSView *button, NSView *into, BOOL *shown) {
    if (shown) *shown = NO;
    NSView *close = W7SafariIvarView(button, "_closeButton");
    if (!close || !into || ![close isDescendantOf:button]) return CGRectZero;
    // Shown as Safari shows it: not hidden and not faded out. The alpha 0 of _contentView (ours) is not Safari's.
    if (shown) *shown = !close.isHiddenOrHasHiddenAncestor && close.alphaValue > 0.01;
    return [into convertRect:close.bounds fromView:close];
}

#pragma mark - Safari's other in-tab controls

enum { kMaxAccessories = 4 };
static const CFTimeInterval kAccessoryScanInterval = 0.5;   // the scan walks subviews (copies): at most twice a second

/// Whether a control is Safari's audio (mute/speaker) button: by class name or identifier, without allocating.
static BOOL W7SafariIsAudioControl(NSView *v) {
    static const char *const words[] = { "audio", "mute", "sound", "speaker" };
    const char *cls = class_getName(object_getClass(v));
    NSString *identifier = v.identifier;
    for (size_t i = 0; i < sizeof words / sizeof *words; i++) {
        if (cls && strcasestr(cls, words[i])) return YES;
        if (identifier && [identifier rangeOfString:@(words[i]) options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

/// Visible buttons and image views under `v` (Safari's tab content) other than the title, the favicon and the close
/// button: their frames in `into` and their kind. Never descends into hidden or excluded views; at most 64 views.
static void W7SafariCollectAccessories(NSView *v, int depth, int *budget, NSView *const skip[3], NSView *into, CGRect *rects,
                                       W7IETabAccessory *kinds, NSInteger *n) {
    if (depth > 5) return;
    for (NSView *sub in v.subviews) {
        if (*n >= kMaxAccessories || --(*budget) < 0) return;
        if (sub.isHidden || sub == skip[0] || sub == skip[1] || sub == skip[2] || W7SafariIsExcludedCName(class_getName(object_getClass(sub))))
            continue;
        if ([sub isKindOfClass:NSButton.class] || [sub isKindOfClass:NSImageView.class]) {
            CGRect r = [into convertRect:sub.bounds fromView:sub];
            if (sub.alphaValue > 0.01 && !CGRectIsEmpty(r)) {
                rects[*n] = r;
                kinds[*n] = W7SafariIsAudioControl(sub) ? W7IETabAccessorySpeaker : W7IETabAccessoryGeneric;
                (*n)++;
            }
            continue;
        }
        W7SafariCollectAccessories(sub, depth + 1, budget, skip, into, rects, kinds, n);
    }
}

#pragma mark - IE's page icon from the user's set

NSImage *W7IETabIconFor(NSImage *safariIcon) {
    static NSImage *page;   // the user's ie-page icon (shared: drawn, never mutated), or nil
    static NSUInteger generation;
    static BOOL asked;
    @try {
        if (!safariIcon.isTemplate) return safariIcon;   // a real favicon (or nil) as it is
        NSUInteger now = W7UserIconsGeneration();
        if (!asked || now != generation) {   // asked again only after the icon loader resets
            page = W7UserIconImage(@"ie-page", 16);
            generation = now;
            asked = YES;
        }
        return page ?: safariIcon;   // none: the template, drawn by Theme as IE's page icon
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari tab page icon failed: %{public}@", e.reason ?: @"unknown");
        return safariIcon;
    }
}

#pragma mark - The facsimile view

@interface W7SafariTabFacsimileView : NSView
@property (nonatomic, weak) NSView *button;
@property (nonatomic, readonly) NSUInteger drawCount, redrawRequests;
@property (nonatomic, readonly) BOOL iconIsTemplate;   // the icon last read is a template image (IE's page icon drawn)
@end

@implementation W7SafariTabFacsimileView {
    W7IETabState _state;
    BOOL _pinned, _closeShown, _pointerInside, _closeHover, _iconIsTemplate;
    CGRect _closeRect;
    NSString *_title;   // Safari's, for drawing only: never logged
    NSString *_shownTitle;   // _title shortened for _shownWidth (worked out again only when either changes)
    CGFloat _shownWidth;
    NSImage *_icon;
    NSTrackingArea *_tracking;
    CGRect _accRects[kMaxAccessories];   // Safari's other visible in-tab controls (this view's coordinates)
    W7IETabAccessory _accKinds[kMaxAccessories];
    NSInteger _accCount;
    CFTimeInterval _accScanned;
}

- (NSView *)hitTest:(NSPoint)point { return nil; }   // every event goes to Safari's button under it
- (BOOL)isFlipped { return NO; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (void)setFrameSize:(NSSize)size {
    BOOL changed = !NSEqualSizes(size, self.frame.size);
    [super setFrameSize:size];
    if (changed) self.needsDisplay = YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                 NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

// Tracking only: never forwarded, never consumed from Safari (its own tracking areas get their events as before).
- (void)w7Pointer:(NSEvent *)e inside:(BOOL)inside {
    @try {
        BOOL entered = inside && !_pointerInside;
        _pointerInside = inside;
        if (entered) W7SafariCloseButtonLiftBackOff(self.button);   // the × never stays at the left while the user looks at the tab
        BOOL closeHover = inside && _closeShown && NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], _closeRect);
        if (closeHover != _closeHover) { _closeHover = closeHover; [self setNeedsDisplayInRect:NSInsetRect(_closeRect, -1, -1)]; }
        NSView *button = self.button;
        if (button) [self w7RefreshFromButton:button];
    } @catch (NSException *ex) { os_log_error(W7Log(), "Safari facsimile hover failed: %{public}@", ex.reason ?: @"unknown"); }
}
- (void)mouseEntered:(NSEvent *)e { [self w7Pointer:e inside:YES]; }
- (void)mouseExited:(NSEvent *)e { [self w7Pointer:e inside:NO]; }
- (void)mouseMoved:(NSEvent *)e { [self w7Pointer:e inside:YES]; }

/// Reads the tab's state, pinned flag, title, icon and close button from Safari's button; redraws on a change. Compare
/// only: nothing is allocated unless something changed (the title string is copied only then).
- (BOOL)w7RefreshFromButton:(NSView *)button {
    W7IETabState state = W7SafariTabButtonState(button);
    if (state == W7IETabNormal && _pointerInside) state = W7IETabHover;
    BOOL pinned = NO;
    W7SafariReadBool(button, W7SafariSel("isPinned"), &pinned);
    NSTextField *field = (NSTextField *)W7SafariIvarView(button, "_titleTextField");
    NSString *title = [field isKindOfClass:NSTextField.class] ? field.stringValue : nil;
    // The image whatever the view's alpha (Safari fades the icon out under the pointer to show its ×); hidden respected.
    NSImageView *iconView = (NSImageView *)W7SafariIvarView(button, "_iconImageView");
    NSImage *icon = [iconView isKindOfClass:NSImageView.class] && !iconView.isHidden ? iconView.image : nil;
    BOOL closeShown = NO;
    W7SafariCloseButtonPlace(button, button.window);   // Never read (and draw) Safari's left-end frame while placing
    CGRect closeRect = W7SafariFacsimileCloseRect(button, self, &closeShown);
    BOOL titleChanged = title != _title && !(title && _title && [title isEqualToString:_title]);
    W7SafariNoteTabTitle(button, field, titleChanged);   // the IE7 row again when the title's width changed
    BOOL changed = state != _state || pinned != _pinned || titleChanged || icon != _icon || closeShown != _closeShown ||
                   (closeShown && !CGRectEqualToRect(closeRect, _closeRect));
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _accScanned >= kAccessoryScanInterval) {   // throttled: the walk copies subview arrays
        _accScanned = now;
        CGRect rects[kMaxAccessories];
        W7IETabAccessory kinds[kMaxAccessories];
        NSInteger n = 0;
        int budget = 64;
        NSView *const skip[3] = { field, iconView, W7SafariIvarView(button, "_closeButton") };
        NSView *content = W7SafariIvarView(button, "_contentView");
        if (content) W7SafariCollectAccessories(content, 0, &budget, skip, self, rects, kinds, &n);
        BOOL same = n == _accCount;
        for (NSInteger i = 0; same && i < n; i++) same = CGRectEqualToRect(rects[i], _accRects[i]) && kinds[i] == _accKinds[i];
        if (!same) {
            for (NSInteger i = 0; i < n; i++) _accRects[i] = rects[i], _accKinds[i] = kinds[i];
            _accCount = n, _shownTitle = nil;
            changed = YES;
        }
    }
    if (!changed) return NO;
    _state = state, _pinned = pinned, _icon = icon, _closeShown = closeShown, _closeRect = closeRect;
    _iconIsTemplate = icon.isTemplate;   // a count for the diagnostics only, never the image
    if (titleChanged) _title = [title copy], _shownTitle = nil;
    if (!closeShown) _closeHover = NO;
    _redrawRequests++;
    self.needsDisplay = YES;   // this tab only: the view is the tab
    return YES;
}

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        if (!ctx) return;
        _drawCount++;
        W7IETabCloseState close = !_closeShown ? W7IETabCloseHidden : _closeHover ? W7IETabCloseHover : W7IETabCloseNormal;
        // The title's room clear of Safari's other controls; the middle-shortened title only when the title or its room
        // changed (a resize animation redraws every frame).
        CGRect room = W7IETabTitleRectAvoiding(W7IETabFacsimileLayoutFor(self.bounds, _state, _pinned, _closeRect, _closeShown).title,
                                               _accRects, _accCount);
        if (!_shownTitle || fabs(room.size.width - _shownWidth) > 0.25) {
            _shownTitle = W7IEMiddleTruncatedTitle(_title, room.size.width, W7UIFont(12));
            _shownWidth = room.size.width;
        }
        W7DrawIETabFacsimile(ctx, self.bounds, _state, _pinned, W7IETabIconFor(_icon), _shownTitle, room, _closeRect, close);
        for (NSInteger i = 0; i < _accCount; i++) W7DrawIETabAccessoryGlyph(ctx, _accRects[i], _accKinds[i]);
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari facsimile draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

#pragma mark - Per button: saved alphas and the view

@interface W7SafariFacsimileState : NSObject
@property (nonatomic, strong) NSMapTable<NSView *, NSNumber *> *alphas;   // face (weak) → the alpha to put back
@property (nonatomic, strong) NSHashTable<NSView *> *seen, *skipped;      // faces checked once for excluded views / left alone
@property (nonatomic, strong) W7SafariTabFacsimileView *view;
@property (nonatomic) NSInteger took, faces;   // faces that read back alpha 0 / faces found, on the last pass
@end
@implementation W7SafariFacsimileState
@end

static const void *kFacsimileKey = &kFacsimileKey;   // on a tab button: its W7SafariFacsimileState

static W7SafariFacsimileState *W7SafariFacsimileStateOf(NSView *button) {
    return button ? objc_getAssociatedObject(button, kFacsimileKey) : nil;
}

BOOL W7SafariFacsimileIsStyled(NSView *button) { return W7SafariFacsimileStateOf(button) != nil; }
NSView *W7SafariFacsimileViewForButton(NSView *button) { return W7SafariFacsimileStateOf(button).view; }
NSUInteger W7SafariFacsimileDrawCount(NSView *facsimile) {
    return [facsimile isKindOfClass:W7SafariTabFacsimileView.class] ? ((W7SafariTabFacsimileView *)facsimile).drawCount : 0;
}
NSUInteger W7SafariFacsimileRedrawRequests(NSView *facsimile) {
    return [facsimile isKindOfClass:W7SafariTabFacsimileView.class] ? ((W7SafariTabFacsimileView *)facsimile).redrawRequests : 0;
}
BOOL W7SafariFacsimileIconIsTemplate(NSView *facsimile) {
    return [facsimile isKindOfClass:W7SafariTabFacsimileView.class] && ((W7SafariTabFacsimileView *)facsimile).iconIsTemplate;
}

static uint64_t gRezeros;   // a face Safari gave an alpha again since hook c zeroed it (a ping-pong would show)
uint64_t W7SafariFacsimileRezeroCount(void) { return gRezeros; }

/// Alpha 0 on every face (saving the alpha Safari gave it first, and again whenever Safari changed it since). A face
/// holding an excluded view (W7SafariIsExcludedClassName: address field, AutoFill, …) is checked the first time it is
/// seen and then left alone for good.
static void W7SafariZeroFaces(NSView *button, W7SafariFacsimileState *s) {
    NSInteger took = 0, faces = 0;
    for (size_t i = 0; i < kFaceCount; i++) {
        NSView *v = W7SafariIvarView(button, kFaceIvars[i]);
        if (!v || v == s.view || ![v isDescendantOf:button] || [s.skipped containsObject:v]) continue;
        if (![s.seen containsObject:v]) {   // once per face: the only walk of its subviews
            [s.seen addObject:v];
            NSString *excluded = W7SafariGlassExclusionIn(v, button);
            if (excluded) {
                [s.skipped addObject:v];
                os_log(W7Log(), "Safari tabs: tab face %{public}s left visible (holds %{public}@)", kFaceIvars[i], excluded);
                continue;
            }
        }
        faces++;
        if (v.alphaValue != 0) {
            if ([s.alphas objectForKey:v]) gRezeros++;
            [s.alphas setObject:@(v.alphaValue) forKey:v];   // Safari's (newest) value, for the restore
            v.alphaValue = 0;
        }
        took += v.alphaValue == 0;
    }
    s.took = took, s.faces = faces;
}

/// The facsimile as the button's topmost subview, at its bounds; above Safari's layers even if Safari adds a subview later.
static void W7SafariPlaceFacsimile(NSView *button, W7SafariFacsimileState *s) {
    W7SafariTabFacsimileView *view = s.view;
    if (!view) {
        view = [[W7SafariTabFacsimileView alloc] initWithFrame:button.bounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.wantsLayer = YES;
        view.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        view.button = button;
        s.view = view;
    }
    if (view.superview != button) [button addSubview:view positioned:NSWindowAbove relativeTo:nil];
    if (!NSEqualRects(view.frame, button.bounds)) view.frame = button.bounds;
    if (view.layer && view.layer.zPosition < 1000) view.layer.zPosition = 1000;
}

BOOL W7SafariFacsimileStyleButton(NSView *button) {
    @try {
        if (!gFacsimileEnabled || !button) return NO;
        W7SafariFacsimileState *s = W7SafariFacsimileStateOf(button);
        if (!s) {
            s = [W7SafariFacsimileState new];
            s.alphas = [NSMapTable weakToStrongObjectsMapTable];
            s.seen = [NSHashTable weakObjectsHashTable];
            s.skipped = [NSHashTable weakObjectsHashTable];
            objc_setAssociatedObject(button, kFacsimileKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        W7SafariPlaceFacsimile(button, s);
        W7SafariZeroFaces(button, s);
        [s.view w7RefreshFromButton:button];
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari facsimile styling failed: %{public}@", e.reason ?: @"unknown");
        W7SafariFacsimileUnstyleButton(button);   // fail open: Safari's own tab
        return NO;
    }
}

void W7SafariFacsimileUnstyleButton(NSView *button) {
    @try {
        W7SafariCloseButtonRestore(button);   // Safari's × back where Safari had it (moved before the styling)
        W7SafariFacsimileState *s = W7SafariFacsimileStateOf(button);
        if (!s) return;
        objc_setAssociatedObject(button, kFacsimileKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [s.view removeFromSuperview];
        for (NSView *v in s.alphas.keyEnumerator.allObjects) {
            NSNumber *alpha = [s.alphas objectForKey:v];
            if (v.alphaValue == 0) v.alphaValue = alpha.doubleValue;   // still ours (Safari did not set its own since)
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari facsimile restore failed: %{public}@", e.reason ?: @"unknown"); }
}

BOOL W7SafariFacsimileRefreshButton(NSView *button) {
    @try {
        W7SafariFacsimileState *s = W7SafariFacsimileStateOf(button);
        return s.view && [s.view w7RefreshFromButton:button];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Safari facsimile refresh failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Window side

void W7SafariFacsimileRefreshWindow(NSWindow *w, BOOL force) {
    @try {
        if (!gFacsimileEnabled || ![w isKindOfClass:NSWindow.class] || !W7SafariWindowIsThemed(w)) return;
        W7SafariWindowState *st = W7SafariState(w, NO);
        CFTimeInterval now = CACurrentMediaTime();
        if (!force && now - st.lastFacsimileRefresh < 0.25) return;   // window updates come with every event
        st.lastFacsimileRefresh = now;
        for (NSView *b in st.styledButtons) W7SafariFacsimileRefreshButton(b);
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari facsimile window refresh failed: %{public}@", e.reason ?: @"unknown"); }
}

BOOL W7SafariFacsimileLineY(NSView *tabBar, NSView *into, CGFloat *y) {
    id buttons = W7SafariIvar(tabBar, "_visibleTabBarButtons");
    if (!into || ![buttons conformsToProtocol:@protocol(NSFastEnumeration)]) return NO;
    for (NSView *b in buttons) {
        if (![b isKindOfClass:NSView.class] || b.isHiddenOrHasHiddenAncestor || !W7SafariFacsimileIsStyled(b)) continue;
        if (y) *y = NSMinY([into convertRect:b.bounds fromView:b]);
        return YES;
    }
    return NO;
}

/// Whether `layer` reaches the window's root layer through its superlayers with none of them hidden or at opacity 0.
static BOOL W7SafariLayerShows(CALayer *layer, NSWindow *w) {
    CALayer *root = w.contentView.superview.layer ?: w.contentView.layer;
    for (CALayer *l = layer; l; l = l.superlayer) {
        if (l.hidden || l.opacity <= 0) return NO;
        if (l == root) return YES;
    }
    return NO;
}

NSArray<NSString *> *W7SafariFacsimileDiagnostics(NSWindow *w) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @try {
        if (!gFacsimileEnabled) return @[ @"facsimile tabs: off (W7SafariFacsimileTabsDisabled or W7SafariHooksDisabled): Safari's own tabs" ];
        NSInteger n = 0, took = 0, faces = 0, close = 0, moved = 0, backedOff = 0, templates = 0;
        NSView *selected = nil;
        for (NSView *b in W7SafariState(w, NO).styledButtons) {
            W7SafariFacsimileState *s = W7SafariFacsimileStateOf(b);
            if (!s.view || b.window != w) continue;
            n++, took += s.took, faces += s.faces;
            W7SafariCloseButtonPlacement placement = W7SafariCloseButtonPlacementOf(b);
            close += placement != W7SafariCloseButtonNotFound;
            moved += placement == W7SafariCloseButtonMoved;
            backedOff += placement == W7SafariCloseButtonBackedOff;
            templates += s.view.iconIsTemplate;
            if (W7SafariTabButtonState(b) == W7IETabSelected) selected = b;
        }
        [lines addObject:[NSString stringWithFormat:@"facsimile tabs: %ld drawn by win7mac; Safari's faces at alpha 0: %ld of %ld found "
                                                    @"(AppKit hit testing ignores alpha: Safari's buttons keep every click); _closeButton found on %ld",
                          (long)n, (long)took, (long)faces, (long)close]];
        [lines addObject:[NSString stringWithFormat:@"facsimile close buttons: moved to the right end %ld, left where Safari puts them "
                                                    @"(backed off) %ld, not found %ld; template tab icons (drawn as IE's page icon) %ld",
                          (long)moved, (long)backedOff, (long)(n - close), (long)templates]];
        if (selected) {
            NSView *view = W7SafariFacsimileStateOf(selected).view;
            NSView *scroll = W7SafariIvarView(W7SafariTabBarView(w), "_scrollView");
            CGRect tab = [selected convertRect:selected.bounds toView:nil];
            [lines addObject:[NSString stringWithFormat:@"facsimile selected tab: in %@, its layer shows in the window's layer tree %d "
                                                        @"(button layer opacity %g); tab bottom y %g, tab scroll view bottom y %@",
                              NSStringFromClass(selected.superview.class), W7SafariLayerShows(view.layer, w),
                              selected.layer ? selected.layer.opacity : -1.0, CGRectGetMinY(tab),
                              scroll ? @(NSMinY([scroll convertRect:scroll.bounds toView:nil])) : @"-"]];
        } else if (n) {
            [lines addObject:@"facsimile selected tab: none among the styled buttons yet"];
        }
    } @catch (NSException *e) { [lines addObject:[NSString stringWithFormat:@"facsimile diagnostics failed: %@", e.reason]]; }
    return lines;
}

void W7SafariFacsimileStart(BOOL enabled) {
    static BOOL observing;
    gFacsimileEnabled = enabled;
    W7SafariReport([NSString stringWithFormat:@"facsimile tabs %@", enabled ? @"on" : @"off (W7SafariFacsimileTabsDisabled or W7SafariHooksDisabled)"]);
    if (!enabled || observing) return;
    observing = YES;
    @try {
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowWillCloseNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            @try {   // every alpha back before the window's views go (a tab button may live on in another window)
                NSWindow *w = n.object;
                if (![w isKindOfClass:NSWindow.class]) return;
                W7SafariWindowState *st = W7SafariState(w, NO);
                for (NSView *b in st.styledButtons.allObjects) W7SafariFacsimileUnstyleButton(b);
            } @catch (NSException *e) { os_log_error(W7Log(), "Safari facsimile close failed: %{public}@", e.reason ?: @"unknown"); }
        }];
        [nc addObserverForName:NSWindowDidUpdateNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            W7SafariFacsimileRefreshWindow(n.object, NO);   // titles and favicons that changed without a layout pass
        }];
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari facsimile start failed: %{public}@", e.reason ?: @"unknown"); }
}
