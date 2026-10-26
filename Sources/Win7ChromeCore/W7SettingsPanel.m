// System Settings and the Windows 7 Control Panel. On macOS 26+ the System Settings sidebar is
// Liquid Glass (an NSGlassEffectView holding the list) and cannot be restyled with public API: nothing drawn
// under or inside the glass shows, and its material cannot be turned off. What remains is the white window
// background + security-pane exclusion only: the window background is white while the visible pane is not
// one of the security panes, and put back exactly the moment one shows. The sidebar is never changed.
//
// Scope: System Settings' own process (com.apple.systempreferences) only. Pane content is an
// _EXHostViewController → NSRemoteView drawn by the pane's own .appex process and is never touched;
// the security panes' processes are on the default denylist and the Ammonia blacklist besides.
//
// Pane detection has no AX: the visible _EXHostViewController's configuration names the extension
// (extensionIdentity.bundleIdentifier), with the NSRemoteView's service bundle id as the fallback.
// Unknown or transitioning panes count as excluded, so the window is native until the pane is known.
// Re-checked after -[_EXHostViewController setConfiguration:] / -viewWillAppear, on title and appearance
// changes and on key/main changes. Kill switch: `defaults write com.apple.systempreferences
// W7SettingsPanelDisabled -bool YES`. Every private call is checked first (class, respondsToSelector, type
// encoding), runs in @try, and a failure leaves (or puts back) the native look.
#import "W7SettingsPanelInternal.h"
#import <objc/runtime.h>

static NSString *const kSettingsBundleID = @"com.apple.systempreferences";
static NSString *const kSettingsPanelDisabledKey = @"W7SettingsPanelDisabled";


#pragma mark - Pure decisions

NSArray<NSString *> *W7SettingsExcludedPaneIDs(void) {
    return [W7SettingsExcludedExtensionIDs() arrayByAddingObjectsFromArray:@[
        @"com.apple.settings.privacyAndSecurity", @"com.apple.preference.security",
        @"com.apple.settings.passcodeAndBiometrics", @"com.apple.preferences.password",
        @"com.apple.settings.usersAndGroups", @"com.apple.preferences.users",
        @"com.apple.settings.lockScreen", @"com.apple.Passwords",
    ]];
}

/// Lowercased, trimmed, without a `?…`/`#…` anchor; nil when nothing is left.
static NSString *W7NormalizedPaneID(NSString *paneID) {
    if (![paneID isKindOfClass:NSString.class]) return nil;
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *s = [paneID stringByTrimmingCharactersInSet:space];
    NSRange anchor = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
    if (anchor.location != NSNotFound) s = [[s substringToIndex:anchor.location] stringByTrimmingCharactersInSet:space];
    return s.length ? s.lowercaseString : nil;   // -lowercaseString is locale-independent (Turkish I stays i)
}

BOOL W7SettingsPaneIsExcluded(NSString *paneID) {
    NSString *norm = W7NormalizedPaneID(paneID);
    if (!norm) return YES;
    for (NSString *excluded in W7SettingsExcludedPaneIDs()) {
        NSString *ex = excluded.lowercaseString;
        if ([norm isEqualToString:ex] || [norm hasPrefix:[ex stringByAppendingString:@"."]]) return YES;
    }
    return NO;
}

NSString *W7SettingsResolvePaneID(NSString *configurationID, NSString *remoteServiceID) {
    if (W7NormalizedPaneID(configurationID)) return configurationID;
    if (W7NormalizedPaneID(remoteServiceID)) return remoteServiceID;
    return nil;
}

BOOL W7SettingsProbeIsExcluded(NSString *configurationID, NSString *remoteServiceID) {
    BOOL knowsConfig = W7NormalizedPaneID(configurationID) != nil, knowsRemote = W7NormalizedPaneID(remoteServiceID) != nil;
    if (!knowsConfig && !knowsRemote) return YES;
    if (knowsConfig && W7SettingsPaneIsExcluded(configurationID)) return YES;
    if (knowsRemote && W7SettingsPaneIsExcluded(remoteServiceID)) return YES;
    return NO;
}

