// Turns Finder browser windows into Windows 7 Explorer windows and wires the bars to Finder.
#import "W7ExplorerInternal.h"
#import <objc/runtime.h>
#import <Carbon/Carbon.h>

static const void *kExplorerKey = &kExplorerKey;
static void *kExplorerKVOCtx = &kExplorerKVOCtx;
static const NSTimeInterval kRefreshInterval = 0.1;   // 10 Hz

NSFont *W7ExplorerFont(void) {
    static NSFont *font; static dispatch_once_t once;
    dispatch_once(&once, ^{ font = W7UIFont(12); });
    return font;
}

BOOL W7IsExplorerWindow(NSWindow *window) {
    return window && objc_getAssociatedObject(window, kExplorerKey) != nil;
}

W7ExplorerController *W7ExplorerControllerForWindow(NSWindow *window) {
    return window ? objc_getAssociatedObject(window, kExplorerKey) : nil;
}

CGRect W7ExplorerGlassRect(NSWindow *window, NSView *view) {
    @try {
        NSView *titlebar = [window standardWindowButton:NSWindowCloseButton].superview;
        NSView *nav = nil;
        for (NSTitlebarAccessoryViewController *a in window.titlebarAccessoryViewControllers)
            if ([a isKindOfClass:W7ExplorerNavBarController.class]) { nav = a.viewLoaded ? a.view : nil; break; }
        if (!titlebar) return view.bounds;
        NSRect tb = [view convertRect:titlebar.bounds fromView:titlebar];
        if (!nav || nav.window != window) return tb;
        NSRect n = [view convertRect:nav.bounds fromView:nav];
        CGFloat bottom = NSMinY(n) - 8;
        return NSMakeRect(NSMinX(tb), bottom, NSWidth(tb), MAX(0, NSMaxY(tb) - bottom));
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer glass rect failed: %{public}@", e.reason ?: @"unknown");
        return view.bounds;
    }
}

NSMenuItem *W7ExplorerProxyItem(W7ExplorerController *explorer, NSString *title, NSString *key,
                                NSEventModifierFlags mods) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(w7PerformProxy:) keyEquivalent:@""];
    item.target = explorer;   // weak
    item.representedObject = @{ @"key": key, @"mods": @(mods) };
    return item;
}

/// Printable form of a key equivalent for the log ("\b" → "U+0008").
static NSString *W7KeyDescription(NSString *key) {
    if (key.length == 1 && [key characterAtIndex:0] < 0x20) return [NSString stringWithFormat:@"U+%04X", [key characterAtIndex:0]];
    return key;
}

static const NSTimeInterval kLocationDebounce = 0.25;
static const NSTimeInterval kOsascriptTimeout = 5;

