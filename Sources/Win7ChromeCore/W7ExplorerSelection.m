// Finder's selection in an Explorer window, for the details pane and the command bar.
//
// Finder keeps its selection as a C++ TFENodeVector (-[TBaseBrowserViewController selectedNodes]),
// which can't be taken over safely from Objective-C. Instead the browser view controller is asked the
// way the Services menu asks it: -validRequestorForSendType:returnType: and
// -writeSelectionToPasteboard:types: into a private pasteboard, which yields file URLs. Changes are
// noticed through a guarded hook on the browser controllers' -selectionChanged (exact encoding
// v16@0:8, the original always runs first; off with W7ExplorerSelectionDisabled) and, as a fallback,
// by polling -selectedNodesCount (Q16@0:8) with the window's 10 Hz refresh. No AppleScript, no file writes.
//
// Cost per selection change, after the debounce: one count call; nothing more for 0 items or for more
// than W7ExplorerSelectionReadLimit; otherwise one pasteboard round trip on the main thread and, off it,
// one resource-value read per item (plus, for a single item only, its default app and image header).
#import "W7ExplorerInternal.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>

@implementation W7ExplorerSelectionSnapshot

- (instancetype)initWithURLs:(NSArray<NSURL *> *)urls items:(NSArray<W7ExplorerItemInfo *> *)items count:(NSInteger)count
                      unread:(BOOL)unread folderHasImages:(BOOL)folderHasImages folderPath:(NSString *)folderPath known:(BOOL)known {
    if ((self = [super init])) {
        _urls = [urls copy];
        _items = [items copy];
        _selectedCount = count;
        _unread = unread;
        _folderHasImages = folderHasImages;
        _folderPath = [folderPath copy];
        _known = known;
    }
    return self;
}

@end

#pragma mark - Reading Finder's selection

/// The type encoding `object` has for `sel` equals `types`.
static BOOL W7HasMethod(id object, SEL sel, const char *types) {
    Method m = object ? class_getInstanceMethod(object_getClass(object), sel) : NULL;
    const char *actual = m ? method_getTypeEncoding(m) : NULL;
    return actual && strcmp(actual, types) == 0;
}

/// -selectedNodesCount of a browser view controller, or -1 when it has none of the expected type.
static NSInteger W7SelectedCount(NSViewController *browser) {
    SEL sel = sel_registerName("selectedNodesCount");
    if (!W7HasMethod(browser, sel, "Q16@0:8")) return -1;
    return (NSInteger)((unsigned long (*)(id, SEL))objc_msgSend)(browser, sel);
}

static NSPasteboard *W7SelectionPasteboard(void) {
    static NSPasteboard *pb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pb = [NSPasteboard pasteboardWithUniqueName]; });
    return pb;
}

static NSString *const kLegacyFilenamesType = @"NSFilenamesPboardType";