BOOL W7SettingsProbesAllowStyling(NSArray<NSDictionary<NSString *, NSString *> *> *probes) {
    if (![probes isKindOfClass:NSArray.class] || probes.count == 0) return NO;
    for (NSDictionary *probe in probes) {
        if (![probe isKindOfClass:NSDictionary.class]) return NO;
        if (W7SettingsProbeIsExcluded(probe[@"configuration"], probe[@"remote"])) return NO;
    }
    return YES;
}

BOOL W7SettingsPanelShouldInstall(NSString *bundleID, BOOL disabled) {
    return !disabled && [bundleID isKindOfClass:NSString.class] && [bundleID isEqualToString:kSettingsBundleID];
}

#pragma mark - Pane detection

static NSString *W7RemoteServiceID(NSView *remoteView) {
    SEL service = sel_registerName("serviceBundleIdentifier");
    NSString *sid = W7SPGetString(remoteView.nextResponder, service);
    if (!sid) sid = W7SPGetString(W7SPGetObject(remoteView, sel_registerName("remoteViewController")), service);
    return sid;
}

static NSString *W7HostConfigurationID(NSViewController *vc) {
    id configuration = W7SPGetObject(vc, sel_registerName("configuration"));
    id identity = W7SPGetObject(configuration, sel_registerName("extensionIdentity"));
    return W7SPGetString(identity, sel_registerName("bundleIdentifier"));
}

typedef struct {
    Class host, remote;
    NSUInteger budget;
    BOOL truncated;
} W7ProbeWalk;

static void W7ProbeView(NSView *v, W7ProbeWalk *walk, NSMutableDictionary *current, NSMutableArray *out, NSUInteger depth) {
    if (!v || v.isHidden) return;
    if (depth > kProbeMaxDepth || walk->budget == 0) { walk->truncated = YES; return; }
    walk->budget--;
    NSMutableDictionary *probe = current;
    id responder = v.nextResponder;
    if (walk->host && [responder isKindOfClass:walk->host] && [responder isKindOfClass:NSViewController.class] &&
        ((NSViewController *)responder).viewIfLoaded == v) {
        probe = [NSMutableDictionary dictionary];
        NSString *config = W7HostConfigurationID(responder);
        if (config) probe[@"configuration"] = config;
        [out addObject:probe];
    }
    if (walk->remote && [v isKindOfClass:walk->remote]) {
        NSString *sid = W7RemoteServiceID(v);
        if (!probe) {
            probe = [NSMutableDictionary dictionary];
            [out addObject:probe];
        }
        if (sid && !probe[@"remote"]) probe[@"remote"] = sid;
        return;   // the remote view's content belongs to the pane's process
    }
    for (NSView *sub in v.subviews) W7ProbeView(sub, walk, probe, out, depth + 1);
}

NSArray<NSDictionary<NSString *, NSString *> *> *W7SettingsProbePanes(NSView *root, Class hostClass, Class remoteViewClass) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        if (!root || (!hostClass && !remoteViewClass)) return @[];
        W7ProbeWalk walk = { hostClass, remoteViewClass, kProbeMaxViews, NO };
        W7ProbeView(root, &walk, nil, out, 0);
        // A walk cut short may have missed an excluded pane: report one unknown pane.
        if (walk.truncated) [out addObject:[NSMutableDictionary dictionary]];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "settings panel: pane probe failed: %{public}@", e.reason ?: @"unknown");
        [out addObject:[NSMutableDictionary dictionary]];
    }
    NSMutableArray *copies = [NSMutableArray arrayWithCapacity:out.count];
    for (NSDictionary *probe in out) [copies addObject:[probe copy]];
    return copies;
}

#pragma mark - Window background

