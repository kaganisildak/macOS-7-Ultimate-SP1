// Internet Explorer 7/8 navigation row for Safari: back/forward first, the address item next and growing,
// Safari's other items together at the right (the search box slot), no flexible spaces, nothing centred.
//
// Public NSToolbar API only (-removeItemAtIndex:, -insertItemWithItemIdentifier:atIndex:, centeredItemIdentifiers,
// autosavesConfiguration); no item view is modified. The address item is never removed: other items move around
// it. Safari's toolbar is restored exactly (item order, centred identifiers, autosave flag) when the last themed
// window using that toolbar identifier is un-themed or closes. While themed, autosave is off on every toolbar with
// the identifier (NSToolbars with one identifier share their configuration), so Safari's saved toolbar is never
// changed. Items Safari or the user add or remove while themed are taken into the saved order and ours is re-applied
// once (coalesced, at most 5 times in 10 s). Kill switch: `defaults write -g W7SafariToolbarOrderDisabled -bool YES`.
#import "W7SafariInternal.h"

static NSString *const kBackForward = @"BackForwardToolbarIdentifier";
static NSString *const kAddress = @"InputFieldsToolbarIdentifier";

#pragma mark - Pure

BOOL W7SafariToolbarItemIsSpacer(NSString *identifier) {
    return [identifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier] || [identifier isEqualToString:NSToolbarSpaceItemIdentifier] ||
           [identifier isEqualToString:@"SidebarSeparatorToolbarItemIdentifier"] || [identifier hasSuffix:@"SeparatorItemIdentifier"] ||
           [identifier isEqualToString:@"NSToolbarSidebarTrackingSeparatorItemIdentifier"];
}

NSArray<NSString *> *W7SafariIEToolbarOrder(NSArray<NSString *> *identifiers) {
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    if ([identifiers containsObject:kBackForward]) [order addObject:kBackForward];
    if ([identifiers containsObject:kAddress]) [order addObject:kAddress];
    for (NSString *identifier in identifiers)   // everything else, in Safari's order, at the right
        if (![identifier isEqualToString:kBackForward] && ![identifier isEqualToString:kAddress] && !W7SafariToolbarItemIsSpacer(identifier))
            [order addObject:identifier];
    return order;
}

/// One edit: remove the item at `index`, or insert `identifier` at `index`.
static void W7SafariApplyEdit(NSMutableArray<NSString *> *list, BOOL insert, NSUInteger index, NSString *identifier) {
    if (insert) [list insertObject:identifier atIndex:MIN(index, list.count)];
    else if (index < list.count) [list removeObjectAtIndex:index];
}

NSArray<NSDictionary *> *W7SafariToolbarEdits(NSArray<NSString *> *current, NSArray<NSString *> *target, NSString *protectedIdentifier) {
    NSMutableArray<NSDictionary *> *edits = [NSMutableArray array];
    NSMutableArray<NSString *> *list = [current mutableCopy];
    void (^edit)(BOOL, NSUInteger, NSString *) = ^(BOOL insert, NSUInteger index, NSString *identifier) {
        W7SafariApplyEdit(list, insert, index, identifier);
        [edits addObject:@{ @"insert": @(insert), @"index": @(index), @"identifier": identifier }];
    };
    for (NSUInteger guard = 0; guard < 4 * (current.count + target.count) + 8 && ![list isEqualToArray:target]; guard++) {
        NSUInteger k = 0;
        while (k < list.count && k < target.count && [list[k] isEqualToString:target[k]]) k++;
        if (k >= target.count) { edit(NO, k, list[k]); continue; }   // extras at the end
        NSString *want = target[k], *have = k < list.count ? list[k] : nil;
        if (have && [have isEqualToString:protectedIdentifier]) {
            // Never move the protected item: whatever is wanted here comes from after it.
            NSUInteger j = [list indexOfObject:want inRange:NSMakeRange(k + 1, list.count - k - 1)];
            if (j != NSNotFound) edit(NO, j, want);
            edit(YES, k, want);
            continue;
        }
        if (have && [want isEqualToString:protectedIdentifier]) {   // move what is in its way to after it
            NSUInteger targetIndex = [target indexOfObject:have inRange:NSMakeRange(k + 1, target.count - k - 1)];
            edit(NO, k, have);
            if (targetIndex != NSNotFound) edit(YES, MIN(targetIndex, list.count), have);
            continue;
        }
        NSUInteger j = have ? [list indexOfObject:want inRange:NSMakeRange(k + 1, list.count - k - 1)] : NSNotFound;
        if (j != NSNotFound) edit(NO, j, want);
        edit(YES, k, want);
    }
    return [list isEqualToArray:target] ? edits : nil;
}

#pragma mark - Live toolbar

static BOOL gOrderEnabled;
void W7SafariToolbarOrderSetEnabled(BOOL enabled) { gOrderEnabled = enabled; }

