// Support for W7SettingsPanel.m: guarded private getters, the per-window change snapshot, the
// sidebar wrapper lookup (the "main Settings window" gate) and the read-only diagnostics, among them the sidebar
// view-tree dump. See W7SettingsPanelInternal.h and Win7ChromeCore.h.
#import "W7SettingsPanelInternal.h"
#import <objc/message.h>
#import <objc/runtime.h>

static const NSUInteger kDiagnosticsMaxDepth = 14, kDiagnosticsMaxLines = 800;

#pragma mark - Guarded private calls

/// `object`'s method for `sel` has one of the `count` encodings in `types`.
BOOL W7SPHasTypes(id object, SEL sel, const char *const *types, size_t count) {
    if (!object || ![object respondsToSelector:sel]) return NO;
    Method m = class_getInstanceMethod(object_getClass(object), sel);
    const char *actual = m ? method_getTypeEncoding(m) : NULL;
    if (!actual) return NO;
    for (size_t i = 0; i < count; i++) if (strcmp(actual, types[i]) == 0) return YES;
    return NO;
}

id W7SPGetObject(id object, SEL sel) {
    static const char *const types[] = { "@16@0:8" };
    if (!W7SPHasTypes(object, sel, types, 1)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

NSString *W7SPGetString(id object, SEL sel) {
    id value = W7SPGetObject(object, sel);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

/// Reads a BOOL getter; `ok` says whether it could.
BOOL W7SPGetBool(id object, SEL sel, BOOL *ok) {
    static const char *const types[] = { "B16@0:8", "c16@0:8" };
    BOOL can = W7SPHasTypes(object, sel, types, 2);
    if (ok) *ok = can;
    return can ? ((BOOL (*)(id, SEL))objc_msgSend)(object, sel) : NO;
}


#pragma mark - Snapshot of every change

static const void *kSnapshotKey = &kSnapshotKey;               // NSWindow: its W7SettingsSnapshot while styled
static const void *kTransitionLinesKey = &kTransitionLinesKey; // NSWindow: the last transition's lines

id W7SPBoxed(id value) { return value ?: NSNull.null; }
id W7SPUnboxed(id value) { return value == NSNull.null ? nil : value; }

/// One property the panel changed: the value it had before the first change, and how to read and put it back.
@interface W7SettingsChange : NSObject
/// Weak: the snapshot never keeps a view, item or window alive (no window → snapshot → window cycle). A
/// target gone by restore time needs nothing put back.
@property (nonatomic, weak) id target;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) id original;   // NSNull for nil
@property (nonatomic, copy) id (^read)(id target);
@property (nonatomic, copy) void (^restore)(id target, id original);
@end

@implementation W7SettingsChange
@end

/// Every change made to one window, in order. Restored in reverse, each change on its own, from the
/// recorded targets (not from a new walk of the view tree, which may have changed since).
@interface W7SettingsSnapshot : NSObject
@property (nonatomic, readonly) NSMutableArray<W7SettingsChange *> *changes;
@end

@implementation W7SettingsSnapshot
- (instancetype)init {
    if ((self = [super init])) _changes = [NSMutableArray array];
    return self;
}
@end

W7SettingsSnapshot *W7SPSnapshotFor(NSWindow *w) { return w ? objc_getAssociatedObject(w, kSnapshotKey) : nil; }

/// The windows styled now (weak), so a pane change without a window can restore them all.
NSHashTable<NSWindow *> *W7SPStyledWindows(void) {
    static NSHashTable<NSWindow *> *windows;
    if (!windows) windows = [NSHashTable weakObjectsHashTable];
    return windows;
}

BOOL W7SPWindowIsStyled(NSWindow *w) { return W7SPSnapshotFor(w) != nil; }

/// Records `target`'s `name` (its value now, before the caller changes it) once per snapshot.
void W7SPRecord(W7SettingsSnapshot *snapshot, id target, NSString *name, id (^read)(id),
                     void (^restore)(id, id)) {
    for (W7SettingsChange *c in snapshot.changes)
        if (c.target == target && [c.name isEqualToString:name]) return;
    W7SettingsChange *change = [W7SettingsChange new];
    change.target = target;
    change.name = name;
    change.read = read;
    change.restore = restore;
    change.original = W7SPBoxed(read(target));
    [snapshot.changes addObject:change];
}

static NSString *W7DescribeValue(id value) {
    value = W7SPUnboxed(value);
    if (!value) return @"nil";
    if ([value isKindOfClass:NSColor.class]) return W7SPColorDescription(value);
    if ([value isKindOfClass:NSAppearance.class]) return ((NSAppearance *)value).name;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    if ([value isKindOfClass:NSString.class]) return value;
    return NSStringFromClass([value class]);
}

/// `name: original → current` for each change.
NSArray<NSString *> *W7SPChangeLines(W7SettingsSnapshot *snapshot) {
    NSMutableArray *lines = [NSMutableArray array];
    for (W7SettingsChange *c in snapshot.changes) {
        NSString *current;
        id target = c.target;
        @try { current = target ? W7DescribeValue(c.read(target)) : @"(gone)"; }
        @catch (NSException *e) { current = @"(unreadable)"; }
        [lines addObject:[NSString stringWithFormat:@"%@: %@ → %@", c.name, W7DescribeValue(c.original), current]];
    }
    return lines;
}

NSString *W7SPChangeName(id target, NSString *property) {
    return [NSString stringWithFormat:@"%@.%@", NSStringFromClass([target class]), property];
}

#pragma mark - Sidebar and window

BOOL W7SPIsSidebarWrapper(NSView *v) {
    if (![NSStringFromClass(v.class) hasSuffix:@"SplitViewItemViewWrapper"]) return NO;
    BOOL ok = NO;
    return W7SPGetBool(v, sel_registerName("isSidebar"), &ok) && ok;
}

BOOL W7SPIsAnyWrapper(NSView *v) { return [NSStringFromClass(v.class) hasSuffix:@"SplitViewItemViewWrapper"]; }

static void W7CollectWrappers(NSView *v, NSMutableArray<NSView *> *out, NSUInteger depth, NSUInteger *budget) {
    if (!v || depth > kProbeMaxDepth || *budget == 0) return;
    (*budget)--;
    if (W7SPIsAnyWrapper(v)) {
        if (W7SPIsSidebarWrapper(v)) [out addObject:v];
        return;   // the other columns are never searched
    }
    for (NSView *sub in v.subviews) W7CollectWrappers(sub, out, depth + 1, budget);
}

NSArray<NSView *> *W7SPSidebarWrappers(NSWindow *w) {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger budget = kProbeMaxViews;
    W7CollectWrappers(w.contentView, out, 0, &budget);
    return out;
}

NSSplitViewItem *W7SPWrapperItem(NSView *wrapper) {
    id item = W7SPGetObject(wrapper, sel_registerName("splitViewItem"));
    return [item isKindOfClass:NSSplitViewItem.class] ? item : nil;
}

/// Puts back every recorded change, last first, each on its own (one failure does not stop the rest), and
/// forgets the snapshot. Returns `name: original → current` for each, read after the restore.
NSArray<NSString *> *W7SPRestoreSnapshot(NSWindow *window) {
    W7SettingsSnapshot *snapshot = W7SPSnapshotFor(window);
    if (!snapshot) return @[];
    objc_setAssociatedObject(window, kSnapshotKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // no re-styling from here on
    [W7SPStyledWindows() removeObject:window];
    for (W7SettingsChange *c in snapshot.changes.reverseObjectEnumerator) {
        id target = c.target;
        if (!target) continue;
        @try { c.restore(target, c.original); }
        @catch (NSException *e) {
            os_log_error(W7Log(), "settings panel: restoring %{public}@ failed: %{public}@", c.name, e.reason ?: @"unknown");
        }
    }
    return W7SPChangeLines(snapshot);
}

void W7SPLogTransition(NSWindow *window, NSString *what, NSArray<NSString *> *lines) {
    objc_setAssociatedObject(window, kTransitionLinesKey, lines, OBJC_ASSOCIATION_COPY_NONATOMIC);
    os_log(W7Log(), "settings panel transition %{public}@ (%lu changes)", what, (unsigned long)lines.count);
    for (NSString *line in lines) os_log(W7Log(), "settings panel transition %{public}@ %{public}@", what, line);
}

/// `defaults write com.apple.systempreferences W7SettingsPanelVerboseLog -bool YES`, read once per launch.
BOOL W7SPVerboseLog(void) {
    static BOOL verbose;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ verbose = [NSUserDefaults.standardUserDefaults boolForKey:@"W7SettingsPanelVerboseLog"]; });
    return verbose;
}

W7SettingsSnapshot *W7SPCreateSnapshot(NSWindow *window) {
    W7SettingsSnapshot *snapshot = [W7SettingsSnapshot new];
    objc_setAssociatedObject(window, kSnapshotKey, snapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [W7SPStyledWindows() addObject:window];
    return snapshot;
}

NSArray<NSString *> *W7SettingsLastTransitionLines(NSWindow *window) {
    return (window ? objc_getAssociatedObject(window, kTransitionLinesKey) : nil) ?: @[];
}

#pragma mark - Diagnostics

NSString *W7SPColorDescription(NSColor *color) {
    if (!color) return @"nil";
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) return color.description;
    return [NSString stringWithFormat:@"#%02X%02X%02X@%.2f", (int)lround(rgb.redComponent * 255),
            (int)lround(rgb.greenComponent * 255), (int)lround(rgb.blueComponent * 255), rgb.alphaComponent];
}

static NSString *W7ViewDiagnostics(NSView *v) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ %@ opaque=%d hidden=%d", NSStringFromClass(v.class),
                          NSStringFromRect(v.frame), v.isOpaque, v.isHidden];
    if (v.layer.backgroundColor) [s appendFormat:@" layerBg=%@", W7SPColorDescription([NSColor colorWithCGColor:v.layer.backgroundColor])];
    if (W7SPIsAnyWrapper(v)) {
        BOOL ok = NO;
        BOOL sidebar = W7SPGetBool(v, sel_registerName("isSidebar"), &ok);
        BOOL floatingLayout = W7SPGetBool(v, sel_registerName("allowsFloatingLayout"), NULL);
        NSSplitViewItem *item = W7SPWrapperItem(v);
        BOOL wants = W7SPGetBool(item, sel_registerName("wantsFloatingAppearance"), NULL);   // read only
        [s appendFormat:@" isSidebar=%d allowsFloatingLayout=%d behavior=%ld wantsFloatingAppearance=%d", sidebar,
                        floatingLayout, item ? (long)item.behavior : -1L, wants];
    }
    if ([v isKindOfClass:NSVisualEffectView.class]) {
        NSVisualEffectView *e = (NSVisualEffectView *)v;
        [s appendFormat:@" material=%ld state=%ld blending=%ld", (long)e.material, (long)e.state, (long)e.blendingMode];
    }
    if ([v isKindOfClass:NSScrollView.class]) [s appendFormat:@" drawsBackground=%d", ((NSScrollView *)v).drawsBackground];
    if ([v isKindOfClass:NSTableView.class]) {
        NSTableView *t = (NSTableView *)v;
        NSTableRowView *row = t.numberOfRows > 0 ? [t rowViewAtRow:0 makeIfNecessary:NO] : nil;
        [s appendFormat:@" style=%ld selectionHighlightStyle=%ld bg=%@ rowView=%@", (long)t.style, (long)t.selectionHighlightStyle,
                        W7SPColorDescription(t.backgroundColor), row ? NSStringFromClass(row.class) : @"none"];
    }
    if ([NSStringFromClass(v.class) hasSuffix:@"RemoteView"]) {
        [s appendFormat:@" serviceName=%@", W7SPGetString(v, sel_registerName("serviceName")) ?: @"?"];
    }
    if (v.appearance) [s appendFormat:@" appearance=%@", v.appearance.name];
    return s;
}

