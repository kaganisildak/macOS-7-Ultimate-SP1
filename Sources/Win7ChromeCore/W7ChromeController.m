#import "Win7ChromeCore.h"
#import <objc/runtime.h>

static const void *kDecoratedKey = &kDecoratedKey;

static const void *kClassLoggedKey = &kClassLoggedKey;

/// Set on full-size-content toolbar windows converted to a classic title bar. The value is
/// the window's original titlebarAppearsTransparent, for W7RevertConversion.
static const void *kConvertedKey = &kConvertedKey;

static W7TitlebarView *W7BarForWindow(NSWindow *w) {
    return objc_getAssociatedObject(w, kDecoratedKey);
}

/// In Finder, turns browser windows into Explorer windows before they are decorated. Logs each
/// window's class once, so the real browser-window class can be reported.
static void W7MaybeAdoptExplorer(NSWindow *w) {
    static NSString *bundleID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bundleID = [NSBundle.mainBundle.bundleIdentifier copy]; });
    if (![bundleID isEqualToString:@"com.apple.finder"]) return;
    W7ExplorerInstallBrowseHook();   // once, before the first adoption; Finder only
    W7ExplorerInstallFolderIconHook();   // once; Finder only
    if (W7IsExplorerWindow(w)) return;
    NSString *cls = NSStringFromClass(w.class);
    // The toolbar fallback only counts for resizable, top-level windows (not Settings, panels or sheets).
    BOOL shape = (w.styleMask & NSWindowStyleMaskTitled) && (w.styleMask & NSWindowStyleMaskResizable) &&
                 ![w isKindOfClass:NSPanel.class] && w.sheetParent == nil;
    BOOL adopt = shape && W7ExplorerShouldAdopt(bundleID, cls, w.toolbar != nil);
    if (!objc_getAssociatedObject(w, kClassLoggedKey)) {
        objc_setAssociatedObject(w, kClassLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        os_log(W7Log(), "Finder window class %{public}@ (toolbar %d, mask 0x%lx): explorer %d",
               cls, w.toolbar != nil, (unsigned long)w.styleMask, adopt);
    }
    if (adopt) W7ExplorerAdopt(w);
}

@interface NSWindow (W7ConvertedWindowGuards)
@end

@implementation NSWindow (W7ConvertedWindowGuards)
// After the swizzle, these selectors hold the ORIGINAL setters. Apps (SwiftUI especially) re-set the
// mask and the toolbar style later; a converted window keeps FullSizeContentView off outside full
// screen and its toolbar Expanded, below the caption row rather than under the caption buttons.
- (void)w7_setStyleMask:(NSWindowStyleMask)mask {
    NSWindowStyleMask guarded = mask;
    @try {
        guarded = W7GuardedStyleMask(mask, objc_getAssociatedObject(self, kConvertedKey) != nil);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "setStyleMask guard failed: %{public}@", e.reason ?: @"unknown");
    }
    [self w7_setStyleMask:guarded];
}

- (void)w7_setToolbarStyle:(NSWindowToolbarStyle)style {
    NSWindowToolbarStyle guarded = style;
    @try {
        guarded = W7GuardedToolbarStyle(style, objc_getAssociatedObject(self, kConvertedKey) != nil);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "setToolbarStyle guard failed: %{public}@", e.reason ?: @"unknown");
    }
    [self w7_setToolbarStyle:guarded];
}
@end

