// The Windows 7 navigation pane tree in Finder's sidebar: icons, and the hooks on Finder's
// sidebar cell class.
//
// Static analysis of Finder (task-24 research artifacts: methods.tsv, calls.tsv, the objc dump):
//   - TSidebarView (an NSOutlineView) is driven by TSidebarViewController. -outlineView:viewForTableColumn:
//     item: asks -itemIsZoneHeader: and, for a section header, makes a plain cell with
//     makeViewWithIdentifier:owner: and -setStringValue:; for an item, a TSidebarItemCell
//     (NSTableCellView), finished with -finishMakingWithNode:iconGetter: (the node is kept in the cell's
//     `_node` ivar, a TFENode `{TFENode="fNodeRef"^{OpaqueNodeRef}}`, and the icon comes from a
//     std::function).
//   - -[TSidebarItemCell updateNameAndIcon] does [self.imageView setImage:[self image]], tints it with
//     secondaryLabelColor (SF Symbols are templates), and sets the text field to -name in labelColor.
//     -image builds the icon through the iconGetter at -imageSize (by rowSizeStyle); -layoutDetails (from
//     -viewWillDraw) lays the text out from -_textFieldFrame. Section headers expand and collapse only
//     through AppKit's show/hide button (NSOutlineViewShowHideButtonKey → -_outlineControlClicked:).
// So TSidebarItemCell's -image, -imageSize and -_textFieldFrame are hooked (exact encodings), and an added
// -setFrame: indents the cell where AppKit places it. A row's target is its node's FINode (class,
// fileURL), read through `_node`; without that ivar, its title. Kill switch: W7ExplorerNavPaneDisabled.
#import "Win7ChromeCore.h"
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <time.h>
#import <unistd.h>

static const char *const kNodeIvarTypes = "{TFENode=\"fNodeRef\"^{OpaqueNodeRef}}";
static const char *const kRectGetterTypes = "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8";

#pragma mark - Images

/// Icons by "generation|name|points" (NSImage, or NSNull when there is none): W7UserIconsGeneration changes on
/// every loader reset (a new asset root or new embedded icons), so nothing stale is served.
static NSCache *W7NavIconCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
    });
    return cache;
}

/// The user's icon `name` as a CGImage object `pixels` square (W7UserIconBitmap: `<asset root>/icons/<name>.png`,
/// else the embedded `__w7icons` PNG, drawn aspect-fit). nil when there is none.
static id W7NavAssetBitmap(NSString *name, size_t pixels) {
    return W7UserIconBitmap(name, pixels);
}

/// A `pixels` square bitmap drawn by `draw` (in a non-flipped context of that size).
static id W7NavDrawnBitmap(size_t pixels, void (^draw)(CGContextRef ctx, CGRect rect)) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixels, pixels, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    draw(ctx, CGRectMake(0, 0, pixels, pixels));
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return CFBridgingRelease(img);
}

/// `image`'s representation for `pixels` (W7FolderIconImage gives exact 1x and 2x bitmaps).
static CGImageRef W7NavCGImage(NSImage *image, size_t pixels) {
    NSRect r = NSMakeRect(0, 0, pixels, pixels);
    return [image CGImageForProposedRect:&r context:nil hints:@{ NSImageHintCTM: [NSAffineTransform transform] }];
}

static W7FolderIconKind W7NavFolderKindForName(NSString *name, BOOL *found) {
    for (NSInteger k = 0; k < W7FolderIconKindCount; k++) {
        if ([W7FolderIconAssetName((W7FolderIconKind)k) isEqualToString:name]) { *found = YES; return (W7FolderIconKind)k; }
    }
    *found = NO;
    return W7FolderIconPlain;
}