/// Runs `script` through /usr/bin/osascript and returns its stdout, or nil on failure. Blocks the
/// calling thread until osascript exits (killed after kOsascriptTimeout): never call it on the main thread.
static NSString *W7RunOsascriptSync(NSString *script) {
    @try {
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        task.arguments = @[ @"-e", script ];
        NSPipe *out = [NSPipe pipe];
        task.standardInput = NSFileHandle.fileHandleWithNullDevice;
        task.standardOutput = out;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSError *error = nil;
        if (![task launchAndReturnError:&error]) {
            os_log_error(W7Log(), "Explorer: osascript launch failed: %{public}@", error.localizedDescription ?: @"unknown");
            return nil;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOsascriptTimeout * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (task.isRunning) [task terminate];
        });
        NSData *data = [out.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        if (task.terminationStatus != 0) return nil;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer: osascript failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

@implementation W7ExplorerLocation

- (instancetype)initWithPath:(NSString *)path title:(NSString *)title segments:(NSArray *)segments
                        icon:(NSImage *)icon count:(NSInteger)count {
    if ((self = [super init])) {
        _path = [path copy];
        _title = [title copy] ?: @"";
        _segments = [segments copy];
        _icon = icon;
        _itemCount = count;
    }
    return self;
}

+ (instancetype)locationForPath:(NSString *)path title:(NSString *)title {
    if (path.length == 0) {
        NSImage *icon = [NSImage imageNamed:NSImageNameFolder];
        return [[self alloc] initWithPath:nil title:title segments:@[ @{ @"title": title ?: @"", @"path": @"" } ] icon:icon count:-1];
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *segs = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *seg in W7BreadcrumbSegments([NSURL fileURLWithPath:path isDirectory:YES],
                                                                          NSHomeDirectory())) {
        NSString *p = seg[@"path"];
        // "Documents" shows as Finder shows it ("Belgeler"); the root keeps Windows' "Computer".
        NSString *name = [p isEqualToString:@"/"] ? seg[@"title"] : ([fm displayNameAtPath:p] ?: seg[@"title"]);
        [segs addObject:@{ @"title": name ?: @"", @"path": p ?: @"" }];
    }
    // The Windows 7 picture (folder art, the user's drive icon) when there is one; else the URL
    // resource value, rather than NSWorkspace, because this runs off the main thread.
    NSImage *icon = W7ExplorerIconForPath(path, 16);
    if (!icon) [[NSURL fileURLWithPath:path isDirectory:YES] getResourceValue:&icon forKey:NSURLEffectiveIconKey error:NULL];
    if (![icon isKindOfClass:NSImage.class]) icon = [NSImage imageNamed:NSImageNameFolder];
    return [[self alloc] initWithPath:path title:title segments:segs icon:icon count:W7CountVisibleItems(path)];
}

+ (instancetype)unreadLocationForTitle:(NSString *)title {
    W7ExplorerLocation *location = [self locationForPath:nil title:title];
    location->_unread = YES;
    return location;
}

@end

@interface W7ExplorerController ()
- (void)w7AttachNav:(W7ExplorerNavBarController *)nav command:(W7ExplorerCommandBarController *)command;
- (void)w7AttachDetails:(nullable W7ExplorerDetailsController *)details styler:(W7ExplorerContentStyler *)styler;
- (void)w7SetLocation:(W7ExplorerLocation *)location;
- (void)w7StartObserving;
@end

@implementation W7ExplorerController {
    __weak NSWindow *_window;
    __weak W7ExplorerNavBarController *_nav;
    __weak W7ExplorerCommandBarController *_command;
    W7ExplorerDetailsController *_details;
    W7ExplorerContentStyler *_styler;
    BOOL _observing;
    BOOL _refreshPending;
    W7ExplorerLocation *_location;
    NSInteger _finderWindowID;      // Finder's AppleScript id for this window, once known
    NSUInteger _queryToken;         // debounce generation
    BOOL _queryRunning, _queryAgain;
    BOOL _shareRunning;             // a Share with selection query is in flight
    W7ExplorerSelectionTracker *_selectionTracker;
    W7ExplorerComputerController *_computer;
}

- (instancetype)initWithWindow:(NSWindow *)window {
    if ((self = [super init])) {
        _window = window;
        __weak W7ExplorerController *weakSelf = self;
        _selectionTracker = [[W7ExplorerSelectionTracker alloc] initWithHost:self onChange:^{
            [weakSelf w7SelectionDidChange];
        }];
        _computer = [[W7ExplorerComputerController alloc] initWithExplorer:self];
    }
    return self;
}

- (NSWindow *)window { return _window; }

- (void)dealloc {
    // The window owns this object, so it only goes away with the window; KVO tolerates an observed
    // object that deallocates with observers still registered (macOS 10.13+).
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSURL *)currentFolder {
    NSURL *represented = W7ExplorerFolderURL(_window.representedURL);
    if (represented) return represented;
    NSString *path = _location.path;
    return path.length ? [NSURL fileURLWithPath:path isDirectory:YES] : nil;
}

- (W7ExplorerLocation *)location { return _location; }

- (W7ExplorerSelectionSnapshot *)selection { return _selectionTracker.snapshot; }

- (W7ExplorerSelectionTracker *)selectionTracker { return _selectionTracker; }

- (W7ExplorerComputerController *)computer { return _computer; }

- (void)computerViewDidChange {
    @try {
        [_command selectionChanged];
        [_details refresh];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer computer view change failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)w7SelectionDidChange {
    @try {
        [_details refresh];
        [_command selectionChanged];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer selection change failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark Location

- (void)scheduleLocationQuery {
    if (!_observing) return;
    NSUInteger token = ++_queryToken;
    __weak W7ExplorerController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLocationDebounce * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        W7ExplorerController *s = weakSelf;
        if (!s || s->_queryToken != token) return;
        @try { [s w7RunLocationQuery]; }
        @catch (NSException *e) { os_log_error(W7Log(), "Explorer location query failed: %{public}@", e.reason ?: @"unknown"); }
    });
}

/// representedURL first (macOS 27 Finder leaves it nil); otherwise ask Finder through osascript.
/// While the window is key it is Finder's front window ("Finder window 1"), which also yields its id;
/// in the background only a known id can match it. One query at a time per window; everything that
/// touches the file system or osascript runs off the main thread.
- (void)w7RunLocationQuery {
    NSWindow *w = _window;
    if (!w || !_observing) return;
    if (_queryRunning) { _queryAgain = YES; return; }
    NSString *title = [w.title copy] ?: @"";
    NSURL *representedURL = w.representedURL;
    BOOL key = w.isKeyWindow;
    NSInteger windowID = key ? 0 : _finderWindowID;
    if (!representedURL.isFileURL && !key && windowID <= 0) return;
    _queryRunning = YES;
    __weak W7ExplorerController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = nil;
        NSDictionary *parsed = nil;
        BOOL asked = NO;
        W7ExplorerLocation *location = nil;
        @try {
            path = W7ExplorerFolderURL(representedURL).path;
            if (!path && (key || windowID > 0)) {
                asked = YES;
                parsed = W7ParseFinderTargetOutput(W7RunOsascriptSync(W7FinderTargetScript(windowID)) ?: @"");
                path = parsed[@"path"];
            }
            // Built here (file I/O) on the chance the answer is accepted on the main thread.
            location = [W7ExplorerLocation locationForPath:path title:title];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "Explorer location lookup failed: %{public}@", e.reason ?: @"unknown");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            W7ExplorerController *s = weakSelf;
            if (!s) return;
            @try {
                s->_queryRunning = NO;
                NSWindow *win = s->_window;
                if (!s->_observing || !win) return;
                NSString *current = win.title ?: @"";
                W7TargetDecision decision = W7TargetDecisionAccept;
                if (asked) {
                    // Another window may have come to the front, the id may not be this window's, or
                    // the window may have navigated while osascript ran.
                    decision = W7DecideFinderTarget(parsed, title, current, s->_location.title, windowID > 0, win.isKeyWindow);
                }
                switch (decision) {
                    case W7TargetDecisionAccept:
                        if (asked && parsed && windowID <= 0) s->_finderWindowID = [parsed[@"id"] integerValue];
                        if (location) [s w7SetLocation:location];
                        break;
                    case W7TargetDecisionRequery:
                        s->_queryAgain = YES;   // keeps the id: the answer was stale, not wrong
                        break;
                    case W7TargetDecisionWrongWindow:
                        s->_finderWindowID = 0;
                        if (![s->_location.title isEqualToString:current])
                            [s w7SetLocation:[W7ExplorerLocation locationForPath:nil title:current]];
                        if (win.isKeyWindow) s->_queryAgain = YES;   // the front query can find the right id
                        break;
                    case W7TargetDecisionTitleOnly:
                        // Never leave another folder's breadcrumb, count and path (Refresh, Share) behind.
                        [s w7SetLocation:[W7ExplorerLocation locationForPath:nil title:current]];
                        break;
                    case W7TargetDecisionKeep:
                        break;
                }
                if (s->_queryAgain) { s->_queryAgain = NO; [s scheduleLocationQuery]; }
            } @catch (NSException *e) {
                os_log_error(W7Log(), "Explorer location update failed: %{public}@", e.reason ?: @"unknown");
            }
        });
    });
}