/// The file URLs `browser` would hand to a service. Main thread.
static NSArray<NSURL *> *W7SelectionURLs(NSViewController *browser) {
    id requestor = nil;
    for (NSPasteboardType type in @[ NSPasteboardTypeFileURL, kLegacyFilenamesType ]) {
        requestor = [browser validRequestorForSendType:type returnType:nil];
        if (requestor) break;
    }
    if (![requestor respondsToSelector:@selector(writeSelectionToPasteboard:types:)]) return @[];
    NSPasteboard *pb = W7SelectionPasteboard();
    [pb clearContents];
    NSArray<NSURL *> *urls = nil;
    if ([requestor writeSelectionToPasteboard:pb types:@[ NSPasteboardTypeFileURL, kLegacyFilenamesType ]]) {
        urls = [pb readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
        if (urls.count == 0) {
            id paths = [pb propertyListForType:kLegacyFilenamesType];
            NSMutableArray<NSURL *> *fromPaths = [NSMutableArray array];
            if ([paths isKindOfClass:NSArray.class])
                for (id p in paths) if ([p isKindOfClass:NSString.class] && [p length]) [fromPaths addObject:[NSURL fileURLWithPath:p]];
            urls = fromPaths;
        }
    }
    [pb clearContents];
    return urls ?: @[];
}

/// Whether `browser` is the visible browser of `window`.
static BOOL W7IsLiveBrowser(NSViewController *browser, NSWindow *window) {
    if (!browser || !window || !browser.isViewLoaded) return NO;
    NSView *v = browser.view;
    return v.window == window && !v.isHiddenOrHasHiddenAncestor;
}

/// The visible browser view controllers of `window`'s content view controller tree (bounded).
static void W7CollectBrowsers(NSViewController *vc, Class base, NSWindow *window, NSMutableArray<NSViewController *> *out, NSUInteger depth) {
    if (!vc || depth > 32) return;
    if ([vc isKindOfClass:base] && W7IsLiveBrowser(vc, window)) [out addObject:vc];
    for (NSViewController *child in [vc.childViewControllers copy]) W7CollectBrowsers(child, base, window, out, depth + 1);
}

#pragma mark - Tracker

@implementation W7ExplorerSelectionTracker {
    __weak id<W7ExplorerSelectionHost> _host;
    __weak NSViewController *_browser;
    void (^_onChange)(void);
    W7ExplorerSelectionSnapshot *_snapshot;
    NSInteger _lastCount;
    NSTimer *_debounceTimer;        // restarted by every trigger
    CFAbsoluteTime _pendingSince;   // first trigger of the current burst; 0 when none is pending
    atomic_ulong _generation;       // read generation: a later read supersedes an unfinished one
}

- (instancetype)initWithHost:(id<W7ExplorerSelectionHost>)host onChange:(void (^)(void))onChange {
    if ((self = [super init])) {
        _host = host;
        _onChange = [onChange copy];
        _lastCount = -2;
        _debounceInterval = 0.1;
        _maxDebounceWait = 0.5;
        _infoLoader = ^W7ExplorerItemInfo *(NSURL *url, BOOL detailed) { return [W7ExplorerItemInfo infoForURL:url detailed:detailed]; };
    }
    return self;
}

- (W7ExplorerSelectionSnapshot *)snapshot { return _snapshot; }

- (void)noteBrowser:(NSViewController *)browser {
    if (W7IsLiveBrowser(browser, _host.window)) _browser = browser;
}

/// The window's visible browser view controller: the last one that reported, else the one holding the
/// first responder, else the first visible one.
- (NSViewController *)w7Browser {
    NSWindow *w = _host.window;
    NSViewController *b = _browser;
    if (W7IsLiveBrowser(b, w)) return b;
    Class base = NSClassFromString(@"TBaseBrowserViewController");
    if (!base || !w) return nil;
    NSMutableArray<NSViewController *> *found = [NSMutableArray array];
    W7CollectBrowsers(w.contentViewController, base, w, found, 0);
    NSResponder *fr = w.firstResponder;
    b = found.firstObject;
    if ([fr isKindOfClass:NSView.class])
        for (NSViewController *vc in found) if ([(NSView *)fr isDescendantOf:vc.view]) { b = vc; break; }
    _browser = b;
    return b;
}

- (void)dealloc { [_debounceTimer invalidate]; }

/// Each call restarts the wait; a burst never waits longer than maxDebounceWait after its first call.
/// A main run loop timer in the common modes (so it also fires while Finder tracks the mouse).
- (void)setNeedsUpdate {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_pendingSince == 0) _pendingSince = now;
    NSTimeInterval delay = MAX(0, MIN(_debounceInterval, _pendingSince + _maxDebounceWait - now));
    [_debounceTimer invalidate];
    __weak W7ExplorerSelectionTracker *weakSelf = self;
    _debounceTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(__unused NSTimer *t) {
        W7ExplorerSelectionTracker *s = weakSelf;
        if (!s) return;
        s->_debounceTimer = nil;
        s->_pendingSince = 0;
        @try { [s w7Read]; }
        @catch (NSException *e) { os_log_error(W7Log(), "Explorer selection read failed: %{public}@", e.reason ?: @"unknown"); }
    }];
    [NSRunLoop.mainRunLoop addTimer:_debounceTimer forMode:NSRunLoopCommonModes];
}