static void W7LogTree(NSView *v, NSUInteger depth, NSUInteger *lines) {
    if (!v || depth > kDiagnosticsMaxDepth || *lines >= kDiagnosticsMaxLines) return;
    (*lines)++;
    os_log(W7Log(), "settings panel tree %{public}@%{public}@",
           [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0], W7ViewDiagnostics(v));
    for (NSView *sub in v.subviews) W7LogTree(sub, depth + 1, lines);
}

NSString *W7SPProbeSummary(NSArray<NSDictionary<NSString *, NSString *> *> *probes) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *p in probes) {
        NSString *resolved = W7SettingsResolvePaneID(p[@"configuration"], p[@"remote"]);
        [parts addObject:[NSString stringWithFormat:@"%@ (configuration %@, remote %@, excluded %d)", resolved ?: @"unknown",
                          p[@"configuration"] ?: @"-", p[@"remote"] ?: @"-",
                          W7SettingsProbeIsExcluded(p[@"configuration"], p[@"remote"])]];
    }
    return parts.count ? [parts componentsJoinedByString:@"; "] : @"none";
}

void W7SPLogDiagnostics(NSWindow *w, NSString *summary) {
    os_log(W7Log(), "settings panel window %{public}@ id=%{public}@ bg=%{public}@ appearance=%{public}@ effective=%{public}@: %{public}@",
           NSStringFromClass(w.class), w.identifier ?: @"-", W7SPColorDescription(w.backgroundColor),
           w.appearance.name ?: @"-", w.effectiveAppearance.name ?: @"-", summary);
    // The view tree only with `defaults write com.apple.systempreferences W7SettingsPanelVerboseLog -bool YES`.
    if (!W7SPVerboseLog()) return;
    NSUInteger lines = 0;
    W7LogTree(w.contentView, 0, &lines);
    if (lines >= kDiagnosticsMaxLines) os_log(W7Log(), "settings panel tree truncated at %lu lines", (unsigned long)lines);
}