- (void)applyLocation:(W7ExplorerLocation *)location {
    if (location) [self w7SetLocation:location];
}

- (void)w7SetLocation:(W7ExplorerLocation *)location {
    _location = location;
    [_nav refreshLocation];
    [_computer update];   // Finder's Computer location: the Windows 7 Computer view
    [_details refresh];
    [_selectionTracker setNeedsUpdate];   // a new folder: a new selection, and maybe images for Slide show
}

- (void)refreshFolder {
    @try {
        NSString *path = self.currentFolder.path;
        if (path.length) [self navigateToPath:path];
        else [self scheduleLocationQuery];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer refresh failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)shareFromView:(NSView *)view rect:(NSRect)rect {
    @try {
        if (_shareRunning) return;   // one selection query at a time
        NSString *folder = self.currentFolder.path;
        // Finder's selection as the tracker read it, when it could (no osascript needed).
        W7ExplorerSelectionSnapshot *selection = self.selection;
        NSArray<NSURL *> *items = nil;
        switch (W7ExplorerShareDecisionFor(selection, folder)) {
            case W7ExplorerShareSelection: items = selection.urls; break;
            case W7ExplorerShareFolder: items = @[ [NSURL fileURLWithPath:folder isDirectory:YES] ]; break;
            case W7ExplorerShareBeep: NSBeep(); return;   // e.g. an unread (over 1000 items) selection
            case W7ExplorerShareAskFinder: break;
        }
        if (items) {
            NSSharingServicePicker *picker = [[NSSharingServicePicker alloc] initWithItems:items];
            [picker showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMinY];
            return;
        }
        NSString *script = W7FinderSelectionScript();
        __weak NSView *weakView = view;
        __weak W7ExplorerController *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<NSString *> *paths = @[];
            @try { paths = W7ParsePathLines(W7RunOsascriptSync(script) ?: @""); }
            @catch (NSException *e) { os_log_error(W7Log(), "Explorer selection read failed: %{public}@", e.reason ?: @"unknown"); }
            dispatch_async(dispatch_get_main_queue(), ^{
                W7ExplorerController *s = weakSelf;
                if (s) s->_shareRunning = NO;
                @try {
                    NSView *v = weakView;
                    if (!v.window) return;
                    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
                    for (NSString *p in paths) [urls addObject:[NSURL fileURLWithPath:p]];
                    if (urls.count == 0 && folder.length) [urls addObject:[NSURL fileURLWithPath:folder isDirectory:YES]];
                    if (urls.count == 0) { NSBeep(); return; }
                    NSSharingServicePicker *picker = [[NSSharingServicePicker alloc] initWithItems:urls];
                    [picker showRelativeToRect:rect ofView:v preferredEdge:NSRectEdgeMinY];
                } @catch (NSException *e) {
                    os_log_error(W7Log(), "Explorer share picker failed: %{public}@", e.reason ?: @"unknown");
                }
            });
        });
        // Only once the query is on its way; its completion (main queue, later) clears it again.
        _shareRunning = YES;
    } @catch (NSException *e) {
        _shareRunning = NO;
        os_log_error(W7Log(), "Explorer share failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark Observation

- (void)w7AttachNav:(W7ExplorerNavBarController *)nav command:(W7ExplorerCommandBarController *)command {
    _nav = nav;
    _command = command;
}

- (void)w7AttachDetails:(W7ExplorerDetailsController *)details styler:(W7ExplorerContentStyler *)styler {
    _details = details;
    _styler = styler;
}

- (void)w7StartObserving {
    NSWindow *w = _window;
    if (!w || _observing) return;
    _observing = YES;
    [w addObserver:self forKeyPath:@"representedURL" options:0 context:kExplorerKVOCtx];
    [w addObserver:self forKeyPath:@"title" options:0 context:kExplorerKVOCtx];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(w7WindowWillClose:) name:NSWindowWillCloseNotification object:w];
    [nc addObserver:self selector:@selector(w7WindowDidUpdate:) name:NSWindowDidUpdateNotification object:w];
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                                      NSWindowDidBecomeMainNotification, NSWindowDidResignMainNotification]) {
        [nc addObserver:self selector:@selector(w7WindowActiveChanged:) name:name object:w];
    }
}