- (NSInteger)liveSelectedCount {
    @try {
        NSViewController *b = [self w7Browser];
        return b ? W7SelectedCount(b) : -1;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer live selection count failed: %{public}@", e.reason ?: @"unknown");
        return -1;
    }
}

- (void)poll {
    @try {
        NSViewController *b = [self w7Browser];
        NSInteger count = b ? W7SelectedCount(b) : -1;
        if (count != _lastCount) {
            _lastCount = count;
            [self setNeedsUpdate];
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer selection poll failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)w7Publish:(W7ExplorerSelectionSnapshot *)snap {
    _snapshot = snap;
    @try { if (_onChange) _onChange(); }
    @catch (NSException *e) { os_log_error(W7Log(), "Explorer selection update failed: %{public}@", e.reason ?: @"unknown"); }
}

- (void)w7Read {
    id<W7ExplorerSelectionHost> host = _host;
    if (!host.window) return;
    _readCount++;
    NSViewController *browser = [self w7Browser];
    NSInteger count = browser ? W7SelectedCount(browser) : -1;
    _lastCount = count;
    BOOL known = browser != nil;
    NSString *folder = host.currentFolder.path;
    W7ExplorerSelectionSnapshot *old = _snapshot;
    unsigned long generation = atomic_fetch_add(&_generation, 1) + 1;   // supersedes any unfinished load

    // Too many to read one by one: count only, no pasteboard, no file I/O.
    if (count > (NSInteger)W7ExplorerSelectionReadLimit) {
        if (old.unread && old.selectedCount == count) return;
        [self w7Publish:[[W7ExplorerSelectionSnapshot alloc] initWithURLs:@[] items:@[] count:count unread:YES
                                                          folderHasImages:NO folderPath:folder known:YES]];
        return;
    }
    // A count of 0 is trusted: some requestors hand over the open folder when nothing is selected.
    NSArray<NSURL *> *urls = (browser && count != 0) ? W7SelectionURLs(browser) : @[];
    if (old && !old.unread && old.known == known && [old.urls isEqualToArray:urls] &&
        (urls.count > 0 || old.folderPath == folder || [old.folderPath isEqualToString:folder])) return;

    W7ExplorerItemInfo *(^loader)(NSURL *, BOOL) = _infoLoader;
    BOOL detailed = urls.count == 1;
    __weak W7ExplorerSelectionTracker *weakSelf = self;
    W7ExplorerSelectionTracker *strongForBackground = self;   // only to read _generation; released with the block
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<W7ExplorerItemInfo *> *items = [NSMutableArray arrayWithCapacity:urls.count];
        for (NSURL *url in urls) {
            if (atomic_load(&strongForBackground->_generation) != generation) return;   // superseded
            W7ExplorerItemInfo *info = nil;
            @try { info = loader ? loader(url, detailed) : nil; }
            @catch (NSException *e) {
                os_log_error(W7Log(), "Explorer selection: reading %{public}@ failed: %{public}@", url.lastPathComponent ?: @"?",
                             e.reason ?: @"unknown");
            }
            if (!info) {
                os_log(W7Log(), "Explorer selection: %{public}@ shown by name only", url.lastPathComponent ?: @"?");
                info = [W7ExplorerItemInfo nameOnlyInfoForURL:url];
            }
            [items addObject:info];
        }
        BOOL hasImages = NO;
        @try { if (urls.count == 0) hasImages = W7ExplorerFolderHasImages(folder); }
        @catch (NSException *e) { os_log_error(W7Log(), "Explorer folder image scan failed: %{public}@", e.reason ?: @"unknown"); }
        W7ExplorerSelectionSnapshot *snap = [[W7ExplorerSelectionSnapshot alloc] initWithURLs:urls items:items count:count unread:NO
                                                                               folderHasImages:hasImages folderPath:folder known:known];
        // Back on the main run loop (common modes), like the debounce timer.
        CFRunLoopRef main = CFRunLoopGetMain();
        CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
            W7ExplorerSelectionTracker *s = weakSelf;
            if (!s || atomic_load(&s->_generation) != generation) return;   // superseded meanwhile
            [s w7Publish:snap];
        });
        CFRunLoopWakeUp(main);
    });
}

