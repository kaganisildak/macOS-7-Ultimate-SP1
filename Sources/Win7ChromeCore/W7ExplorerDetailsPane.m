// Windows 7 details pane: a 60 pt bar along the bottom of the Explorer window (W7ExplorerDetailsView
// draws it). With nothing selected it shows the folder's icon and item count; otherwise the
// selection's icon (a Quick Look thumbnail for one image or PDF, a stack of up to three icons for
// several items) and its properties. On Finder's Computer location it shows the Computer view's
// selected drive, or the computer (W7ExplorerComputerView.m).
//
// Placement, least invasive first:
//   1. Lifted: Finder's top-level content views make room. Every change is planned first and applied
//      only if all of them are possible (no partial lifts). Autoresizing views in the lower half move
//      BY the pane height exactly once (a marker), and views reaching the top also shrink by it, so
//      views stacked at the bottom stay stacked. Auto Layout views get original constant − height on
//      their bottom-to-content constraint (the original is kept on the constraint). Flipped content works.
//   2. Overlay: when the content is (or contains) a split view, the pane floats at the bottom of the
//      split view's last arranged subview (the browser side), whose bottom-touching scroll views get
//      a bottom inset of the pane's height. It is never a split pane and never goes into the window's
//      frame view.
//   3. Otherwise no pane ("details pane skipped (<reason>)" in the log).
#import "W7ExplorerInternal.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

const CGFloat W7ExplorerDetailsPaneHeight = 60;
static const NSTimeInterval kMaintainInterval = 1.0;
static const void *kInsetKey = &kInsetKey;
static const void *kLiftedKey = &kLiftedKey;
static const void *kOriginalConstantKey = &kOriginalConstantKey;
static const void *kLastTargetKey = &kLastTargetKey;

typedef NS_ENUM(NSInteger, W7DetailsMode) { W7DetailsModeNone, W7DetailsModeLifted, W7DetailsModeOverlay };

static const CGFloat kThumbnailSide = 48;
static const NSUInteger kMaxStackedIcons = 3;

/// QuickLookThumbnailing is not linked into the dylib; Finder has it loaded, otherwise it is opened once.
static Class W7QuickLookClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls) return cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/QuickLookThumbnailing.framework/QuickLookThumbnailing", RTLD_LAZY | RTLD_LOCAL);
    });
    return NSClassFromString(name);
}

/// Quick Look thumbnails only for images and PDFs (other kinds keep their Finder icon).
static BOOL W7WantsThumbnail(W7ExplorerItemInfo *item) {
    return item.isImage || [item.url.pathExtension caseInsensitiveCompare:@"pdf"] == NSOrderedSame;
}

/// The Windows 7 picture for `url` (folder art, the user's type icon; W7ExplorerIconForPath), else the icon
/// NSWorkspace gives it, sized for the pane.
static NSImage *W7IconForURL(NSURL *url, CGFloat side) {
    if (url.path.length == 0) return nil;
    NSImage *own = W7ExplorerIconForPath(url.path, side);
    if (own) return own;
    NSImage *icon = [[NSWorkspace.sharedWorkspace iconForFile:url.path] copy];
    icon.size = NSMakeSize(side, side);
    return icon;
}

#pragma mark - Geometry helpers

/// Distance from `child`'s bottom edge to `parent`'s bottom edge, whatever the flip.
static CGFloat W7BottomGap(NSView *child, NSView *parent) {
    NSRect f = child.frame;
    return parent.isFlipped ? NSHeight(parent.bounds) - NSMaxY(f) : NSMinY(f);
}

static CGFloat W7TopGap(NSView *child, NSView *parent) {
    NSRect f = child.frame;
    return parent.isFlipped ? NSMinY(f) : NSHeight(parent.bounds) - NSMaxY(f);
}