/// The bitmap for `name` at `pixels` (`points` × scale): the asset, else the drawn fallback.
static id W7NavIconBitmap(NSString *name, CGFloat points, size_t pixels) {
    // The user's PNG only: no drawn stand-in, so Finder's own icon stays while it is absent.
    if ([name isEqualToString:@"recycle-bin-empty"] || [name isEqualToString:@"recycle-bin-full"] ||
        [name isEqualToString:@"recent-places"] || [name isEqualToString:@"shared"]) return W7NavAssetBitmap(name, pixels);
    if ([name isEqualToString:@"w7-star"]) {
        id own = W7NavAssetBitmap(@"favorites", pixels);   // the user's Favorites star first
        if (own) return own;
        return W7NavDrawnBitmap(pixels, ^(CGContextRef ctx, CGRect rect) { W7DrawFavoritesStar(ctx, rect); });
    }
    if ([name isEqualToString:@"user"]) {
        id own = W7NavAssetBitmap(@"user", pixels);
        if (own) return own;
        CGImageRef folder = W7NavCGImage(W7FolderIconImage(W7FolderIconUser, NSMakeSize(points, points)), pixels);
        return folder ? (__bridge id)folder : nil;
    }
    BOOL isFolder = NO;
    W7FolderIconKind kind = W7NavFolderKindForName(name, &isFolder);
    if (isFolder) {
        CGImageRef folder = W7NavCGImage(W7FolderIconImage(kind, NSMakeSize(points, points)), pixels);
        return folder ? (__bridge id)folder : nil;
    }
    if ([name isEqualToString:@"applications"]) {
        CGImageRef folder = W7NavCGImage(W7FolderIconImage(W7FolderIconPlain, NSMakeSize(points, points)), pixels);
        if (!folder) return nil;
        id held = (__bridge id)folder;
        return W7NavDrawnBitmap(pixels, ^(CGContextRef ctx, CGRect rect) {
            CGContextDrawImage(ctx, rect, (__bridge CGImageRef)held);
            CGFloat badge = round(CGRectGetWidth(rect) * 0.62);
            W7DrawNavPaneGlyph(ctx, CGRectMake(CGRectGetMaxX(rect) - badge, 0, badge, badge), W7NavPaneGlyphAppBadge);
        });
    }
    id own = [name hasPrefix:@"w7-"] ? nil : W7NavAssetBitmap(name, pixels);
    if (own) return own;
    NSDictionary<NSString *, NSNumber *> *glyphs = @{
        @"drive-system": @(W7NavPaneGlyphSystemDrive), @"drive": @(W7NavPaneGlyphDrive),
        @"network": @(W7NavPaneGlyphNetwork), @"computer": @(W7NavPaneGlyphComputer),
        @"w7-tag": @(W7NavPaneGlyphTag), @"w7-cloud": @(W7NavPaneGlyphCloud),
    };
    NSNumber *glyph = glyphs[name];
    if (!glyph) return nil;
    return W7NavDrawnBitmap(pixels, ^(CGContextRef ctx, CGRect rect) { W7DrawNavPaneGlyph(ctx, rect, glyph.integerValue); });
}

/// Marks the NSImages made here, so an image view showing one can be told apart from Finder's.
static const void *kOurIconKey = &kOurIconKey;
static NSString *gTrashPath;   // nil: ~/.Trash (tests set a directory)

BOOL W7NavPaneImageIsOurs(NSImage *image) {
    return image && objc_getAssociatedObject(image, kOurIconKey) != nil;
}

/// The last Trash fullness read and when (main thread, monotonic seconds): -image and the restyle ask
/// often, so the directory is read once and then again when a vnode source on it fires (an item put in
/// or emptied), with kTrashTTL as the fallback.
static const double kTrashTTL = 1.5;
static double gTrashReadAt = -1e9;
static BOOL gTrashFull;
static double (^gClock)(void);                       // tests; nil: CLOCK_UPTIME_RAW
static dispatch_source_t gTrashWatch;                // on gTrashWatchPath
static NSString *gTrashWatchPath;
static NSHashTable<NSImageView *> *gTrashImageViews; // image views showing the Recycle Bin (weak)
static const void *kTrashTitleKey = &kTrashTitleKey;
static NSUInteger gTrashWatchFires;

