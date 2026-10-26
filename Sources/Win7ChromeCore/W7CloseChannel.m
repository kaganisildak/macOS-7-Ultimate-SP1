#import "Win7ChromeCore.h"
#import <unistd.h>

// the taskbar's "Close window" / "Close all windows" reach the app through a distributed notification
// named after its pid, so no Accessibility permission is needed and the app closes its windows itself, exiting
// afterwards as a Windows 7 program does.

NSString *W7CloseChannelNotificationName(W7CloseRequest request, pid_t pid) {
    return [NSString stringWithFormat:@"com.win7mac.%@.%d",
            request == W7CloseRequestAllWindows ? @"closeAllWindows" : @"closeWindow", (int)pid];
}

NSString *W7CloseChannelAckName(pid_t pid) {
    return [NSString stringWithFormat:@"com.win7mac.closeHandled.%d", (int)pid];
}

BOOL W7CloseChannelWindowEligible(NSWindowStyleMask mask, BOOL isPanel, BOOL isSheet, BOOL isVisible,
                                  BOOL isMiniaturized) {
    if (!(mask & NSWindowStyleMaskClosable)) return NO;
    if (isPanel || isSheet) return NO;
    return isVisible || isMiniaturized;
}

NSString *const W7CloseKeepAliveDefaultsKey = @"W7CloseKeepAlive";

BOOL W7CloseChannelWindowKeepsAppRunning(NSWindowStyleMask mask, BOOL isPanel, BOOL isSheet, BOOL isVisible,
                                         BOOL isMiniaturized) {
    if (!(mask & NSWindowStyleMaskTitled)) return NO;
    if (isPanel || isSheet) return NO;
    return isVisible || isMiniaturized;
}

BOOL W7CloseChannelKeepsAliveInList(NSString *bundleID, NSArray *list) {
    if (![bundleID isKindOfClass:NSString.class]) return NO;
    if ([bundleID isEqualToString:@"com.apple.finder"]) return YES;
    if (![list isKindOfClass:NSArray.class]) return NO;
    for (id entry in list) {
        if ([entry isKindOfClass:NSString.class] && [entry isEqualToString:bundleID]) return YES;
    }
    return NO;
}

// Read at each exit check (rare), so a change applies without relaunching the app.
BOOL W7CloseChannelKeepsAlive(NSString *bundleID) {
    NSArray *list = nil;
    @try { list = [NSUserDefaults.standardUserDefaults arrayForKey:W7CloseKeepAliveDefaultsKey]; }
    @catch (NSException *e) { list = nil; }
    return W7CloseChannelKeepsAliveInList(bundleID, list);
}

BOOL W7CloseChannelDisabled(void) {
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7CloseChannelDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

static BOOL W7CloseChannelIsEligible(NSWindow *w) {
    if (![w isKindOfClass:NSWindow.class]) return NO;
    return W7CloseChannelWindowEligible(w.styleMask, [w isKindOfClass:NSPanel.class], w.isSheet, w.isVisible,
                                        w.isMiniaturized);
}

static BOOL W7CloseChannelKeepsRunning(NSWindow *w) {
    if (![w isKindOfClass:NSWindow.class]) return NO;
    return W7CloseChannelWindowKeepsAppRunning(w.styleMask, [w isKindOfClass:NSPanel.class], w.isSheet, w.isVisible,
                                               w.isMiniaturized);
}

@implementation W7CloseChannel {
    NSString *_bundleID;
    NSArray<NSWindow *> *(^_windows)(void);
    NSArray<NSWindow *> *(^_ordered)(void);
    NSWindow *(^_key)(void);
    NSWindow *(^_main)(void);
    void (^_terminate)(void);
    NSTimeInterval _settle;
    BOOL _disabled;
}

- (instancetype)initWithBundleID:(NSString *)bundleID
                         windows:(NSArray<NSWindow *> *(^)(void))windows
                  orderedWindows:(NSArray<NSWindow *> *(^)(void))orderedWindows
                       keyWindow:(NSWindow *(^)(void))keyWindow
                      mainWindow:(NSWindow *(^)(void))mainWindow
                       terminate:(void (^)(void))terminate
                     settleDelay:(NSTimeInterval)settleDelay
                        disabled:(BOOL)disabled {
    if ((self = [super init])) {
        _bundleID = [bundleID copy];
        _windows = [windows copy];
        _ordered = [orderedWindows copy];
        _key = [keyWindow copy];
        _main = [mainWindow copy];
        _terminate = [terminate copy];
        _settle = settleDelay;
        _disabled = disabled;
    }
    return self;
}

- (NSArray<NSWindow *> *)eligibleWindows {
    @try {
        NSMutableArray<NSWindow *> *out = [NSMutableArray array];
        for (NSWindow *w in [(_windows ? _windows() : @[]) copy]) if (W7CloseChannelIsEligible(w)) [out addObject:w];
        return out;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "close channel: window list failed: %{public}@", e.reason ?: @"unknown");
        return @[];
    }
}