/// What Safari had, per toolbar identifier (shared by every window using it).
@interface W7SafariToolbarSnapshot : NSObject
@property (nonatomic, strong) NSMutableArray<NSString *> *order;
@property (nonatomic, strong) NSSet<NSString *> *centered;
@property (nonatomic, strong) NSHashTable<NSWindow *> *windows;     // themed windows using it
@property (nonatomic) BOOL editing, pending, loggedAfter;
@property (nonatomic) NSInteger reapplies;
@property (nonatomic) CFTimeInterval reapplyWindow;
@end
@implementation W7SafariToolbarSnapshot
@end

static NSMutableDictionary<NSString *, W7SafariToolbarSnapshot *> *gSnapshots;
static const void *kAutosaveKey = &kAutosaveKey;   // on a toolbar: its own autosave flag before we turned it off

static NSArray<NSString *> *W7SafariToolbarIdentifiers(NSToolbar *t) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSToolbarItem *item in t.items) [ids addObject:item.itemIdentifier ?: @"?"];
    return ids;
}

/// Every open window's toolbar with `identifier` (they share one configuration).
static void W7SafariForEachToolbar(NSString *identifier, void (^body)(NSToolbar *t)) {
    for (NSWindow *w in NSApp.windows) if ([w.toolbar.identifier isEqualToString:identifier]) body(w.toolbar);
}

/// The address item's view width and its toolbar item's limits, for the diagnostics.
static NSString *W7SafariAddressSizing(NSToolbar *t) {
    for (NSToolbarItem *item in t.items)
        if ([item.itemIdentifier isEqualToString:kAddress])
            return [NSString stringWithFormat:@"address item view %.0f wide (window %.0f)", item.view.frame.size.width,
                    item.view.window.frame.size.width];
    return @"no address item";
}

/// Edits `t` from `current` to `target` (public API), marking them ours so the item notifications ignore them.
static BOOL W7SafariEditToolbar(NSToolbar *t, NSArray<NSString *> *target, W7SafariToolbarSnapshot *s) {
    NSArray<NSDictionary *> *edits = W7SafariToolbarEdits(W7SafariToolbarIdentifiers(t), target, kAddress);
    if (!edits) return NO;
    s.editing = YES;
    @try {
        for (NSDictionary *e in edits) {
            NSUInteger index = [e[@"index"] unsignedIntegerValue];
            if ([e[@"insert"] boolValue]) [t insertItemWithItemIdentifier:e[@"identifier"] atIndex:(NSInteger)MIN(index, t.items.count)];
            else if (index < t.items.count) [t removeItemAtIndex:(NSInteger)index];
        }
    } @finally { s.editing = NO; }
    return [W7SafariToolbarIdentifiers(t) isEqualToArray:target];
}

static void W7SafariObserveToolbarChanges(void);