NSUInteger W7SettingsApplyWindowBackground(NSWindow *window, BOOL style) {
    if (!window) return 0;
    NSUInteger count = 0;
    @try {
        // A sidebar marks the main Settings window; it is only looked at, never changed.
        count = W7SPSidebarWrappers(window).count;
        if (style && count > 0) {
            W7SettingsSnapshot *snapshot = W7SPSnapshotFor(window);
            BOOL fresh = snapshot == nil;
            if (fresh) snapshot = W7SPCreateSnapshot(window);
            W7SPRecord(snapshot, window, W7SPChangeName(window, @"backgroundColor"),
                     ^id(NSWindow *w) { return w.backgroundColor; },
                     ^(NSWindow *w, id original) { w.backgroundColor = W7SPUnboxed(original); });   // nil included (null_resettable)
            if (window.backgroundColor != NSColor.whiteColor) window.backgroundColor = NSColor.whiteColor;
            if (fresh) W7SPLogTransition(window, @"styled", W7SPChangeLines(snapshot));
        } else if (W7SPWindowIsStyled(window)) {
            W7SPLogTransition(window, @"restored", W7SPRestoreSnapshot(window));
        }
        return count;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "settings panel: %{public}s failed: %{public}@", style ? "styling" : "restoring",
                     e.reason ?: @"unknown");
        @try {
            if (W7SPWindowIsStyled(window)) W7SPLogTransition(window, @"restored after failure", W7SPRestoreSnapshot(window));
        } @catch (NSException *e2) {
            os_log_error(W7Log(), "settings panel: restore after failure failed: %{public}@", e2.reason ?: @"unknown");
        }
        return 0;
    }
}

#pragma mark - Refresh

static const void *kLastSummaryKey = &kLastSummaryKey;

BOOL W7SettingsRefreshWindowWithClasses(NSWindow *window, Class hostClass, Class remoteViewClass) {
    if (!window) return NO;
    @try {
        NSArray *probes = W7SettingsProbePanes(window.contentView, hostClass, remoteViewClass);
        BOOL dark = W7ExplorerAppearanceIsDark(window.effectiveAppearance);
        BOOL style = !dark && W7SettingsProbesAllowStyling(probes);
        NSUInteger sidebars = W7SettingsApplyWindowBackground(window, style);
        BOOL styled = style && sidebars > 0 && W7SPWindowIsStyled(window);
        NSString *summary = [NSString stringWithFormat:@"panes [%@], dark %d, sidebars %lu, styled %d", W7SPProbeSummary(probes),
                             dark, (unsigned long)sidebars, styled];
        // Windows without panes or a sidebar (menus, panels) are not logged.
        BOOL relevant = sidebars > 0 || probes.count > 0 || objc_getAssociatedObject(window, kLastSummaryKey);
        if (relevant && ![summary isEqualToString:objc_getAssociatedObject(window, kLastSummaryKey)]) {
            objc_setAssociatedObject(window, kLastSummaryKey, summary, OBJC_ASSOCIATION_COPY_NONATOMIC);
            W7SPLogDiagnostics(window, summary);
        }
        return styled;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "settings panel: refresh failed: %{public}@", e.reason ?: @"unknown");
        W7SettingsApplyWindowBackground(window, NO);
        return NO;
    }
}

BOOL W7SettingsRefreshWindow(NSWindow *window) {
    return W7SettingsRefreshWindowWithClasses(window, NSClassFromString(@"_EXHostViewController"), NSClassFromString(@"NSRemoteView"));
}

/// Refreshes `window` (or every window, when nil) on the main run loop's next pass, once per pass.
static void W7ScheduleRefresh(NSWindow *window) {
    static NSHashTable<NSWindow *> *pending;
    static BOOL scheduled, all;
    if (!pending) pending = [NSHashTable weakObjectsHashTable];
    if (window) [pending addObject:window];
    else all = YES;
    if (scheduled) return;
    scheduled = YES;
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, ^{
        scheduled = NO;
        NSArray<NSWindow *> *windows = all ? [NSApp.windows copy] : pending.allObjects;
        all = NO;
        [pending removeAllObjects];
        for (NSWindow *w in windows) W7SettingsRefreshWindow(w);
    });
    CFRunLoopWakeUp(main);
}

/// Now and once more after the pane has had time to settle.
static void W7ScheduleRefreshAndSettle(NSWindow *window) {
    W7ScheduleRefresh(window);
    __weak NSWindow *weakWindow = window;
    BOOL any = window == nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        NSWindow *w = weakWindow;
        if (w || any) W7ScheduleRefresh(w);
    });
}

#pragma mark - Observation