/// The pane's frame and autoresizing at the bottom of `host`.
static void W7PlacePane(NSView *pane, NSView *host) {
    CGFloat h = W7ExplorerDetailsPaneHeight;
    NSRect b = host.bounds;
    pane.frame = NSMakeRect(NSMinX(b), host.isFlipped ? NSMaxY(b) - h : NSMinY(b), NSWidth(b), h);
    pane.autoresizingMask = NSViewWidthSizable | (host.isFlipped ? NSViewMinYMargin : NSViewMaxYMargin);
}

/// `item`/`attr` names the content view's bottom edge (the view itself or a layout guide it owns).
static BOOL W7IsContentBottom(id item, NSLayoutAttribute attr, NSView *content) {
    if (attr != NSLayoutAttributeBottom) return NO;
    if (item == content) return YES;
    return [item isKindOfClass:NSLayoutGuide.class] && ((NSLayoutGuide *)item).owningView == content;
}

/// Plans the lift of `content`'s children by `h` and applies it only when every needed change is
/// possible. Idempotent: lifted frames carry a marker, constraints keep their original constant.
/// Returns NO (and changes nothing) when some child can't be lifted; `reason` says which.
static BOOL W7LiftContentForDetailsPane(NSView *content, NSView *_Nullable pane, NSString *_Nullable *_Nullable reason) {
    CGFloat h = W7ExplorerDetailsPaneHeight;
    CGFloat height = NSHeight(content.bounds);
    BOOL flipped = content.isFlipped;
    NSMutableArray<void (^)(void)> *actions = [NSMutableArray array];
    for (NSView *child in content.subviews) {
        if (child == pane) continue;
        CGFloat bottom = W7BottomGap(child, content);
        if (child.translatesAutoresizingMaskIntoConstraints) {
            NSValue *liftedTo = objc_getAssociatedObject(child, kLiftedKey);   // the frame we gave it
            // Moved once already: leave it while it is clear of the pane or still where we put it.
            if (liftedTo && (bottom >= h - 0.5 || NSEqualRects(liftedTo.rectValue, child.frame))) continue;
            if (bottom >= height / 2) continue;              // upper-half views stay where they are
            // Only a view that stretches with the content and is pinned to its bottom shrinks (its top
            // stays put); anything else just moves, so nothing ratchets smaller on every re-lift.
            NSAutoresizingMaskOptions mask = child.autoresizingMask;
            BOOL fixedBottom = !(mask & (flipped ? NSViewMaxYMargin : NSViewMinYMargin));
            BOOL shrink = W7TopGap(child, content) <= 0.5 && (mask & NSViewHeightSizable) && fixedBottom;
            NSRect f = child.frame;
            if (shrink && NSHeight(f) - h < 1) {
                if (reason) *reason = [NSString stringWithFormat:@"%@ is too short to lift", NSStringFromClass(child.class)];
                return NO;
            }
            // Move BY h (away from the bottom); a shrinking view gives up h of height instead.
            if (!flipped) { f.origin.y += h; if (shrink) f.size.height -= h; }
            else if (shrink) f.size.height -= h;
            else f.origin.y -= h;
            [actions addObject:^{
                child.frame = f;
                objc_setAssociatedObject(child, kLiftedKey, [NSValue valueWithRect:f], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }];
            continue;
        }
        BOOL found = NO;
        for (NSLayoutConstraint *c in content.constraints) {
            if (!c.active || c.relation != NSLayoutRelationEqual) continue;
            CGFloat sign = 0;
            if (c.firstItem == child && c.firstAttribute == NSLayoutAttributeBottom && W7IsContentBottom(c.secondItem, c.secondAttribute, content)) sign = -1;
            else if (c.secondItem == child && c.secondAttribute == NSLayoutAttributeBottom && W7IsContentBottom(c.firstItem, c.firstAttribute, content)) sign = 1;
            if (sign == 0) continue;
            found = YES;
            NSNumber *original = objc_getAssociatedObject(c, kOriginalConstantKey);
            NSNumber *lastTarget = objc_getAssociatedObject(c, kLastTargetKey);
            // A constant other than the one we last set means Finder changed it: that's the new original.
            BOOL ours = original && lastTarget && c.constant == lastTarget.doubleValue;
            CGFloat base = ours ? original.doubleValue : c.constant;
            CGFloat target = base + sign * h;   // child.bottom = content.bottom + c: −h lifts it
            if (ours) continue;
            [actions addObject:^{
                objc_setAssociatedObject(c, kOriginalConstantKey, @(base), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(c, kLastTargetKey, @(target), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                c.constant = target;
            }];
        }
        // A view stacked on a sibling (its bottom tied to the sibling's top) moves with that sibling.
        if (!found) {
            for (NSLayoutConstraint *c in content.constraints) {
                if (!c.active) continue;
                BOOL childBottomFirst = c.firstItem == child && c.firstAttribute == NSLayoutAttributeBottom &&
                                        [content.subviews containsObject:c.secondItem] && c.secondAttribute == NSLayoutAttributeTop;
                BOOL childBottomSecond = c.secondItem == child && c.secondAttribute == NSLayoutAttributeBottom &&
                                         [content.subviews containsObject:c.firstItem] && c.firstAttribute == NSLayoutAttributeTop;
                if (childBottomFirst || childBottomSecond) { found = YES; break; }
            }
        }
        if (!found && bottom < h - 0.5) {
            if (reason) *reason = [NSString stringWithFormat:@"%@ has no bottom constraint to the content", NSStringFromClass(child.class)];
            return NO;
        }
    }
    for (void (^action)(void) in actions) action();
    return YES;
}

/// The browser side of the first split view at or under `content` (breadth-first, bounded). Also the Computer
/// view's host (W7ExplorerComputerView.m).
NSView *W7ExplorerBrowserPaneHost(NSView *content) {
    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:content];
    NSUInteger visited = 0;
    while (queue.count && visited < 400) {
        NSView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if ([v isKindOfClass:NSSplitView.class]) {
            NSSplitView *split = (NSSplitView *)v;
            NSView *last = split.arrangedSubviews.lastObject;
            if (!last && split.arrangesAllSubviews) last = split.subviews.lastObject;
            return last;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

@implementation W7ExplorerDetailsController {
    __weak NSWindow *_window;
    __weak W7ExplorerController *_explorer;
    __weak NSView *_content;   // the content view the mode was chosen for
    __weak NSView *_host;
    W7ExplorerDetailsView *_view;
    W7DetailsMode _mode;
    BOOL _liftFailed;
    NSString *_liftFailure;
    CFAbsoluteTime _lastMaintain;
    W7ExplorerSelectionSnapshot *_shownSelection;   // what the view shows, to skip unchanged refreshes
    W7ExplorerLocation *_shownLocation;
    BOOL _showingComputer;                           // the Computer view's details are shown
    NSUInteger _shownComputerChange;                 // its changeCount when they were
    QLThumbnailGenerationRequest *_thumbnailRequest; // in flight for the shown selection
}

+ (instancetype)installInWindow:(NSWindow *)window explorer:(W7ExplorerController *)explorer {
    @try {
        if (!window.contentView) return nil;
        W7ExplorerDetailsController *d = [[self alloc] init];
        d->_window = window;
        d->_explorer = explorer;
        [d w7Install];
        return d;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer details pane install failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

- (void)w7Install {
    NSView *content = _window.contentView;
    [_view removeFromSuperview];
    _content = content;
    _host = nil;
    _mode = W7DetailsModeNone;
    if (!content) return;
    if (!_view) _view = [[W7ExplorerDetailsView alloc] initWithFrame:NSMakeRect(0, 0, 100, W7ExplorerDetailsPaneHeight)];
    [self w7ShowSelection];

    NSString *reason = nil;
    if (![content isKindOfClass:NSSplitView.class]) {
        [content layoutSubtreeIfNeeded];   // Auto Layout children need real frames to be judged
        if (W7LiftContentForDetailsPane(content, nil, &reason)) {
            W7PlacePane(_view, content);
            [content addSubview:_view positioned:NSWindowAbove relativeTo:nil];
            _host = content;
            _mode = W7DetailsModeLifted;
            os_log(W7Log(), "Explorer: details pane installed (content lifted, content %{public}@)", NSStringFromClass(content.class));
            return;
        }
    } else {
        reason = @"the content view is a split view";
    }
    NSView *host = W7ExplorerBrowserPaneHost(content);
    if (!host) {
        os_log(W7Log(), "Explorer: details pane skipped (%{public}@; no split view browser pane to float in)", reason ?: @"unknown");
        return;
    }
    W7PlacePane(_view, host);
    [host addSubview:_view positioned:NSWindowAbove relativeTo:nil];
    _host = host;
    _mode = W7DetailsModeOverlay;
    [self w7InsetScrollViews];
    os_log(W7Log(), "Explorer: details pane installed (overlay in %{public}@, %{public}@)", NSStringFromClass(host.class), reason ?: @"");
}

/// Overlay mode: scroll views in the host whose bottom is under the pane get a bottom inset.
- (void)w7InsetScrollViews {
    NSView *host = _host;
    if (!host) return;
    NSRect hostInWindow = [host convertRect:host.bounds toView:nil];
    // A browser pane that is itself a scroll view is inset directly (the pane floats above its clip view).
    NSMutableArray<NSView *> *queue = [host isKindOfClass:NSScrollView.class] ? [NSMutableArray arrayWithObject:host]
                                                                             : [NSMutableArray arrayWithArray:host.subviews];
    NSUInteger visited = 0;
    while (queue.count && visited < 4000) {
        NSView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (v == _view) continue;
        if ([v isKindOfClass:NSScrollView.class]) {
            NSScrollView *sv = (NSScrollView *)v;
            NSRect inWindow = [sv convertRect:sv.bounds toView:nil];
            if (NSMinY(inWindow) < NSMinY(hostInWindow) + W7ExplorerDetailsPaneHeight && !objc_getAssociatedObject(sv, kInsetKey)) {
                objc_setAssociatedObject(sv, kInsetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSEdgeInsets in = sv.contentInsets;
                sv.automaticallyAdjustsContentInsets = NO;
                in.bottom = MAX(in.bottom, W7ExplorerDetailsPaneHeight);
                sv.contentInsets = in;
            }
            continue;   // a scroll view's insides are its own business
        }
        [queue addObjectsFromArray:v.subviews];
    }
}

- (void)refresh {
    @try {
        [self w7ShowSelection];
        [self w7Maintain];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer details refresh failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark Content

/// Text and icons for the explorer's selection (or its folder), when either changed since last time.
- (void)w7ShowSelection {
    W7ExplorerController *ex = _explorer;
    W7ExplorerSelectionSnapshot *selection = ex.selection;
    W7ExplorerLocation *location = ex.location;
    W7ExplorerDetailsView *view = _view;
    if (!view) return;
    // On Finder's Computer location the Computer view's selection (a drive, or the computer) is shown instead.
    W7ExplorerComputerController *computer = ex.computer;
    if (computer.shown) {
        if (_showingComputer && _shownComputerChange == computer.changeCount) return;
        _showingComputer = YES;
        _shownComputerChange = computer.changeCount;
        [self w7CancelThumbnail];
        view.content = computer.detailsContent;
        view.icons = computer.detailsIcons;
        return;
    }
    BOOL leftComputer = _showingComputer;
    _showingComputer = NO;
    if (!leftComputer && selection == _shownSelection && location == _shownLocation) return;
    BOOL selectionChanged = selection != _shownSelection || leftComputer;
    _shownSelection = selection;
    _shownLocation = location;
    if (selection.unread) {   // over W7ExplorerSelectionReadLimit: the count only
        [self w7CancelThumbnail];
        view.content = W7ExplorerDetailsForUnreadSelection((NSUInteger)MAX(selection.selectedCount, 0));
        NSImage *many = [NSImage imageNamed:NSImageNameMultipleDocuments];
        view.icons = many ? @[ many ] : @[];
        return;
    }
    NSArray<W7ExplorerItemInfo *> *items = selection.items ?: @[];
    view.content = W7ExplorerDetailsForItems(items, location.segments.lastObject[@"title"] ?: @"", location.itemCount,
                                             NSLocale.currentLocale, NSTimeZone.localTimeZone);
    if (items.count == 0) {
        [self w7CancelThumbnail];
        view.icons = @[ location.icon ?: [NSImage imageNamed:NSImageNameFolder] ];
        return;
    }
    if (!selectionChanged) return;   // only the folder's count changed: the selection's icons stay
    [self w7CancelThumbnail];
    NSMutableArray<NSImage *> *icons = [NSMutableArray array];
    CGFloat side = items.count == 1 ? kThumbnailSide : 40;
    for (W7ExplorerItemInfo *item in items) {
        NSImage *icon = W7IconForURL(item.url, side);
        if (icon) [icons addObject:icon];
        if (icons.count == kMaxStackedIcons) break;
    }
    view.icons = icons;
    if (items.count == 1 && W7WantsThumbnail(items.firstObject)) [self w7RequestThumbnailFor:items.firstObject.url];
}

- (void)w7CancelThumbnail {
    QLThumbnailGenerationRequest *request = _thumbnailRequest;
    _thumbnailRequest = nil;
    if (request) [[W7QuickLookClass(@"QLThumbnailGenerator") sharedGenerator] cancelRequest:request];
}

/// Asks Quick Look for a 48 pt thumbnail; it replaces the icon if the selection is still the same.
- (void)w7RequestThumbnailFor:(NSURL *)url {
    Class requestClass = W7QuickLookClass(@"QLThumbnailGenerationRequest"), generatorClass = W7QuickLookClass(@"QLThumbnailGenerator");
    if (!url || !requestClass || !generatorClass) return;
    CGFloat scale = _window.backingScaleFactor ?: 2;
    QLThumbnailGenerationRequest *request = [[requestClass alloc] initWithFileAtURL:url size:CGSizeMake(kThumbnailSide, kThumbnailSide)
        scale:scale representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
    if (!request) return;
    _thumbnailRequest = request;
    __weak W7ExplorerDetailsController *weakSelf = self;
    [[generatorClass sharedGenerator] generateBestRepresentationForRequest:request
                                                         completionHandler:^(QLThumbnailRepresentation *thumbnail, NSError *error) {
        NSImage *image = thumbnail.NSImage;
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            W7ExplorerDetailsController *s = weakSelf;
            if (!s || s->_thumbnailRequest != request) return;   // cancelled or superseded
            s->_thumbnailRequest = nil;
            @try { s->_view.icons = @[ image ]; }
            @catch (NSException *e) { os_log_error(W7Log(), "Explorer thumbnail failed: %{public}@", e.reason ?: @"unknown"); }
        });
    }];
}

/// Finder may lay its content out again (view switches, sidebar toggles) or replace its content view:
/// keep the content clear of the pane and the pane on top, at most once a second.
- (void)w7Maintain {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastMaintain < kMaintainInterval) return;
    _lastMaintain = now;
    NSWindow *w = _window;
    if (!w) return;
    NSView *host = _host;
    if (w.contentView != _content || (_mode != W7DetailsModeNone && (!host || host.window != w))) {
        [self w7Install];
        return;
    }
    W7ExplorerDetailsView *v = _view;
    if (_mode == W7DetailsModeNone || !v.superview) return;
    if (_mode == W7DetailsModeLifted) {
        NSString *reason = nil;
        BOOL ok = W7LiftContentForDetailsPane(host, v, &reason);
        // Logged when the state changes (and with a new reason), not on every maintenance pass.
        if (!ok && (!_liftFailed || ![reason isEqualToString:_liftFailure]))
            os_log(W7Log(), "Explorer: details pane lift no longer possible (%{public}@)", reason ?: @"unknown");
        else if (ok && _liftFailed)
            os_log(W7Log(), "Explorer: details pane lift possible again");
        _liftFailed = !ok;
        _liftFailure = ok ? nil : [reason copy];
    } else {
        [self w7InsetScrollViews];
    }
    if (host.subviews.lastObject != v) [host addSubview:v positioned:NSWindowAbove relativeTo:nil];
}

@end