- (void)w7StopObservingWindow:(NSWindow *)w {
    if (!_observing) return;
    _observing = NO;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (w) {
        @try {
            [w removeObserver:self forKeyPath:@"representedURL" context:kExplorerKVOCtx];
            [w removeObserver:self forKeyPath:@"title" context:kExplorerKVOCtx];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "Explorer KVO removal failed: %{public}@", e.reason ?: @"unknown");
        }
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)ctx {
    if (ctx != kExplorerKVOCtx) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:ctx];
        return;
    }
    __weak W7ExplorerController *weakSelf = self;
    void (^refresh)(void) = ^{
        @try { [weakSelf w7RefreshLocation]; }
        @catch (NSException *e) { os_log_error(W7Log(), "Explorer location refresh failed: %{public}@", e.reason ?: @"unknown"); }
    };
    if (NSThread.isMainThread) refresh(); else dispatch_async(dispatch_get_main_queue(), refresh);
}

- (void)w7RefreshLocation {
    if (!_observing) return;
    [_nav refreshLocation];
    [_computer update];             // a new title: the Computer view goes before the location query answers
    [self scheduleLocationQuery];   // a title change is how a navigation shows up
}

- (void)w7WindowWillClose:(NSNotification *)n {
    @try {
        // Finder saves per-folder window state (.DS_Store) around close; never save it with the
        // toolbar hidden, so folders look normal again once the dylib is gone.
        NSWindow *w = n.object;
        if ([w isKindOfClass:NSWindow.class]) w.toolbar.visible = YES;
        [_computer invalidate];
        [self w7StopObservingWindow:w];
    }
    @catch (NSException *e) { os_log_error(W7Log(), "Explorer willClose failed: %{public}@", e.reason ?: @"unknown"); }
}