#pragma mark - Sidebar view-tree diagnostics

// Behind `defaults write -g W7SettingsVerboseLog -bool YES`, once per System Settings main window, a second after it
// first becomes key or main: the sidebar pane's view tree only (class names, frames, whether the list is an
// NSOutlineView/NSTableView with NSTableCellView rows holding an NSImageView + NSTextField, or a SwiftUI host; the
// glass containers; row counts), so the band's scope can be fixed. Public API only, nothing drawn, set, made or hooked.
// The pane content area is never walked: the sidebar is found through the split view controller's sidebar item, and
// the fallback search for a split view stops at it (and at a remote view). Names and numbers only: never a row title,
// string value, tool tip, accessibility label, identifier, image name or window title.
// Kill switch: `defaults write -g W7SettingsSidebarDisabled -bool YES` skips even the dump.

static NSInteger gSidebarDisabledOverride = -1, gSettingsVerboseOverride = -1;
static const void *kSidebarDumpedKey = &kSidebarDumpedKey;   // on a window: its dump is scheduled or done
enum { kSidebarVCMaxDepth = 8, kSidebarVCMax = 200, kSidebarInventoryMaxDepth = 40, kSidebarInventoryMaxViews = 2000,
       kSidebarLinesPerKind = 10, kSidebarRowSamples = 3, kSidebarTreeDepth = 24, kSidebarTreeViews = 400, kSidebarClassNameMax = 160 };