/// Turns `t`'s autosave off (its own flag kept for the restore): it shows a toolbar we reorder, and AppKit syncs the
/// order into every toolbar with that identifier, including new windows' (Cmd-N) and un-themed ones.
static void W7SafariGuardAutosave(NSToolbar *t) {
    if (!t) return;
    if (!objc_getAssociatedObject(t, kAutosaveKey))
        objc_setAssociatedObject(t, kAutosaveKey, @(t.autosavesConfiguration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (t.autosavesConfiguration) t.autosavesConfiguration = NO;   // Safari's saved toolbar stays as it is
}

void W7SafariGuardToolbarAutosave(NSWindow *w) {
    @try {
        NSToolbar *t = w.toolbar;
        if (t.identifier && gSnapshots[t.identifier]) W7SafariGuardAutosave(t);
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari toolbar autosave guard failed: %{public}@", e.reason ?: @"unknown"); }
}

void W7SafariApplyToolbarOrder(NSWindow *w) {
    @try {
        NSToolbar *t = w.toolbar;
        NSString *identifier = t.identifier;
        if (!gOrderEnabled || !t || !identifier) return;
        W7SafariObserveToolbarChanges();
        if (!gSnapshots) gSnapshots = [NSMutableDictionary dictionary];
        W7SafariToolbarSnapshot *s = gSnapshots[identifier];
        if (!s) {
            s = [W7SafariToolbarSnapshot new];
            s.order = [W7SafariToolbarIdentifiers(t) mutableCopy];
            s.centered = t.centeredItemIdentifiers;
            s.windows = [NSHashTable weakObjectsHashTable];
            gSnapshots[identifier] = s;
        }
        [s.windows addObject:w];
        W7SafariForEachToolbar(identifier, ^(NSToolbar *each) { W7SafariGuardAutosave(each); });
        NSArray<NSString *> *before = W7SafariToolbarIdentifiers(t), *target = W7SafariIEToolbarOrder(s.order);
        NSString *sizingBefore = W7SafariAddressSizing(t);
        if (t.centeredItemIdentifiers.count) t.centeredItemIdentifiers = [NSSet set];
        if ([before isEqualToArray:target]) return;
        BOOL ok = W7SafariEditToolbar(t, target, s);
        os_log(W7Log(), "Safari toolbar: IE7 order %{public}s: %{public}@ → %{public}@ (%{public}@; centred %{public}@ cleared)",
               ok ? "applied" : "NOT reached", [before componentsJoinedByString:@","], [W7SafariToolbarIdentifiers(t) componentsJoinedByString:@","],
               sizingBefore, [s.centered.allObjects componentsJoinedByString:@","] ?: @"none");
        if (!s.loggedAfter) {   // the address item's width once the toolbar has laid out again
            s.loggedAfter = YES;
            __weak NSToolbar *weak = t;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                @try { NSToolbar *later = weak; if (later) os_log(W7Log(), "Safari toolbar: after the IE7 order, %{public}@", W7SafariAddressSizing(later)); }
                @catch (NSException *e) {}
            });
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari toolbar order failed: %{public}@", e.reason ?: @"unknown"); }
}

void W7SafariRestoreToolbarOrder(NSWindow *w) {
    @try {
        NSString *identifier = w.toolbar.identifier;
        W7SafariToolbarSnapshot *s = identifier ? gSnapshots[identifier] : nil;
        if (!s) return;
        [s.windows removeObject:w];
        if (s.windows.allObjects.count) return;   // another themed window still shows this toolbar
        [gSnapshots removeObjectForKey:identifier];
        BOOL ok = W7SafariEditToolbar(w.toolbar, s.order, s);
        w.toolbar.centeredItemIdentifiers = s.centered ?: [NSSet set];
        if (ok) W7SafariForEachToolbar(identifier, ^(NSToolbar *each) {   // a partial order is never saved
            NSNumber *autosave = objc_getAssociatedObject(each, kAutosaveKey);
            if (autosave) each.autosavesConfiguration = autosave.boolValue;
            objc_setAssociatedObject(each, kAutosaveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
        os_log(W7Log(), "Safari toolbar: Safari's order %{public}s: %{public}@", ok ? "restored" : "NOT fully restored (autosave left off)",
               [W7SafariToolbarIdentifiers(w.toolbar) componentsJoinedByString:@","]);
    } @catch (NSException *e) { os_log_error(W7Log(), "Safari toolbar restore failed: %{public}@", e.reason ?: @"unknown"); }
}

/// A foreign add/remove (Safari or the user customizing) on a toolbar we reorder: the saved order follows it (added
/// items at the end, removed ones dropped) and ours is applied again on the next pass, at most 5 times in 10 s.
static void W7SafariToolbarChanged(NSNotification *n) {
    NSToolbar *t = n.object;
    W7SafariToolbarSnapshot *s = [t isKindOfClass:NSToolbar.class] && t.identifier ? gSnapshots[t.identifier] : nil;
    if (!s) return;
    W7SafariGuardAutosave(t);   // first, even for our own edits: a toolbar AppKit syncs (Cmd-N) must not save them
    if (s.editing) return;
    NSToolbarItem *item = n.userInfo[@"item"];
    NSString *identifier = [item isKindOfClass:NSToolbarItem.class] ? item.itemIdentifier : nil;
    if (identifier && [n.name isEqualToString:NSToolbarWillAddItemNotification] && ![s.order containsObject:identifier]) [s.order addObject:identifier];
    if (identifier && [n.name isEqualToString:NSToolbarDidRemoveItemNotification]) [s.order removeObject:identifier];
    CFTimeInterval now = CACurrentMediaTime();
    if (now - s.reapplyWindow > 10) s.reapplyWindow = now, s.reapplies = 0;
    if (s.pending || ++s.reapplies > 5) return;
    s.pending = YES;
    __weak W7SafariToolbarSnapshot *weak = s;
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{   // the next run-loop pass, after AppKit's own insertion
        @try {
            W7SafariToolbarSnapshot *snap = weak;
            snap.pending = NO;
            NSWindow *w = snap.windows.allObjects.firstObject;
            if (w) W7SafariApplyToolbarOrder(w);
        } @catch (NSException *e) { os_log_error(W7Log(), "Safari toolbar re-order failed: %{public}@", e.reason ?: @"unknown"); }
    });
    CFRunLoopWakeUp(main);
}

static void W7SafariObserveToolbarChanges(void) {
    static BOOL observing;
    if (observing) return;
    observing = YES;
    for (NSNotificationName name in @[ NSToolbarWillAddItemNotification, NSToolbarDidRemoveItemNotification ])
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) {
            @try { W7SafariToolbarChanged(n); } @catch (NSException *e) {}
        }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        @try { if ([n.object isKindOfClass:NSWindow.class]) W7SafariRestoreToolbarOrder(n.object); } @catch (NSException *e) {}
    }];
}