- (void)w7WindowActiveChanged:(NSNotification *)n {
    @try {
        [_nav refreshActive];
        if ([n.name isEqualToString:NSWindowDidBecomeKeyNotification]) {
            [self scheduleLocationQuery];
            [_command validateSelectionCommands];   // Open / Print / Slide show: on key changes, not at 10 Hz
        }
        [self w7WindowDidUpdate:n];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer key/main handler failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// NSWindowDidUpdate arrives after every event; coalesce to at most one refresh per 0.1 s.
- (void)w7WindowDidUpdate:(NSNotification *)n {
    @try {
        if (_refreshPending || !_observing) return;
        _refreshPending = YES;
        __weak W7ExplorerController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRefreshInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            W7ExplorerController *s = weakSelf;
            if (!s) return;
            s->_refreshPending = NO;
            [s w7RefreshNow];
        });
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer update handler failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)w7RefreshNow {
    @try {
        NSWindow *w = _window;
        if (!w || !_observing) return;
        [_styler refresh];
        [_selectionTracker poll];
        [_computer update];
        [_details refresh];
        // Menu validation follows the key window's responder chain, so only the key window asks.
        if (w.isKeyWindow) {
            [_nav refreshNavigation];
            [_command refresh];
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer refresh failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark Finder actions

// Found menu items, cached weakly per shortcut (main thread only), so the 10 Hz refresh doesn't walk
// Finder's main menu for every control. The keyboard layout's data is cached with them; a layout
// change (key equivalents are localized to it) or a replaced main menu clears both.
static NSMapTable<NSString *, NSMenuItem *> *gMenuItemCache;
static NSMutableSet<NSString *> *gMenuLookupLogged;
static NSData *gMenuLayoutData;
static BOOL gMenuLayoutLoaded;

static void W7ResetMenuItemCache(void) {
    [gMenuItemCache removeAllObjects];
    [gMenuLookupLogged removeAllObjects];
    gMenuLayoutData = nil;
    gMenuLayoutLoaded = NO;
}

static NSString *W7MenuMatchName(W7MenuMatch how) {
    switch (how) {
        case W7MenuMatchKeyEquivalent: return @"key equivalent";
        case W7MenuMatchUserKeyEquivalent: return @"user key equivalent";
        case W7MenuMatchLocalizedKey: return @"localized key equivalent";
        case W7MenuMatchActionName: return @"action name";
        default: return @"nothing";
    }
}

- (NSMenuItem *)itemForKey:(NSString *)key mods:(NSEventModifierFlags)mods {
    static __weak NSMenu *cachedMain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gMenuItemCache = [NSMapTable strongToWeakObjectsMapTable];
        gMenuLookupLogged = [NSMutableSet set];
        [NSDistributedNotificationCenter.defaultCenter
            addObserverForName:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            @try { W7ResetMenuItemCache(); }
            @catch (NSException *e) { os_log_error(W7Log(), "Explorer: menu cache reset failed: %{public}@", e.reason ?: @"unknown"); }
        }];
    });
    NSMenu *main = NSApp.mainMenu;
    if (cachedMain != main) {   // a replaced main menu invalidates everything found in the old one
        [gMenuItemCache removeAllObjects];
        cachedMain = main;
    }
    NSString *tag = [NSString stringWithFormat:@"%@|%lu", key, (unsigned long)mods];
    NSMenuItem *item = [gMenuItemCache objectForKey:tag];
    if (item && item.menu) return item;
    if (!gMenuLayoutLoaded) {
        gMenuLayoutData = W7CurrentKeyboardLayoutData();
        gMenuLayoutLoaded = YES;
    }
    W7MenuMatch how = W7MenuMatchNone;
    item = main ? W7FindMenuItemMatching(main, key, mods, gMenuLayoutData, W7MenuActionHint(key, mods), &how) : nil;
    if (item) {
        [gMenuItemCache setObject:item forKey:tag];
        if (how != W7MenuMatchKeyEquivalent && ![gMenuLookupLogged containsObject:tag]) {
            [gMenuLookupLogged addObject:tag];
            os_log(W7Log(), "Explorer: menu item for key %{public}@ mods 0x%lx found by %{public}@ (\"%{public}@\" %{public}@ key %{public}@)",
                   W7KeyDescription(key), (unsigned long)mods, W7MenuMatchName(how), item.title ?: @"",
                   item.action ? NSStringFromSelector(item.action) : @"(no action)", W7KeyDescription(item.keyEquivalent ?: @""));
        }
    } else {
        [gMenuItemCache removeObjectForKey:tag];
        if (![gMenuLookupLogged containsObject:tag]) {
            [gMenuLookupLogged addObject:tag];
            os_log(W7Log(), "Explorer: Finder has no menu item for key %{public}@ mods 0x%lx; control disabled",
                   W7KeyDescription(key), (unsigned long)mods);
        }
    }
    return item;
}

- (void)validateItems:(NSArray<NSMenuItem *> *)items {
    NSMutableArray<NSMenu *> *menus = [NSMutableArray array];
    for (NSMenuItem *item in items) {
        NSMenu *m = item.menu;
        if (m && [menus indexOfObjectIdenticalTo:m] == NSNotFound) [menus addObject:m];
    }
    for (NSMenu *m in menus) [m update];
}

- (NSMenuItem *)itemForAction:(NSString *)action key:(NSString *)key mods:(NSEventModifierFlags)mods {
    NSMenu *main = NSApp.mainMenu;
    NSString *tag = [@"sel|" stringByAppendingString:action ?: @""];
    NSMenuItem *item = [self itemForKey:key mods:mods];   // also resets the cache for a replaced main menu
    if (item.action && [NSStringFromSelector(item.action) isEqualToString:action]) return item;
    NSMenuItem *bySelector = [gMenuItemCache objectForKey:tag];
    if (bySelector.menu) return bySelector;
    bySelector = action.length && main ? W7SafariFindMenuItem(main, @[ action ]) : nil;   // by selector, breadth first
    if (bySelector) [gMenuItemCache setObject:bySelector forKey:tag];
    return bySelector ?: item;
}

- (BOOL)performAction:(NSString *)action key:(NSString *)key mods:(NSEventModifierFlags)mods {
    @try { return [self w7PerformItem:[self itemForAction:action key:key mods:mods]]; }
    @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer perform failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

- (BOOL)performKey:(NSString *)key mods:(NSEventModifierFlags)mods {
    @try { return [self w7PerformItem:[self itemForKey:key mods:mods]]; }
    @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer perform failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

/// Makes the window key, validates and performs Finder's `item`. NO when missing or disabled.
- (BOOL)w7PerformItem:(NSMenuItem *)item {
    @try {
        NSWindow *w = _window;
        NSMenu *menu = item.menu;
        if (!w || !item || !menu) return NO;
        if (!w.isKeyWindow) [w makeKeyAndOrderFront:nil];
        [menu update];
        if (!item.isEnabled) return NO;
        NSInteger index = [menu indexOfItem:item];
        if (index < 0) return NO;
        [menu performActionForItemAtIndex:index];
        [self scheduleLocationQuery];
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer perform failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

- (void)w7PerformProxy:(NSMenuItem *)sender {
    @try {
        NSDictionary *spec = [sender.representedObject isKindOfClass:NSDictionary.class] ? sender.representedObject : nil;
        NSString *key = spec[@"key"];
        if (![key isKindOfClass:NSString.class]) return;
        [self performKey:key mods:[spec[@"mods"] unsignedIntegerValue]];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer proxy failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)navigateToPath:(NSString *)path {
    @try {
        if (path.length == 0) return;
        NSString *script = W7FinderGoScript(path);
        // Launch off the main thread: Finder's main thread must never wait on the subprocess.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @try {
                NSTask *task = [NSTask new];
                task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
                task.arguments = @[ @"-e", script ];
                task.standardInput = NSFileHandle.fileHandleWithNullDevice;
                task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
                task.standardError = NSFileHandle.fileHandleWithNullDevice;
                __weak W7ExplorerController *weakSelf = self;
                task.terminationHandler = ^(NSTask *t) {
                    if (t.terminationStatus != 0)
                        os_log_error(W7Log(), "Explorer: osascript navigation exited with %d", t.terminationStatus);
                    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf scheduleLocationQuery]; });
                };
                NSError *error = nil;
                if (![task launchAndReturnError:&error])
                    os_log_error(W7Log(), "Explorer: osascript launch failed: %{public}@", error.localizedDescription ?: @"unknown");
            } @catch (NSException *e) {
                os_log_error(W7Log(), "Explorer navigation task failed: %{public}@", e.reason ?: @"unknown");
            }
        });
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer navigate failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)searchFor:(NSString *)text {
    @try {
        NSString *query = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (query.length == 0) return;
        NSString *scope = self.currentFolder.path ?: NSHomeDirectory();
        NSString *name = [NSString stringWithFormat:@"Win7Search-%@.savedSearch", NSUUID.UUID.UUIDString];
        NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        NSError *error = nil;
        if (![W7SavedSearchPlist(query, scope) writeToURL:url options:NSDataWritingAtomic error:&error]) {
            os_log_error(W7Log(), "Explorer: writing saved search failed: %{public}@", error.localizedDescription ?: @"unknown");
            return;
        }
        if (![NSWorkspace.sharedWorkspace openURL:url]) os_log_error(W7Log(), "Explorer: opening saved search failed");
        NSString *dir = NSTemporaryDirectory();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try { W7RemoveStaleSavedSearches(dir, [NSDate date]); }
            @catch (NSException *e) { os_log_error(W7Log(), "Explorer: saved search cleanup failed: %{public}@", e.reason ?: @"unknown"); }
        });
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer search failed: %{public}@", e.reason ?: @"unknown");
    }
}