@end

#pragma mark - Decisions

W7ExplorerShareDecision W7ExplorerShareDecisionFor(W7ExplorerSelectionSnapshot *selection, NSString *folderPath) {
    if (!selection.known) return W7ExplorerShareAskFinder;
    if (selection.unread) return W7ExplorerShareBeep;   // never the folder in place of a large selection
    if (selection.urls.count > 0) return W7ExplorerShareSelection;
    return folderPath.length ? W7ExplorerShareFolder : W7ExplorerShareBeep;
}

W7ExplorerSlideShowPlan W7ExplorerSlideShowPlanFor(W7ExplorerSelectionSnapshot *selection, NSInteger liveCount, BOOL canRestore) {
    BOOL knownEmpty = selection && selection.known && !selection.unread && selection.selectedCount == 0 && selection.urls.count == 0;
    return knownEmpty && liveCount == 0 && canRestore ? W7ExplorerSlideShowWholeFolder : W7ExplorerSlideShowSelection;
}

#pragma mark - Change hook

static void W7NoteSelectionChanged(NSViewController *vc) {
    if (![vc isKindOfClass:NSViewController.class] || !vc.isViewLoaded) return;
    W7ExplorerController *ex = W7ExplorerControllerForWindow(vc.view.window);
    if (!ex) return;
    [ex.selectionTracker noteBrowser:vc];
    [ex.selectionTracker setNeedsUpdate];
}

static BOOL W7HookSelectionChanged(Class cls) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    SEL sel = sel_registerName("selectionChanged");
    Method m = NULL;
    for (unsigned int i = 0; i < count && !m; i++) if (method_getName(methods[i]) == sel) m = methods[i];
    free(methods);
    const char *types = m ? method_getTypeEncoding(m) : NULL;
    if (!types || strcmp(types, "v16@0:8") != 0) {
        os_log(W7Log(), "Explorer selection: %{public}@ -selectionChanged not hooked (%{public}s)", NSStringFromClass(cls),
               m ? (types ?: "no types") : "not its own");
        return NO;
    }
    void (*original)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id receiver) {
        original(receiver, sel);
        @try {
            if (NSThread.isMainThread) { W7NoteSelectionChanged(receiver); return; }
            __weak id weakReceiver = receiver;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try { W7NoteSelectionChanged(weakReceiver); }
                @catch (NSException *e) { os_log_error(W7Log(), "Explorer selection note failed: %{public}@", e.reason ?: @"unknown"); }
            });
        } @catch (NSException *e) {
            os_log_error(W7Log(), "Explorer selection hook failed: %{public}@", e.reason ?: @"unknown");
        }
    }));
    os_log(W7Log(), "Explorer selection: %{public}@ -selectionChanged hooked", NSStringFromClass(cls));
    return YES;
}

void W7ExplorerInstallSelectionObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
            BOOL disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7ExplorerSelectionDisabled"];
            if (!W7ExplorerSelectionHighlightShouldInstall(bundleID, disabled)) {
                if (disabled) os_log(W7Log(), "Explorer selection: -selectionChanged not hooked (W7ExplorerSelectionDisabled); polling only");
                return;
            }
            for (NSString *name in @[ @"TBaseBrowserViewController", @"TBrowserViewController",
                                      @"TBaseCollectionViewController", @"TGalleryCollectionViewController" ]) {
                Class cls = NSClassFromString(name);
                if (cls) W7HookSelectionChanged(cls);
                else os_log(W7Log(), "Explorer selection: %{public}@ missing", name);
            }
        } @catch (NSException *e) {
            os_log_error(W7Log(), "Explorer selection observer install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}