static const void *kWindowObserverKey = &kWindowObserverKey;
static void *kTitleKVOContext = &kTitleKVOContext;   // title and effectiveAppearance

@interface W7SettingsWindowObserver : NSObject
@property (nonatomic, weak) NSWindow *window;
@end

@implementation W7SettingsWindowObserver

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)ctx {
    if (ctx != kTitleKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:ctx];
        return;
    }
    NSWindow *w = self.window;
    if (NSThread.isMainThread) W7ScheduleRefreshAndSettle(w);
    else dispatch_async(dispatch_get_main_queue(), ^{ W7ScheduleRefreshAndSettle(w); });
}

- (void)w7WindowWillClose:(NSNotification *)n {
    @try {
        NSWindow *w = n.object;
        // A window closed while styled: the background put back and the snapshot dropped.
        if ([w isKindOfClass:NSWindow.class]) W7SettingsApplyWindowBackground(w, NO);
        [NSNotificationCenter.defaultCenter removeObserver:self];
        [w removeObserver:self forKeyPath:@"title" context:kTitleKVOContext];
        [w removeObserver:self forKeyPath:@"effectiveAppearance" context:kTitleKVOContext];
        objc_setAssociatedObject(w, kWindowObserverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "settings panel: observer removal failed: %{public}@", e.reason ?: @"unknown");
    }
}

@end

static void W7TrackWindow(NSWindow *w) {
    if (![w isKindOfClass:NSWindow.class] || objc_getAssociatedObject(w, kWindowObserverKey)) return;
    W7SettingsWindowObserver *observer = [W7SettingsWindowObserver new];
    observer.window = w;
    objc_setAssociatedObject(w, kWindowObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A title change is how a pane switch shows; an appearance change turns Dark Mode's native look on or off.
    [w addObserver:observer forKeyPath:@"title" options:0 context:kTitleKVOContext];
    [w addObserver:observer forKeyPath:@"effectiveAppearance" options:0 context:kTitleKVOContext];
    [NSNotificationCenter.defaultCenter addObserver:observer selector:@selector(w7WindowWillClose:)
                                               name:NSWindowWillCloseNotification object:w];
}

void W7SettingsHostChangedWithClasses(NSViewController *vc, Class hostClass, Class remoteViewClass, BOOL followUps) {
    @try {
        NSWindow *w = vc.viewIfLoaded.window;
        if (w) {
            W7TrackWindow(w);
            W7SettingsRefreshWindowWithClasses(w, hostClass, remoteViewClass);
        } else {
            // No window yet: the new pane can't be probed, so it is unknown, which counts as excluded. Every
            // styled window goes native now; the follow-up refreshes style it again once the pane is known.
            for (NSWindow *styled in W7SPStyledWindows().allObjects) W7SettingsApplyWindowBackground(styled, NO);
        }
        if (followUps) W7ScheduleRefreshAndSettle(w);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "settings panel: pane change check failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// After a host view controller changed its pane (setConfiguration:, viewWillAppear).
static void W7HostChanged(NSViewController *vc) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ W7HostChanged(vc); });
        return;
    }
    W7SettingsHostChangedWithClasses(vc, NSClassFromString(@"_EXHostViewController"), NSClassFromString(@"NSRemoteView"), YES);
}

/// `cls`'s own method for `sel`, or NULL.
static Method W7OwnMethod(Class cls, SEL sel) {
    Method m = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count && !m; i++) if (method_getName(methods[i]) == sel) m = methods[i];
    free(methods);
    return m;
}