@end

#pragma mark - Adoption

void W7ExplorerAdopt(NSWindow *window) {
    @try {
        if (!window || objc_getAssociatedObject(window, kExplorerKey)) return;
        W7ExplorerInstallSelectionObserver();     // once; Finder only
        W7ExplorerInstallSelectionHighlight();    // once; Finder only, kill switch W7ExplorerSelectionDisabled
        W7ExplorerController *explorer = [[W7ExplorerController alloc] initWithWindow:window];
        // Marked first, so a failure part-way never retries on every key change.
        objc_setAssociatedObject(window, kExplorerKey, explorer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        window.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
        window.titlebarAppearsTransparent = NO;
        NSToolbar *toolbar = window.toolbar;
        if (toolbar) {
            // Keep the hidden state out of Finder's saved toolbar configuration.
            toolbar.autosavesConfiguration = NO;
            toolbar.visible = NO;
        }

        W7ExplorerNavBarController *nav = [[W7ExplorerNavBarController alloc] initWithExplorer:explorer];
        W7ExplorerCommandBarController *command = [[W7ExplorerCommandBarController alloc] initWithExplorer:explorer];
        [window addTitlebarAccessoryViewController:nav];
        [window addTitlebarAccessoryViewController:command];
        W7ExplorerContentStyler *styler = [[W7ExplorerContentStyler alloc] initWithWindow:window];
        W7ExplorerDetailsController *details = [W7ExplorerDetailsController installInWindow:window explorer:explorer];
        [explorer w7AttachNav:nav command:command];
        [explorer w7AttachDetails:details styler:styler];
        [explorer w7StartObserving];
        // The seed: title only, marked unread until a location query answers (no Computer view on it).
        [explorer w7SetLocation:[W7ExplorerLocation unreadLocationForTitle:window.title ?: @""]];
        [nav refreshActive];
        [styler refresh];
        [explorer scheduleLocationQuery];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "W7ExplorerAdopt failed: %{public}@", e.reason ?: @"unknown");
    }
}