static double W7NavNow(void) {
    return gClock ? gClock() : clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

void W7NavPaneUseClock(double (^clock)(void)) {
    gClock = [clock copy];
}

static NSString *W7NavTrashPath(void) {
    return gTrashPath ?: [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
}

void W7NavPaneUseTrashDirectory(NSString *path) {
    gTrashPath = [path copy];
    gTrashReadAt = -1e9;
}

NSUInteger W7NavPaneTrashWatchFireCount(void) {
    return gTrashWatchFires;
}

/// The Trash changed: forget its fullness and give every Recycle Bin row its current icon (through
/// W7NavPaneSyncRowIcon, which does not ask Finder's -image).
static void W7NavTrashChanged(void) {
    @try {
        gTrashWatchFires++;
        gTrashReadAt = -1e9;
        for (NSImageView *iv in gTrashImageViews.allObjects) {
            NSView *cell = iv.superview;
            while (cell && ![cell isKindOfClass:NSTableCellView.class] && ![cell.superview isKindOfClass:NSTableRowView.class])
                cell = cell.superview;
            W7NavPaneSyncRowIcon(iv, cell, objc_getAssociatedObject(iv, kTrashTitleKey));
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "nav pane trash refresh failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// Watches the current Trash directory (re-armed when it changes). The handler runs on the main run
/// loop (CFRunLoopPerformBlock, so a nested run loop serves it too).
static void W7NavWatchTrash(NSString *path) {
    if ([gTrashWatchPath isEqualToString:path] && gTrashWatch) return;
    if (gTrashWatch) dispatch_source_cancel(gTrashWatch);
    gTrashWatch = nil;
    gTrashWatchPath = [path copy];
    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (!source) {
        close(fd);
        return;
    }
    __weak dispatch_source_t weakSource = source;
    dispatch_source_set_event_handler(source, ^{
        dispatch_source_t fired = weakSource;
        BOOL gone = fired && (dispatch_source_get_data(fired) & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME));
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
            // The directory itself went away or moved: watch it afresh on the next read.
            if (gone && gTrashWatch == fired) {
                dispatch_source_cancel(fired);
                gTrashWatch = nil;
            }
            W7NavTrashChanged();
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    gTrashWatch = source;
    dispatch_resume(source);
}

/// Remembers an image view that shows the Recycle Bin, for W7NavTrashChanged.
static void W7NavNoteTrashImageView(NSImageView *iv, NSString *title) {
    if (!iv) return;
    if (!gTrashImageViews) gTrashImageViews = [NSHashTable weakObjectsHashTable];
    [gTrashImageViews addObject:iv];
    objc_setAssociatedObject(iv, kTrashTitleKey, title, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static BOOL W7NavTrashIsFullCached(void) {
    NSString *path = W7NavTrashPath();
    W7NavWatchTrash(path);
    double now = W7NavNow();
    if (now - gTrashReadAt >= kTrashTTL) {
        gTrashFull = W7NavPaneTrashIsFull(path);
        gTrashReadAt = now;
    }
    return gTrashFull;
}

/// An NSImage of `points` with 1x and 2x bitmaps for `name`, or nil. Cached per asset root, name and
/// size (a miss too), so a cell gets the same image object every time.
static NSImage *W7NavIcon(NSString *name, CGFloat points) {
    if (name.length == 0 || !(points > 0) || points > 512) return nil;
    NSCache *cache = W7NavIconCache();
    NSString *key = [NSString stringWithFormat:@"%lu|%@|%.0f", (unsigned long)W7UserIconsGeneration(), name, points];
    id hit = [cache objectForKey:key];
    if (hit) return hit == NSNull.null ? nil : hit;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(points, points)];
    objc_setAssociatedObject(image, kOurIconKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (CGFloat scale = 1; scale <= 2 && image; scale++) {
        id bitmap = W7NavIconBitmap(name, points, (size_t)ceil(points * scale));
        if (!bitmap) {
            image = nil;
            break;
        }
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)bitmap];
        rep.size = NSMakeSize(points, points);
        [image addRepresentation:rep];
    }
    [cache setObject:image ?: NSNull.null forKey:key];
    return image;
}

NSImage *W7NavPaneIconImage(NSString *name, CGFloat points) {
    @try {
        if ([name isEqualToString:@"recycle-bin"]) {
            BOOL full = W7NavTrashIsFullCached();
            return W7NavIcon(full ? @"recycle-bin-full" : @"recycle-bin-empty", points);
        }
        if ([name hasPrefix:@"w7-"]) return nil;   // internal names only
        return W7NavIcon(name, points);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "nav pane icon %{public}@ failed: %{public}@", name, e.reason ?: @"unknown");
        return nil;
    }
}

NSImage *W7NavPaneGroupIconImage(W7NavPaneGroupKind kind, CGFloat points) {
    @try {
        switch (kind) {
            case W7NavPaneGroupFavorites: return W7NavIcon(@"w7-star", points);
            case W7NavPaneGroupLocations: return W7NavIcon(@"computer", points);
            case W7NavPaneGroupTags: return W7NavIcon(@"w7-tag", points);
            case W7NavPaneGroupCloud: return W7NavIcon(@"w7-cloud", points);
            case W7NavPaneGroupUnknown: break;
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "nav pane group icon failed: %{public}@", e.reason ?: @"unknown");
    }
    return nil;
}

#pragma mark - Cell targets

/// How one hooked cell class reaches its node.
@interface W7NavCellClassInfo : NSObject
@property (nonatomic) ptrdiff_t nodeOffset;   // -1: no `_node` ivar of the expected type
@property (nonatomic, unsafe_unretained) Class nodeClass;
@property (nonatomic) SEL nameSelector;       // Finder's -name (`@16@0:8`), or NULL
@end
@implementation W7NavCellClassInfo
@end

/// The icon name last resolved for a cell, and what it was resolved from.
@interface W7NavCellState : NSObject
@property (nonatomic) const void *ref;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *name;
@end
@implementation W7NavCellState
@end

static NSMutableDictionary<NSValue *, W7NavCellClassInfo *> *gCellClasses;   // main thread
static const void *kCellStateKey = &kCellStateKey;

static W7NavCellClassInfo *W7NavInfoForCell(id cell) {
    for (Class c = object_getClass(cell); c; c = class_getSuperclass(c)) {
        W7NavCellClassInfo *info = gCellClasses[[NSValue valueWithPointer:(__bridge const void *)c]];
        if (info) return info;
    }
    return nil;
}

static NSDictionary<NSString *, NSString *> *W7NavTitleNames(void) {
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = W7NavPaneTitleIconNames(W7FolderIconSpecialPaths()); });
    return names;
}

/// The node ref in the cell's `_node`, or NULL.
static const void *W7NavNodeRef(id cell, W7NavCellClassInfo *info) {
    if (info.nodeOffset < 0) return NULL;
    const char *base = (const char *)(__bridge const void *)cell;
    return *(void *const *)(base + info.nodeOffset);
}

static NSString *W7NavCellTitle(NSView *cell, W7NavCellClassInfo *info) {
    if (info.nameSelector) {
        id name = ((id (*)(id, SEL))objc_msgSend)(cell, info.nameSelector);
        if ([name isKindOfClass:NSString.class]) return name;
    }
    NSTextField *tf = [cell isKindOfClass:NSTableCellView.class] ? ((NSTableCellView *)cell).textField : nil;
    return tf.stringValue ?: @"";
}

#pragma mark - Diagnostics (fix 1: what Finder actually calls)

static NSUInteger gCalls[W7NavPaneHookKindCount];
static NSUInteger gNodeLogs;

static const char *W7NavHookKindName(W7NavPaneHookKind kind) {
    switch (kind) {
        case W7NavPaneHookImage: return "-image";
        case W7NavPaneHookImageSize: return "-imageSize";
        case W7NavPaneHookTextFrame: return "-_textFieldFrame";
        case W7NavPaneHookSetFrame: return "-setFrame:";
        case W7NavPaneHookMovedToWindow: return "-viewDidMoveToWindow";
        case W7NavPaneHookKindCount: break;
    }
    return "?";
}

/// Counts a hook call; the first three of each kind are logged with `detail`.
static void W7NavNoteCall(W7NavPaneHookKind kind, id receiver, NSString *(^detail)(void)) {
    NSUInteger n = ++gCalls[kind];
    if (n > 3 || !W7NavPaneDiagnosticsEnabled()) return;
    W7NavPaneNoteDiagnosticLine();
    os_log(W7Log(), "nav pane hook: %{public}s call %lu on %{public}@: %{public}@", W7NavHookKindName(kind), (unsigned long)n,
           NSStringFromClass(object_getClass(receiver)), detail ? detail() : @"");
}

NSUInteger W7NavPaneHookCallCount(W7NavPaneHookKind kind) {
    return kind >= 0 && kind < W7NavPaneHookKindCount ? gCalls[kind] : 0;
}

NSString *W7NavPaneHookCallSummary(void) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSInteger k = 0; k < W7NavPaneHookKindCount; k++)
        [parts addObject:[NSString stringWithFormat:@"%s %lu", W7NavHookKindName(k), (unsigned long)gCalls[k]]];
    return [parts componentsJoinedByString:@", "];
}

#pragma mark - Node targets

static id W7NavSendObject(id object, const char *name) {
    SEL sel = sel_registerName(name);
    Method m = object ? class_getInstanceMethod(object_getClass(object), sel) : NULL;
    const char *types = m ? method_getTypeEncoding(m) : NULL;
    if (!types || strcmp(types, "@16@0:8") != 0) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

/// `node`'s class name, file path and volume flag.
static void W7NavDescribeNode(id node, NSString **cls, NSString **path, BOOL *volume) {
    *cls = node ? NSStringFromClass(object_getClass(node)) : nil;
    NSURL *url = W7NavSendObject(node, "fileURL");
    *path = [url isKindOfClass:NSURL.class] && url.isFileURL && url.path.length ? url.path : nil;
    *volume = W7NavPanePathIsMountPoint(*path);   // no file I/O on the main thread
}

/// The icon name for a node ref: its FINode's class and file URL, then (sidebar entries are often alias
/// or proxy nodes) its -original's. `decided`: the node settled it — a name, a class whose icon Finder
/// keeps (AirDrop, iCloud, tags…), or a real path (the node's or its original's) that simply has no
/// Windows 7 icon. Only an undecided row is mapped by its title.
static NSString *W7NavNameForNode(const void *ref, Class nodeClass, NSString *title, BOOL *decided) {
    *decided = NO;
    if (!ref) return nil;
    id node = ((id (*)(id, SEL, const void *))objc_msgSend)(nodeClass, sel_registerName("nodeFromNodeRef:"), ref);
    if (!node) return nil;
    NSString *cls, *path;
    BOOL volume;
    W7NavDescribeNode(node, &cls, &path, &volume);
    NSDictionary *special = W7FolderIconSpecialPaths();
    NSString *name = W7NavPaneIconNameForTarget(cls, path, volume, special);
    BOOL keep = W7NavPaneNodeClassKeepsFinderIcon(cls);
    NSString *originalCls = nil, *originalPath = nil;
    if (!name && !keep) {
        id original = W7NavSendObject(node, "original");
        if (original && original != node) {
            BOOL originalVolume;
            W7NavDescribeNode(original, &originalCls, &originalPath, &originalVolume);
            name = W7NavPaneIconNameForTarget(originalCls, originalPath, originalVolume, special);
            keep = W7NavPaneNodeClassKeepsFinderIcon(originalCls);
        }
    }
    *decided = name != nil || keep || path != nil || originalPath != nil;
    if (gNodeLogs < 16 && W7NavPaneDiagnosticsEnabled()) {
        gNodeLogs++;
        W7NavPaneNoteDiagnosticLine();
        os_log(W7Log(), "nav pane node: '%{public}@' %{public}@ path %{public}@ volume %d original %{public}@ %{public}@ -> %{public}@%{public}s",
               title ?: @"", cls ?: @"-", path ?: @"-", volume, originalCls ?: @"-", originalPath ?: @"-", name ?: @"(none)",
               keep ? " (Finder's icon kept)" : (*decided ? "" : " (by title)"));
    }
    return name;
}

NSString *W7NavPaneCellIconName(NSView *cell) {
    @try {
        W7NavCellClassInfo *info = cell ? W7NavInfoForCell(cell) : nil;
        if (!info) return nil;
        const void *ref = W7NavNodeRef(cell, info);
        NSString *title = W7NavCellTitle(cell, info);
        W7NavCellState *state = objc_getAssociatedObject(cell, kCellStateKey);
        // Keyed by the node and the title (Finder asks for the image before it sets the title).
        if (state && state.ref == ref && [state.title isEqualToString:title]) return state.name;
        BOOL decided = NO;
        NSString *name = W7NavNameForNode(ref, info.nodeClass, title, &decided);
        if (!decided) name = W7NavPaneIconNameForTitle(title, W7NavTitleNames());
        state = [W7NavCellState new];
        state.ref = ref;
        state.title = title;
        state.name = name;
        objc_setAssociatedObject(cell, kCellStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return name;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "nav pane cell target failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

#pragma mark - Hooks

/// `cls`'s own (not inherited) method for `sel`, or NULL.
static Method W7NavOwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count && !found; i++)
        if (method_getName(methods[i]) == sel) found = methods[i];
    free(methods);
    return found;
}

/// The own method of `cls` for `name` when its encoding is exactly `types`; logs why not otherwise.
static Method W7NavCheckedMethod(Class cls, const char *name, const char *types) {
    Method m = W7NavOwnMethod(cls, sel_registerName(name));
    const char *actual = m ? method_getTypeEncoding(m) : NULL;
    if (!actual || strcmp(actual, types) != 0) {
        os_log(W7Log(), "nav pane: %{public}@ -%{public}s not hooked (types %{public}s)", NSStringFromClass(cls), name, actual ?: "(missing)");
        return NULL;
    }
    return m;
}

static BOOL W7NavLeftToRight(NSView *view) {
    return view.userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionLeftToRight;
}

/// The frame AppKit asks for, indented when it is exactly where the outline puts this child row's cell
/// (anything else — already indented, a group row, a drag image — passes unchanged).
static NSRect W7NavIndentedFrame(NSView *cell, NSRect frame) {
    NSView *row = cell.superview;
    if (![row isKindOfClass:NSTableRowView.class] || ((NSTableRowView *)row).isGroupRowStyle) return frame;
    NSView *v = row.superview;
    while (v && ![v isKindOfClass:NSOutlineView.class]) v = v.superview;
    NSOutlineView *ov = (NSOutlineView *)v;
    if (!ov || !W7NavPaneTreeActive(ov) || !W7NavLeftToRight(cell)) return frame;
    NSInteger r = [ov rowForView:row], c = [ov columnForView:cell];
    if (r < 0 || c < 0) return frame;
    CGFloat base = NSMinX([ov frameOfCellAtColumn:c row:r]) - NSMinX(row.frame);
    return fabs(NSMinX(frame) - base) < 0.5 ? W7NavPaneIndentedCellFrame(frame, W7NavPaneChildIndent) : frame;
}

/// Overrides NSView's `sel` on `cls` (its encoding must match NSView's): replaces the class's own
/// method, or adds one. `make` builds the replacement from a block that answers the original IMP — the
/// saved own one, or the superclass's looked up per call (someone may hook it later).
static BOOL W7NavOverrideViewMethod(Class cls, SEL sel, id (^make)(IMP (^original)(void))) {
    Method base = class_getInstanceMethod(NSView.class, sel);
    const char *types = base ? method_getTypeEncoding(base) : NULL;
    Method current = class_getInstanceMethod(cls, sel);
    const char *currentTypes = current ? method_getTypeEncoding(current) : NULL;
    if (!types || !currentTypes || strcmp(types, currentTypes) != 0) return NO;
    Method own = W7NavOwnMethod(cls, sel);
    IMP saved = own ? method_getImplementation(own) : NULL;
    id block = make(^IMP { return saved ?: class_getMethodImplementation(class_getSuperclass(cls), sel); });
    if (own) {
        method_setImplementation(own, imp_implementationWithBlock(block));
        return YES;
    }
    return class_addMethod(cls, sel, imp_implementationWithBlock(block), types);
}

/// -setFrame: indents a child cell where AppKit places it. AppKit sets the frame before the cell is in
/// its row view, so -viewDidMoveToWindow (the row is known by then) sets it once more.
static BOOL W7NavHookIndent(Class cls) {
    SEL setFrame = @selector(setFrame:), moved = @selector(viewDidMoveToWindow);
    BOOL frameHooked = W7NavOverrideViewMethod(cls, setFrame, ^id(IMP (^original)(void)) {
        return ^(NSView *cell, NSRect frame) {
            NSRect target = frame;
            @try {
                target = W7NavIndentedFrame(cell, frame);
                W7NavNoteCall(W7NavPaneHookSetFrame, cell, ^NSString * {
                    return [NSString stringWithFormat:@"%@ -> %@ (row view %@)", NSStringFromRect(frame), NSStringFromRect(target),
                            cell.superview ? NSStringFromClass(cell.superview.class) : @"none yet"];
                });
            }
            @catch (NSException *e) { os_log_error(W7Log(), "nav pane indent failed: %{public}@", e.reason ?: @"unknown"); }
            ((void (*)(id, SEL, NSRect))original())(cell, setFrame, target);
        };
    });
    if (!frameHooked) return NO;
    W7NavOverrideViewMethod(cls, moved, ^id(IMP (^original)(void)) {
        return ^(NSView *cell) {
            ((void (*)(id, SEL))original())(cell, moved);
            @try {
                W7NavNoteCall(W7NavPaneHookMovedToWindow, cell, ^NSString * { return cell.window ? @"in a window" : @"out of window"; });
                if (cell.window) cell.frame = cell.frame;
            } @catch (NSException *e) {
                os_log_error(W7Log(), "nav pane indent on move failed: %{public}@", e.reason ?: @"unknown");
            }
        };
    });
    return YES;
}

BOOL W7NavPaneHookCellClass(Class cellClass, Class nodeClass) {
    @try {
        if (!cellClass || !nodeClass || ![cellClass isSubclassOfClass:NSView.class]) return NO;
        if (!gCellClasses) gCellClasses = [NSMutableDictionary dictionary];
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cellClass];
        if (gCellClasses[key]) return YES;
        NSString *name = NSStringFromClass(cellClass);
        // +nodeFromNodeRef: takes the OpaqueNodeRef pointer: exactly FINode's `@24@0:8^{OpaqueNodeRef=}16`.
        Method fromRef = class_getClassMethod(nodeClass, sel_registerName("nodeFromNodeRef:"));
        const char *fromRefTypes = fromRef ? method_getTypeEncoding(fromRef) : NULL;
        if (!fromRefTypes || strcmp(fromRefTypes, "@24@0:8^{OpaqueNodeRef=}16") != 0) {
            os_log(W7Log(), "nav pane: %{public}@ not hooked, %{public}@ +nodeFromNodeRef: has types %{public}s", name,
                   NSStringFromClass(nodeClass), fromRefTypes ?: "(missing)");
            return NO;
        }
        Method image = W7NavCheckedMethod(cellClass, "image", "@16@0:8");
        if (!image) return NO;

        W7NavCellClassInfo *info = [W7NavCellClassInfo new];
        info.nodeClass = nodeClass;
        info.nodeOffset = -1;
        Ivar ivar = class_getInstanceVariable(cellClass, "_node");
        const char *ivarTypes = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        if (ivarTypes && strcmp(ivarTypes, kNodeIvarTypes) == 0) info.nodeOffset = ivar_getOffset(ivar);
        else os_log(W7Log(), "nav pane: %{public}@ has no _node of the expected type (%{public}s); titles only", name, ivarTypes ?: "missing");
        Method nameMethod = class_getInstanceMethod(cellClass, sel_registerName("name"));
        if (nameMethod && method_getTypeEncoding(nameMethod) && strcmp(method_getTypeEncoding(nameMethod), "@16@0:8") == 0)
            info.nameSelector = sel_registerName("name");
        gCellClasses[key] = info;

        SEL imageSel = method_getName(image);
        id (*originalImage)(id, SEL) = (id (*)(id, SEL))method_getImplementation(image);
        method_setImplementation(image, imp_implementationWithBlock(^id(NSView *cell) {
            id original = originalImage(cell, imageSel);
            @try {
                BOOL active = W7NavPaneTreeActive(cell);
                NSString *iconName = active ? W7NavPaneCellIconName(cell) : nil;
                NSImage *icon = iconName ? W7NavPaneIconImage(iconName, W7NavPaneIconSize) : nil;
                if ([iconName isEqualToString:@"recycle-bin"] && [cell isKindOfClass:NSTableCellView.class])
                    W7NavNoteTrashImageView(((NSTableCellView *)cell).imageView, W7NavCellTitle(cell, info));
                W7NavNoteCall(W7NavPaneHookImage, cell, ^NSString * {
                    return [NSString stringWithFormat:@"'%@' -> %@%@", W7NavCellTitle(cell, info), iconName ?: @"(none)",
                            active ? (icon ? @"" : @", Finder's image") : @", tree look off"];
                });
                return icon ?: original;
            } @catch (NSException *e) {
                os_log_error(W7Log(), "nav pane icon failed: %{public}@", e.reason ?: @"unknown");
                return original;
            }
        }));

        BOOL sized = NO, text = NO, indent = NO;
        Method size = W7NavCheckedMethod(cellClass, "imageSize", "d16@0:8");
        if (size) {
            SEL sel = method_getName(size);
            double (*original)(id, SEL) = (double (*)(id, SEL))method_getImplementation(size);
            method_setImplementation(size, imp_implementationWithBlock(^double(NSView *cell) {
                double value = original(cell, sel);
                @try {
                    W7NavNoteCall(W7NavPaneHookImageSize, cell, ^NSString * { return [NSString stringWithFormat:@"Finder's %.0f", value]; });
                    return W7NavPaneTreeActive(cell) ? W7NavPaneIconSize : value;
                }
                @catch (NSException *e) { return value; }
            }));
            sized = YES;
        }
        Method textFrame = W7NavCheckedMethod(cellClass, "_textFieldFrame", kRectGetterTypes);
        if (textFrame) {
            SEL sel = method_getName(textFrame);
            NSRect (*original)(id, SEL) = (NSRect (*)(id, SEL))method_getImplementation(textFrame);
            method_setImplementation(textFrame, imp_implementationWithBlock(^NSRect(NSView *cell) {
                NSRect value = original(cell, sel);
                @try {
                    NSImageView *iv = [cell isKindOfClass:NSTableCellView.class] ? ((NSTableCellView *)cell).imageView : nil;
                    BOOL apply = iv && !iv.hidden && iv.image && W7NavLeftToRight(cell) && W7NavPaneTreeActive(cell);
                    NSRect result = apply ? W7NavPaneTextFrame(value, iv.frame, W7NavPaneIconSize, W7NavPaneIconGap) : value;
                    W7NavNoteCall(W7NavPaneHookTextFrame, cell, ^NSString * {
                        return [NSString stringWithFormat:@"%@ -> %@ (image view %@)", NSStringFromRect(value), NSStringFromRect(result),
                                iv ? NSStringFromRect(iv.frame) : @"none"];
                    });
                    return result;
                } @catch (NSException *e) {
                    return value;
                }
            }));
            text = YES;
        }
        indent = W7NavHookIndent(cellClass);
        os_log(W7Log(), "nav pane: %{public}@ hooked (image 1, imageSize %d, text frame %d, indent %d, node %{public}s)", name,
               sized, text, indent, info.nodeOffset >= 0 ? "ivar" : "title");
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "nav pane hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Keeping image views in step

/// What an image view showed before our icon replaced it (for a cell without -updateNameAndIcon).
@interface W7NavSavedImage : NSObject
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, strong) NSColor *tint;
@end
@implementation W7NavSavedImage
@end

static const void *kSavedImageKey = &kSavedImageKey;

BOOL W7NavPaneCellIsHooked(NSView *cell) {
    return cell && W7NavInfoForCell(cell) != nil;
}

NSString *W7NavPaneRowIconName(NSView *cell, NSString *title) {
    @try {
        if (cell && W7NavInfoForCell(cell)) return W7NavPaneCellIconName(cell);
        return W7NavPaneIconNameForTitle(title, W7NavTitleNames());
    } @catch (NSException *e) {
        os_log_error(W7Log(), "nav pane row icon name failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

/// `object`'s `name` method has exactly `types`.
static BOOL W7NavHasMethod(id object, const char *name, const char *types) {
    Method m = object ? class_getInstanceMethod(object_getClass(object), sel_registerName(name)) : NULL;
    const char *actual = m ? method_getTypeEncoding(m) : NULL;
    return actual && strcmp(actual, types) == 0;
}

/// Finder's image back in an image view that shows one of ours: the cell's own -updateNameAndIcon
/// (its hooked -image answers Finder's icon now), else what the image view showed before, else the
/// hooked cell's -image with Finder's tint.
static void W7NavRestoreFinderImage(NSImageView *iv, NSView *cell) {
    W7NavSavedImage *saved = objc_getAssociatedObject(iv, kSavedImageKey);
    objc_setAssociatedObject(iv, kSavedImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (W7NavHasMethod(cell, "updateNameAndIcon", "v16@0:8"))
        ((void (*)(id, SEL))objc_msgSend)(cell, sel_registerName("updateNameAndIcon"));
    if (!W7NavPaneImageIsOurs(iv.image)) return;
    if (saved) {
        iv.image = saved.image;
        iv.contentTintColor = saved.tint;
        return;
    }
    if (W7NavInfoForCell(cell) && W7NavHasMethod(cell, "image", "@16@0:8")) {
        id finder = ((id (*)(id, SEL))objc_msgSend)(cell, sel_registerName("image"));
        if ([finder isKindOfClass:NSImage.class] && !W7NavPaneImageIsOurs(finder)) {
            iv.image = finder;
            iv.contentTintColor = NSColor.secondaryLabelColor;
        }
    }
}

BOOL W7NavPaneSyncRowIcon(NSImageView *iv, NSView *cell, NSString *title) {
    @try {
        if (!iv) return NO;
        NSString *name = W7NavPaneTreeActive(iv) ? W7NavPaneRowIconName(cell, title) : nil;
        if ([name isEqualToString:@"recycle-bin"]) W7NavNoteTrashImageView(iv, title);
        NSImage *icon = name ? W7NavPaneIconImage(name, W7NavPaneIconSize) : nil;
        if (icon) {
            if (iv.image == icon) return NO;
            if (!W7NavPaneImageIsOurs(iv.image)) {
                W7NavSavedImage *saved = [W7NavSavedImage new];
                saved.image = iv.image;
                saved.tint = iv.contentTintColor;
                objc_setAssociatedObject(iv, kSavedImageKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            iv.image = icon;
            iv.contentTintColor = nil;
            return YES;
        }
        if (!W7NavPaneImageIsOurs(iv.image)) return NO;
        W7NavRestoreFinderImage(iv, cell);
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "nav pane row icon failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

void W7NavPaneRefreshCell(NSView *cell) {
    @try {
        W7NavCellClassInfo *info = [cell isKindOfClass:NSTableCellView.class] ? W7NavInfoForCell(cell) : nil;
        if (!info) return;
        NSImageView *iv = ((NSTableCellView *)cell).imageView;
        BOOL changed = iv && W7NavPaneSyncRowIcon(iv, cell, W7NavCellTitle(cell, info));
        NSRect before = cell.frame;
        cell.frame = before;   // the setFrame: hook indents it once
        if (changed || !NSEqualRects(before, cell.frame)) cell.needsLayout = YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "nav pane cell refresh failed: %{public}@", e.reason ?: @"unknown");
    }
}

void W7ExplorerInstallNavPaneHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
            BOOL disabled = W7NavPaneTreeDisabled();
            if (!W7NavPaneHooksShouldInstall(bundleID, disabled)) {
                os_log(W7Log(), "nav pane: hooks not installed in %{public}@ (%{public}s)", bundleID ?: @"(none)",
                       disabled ? "W7ExplorerNavPaneDisabled" : "not Finder");
                return;
            }
            Class cell = NSClassFromString(@"TSidebarItemCell"), node = NSClassFromString(@"FINode");
            if (!cell || !node) {
                os_log(W7Log(), "nav pane: hooks not installed, %{public}s missing", !cell ? "TSidebarItemCell" : "FINode");
                return;
            }
            if (!W7ExplorerBrowseImageIsFinder(class_getImageName(cell))) {
                os_log(W7Log(), "nav pane: TSidebarItemCell is in %{public}s, not Finder; not hooked", class_getImageName(cell) ?: "(no image)");
                return;
            }
            if (![cell isSubclassOfClass:NSTableCellView.class]) {
                os_log(W7Log(), "nav pane: TSidebarItemCell is no NSTableCellView; not hooked");
                return;
            }
            W7NavPaneHookCellClass(cell, node);
        } @catch (NSException *e) {
            os_log_error(W7Log(), "nav pane hook install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}