/// Hooks `sel` (exactly `types`) for `host` instances: on `host` itself when it defines the method, otherwise
/// on the nearest superclass that does (with the same encoding check). A hook on a superclass only reacts to
/// `host` instances; every other caller just gets the original. Logs which class was patched.
Class W7SettingsHookHostSelector(Class host, SEL sel, const char *types) {
    if (!host || !types) return Nil;
    Class owner = Nil;
    Method m = NULL;
    for (Class c = host; c && !m; c = class_getSuperclass(c)) {
        m = W7OwnMethod(c, sel);
        if (m) owner = c;
    }
    const char *actual = m ? method_getTypeEncoding(m) : NULL;
    if (!actual || strcmp(actual, types) != 0) {
        os_log(W7Log(), "settings panel: %{public}@ -%{public}@ not hooked (%{public}@ has %{public}s)", NSStringFromClass(host),
               NSStringFromSelector(sel), owner ? NSStringFromClass(owner) : @"no class", actual ?: "nothing");
        return Nil;
    }
    static NSMutableSet<NSString *> *patched;   // "<owner>|<selector>": never wrapped twice
    if (!patched) patched = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%p|%@", (__bridge void *)owner, NSStringFromSelector(sel)];
    if ([patched containsObject:key]) return owner;
    [patched addObject:key];
    if (strcmp(types, "v24@0:8@16") == 0) {
        void (*original)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(NSViewController *vc, id arg) {
            original(vc, sel, arg);
            if ([vc isKindOfClass:host]) W7HostChanged(vc);
        }));
    } else {
        void (*original)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(NSViewController *vc) {
            original(vc, sel);
            if ([vc isKindOfClass:host]) W7HostChanged(vc);
        }));
    }
    os_log(W7Log(), "settings panel: %{public}@ -%{public}@ hooked (patched on %{public}@)", NSStringFromClass(host),
           NSStringFromSelector(sel), NSStringFromClass(owner));
    return owner;
}

/// Diagnostic only: whether this process is a System Settings pane extension. Nothing is styled in one.
static void W7LogExtensionContext(void) {
    NSBundle *b = NSBundle.mainBundle;
    if (![b.bundlePath.pathExtension isEqualToString:@"appex"]) return;
    NSDictionary *info = b.infoDictionary;
    id attrs = info[@"EXAppExtensionAttributes"], legacy = info[@"NSExtension"];
    id point = [attrs isKindOfClass:NSDictionary.class] ? attrs[@"EXExtensionPointIdentifier"] : nil;
    if (!point && [legacy isKindOfClass:NSDictionary.class]) point = legacy[@"NSExtensionPointIdentifier"];
    NSString *pointID = [point isKindOfClass:NSString.class] ? point : nil;
    os_log(W7Log(), "settings panel: in appex %{public}@ (extension point %{public}@, settings pane %d); no styling in extensions",
           b.bundleIdentifier ?: @"-", pointID ?: @"-", [pointID isEqualToString:@"com.apple.Settings.extension.ui"]);
}

void W7SettingsPanelInstall(void) {
    static BOOL installed;
    if (installed) return;
    installed = YES;
    @try {
        W7LogExtensionContext();
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        BOOL disabled = [NSUserDefaults.standardUserDefaults boolForKey:kSettingsPanelDisabledKey];
        if (!W7SettingsPanelShouldInstall(bundleID, disabled)) {
            if (disabled && [bundleID isEqualToString:kSettingsBundleID])
                os_log(W7Log(), "settings panel: not installed (W7SettingsPanelDisabled)");
            return;
        }
        Class host = NSClassFromString(@"_EXHostViewController");
        if (host && [host isSubclassOfClass:NSViewController.class]) {
            W7SettingsHookHostSelector(host, @selector(setConfiguration:), "v24@0:8@16");
            W7SettingsHookHostSelector(host, @selector(viewWillAppear), "v16@0:8");
        } else {
            os_log(W7Log(), "settings panel: _EXHostViewController missing; panes are never detected, the sidebar stays native");
        }
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[ NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification ]) {
            [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                @try {
                    NSWindow *w = n.object;
                    if (![w isKindOfClass:NSWindow.class]) return;
                    W7TrackWindow(w);
                    W7ScheduleRefresh(w);
                } @catch (NSException *e) {
                    os_log_error(W7Log(), "settings panel: key/main check failed: %{public}@", e.reason ?: @"unknown");
                }
            }];
        }
        for (NSWindow *w in [NSApp.windows copy]) W7TrackWindow(w);
        W7ScheduleRefreshAndSettle(nil);
        os_log(W7Log(), "settings panel: installed");
    } @catch (NSException *e) {
        os_log_error(W7Log(), "settings panel: install failed: %{public}@", e.reason ?: @"unknown");
    }
}