static BOOL W7SPReadDefault(NSString *key) {
    @try { return [NSUserDefaults.standardUserDefaults boolForKey:key]; }
    @catch (NSException *e) { return NO; }
}

BOOL W7SettingsSidebarDisabled(void) {
    if (gSidebarDisabledOverride >= 0) return gSidebarDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ disabled = W7SPReadDefault(@"W7SettingsSidebarDisabled"); });
    return disabled;
}

void W7SettingsSidebarUseDisabledOverride(NSInteger value) { gSidebarDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

BOOL W7SettingsVerboseLog(void) {
    if (gSettingsVerboseOverride >= 0) return gSettingsVerboseOverride == 1;
    static BOOL verbose;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ verbose = W7SPReadDefault(@"W7SettingsVerboseLog"); });
    return verbose;
}

void W7SettingsUseVerboseLogOverride(NSInteger value) { gSettingsVerboseOverride = value < 0 ? -1 : (value ? 1 : 0); }

BOOL W7SettingsSidebarShouldDump(NSString *bundleID, BOOL hasSidebar, BOOL disabled, BOOL verbose, BOOL alreadyDumped) {
    return [bundleID isKindOfClass:NSString.class] && [bundleID isEqualToString:@"com.apple.systempreferences"] && hasSidebar &&
           !disabled && verbose && !alreadyDumped;
}

#pragma mark Finding the sidebar pane (public API)

/// `v`'s ancestor (or `v`) that is a direct subview of `split`.
static NSView *W7SPPaneOf(NSSplitView *split, NSView *v) {
    for (NSView *a = v; a && split; a = a.superview) if (a.superview == split) return a;
    return nil;
}

/// The controller's sidebar pane, from views that exist already (no view is loaded).
static NSView *W7SPControllerSidebarPane(NSSplitViewController *c, NSSplitViewItem *__autoreleasing *outItem) {
    if (![c isKindOfClass:NSSplitViewController.class] || !c.isViewLoaded) return nil;
    for (NSSplitViewItem *item in c.splitViewItems) {
        if (item.behavior != NSSplitViewItemBehaviorSidebar) continue;
        NSView *pane = W7SPPaneOf(c.splitView, item.viewController.viewIfLoaded);
        if (pane && outItem) *outItem = item;
        if (pane) return pane;
    }
    return nil;
}