void W7InstallConvertedWindowGuards(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            if (!W7SwizzleInstanceMethod(NSWindow.class, @selector(setStyleMask:), @selector(w7_setStyleMask:))) {
                os_log_error(W7Log(), "swizzle of -[NSWindow setStyleMask:] failed");
            }
            if (!W7SwizzleInstanceMethod(NSWindow.class, @selector(setToolbarStyle:), @selector(w7_setToolbarStyle:))) {
                os_log_error(W7Log(), "swizzle of -[NSWindow setToolbarStyle:] failed");
            }
        } @catch (NSException *e) {
            os_log_error(W7Log(), "converted window guard install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}

#pragma mark - Native title in decorated windows

static const void *kTitleVisibilityCoercedKey = &kTitleVisibilityCoercedKey;
static const void *kTransparencyCoercedKey = &kTransparencyCoercedKey;
static const void *kHiddenTitleClassesKey = &kHiddenTitleClassesKey;

/// Logs the first coercion of `setter` on `w`, so a live log shows which app re-set what.
static void W7LogCoercionOnce(NSWindow *w, const void *key, const char *setter, long requested, long applied) {
    if (objc_getAssociatedObject(w, key)) return;
    objc_setAssociatedObject(w, key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    os_log(W7Log(), "decorated window %{public}@ '%{public}@': %{public}s %ld coerced to %ld",
           NSStringFromClass(w.class), w.title ?: @"", setter, requested, applied);
}

@interface NSWindow (W7DecoratedWindowGuards)
@end

@implementation NSWindow (W7DecoratedWindowGuards)
// After the swizzle, these selectors hold the ORIGINAL setters. Apps (SwiftUI especially) may re-set the
// title visibility and the title bar transparency after decoration; AppKit would then draw its own title next to the Aero
// bar's (a doubled caption text, the app icon over the native title glyphs).
- (void)w7_setTitleVisibility:(NSWindowTitleVisibility)visibility {
    NSWindowTitleVisibility guarded = visibility;
    @try {
        guarded = W7GuardedTitleVisibility(visibility, W7BarForWindow(self) != nil);
        if (guarded != visibility) {
            W7LogCoercionOnce(self, kTitleVisibilityCoercedKey, "titleVisibility", (long)visibility, (long)guarded);
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "setTitleVisibility guard failed: %{public}@", e.reason ?: @"unknown");
    }
    [self w7_setTitleVisibility:guarded];
}

- (void)w7_setTitlebarAppearsTransparent:(BOOL)transparent {
    BOOL guarded = transparent;
    @try {
        guarded = W7GuardedTitlebarAppearsTransparent(transparent, W7BarForWindow(self) != nil);
        if (guarded != transparent) {
            W7LogCoercionOnce(self, kTransparencyCoercedKey, "titlebarAppearsTransparent", transparent, guarded);
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "setTitlebarAppearsTransparent guard failed: %{public}@", e.reason ?: @"unknown");
    }
    [self w7_setTitlebarAppearsTransparent:guarded];
}
@end

void W7InstallDecoratedWindowGuards(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            if (!W7SwizzleInstanceMethod(NSWindow.class, @selector(setTitleVisibility:), @selector(w7_setTitleVisibility:))) {
                os_log_error(W7Log(), "swizzle of -[NSWindow setTitleVisibility:] failed");
            }
            if (!W7SwizzleInstanceMethod(NSWindow.class, @selector(setTitlebarAppearsTransparent:),
                                         @selector(w7_setTitlebarAppearsTransparent:))) {
                os_log_error(W7Log(), "swizzle of -[NSWindow setTitlebarAppearsTransparent:] failed");
            }
        } @catch (NSException *e) {
            os_log_error(W7Log(), "decorated window guard install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}

static BOOL W7CNameHasSuffix(const char *name, const char *suffix) {
    size_t n = strlen(name), s = strlen(suffix);
    return n >= s && strcmp(name + n - s, suffix) == 0;
}

/// AppKit's own title field: a text field directly in the title bar view, showing the window title.
static BOOL W7IsAppKitTitleField(NSView *v, NSString *title) {
    return [v isKindOfClass:NSTextField.class] && title.length && [((NSTextField *)v).stringValue isEqualToString:title];
}

/// Bounded so it stays cheap on every window switch: the title bar view's direct children, and (with
/// `descend`) the direct children of an AppKit toolbar view among them, where the toolbar's title view sits.
/// Toolbar items and accessories are never searched. Class names are read with class_getName, without
/// allocating; `hidden` is only created when something is hidden.
static NSUInteger W7HideTitleViewsIn(NSView *parent, NSView *titlebar, NSString *title, BOOL descend,
                                     NSUInteger *visited, NSMutableArray<NSString *> *__strong *hidden) {
    NSUInteger count = 0;
    for (NSView *v in parent.subviews) {
        (*visited)++;
        if ([v isKindOfClass:W7TitlebarView.class]) continue;
        const char *cls = class_getName(v.class);
        if (W7IsNativeTitleViewClassCName(cls) || (parent == titlebar && W7IsAppKitTitleField(v, title))) {
            if (!v.isHidden && [v respondsToSelector:@selector(setHidden:)]) {
                v.hidden = YES;
                count++;
                if (!*hidden) *hidden = [NSMutableArray array];
                [*hidden addObject:@(cls)];
            }
            continue;
        }
        if (descend && W7CNameHasSuffix(cls, "ToolbarView")) {
            count += W7HideTitleViewsIn(v, titlebar, title, NO, visited, hidden);
        }
    }
    return count;
}

NSUInteger W7HideNativeTitleViewsVisited(NSWindow *w, NSUInteger *visitedViews) {
    NSUInteger visited = 0;
    @try {
        if (!w || !W7BarForWindow(w)) return 0;
        NSView *titlebar = [w standardWindowButton:NSWindowCloseButton].superview;
        if (!titlebar) return 0;
        NSMutableArray<NSString *> *hidden = nil;
        // Hidden views are never shown again: a decorated window is never undecorated.
        NSUInteger count = W7HideTitleViewsIn(titlebar, titlebar, w.title ?: @"", YES, &visited, &hidden);
        if (hidden) {
            NSMutableSet<NSString *> *logged = objc_getAssociatedObject(w, kHiddenTitleClassesKey);
            if (!logged) {
                logged = [NSMutableSet set];
                objc_setAssociatedObject(w, kHiddenTitleClassesKey, logged, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            for (NSString *cls in hidden) {
                if ([logged containsObject:cls]) continue;
                [logged addObject:cls];
                os_log(W7Log(), "decorated window %{public}@ '%{public}@': hid native title view %{public}@",
                       NSStringFromClass(w.class), w.title ?: @"", cls);
            }
        }
        if (visitedViews) *visitedViews = visited;
        return count;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "hiding native title views failed: %{public}@", e.reason ?: @"unknown");
        if (visitedViews) *visitedViews = visited;
        return 0;
    }
}

NSUInteger W7HideNativeTitleViews(NSWindow *w) {
    return W7HideNativeTitleViewsVisited(w, NULL);
}

BOOL W7RehideNativeTitleViewsOncePerTurn(NSWindow *w) {
    // Becoming key and becoming main arrive together on a window switch; one pass per run-loop turn.
    static NSHashTable<NSWindow *> *doneThisTurn;
    if (!w || !W7BarForWindow(w)) return NO;
    if (!doneThisTurn) doneThisTurn = [NSHashTable weakObjectsHashTable];
    if ([doneThisTurn containsObject:w]) return NO;
    if (doneThisTurn.count == 0) {
        // A run-loop block, not dispatch_async: the main queue is not drained while a main-queue block
        // runs a nested run loop, but run-loop blocks run on the loop's next pass in any common mode.
        CFRunLoopRef main = CFRunLoopGetMain();
        CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{ [doneThisTurn removeAllObjects]; });
        CFRunLoopWakeUp(main);
    }
    [doneThisTurn addObject:w];
    W7HideNativeTitleViews(w);
    return YES;
}

/// Title-like views for the diagnostic line: text fields and views whose class names mention a title,
/// except the title bar's own containers ("Titlebar…View"), which every window has. Searched from the
/// same root as the hide pass (the title bar view) but at any depth; `reach=1` marks the views the bounded
/// hide pass looks at, so a title view it misses shows up as `reach=0`.
static void W7CollectTitleViews(NSView *parent, NSString *title, NSUInteger depth, BOOL parentIsToolbar,
                                NSMutableArray<NSString *> *out) {
    for (NSView *v in parent.subviews) {
        NSString *cls = NSStringFromClass(v.class);
        if ([cls hasPrefix:@"W7"]) continue;
        BOOL field = [v isKindOfClass:NSTextField.class];
        BOOL titled = W7IsNativeTitleViewClassName(cls) || ([cls containsString:@"Title"] && ![cls containsString:@"Titlebar"]);
        if (field || titled) {
            // Text field contents are not logged, only whether they show the window title.
            BOOL showsTitle = field && title.length && [((NSTextField *)v).stringValue isEqualToString:title];
            BOOL reach = depth == 1 || (depth == 2 && parentIsToolbar);
            [out addObject:[NSString stringWithFormat:@"%@(depth=%lu,reach=%d,hidden=%d,effective=%d%@)", cls,
                            (unsigned long)depth, reach, v.isHidden, v.isHiddenOrHasHiddenAncestor,
                            showsTitle ? @",title" : @""]];
        }
        W7CollectTitleViews(v, title, depth + 1, depth == 1 && [cls hasSuffix:@"ToolbarView"], out);
    }
}

NSString *W7TitlebarDiagnostics(NSWindow *w) {
    @try {
        NSToolbar *tb = w.toolbar;
        NSMutableArray<NSString *> *items = [NSMutableArray array];
        for (NSToolbarItem *item in tb.items) [items addObject:item.itemIdentifier ?: @"?"];
        NSMutableArray<NSString *> *views = [NSMutableArray array];
        NSView *titlebar = [w standardWindowButton:NSWindowCloseButton].superview;
        if (titlebar) W7CollectTitleViews(titlebar, w.title ?: @"", 1, NO, views);
        return [NSString stringWithFormat:@"%@ '%@' titleVisibility=%ld transparent=%d toolbar=%d displayMode=%ld "
                                          @"toolbarStyle=%ld items=[%@] titleViews(under %@)=[%@]",
                NSStringFromClass(w.class), w.title ?: @"", (long)w.titleVisibility, w.titlebarAppearsTransparent,
                tb != nil, (long)tb.displayMode, (long)w.toolbarStyle, [items componentsJoinedByString:@","],
                titlebar ? NSStringFromClass(titlebar.class) : @"nil", [views componentsJoinedByString:@", "]];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"diagnostics failed: %@", e.reason ?: @"unknown"];
    }
}

/// Logs the title bar once at decoration (with the values the app had set) and once more after a second,
/// when SwiftUI has built its toolbar and may have re-set the title, hiding any native title view by then.
static void W7LogDecoration(NSWindow *w, NSWindowTitleVisibility appVisibility, BOOL appTransparent,
                            NSWindowToolbarStyle appStyle) {
    os_log(W7Log(), "decorated (app had titleVisibility=%ld transparent=%d toolbarStyle=%ld): %{public}@",
           (long)appVisibility, appTransparent, (long)appStyle, W7TitlebarDiagnostics(w));
    __weak NSWindow *weakWindow = w;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @try {
            NSWindow *win = weakWindow;
            if (!win || !W7BarForWindow(win)) return;
            W7HideNativeTitleViews(win);
            os_log(W7Log(), "decorated, settled: %{public}@", W7TitlebarDiagnostics(win));
        } @catch (NSException *e) {
            os_log_error(W7Log(), "settled diagnostics failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}

/// Turns a unified-toolbar window (Safari, Notes, Mail, System Settings), or an Apple app's toolbar-less
/// full-size window (Terminal), into a classic title bar with any toolbar below it, so the normal decoration
/// path accepts it. The window is marked first, so a failure part-way through is still reverted by
/// decorateWindow's catch path.
static void W7MaybeConvertFullSizeWindow(NSWindow *w) {
    if (!W7ShouldConvertFullSizeWindow(w.styleMask, [w isKindOfClass:NSPanel.class], w.sheetParent != nil,
                                       w.toolbar != nil, W7IsAppleAppForFullSizeConversion(NSBundle.mainBundle.bundleIdentifier),
                                       NSStringFromClass(w.class))) return;
    objc_setAssociatedObject(w, kConvertedKey, @(w.titlebarAppearsTransparent), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    w.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
    w.titlebarAppearsTransparent = NO;
}

/// Undoes a conversion whose decoration failed before the bar was attached, so the window is not left
/// mask-stripped without an Aero bar and the next key/main notification can retry from its original state.
static void W7RevertConversion(NSWindow *w) {
    @try {
        NSNumber *originalTransparent = objc_getAssociatedObject(w, kConvertedKey);
        if (!originalTransparent || objc_getAssociatedObject(w, kDecoratedKey)) return;
        objc_setAssociatedObject(w, kConvertedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The conversion only ran on windows with FullSizeContentView, so restoring it is exact.
        w.styleMask |= NSWindowStyleMaskFullSizeContentView;
        w.titlebarAppearsTransparent = originalTransparent.boolValue;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "conversion revert failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark - The app's own icon from the user's set

static NSImage *gAppliedAppIcon;   // set once on the main thread at start, then only read

NSString *W7AppIconOverrideName(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0 || bundleID.length > 120) return nil;
    for (NSUInteger i = 0; i < bundleID.length; i++) {   // IconOverrideNames.app: [A-Za-z0-9][A-Za-z0-9._-]*
        unichar c = [bundleID characterAtIndex:i];
        BOOL alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        if (!alnum && (i == 0 || (c != '.' && c != '-' && c != '_'))) return nil;
    }
    return [@"app-" stringByAppendingString:bundleID];
}

BOOL W7AppIconOverrideShouldApply(NSString *bundleID, BOOL disabled) {
    return !disabled && W7AppIconOverrideName(bundleID) != nil && ![bundleID isEqualToString:@"com.win7mac.shell"];
}

BOOL W7AppIconOverrideAppliesToProcess(NSString *bundleID, NSString *bundlePath) {
    // Apps only (as the font substitution): an appex, XPC or view service never looks an icon up.
    return W7AppIconOverrideName(bundleID) != nil && ![bundleID isEqualToString:@"com.win7mac.shell"] &&
           W7FontSubstitutionAppliesToBundlePath(bundlePath);
}

NSImage *W7AppIconOverrideImage(NSString *bundleID, BOOL disabled) {
    @try {
        if (!W7AppIconOverrideShouldApply(bundleID, disabled)) return nil;
        // A new image (1x and 2x from the loader's cache): AppKit may resize what it is handed.
        return W7UserIconImageSized(W7AppIconOverrideName(bundleID), NSMakeSize(128, 128));
    } @catch (NSException *e) {
        os_log_error(W7Log(), "app icon failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

BOOL W7AppIconDisabled(void) {
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7AppIconDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

NSImage *W7AppIconOverrideAppliedImage(void) { return gAppliedAppIcon; }

void W7AppIconOverrideInstall(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    @try {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        // Nothing to look up, the shell, or not an .app (extensions and services): no lookup, no log line.
        if (!W7AppIconOverrideAppliesToProcess(bundleID, NSBundle.mainBundle.bundlePath)) return;
        NSString *name = W7AppIconOverrideName(bundleID);
        BOOL disabled = W7AppIconDisabled();
        NSImage *image = W7AppIconOverrideImage(bundleID, disabled);
        if (image) {
            NSApp.applicationIconImage = image;
            gAppliedAppIcon = image;
        }
        os_log(W7Log(), "app icon: %{public}@ %{public}s", name, disabled ? "disabled" : image ? "applied" : "absent");
    } @catch (NSException *e) {
        os_log_error(W7Log(), "app icon install failed: %{public}@", e.reason ?: @"unknown");
    }
}

@implementation W7ChromeController

+ (void)start {
    static BOOL started;
    if (started) return;
    started = YES;
    @try {
        W7InstallContextMenuHook();
        [W7PeekController start];
        [W7CloseChannel start];   // the taskbar's Close window / Close all windows (W7CloseChannelDisabled)
        W7InstallCursors();   // already done by the constructor; idempotent
        [[NSCursor arrowCursor] set];
        W7InstallConvertedWindowGuards();
        W7InstallDecoratedWindowGuards();
        W7InstallMessageBoxes();   // (frame overlays attach from W7TitlebarView)
        W7ToolbarLookInstall();   // the command-bar look for app toolbars (W7ToolbarLookDisabled)
        W7MessagesLookInstall();   // Messages only; the Messenger band, diagnostics behind W7MessagesVerboseLog (W7MessagesLookDisabled)
        W7SettingsPanelInstall();   // System Settings only
        W7InstallFontSubstitution();   // only when the user imported Segoe UI; before windows are decorated
        W7AppIconOverrideInstall();   // app-<bundle id>.png as the app's own icon; before windows are decorated
        if (W7InstallControlHooks()) {   // push buttons, check boxes, radios, scroll bars
            for (NSWindow *w in [NSApp.windows copy]) W7AdoptScrollersInView(w.contentView.superview ?: w.contentView);
        }
        for (NSWindow *w in [NSApp.windows copy]) {
            [self decorateWindow:w];
            W7ToolbarLookUpdate(w);
            W7MessagesLookUpdate(w);
            W7SettingsSidebarDiagnosticsUpdate(w);
        }
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        NSOperationQueue *q = NSOperationQueue.mainQueue;
        void (^onBecome)(NSNotification *) = ^(NSNotification *n) { [self w7KeyOrMainChanged:n becoming:YES]; };
        void (^onResign)(NSNotification *) = ^(NSNotification *n) { [self w7KeyOrMainChanged:n becoming:NO]; };
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:q usingBlock:onBecome];
        [nc addObserverForName:NSWindowDidBecomeMainNotification object:nil queue:q usingBlock:onBecome];
        [nc addObserverForName:NSWindowDidResignKeyNotification object:nil queue:q usingBlock:onResign];
        [nc addObserverForName:NSWindowDidResignMainNotification object:nil queue:q usingBlock:onResign];
        // No occlusion observer: the title bar's layers keep their contents while covered, so
        // an occlusion change needs no redraw.
        W7SafariChromeStart();   // Safari only; after the observers above, so windows are decorated first
    } @catch (NSException *e) {
        os_log_error(W7Log(), "W7ChromeController start failed: %{public}@", e.reason ?: @"unknown");
    }
}

+ (void)w7KeyOrMainChanged:(NSNotification *)n becoming:(BOOL)becoming {
    @try {
        NSWindow *w = n.object;
        if (![w isKindOfClass:NSWindow.class]) return;
        BOOL wasDecorated = W7BarForWindow(w) != nil;
        [self decorateWindow:w];
        W7ToolbarLookUpdate(w);   // after decorating (it needs the Aero title bar); idempotent
        W7MessagesLookUpdate(w);   // Messages only; after the toolbar look (the band takes its fill); the dump once per main window
        W7SettingsSidebarDiagnosticsUpdate(w);   // System Settings only, once per main window (W7SettingsVerboseLog); draws nothing
        // A window decorated just now already had its hide pass in decorateWindow.
        if (becoming && wasDecorated) W7RehideNativeTitleViewsOncePerTurn(w);
        [W7BarForWindow(w) refresh];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "key/main handler failed: %{public}@", e.reason ?: @"unknown");
    }
}

+ (void)decorateWindow:(NSWindow *)w {
    @try {
        if (!w || objc_getAssociatedObject(w, kDecoratedKey)) return;
        NSWindowTitleVisibility appVisibility = w.titleVisibility;
        BOOL appTransparent = w.titlebarAppearsTransparent;
        NSWindowToolbarStyle appStyle = w.toolbarStyle;
        W7MaybeAdoptExplorer(w);
        W7MaybeConvertFullSizeWindow(w);
        BOOL isSheet = w.sheetParent != nil;
        BOOL isPanel = [w isKindOfClass:NSPanel.class];
        BOOL isDialog = isPanel && W7IsDialogPanelWindow(w);   // About, Preferences, Get Info
        // Windows 7 Explorer hides its menu bar, so Explorer windows get no strip; dialogs have none either.
        BOOL showStrip = W7ShouldShowMenuStrip(w.styleMask, NSApp.modalWindow == w) && NSApp.mainMenu != nil &&
                         !W7IsExplorerWindow(w) && !isDialog;
        if (!W7ShouldDecorateWindowOrDialog(w.styleMask, isPanel, isDialog, w.titlebarAppearsTransparent, isSheet)) return;
        NSButton *close = [w standardWindowButton:NSWindowCloseButton];
        NSView *bar = close.superview;
        if (!bar) return;

        W7TitlebarView *view = [[W7TitlebarView alloc] initWithFrame:bar.bounds];
        [bar addSubview:view positioned:NSWindowBelow relativeTo:nil];
        objc_setAssociatedObject(w, kDecoratedKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (isDialog) view.w7DialogCaption = YES;

        const NSWindowButton kinds[] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton };
        for (size_t i = 0; i < 3; i++) [w standardWindowButton:kinds[i]].hidden = YES;
        w.titleVisibility = NSWindowTitleHidden;
        w.titlebarAppearsTransparent = YES;
        if (w.toolbar) w.toolbarStyle = NSWindowToolbarStyleExpanded;
        // Inserted at accessory index 0, not appended: first among the bottom accessories, the strip sits
        // directly under the title bar, above an app's own bars (TextEdit's format bar), as the Windows 7
        // menu bar does. A real NSToolbar still comes first: AppKit lays bottom accessories below it, and
        // the one attribute that goes above it (NSLayoutAttributeTop) raises unless the window has
        // FullSizeContentView, which converted windows give up (see W7MenuStripController's init).
        if (showStrip) [w insertTitlebarAccessoryViewController:[[W7MenuStripController alloc] init] atIndex:0];
        W7HideNativeTitleViews(w);
        if (isDialog) W7StyleDialogPanel(w);   // white body and button strip
        W7LogDecoration(w, appVisibility, appTransparent, appStyle);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "decorateWindow failed: %{public}@", e.reason ?: @"unknown");
        if (w) W7RevertConversion(w);
    }
}

@end