- (NSInteger)eligibleWindowCount { return (NSInteger)[self eligibleWindows].count; }

- (NSWindow *)targetWindow {
    @try {
        NSWindow *key = _key ? _key() : nil;
        if (key && W7CloseChannelIsEligible(key)) return key;
        NSWindow *main = _main ? _main() : nil;
        if (main && W7CloseChannelIsEligible(main)) return main;
        // Front to back; a minimized window is not "in front", so only visible ones count here.
        for (NSWindow *w in [(_ordered ? _ordered() : @[]) copy]) {
            if (W7CloseChannelIsEligible(w) && w.isVisible) return w;
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "close channel: target failed: %{public}@", e.reason ?: @"unknown");
    }
    return nil;
}

- (NSInteger)closeWindow { return [self perform:W7CloseRequestWindow beforeClosing:nil]; }

- (NSInteger)closeAllWindows { return [self perform:W7CloseRequestAllWindows beforeClosing:nil]; }

/// `beforeClosing` runs once targets are chosen (at least one) and before the first performClose:, which may run a
/// modal alert from windowShouldClose: and so not return for a long time.
- (NSInteger)perform:(W7CloseRequest)request beforeClosing:(void (^)(void))beforeClosing {
    if (_disabled) return -1;
    NSInteger closed = 0;
    @try {
        NSArray<NSWindow *> *targets;
        if (request == W7CloseRequestWindow) {
            NSWindow *w = [self targetWindow];
            targets = w ? @[w] : @[];
        } else {
            targets = [self eligibleWindows];
        }
        if (targets.count > 0 && beforeClosing) {
            @try { beforeClosing(); }
            @catch (NSException *e) {
                os_log_error(W7Log(), "close channel: before-close failed: %{public}@", e.reason ?: @"unknown");
            }
        }
        for (NSWindow *w in targets) {
            @try {
                [w performClose:nil];
                closed++;
            } @catch (NSException *e) {
                os_log_error(W7Log(), "close channel: performClose failed: %{public}@", e.reason ?: @"unknown");
            }
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "close channel: request failed: %{public}@", e.reason ?: @"unknown");
    }
    const char *name = request == W7CloseRequestAllWindows ? "closeAllWindows" : "closeWindow";
    if (closed == 0) {
        os_log(W7Log(), "close channel: %{public}s closed 0, terminated no", name);
        return 0;
    }
    // The app's own close runs first (document windows close on a later turn, save sheets come up); the exit
    // check waits for the run loop to settle.
    __weak W7CloseChannel *weakSelf = self;
    NSInteger count = closed;
    // A run loop timer (common modes), not dispatch_after: it also fires while the main queue is busy in a nested
    // run loop (a modal session, a menu).
    NSTimer *timer = [NSTimer timerWithTimeInterval:_settle repeats:NO block:^(NSTimer *t) {
        [weakSelf finish:name closed:count];
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    return closed;
}

- (void)finish:(const char *)name closed:(NSInteger)closed {
    BOOL terminated = NO;
    NSInteger left = -1;
    @try {
        // Every visible (or minimized) titled window counts here, with or without a close button: a window the
        // channel could not close still keeps the app running.
        NSMutableArray<NSWindow *> *remaining = [NSMutableArray array];
        for (NSWindow *w in [(_windows ? _windows() : @[]) copy]) if (W7CloseChannelKeepsRunning(w)) [remaining addObject:w];
        left = (NSInteger)remaining.count;
        if (left == 0 && !W7CloseChannelKeepsAlive(_bundleID) && _terminate) {
            terminated = YES;
            _terminate();
        } else {
            // A save sheet came up on a window the taskbar closed: bring it forward so it is seen (the shell yielded
            // activation to the app before asking).
            for (NSWindow *w in remaining) {
                if (w.attachedSheet) { [NSApp activate]; [w makeKeyAndOrderFront:nil]; break; }
            }
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "close channel: exit check failed: %{public}@", e.reason ?: @"unknown");
    }
    os_log(W7Log(), "close channel: %{public}s closed %ld, windows left %ld, terminated %{public}s", name,
           (long)closed, (long)left, terminated ? "yes" : "no");
}

- (void)acknowledge {
    @try {
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:W7CloseChannelAckName(getpid())
                                                                     object:nil userInfo:nil deliverImmediately:YES];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "close channel: acknowledgement failed: %{public}@", e.reason ?: @"unknown");
    }
}