/// The first split view controller with a sidebar pane in the view controller tree. A split view controller's own
/// children (its panes' controllers, the content's among them) are never searched.
static NSSplitViewController *W7SPFindSplitController(NSViewController *vc, NSUInteger depth, NSUInteger *budget) {
    if (!vc || depth > kSidebarVCMaxDepth || *budget == 0) return nil;
    (*budget)--;
    if ([vc isKindOfClass:NSSplitViewController.class])
        return W7SPControllerSidebarPane((NSSplitViewController *)vc, NULL) ? (NSSplitViewController *)vc : nil;
    for (NSViewController *child in vc.childViewControllers) {
        NSSplitViewController *found = W7SPFindSplitController(child, depth + 1, budget);
        if (found) return found;
    }
    return nil;
}

/// A pane's remote content (NSRemoteView) or its extension host's view: never descended into.
static BOOL W7SPIsPaneContentView(NSView *v) {
    if ([NSStringFromClass(v.class) hasSuffix:@"RemoteView"]) return YES;
    id responder = v.nextResponder;
    return [responder isKindOfClass:NSViewController.class] && [NSStringFromClass([responder class]) containsString:@"EXHost"];
}

/// The first split view under `v`; never descends into one, nor into pane content.
static NSSplitView *W7SPFirstSplitView(NSView *v, NSUInteger depth, NSUInteger *budget) {
    if (!v || depth > kProbeMaxDepth || *budget == 0) return nil;
    (*budget)--;
    if ([v isKindOfClass:NSSplitView.class]) return (NSSplitView *)v;
    if (W7SPIsPaneContentView(v)) return nil;
    for (NSView *sub in v.subviews) {
        NSSplitView *found = W7SPFirstSplitView(sub, depth + 1, budget);
        if (found) return found;
    }
    return nil;
}

static NSView *W7SPFindSidebar(NSWindow *w, NSString *__autoreleasing *source, NSSplitViewItem *__autoreleasing *item,
                               NSSplitViewController *__autoreleasing *controller) {
    NSUInteger budget = kSidebarVCMax;
    NSSplitViewController *c = W7SPFindSplitController(w.contentViewController, 0, &budget);
    if (!c) {
        NSUInteger views = kProbeMaxViews;
        NSSplitView *split = W7SPFirstSplitView(w.contentView, 0, &views);
        id delegate = split.delegate;
        if ([delegate isKindOfClass:NSSplitViewController.class] && W7SPControllerSidebarPane(delegate, NULL)) c = delegate;
        else if (split) {
            NSView *first = split.arrangedSubviews.firstObject ?: split.subviews.firstObject;
            if (first && source) *source = @"split-view-first-pane";
            return first;
        }
    }
    if (!c) return nil;
    NSView *pane = W7SPControllerSidebarPane(c, item);
    if (pane && source) *source = @"split-view-controller";
    if (pane && controller) *controller = c;
    return pane;
}

NSView *W7SettingsSidebarPane(NSWindow *w) {
    @try {
        if (![w isKindOfClass:NSWindow.class]) return nil;
        return W7SPFindSidebar(w, NULL, NULL, NULL);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "settings sidebar: lookup failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

#pragma mark The dump (names and numbers only)

static NSString *W7SPRect(NSRect r) {
    return [NSString stringWithFormat:@"(%g,%g %gx%g)", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

/// The object's class name (`-class`: the original class under a KVO subclass), cut at 160 characters.
static NSString *W7SPClassName(id obj) {
    if (!obj) return @"nil";
    NSString *name = @(class_getName([obj class]));
    return name.length > kSidebarClassNameMax ? [[name substringToIndex:kSidebarClassNameMax] stringByAppendingString:@"…"] : name;
}

/// SwiftUI's NSHostingView in the class chain (not AppKit's own _NSCoreHostingView); as W7MessagesLook.m.
static BOOL W7SPIsSwiftUIHost(NSView *v) {
    for (Class c = object_getClass(v); c && c != NSView.class; c = class_getSuperclass(c)) {
        const char *n = class_getName(c);
        if (strstr(n, "CoreHostingView")) continue;
        if (strstr(n, "NSHostingView") || (strstr(n, "HostingView") && strstr(n, "SwiftUI"))) return YES;
    }
    return NO;
}

static BOOL W7SPIsCoreHost(NSView *v) {
    for (Class c = object_getClass(v); c && c != NSView.class; c = class_getSuperclass(c))
        if (strstr(class_getName(c), "CoreHostingView")) return YES;
    return NO;
}

/// An NSVisualEffectView, or a class named *Glass* in the chain (NSGlassEffectView and its containers).
static BOOL W7SPIsGlass(NSView *v) {
    if ([v isKindOfClass:NSVisualEffectView.class]) return YES;
    for (Class c = object_getClass(v); c && c != NSView.class; c = class_getSuperclass(c))
        if (strstr(class_getName(c), "Glass")) return YES;
    return NO;
}

static NSString *W7SPGlassExtra(NSView *v) {
    if (![v isKindOfClass:NSVisualEffectView.class]) return @"";
    NSVisualEffectView *e = (NSVisualEffectView *)v;
    return [NSString stringWithFormat:@" material=%ld blending=%ld state=%ld", (long)e.material, (long)e.blendingMode, (long)e.state];
}

static NSString *W7SPBehaviorName(NSSplitViewItemBehavior b) {
    switch (b) {
        case NSSplitViewItemBehaviorDefault: return @"default";
        case NSSplitViewItemBehaviorSidebar: return @"sidebar";
        case NSSplitViewItemBehaviorContentList: return @"content-list";
        default: return [NSString stringWithFormat:@"%ld", (long)b];
    }
}

/// A cell view: its class, its imageView/textField classes, the image's size and the font's point size; never a
/// string, image name or identifier.
static NSString *W7SPCellDescription(NSView *cell) {
    if (!cell) return @"none";
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ %@", W7SPClassName(cell), W7SPRect(cell.frame)];
    if ([cell isKindOfClass:NSTableCellView.class]) {
        NSTableCellView *t = (NSTableCellView *)cell;
        NSImage *image = t.imageView.image;
        [s appendFormat:@" imageView=%@ image=%@ textField=%@ pointSize=%g", W7SPClassName(t.imageView),
                        image ? [NSString stringWithFormat:@"%gx%g", image.size.width, image.size.height] : @"nil",
                        W7SPClassName(t.textField), t.textField.font.pointSize];
    }
    NSMutableArray<NSString *> *subs = [NSMutableArray array];
    for (NSView *sub in cell.subviews) [subs addObject:W7SPClassName(sub)];
    [s appendFormat:@" subviews=[%@]", [subs componentsJoinedByString:@","]];
    return s;
}

typedef struct {
    NSUInteger views, maxDepth, hosts, coreHosts, glass, lists, outlines, rowViews, cellViews, imageViews, textFields,
               collections, remotes;
    NSInteger rows;
} W7SPSidebarCounts;

static void W7SPSidebarInventory(NSView *v, NSUInteger depth, W7SPSidebarCounts *c,
                                 NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *kinds,
                                 NSTableView *__autoreleasing *firstList) {
    if (c->views >= kSidebarInventoryMaxViews || depth > kSidebarInventoryMaxDepth) return;
    c->views++;
    c->maxDepth = MAX(c->maxDepth, depth);
    NSString *kind = nil, *extra = @"";
    if (W7SPIsPaneContentView(v)) { c->remotes++; return; }   // never descended into
    if (W7SPIsSwiftUIHost(v)) { c->hosts++; kind = @"host"; }
    else if (W7SPIsCoreHost(v)) c->coreHosts++;
    if (W7SPIsGlass(v)) { c->glass++; kind = @"glass"; extra = W7SPGlassExtra(v); }
    if ([v isKindOfClass:NSTableView.class]) {
        NSTableView *t = (NSTableView *)v;
        BOOL outline = [v isKindOfClass:NSOutlineView.class];
        c->lists++;
        if (outline) c->outlines++;
        c->rows += t.numberOfRows;
        if (firstList && !*firstList) *firstList = t;
        NSTableRowView *row = t.numberOfRows > 0 ? [t rowViewAtRow:0 makeIfNecessary:NO] : nil;
        NSView *cell = t.numberOfRows > 0 && t.numberOfColumns > 0 ? [t viewAtColumn:0 row:0 makeIfNecessary:NO] : nil;
        kind = @"list";
        extra = [NSString stringWithFormat:@" %@ rows=%ld cols=%ld rowHeight=%g style=%ld selectionHighlightStyle=%ld "
                                           @"rowSizeStyle=%ld rowView=%@ cellView=%@", outline ? @"outline" : @"table",
                 (long)t.numberOfRows, (long)t.numberOfColumns, t.rowHeight, (long)t.style, (long)t.selectionHighlightStyle,
                 (long)t.effectiveRowSizeStyle, row ? W7SPClassName(row) : @"none", cell ? W7SPClassName(cell) : @"none"];
    } else if ([v isKindOfClass:NSTableRowView.class]) c->rowViews++;
    else if ([v isKindOfClass:NSTableCellView.class]) c->cellViews++;
    else if ([v isKindOfClass:NSImageView.class]) c->imageViews++;
    else if ([v isKindOfClass:NSTextField.class]) c->textFields++;
    else if ([v isKindOfClass:NSCollectionView.class]) { c->collections++; kind = @"collection"; }
    if (kind) {
        NSMutableArray *list = kinds[kind] ?: (kinds[kind] = [NSMutableArray array]);
        if (list.count < kSidebarLinesPerKind)
            [list addObject:[NSString stringWithFormat:@"%@ %@ inWindow=%@ depth=%lu%@", kind, W7SPClassName(v),
                             W7SPRect([v convertRect:v.bounds toView:nil]), (unsigned long)depth, extra]];
    }
    if (strncmp(class_getName(object_getClass(v)), "W7", 2) == 0) return;   // ours: not descended into
    for (NSView *sub in v.subviews) W7SPSidebarInventory(sub, depth + 1, c, kinds, firstList);
}

NSArray<NSString *> *W7SettingsSidebarDump(NSWindow *w) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @try {
        if (![w isKindOfClass:NSWindow.class]) return lines;
        NSString *source = nil;
        NSSplitViewItem *item = nil;
        NSSplitViewController *controller = nil;
        NSView *pane = W7SPFindSidebar(w, &source, &item, &controller);
        if (!pane) {
            [lines addObject:@"sidebar: none found"];
            return lines;
        }
        NSSplitView *split = (NSSplitView *)pane.superview;
        // Never w.title, an identifier or any text.
        NSUInteger index = [split.arrangedSubviews indexOfObjectIdenticalTo:pane];
        [lines addObject:[NSString stringWithFormat:@"sidebar source=%@ split=%@ vertical=%d panes=%lu subviews=%lu paneIndex=%ld pane=%@ "
                                                    @"frame=%@ inWindow=%@ behavior=%@ collapsed=%d controller=%@ itemController=%@ "
                                                    @"window=%@ contentLayoutRect=%@",
                          source, W7SPClassName(split), split.isVertical, (unsigned long)split.arrangedSubviews.count,
                          (unsigned long)split.subviews.count, index == NSNotFound ? -1L : (long)index, W7SPClassName(pane), W7SPRect(pane.frame),
                          W7SPRect([pane convertRect:pane.bounds toView:nil]), item ? W7SPBehaviorName(item.behavior) : @"-",
                          item.isCollapsed, controller ? W7SPClassName(controller) : @"-",
                          item ? W7SPClassName(item.viewController) : @"-", W7SPClassName(w), W7SPRect(w.contentLayoutRect)]];
        // The containers above the pane, up to the window's root view: class and frame only, never their other children.
        NSUInteger level = 0;
        for (NSView *a = split; a && level < kSidebarInventoryMaxDepth; a = a.superview, level++)
            [lines addObject:[NSString stringWithFormat:@"ancestor %lu %@ %@%@%@", (unsigned long)level, W7SPClassName(a),
                              W7SPRect(a.frame), W7SPIsGlass(a) ? @" glass" : @"", W7SPGlassExtra(a)]];
        W7SPSidebarCounts c = {0};
        NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *kinds = [NSMutableDictionary dictionary];
        NSTableView *firstList = nil;
        W7SPSidebarInventory(pane, 0, &c, kinds, &firstList);
        for (NSString *kind in @[ @"host", @"glass", @"list", @"collection" ]) [lines addObjectsFromArray:kinds[kind] ?: @[]];
        // The first rows of the first list, from views that exist already (none is made).
        NSInteger samples = firstList ? MIN((NSInteger)kSidebarRowSamples, firstList.numberOfRows) : 0;
        for (NSInteger r = 0; r < samples; r++) {
            NSTableRowView *rowView = [firstList rowViewAtRow:r makeIfNecessary:NO];
            NSMutableString *row = [NSMutableString stringWithFormat:@"row %ld rowView=%@ selected=%d groupStyle=%d",
                                    (long)r, rowView ? W7SPClassName(rowView) : @"none", [firstList isRowSelected:r],
                                    rowView.isGroupRowStyle];
            if ([firstList isKindOfClass:NSOutlineView.class]) [row appendFormat:@" level=%ld", (long)[(NSOutlineView *)firstList levelForRow:r]];
            for (NSInteger col = 0; col < firstList.numberOfColumns; col++)
                [row appendFormat:@" col %ld: %@", (long)col, W7SPCellDescription([firstList viewAtColumn:col row:r makeIfNecessary:NO])];
            [lines addObject:row];
        }
        [lines addObject:[NSString stringWithFormat:@"summary: views %lu%@, depth %lu, lists %lu, outlines %lu, rows %ld, row views %lu, "
                                                    @"table cell views %lu, image views %lu, text fields %lu, SwiftUI hosts %lu, "
                                                    @"AppKit core hosts %lu, glass containers %lu, collections %lu, remote views %lu",
                          (unsigned long)c.views, c.views >= kSidebarInventoryMaxViews ? @" (capped)" : @"", (unsigned long)c.maxDepth,
                          (unsigned long)c.lists, (unsigned long)c.outlines, (long)c.rows, (unsigned long)c.rowViews,
                          (unsigned long)c.cellViews, (unsigned long)c.imageViews, (unsigned long)c.textFields, (unsigned long)c.hosts,
                          (unsigned long)c.coreHosts, (unsigned long)c.glass, (unsigned long)c.collections, (unsigned long)c.remotes]];
        if (c.remotes == 0) [lines addObjectsFromArray:W7MessagesViewTreeLines(pane, kSidebarTreeDepth, kSidebarTreeViews)];
        else [lines addObject:@"tree not shown: pane content (a remote view) inside the sidebar pane"];
    } @catch (NSException *e) {
        [lines addObject:[NSString stringWithFormat:@"sidebar dump failed: %@", e.reason ?: @"unknown"]];
    }
    return lines;
}

/// os_log truncates long messages: one entry per ~800 characters.
static void W7SPLogSidebarLines(NSArray<NSString *> *lines) {
    NSMutableString *chunk = [NSMutableString string];
    NSUInteger part = 1;
    for (NSString *line in lines) {
        if (chunk.length && chunk.length + line.length > 800) {
            os_log(W7Log(), "settings sidebar diagnostics [%lu]: %{public}@", (unsigned long)part++, chunk);
            [chunk setString:@""];
        }
        [chunk appendFormat:@"%@%@", chunk.length ? @" | " : @"", line];
    }
    if (chunk.length) os_log(W7Log(), "settings sidebar diagnostics [%lu]: %{public}@", (unsigned long)part, chunk);
}

#pragma mark The window path

BOOL W7SettingsSidebarDiagnosticsUpdateForBundle(NSWindow *w, NSString *bundleID) {
    @try {
        if (![w isKindOfClass:NSWindow.class]) return NO;
        BOOL disabled = W7SettingsSidebarDisabled(), verbose = W7SettingsVerboseLog();
        BOOL dumped = objc_getAssociatedObject(w, kSidebarDumpedKey) != nil;
        // The sidebar is searched for only when everything else says yes.
        BOOL hasSidebar = W7SettingsSidebarShouldDump(bundleID, YES, disabled, verbose, dumped) && ![w isKindOfClass:NSPanel.class] &&
                          w.sheetParent == nil && W7SettingsSidebarPane(w) != nil;
        if (!W7SettingsSidebarShouldDump(bundleID, hasSidebar, disabled, verbose, dumped)) return NO;
        objc_setAssociatedObject(w, kSidebarDumpedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak NSWindow *weakWindow = w;
        // A second later: the sidebar list fills in after the window first shows.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            @try {
                NSWindow *win = weakWindow;
                if (!win || W7SettingsSidebarDisabled()) return;
                W7SPLogSidebarLines(W7SettingsSidebarDump(win));
            } @catch (NSException *e) { os_log_error(W7Log(), "settings sidebar diagnostics failed: %{public}@", e.reason ?: @"unknown"); }
        });
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "settings sidebar update failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

void W7SettingsSidebarDiagnosticsUpdate(NSWindow *w) {
    static NSString *bundleID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bundleID = [NSBundle.mainBundle.bundleIdentifier copy]; });
    if (![bundleID isEqualToString:@"com.apple.systempreferences"]) return;   // every other app: one string compare
    W7SettingsSidebarDiagnosticsUpdateForBundle(w, bundleID);
}