// Distributed notifications may arrive off the main thread; hop before touching windows. The acknowledgement goes
// out only when a window is about to be asked to close, so a hidden or windowless app still gets the shell's
// fallback; and it goes out BEFORE performClose:, as windowShouldClose: may run a modal alert that would
// otherwise hold it past the shell's 0.7 s check.
- (void)handle:(W7CloseRequest)request {
    if (_disabled) return;
    void (^work)(void) = ^{
        @try {
            [self perform:request beforeClosing:^{
                self->_acknowledgements++;
                [self acknowledge];
            }];
        }
        @catch (NSException *e) { os_log_error(W7Log(), "close channel handler failed: %{public}@", e.reason ?: @"unknown"); }
    };
    if (NSThread.isMainThread) work(); else dispatch_async(dispatch_get_main_queue(), work);
}

- (void)handleCloseWindowNotification:(NSNotification *)n {
    @try { [self handle:W7CloseRequestWindow]; }
    @catch (NSException *e) { os_log_error(W7Log(), "close channel handler failed: %{public}@", e.reason ?: @"unknown"); }
}

- (void)handleCloseAllWindowsNotification:(NSNotification *)n {
    @try { [self handle:W7CloseRequestAllWindows]; }
    @catch (NSException *e) { os_log_error(W7Log(), "close channel handler failed: %{public}@", e.reason ?: @"unknown"); }
}

+ (void)start {
    static dispatch_once_t once;
    static W7CloseChannel *shared;
    dispatch_once(&once, ^{
        @try {
            NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
            if ([bundleID isEqualToString:@"com.win7mac.shell"]) return;
            if (W7CloseChannelDisabled()) {
                os_log(W7Log(), "close channel: disabled");
                return;
            }
            shared = [[W7CloseChannel alloc] initWithBundleID:bundleID
                windows:^NSArray<NSWindow *> * { return NSApp.windows ?: @[]; }
                orderedWindows:^NSArray<NSWindow *> * { return NSApp.orderedWindows ?: @[]; }
                keyWindow:^NSWindow * { return NSApp.keyWindow; }
                mainWindow:^NSWindow * { return NSApp.mainWindow; }
                terminate:^{ [NSApp terminate:nil]; }
                settleDelay:0.5 disabled:NO];
            pid_t pid = getpid();
            NSDistributedNotificationCenter *dc = NSDistributedNotificationCenter.defaultCenter;
            // DeliverImmediately: the app is usually in the background when its taskbar button is used.
            [dc addObserver:shared selector:@selector(handleCloseWindowNotification:)
                       name:W7CloseChannelNotificationName(W7CloseRequestWindow, pid)
                     object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
            [dc addObserver:shared selector:@selector(handleCloseAllWindowsNotification:)
                       name:W7CloseChannelNotificationName(W7CloseRequestAllWindows, pid)
                     object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "close channel start failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}

@end
