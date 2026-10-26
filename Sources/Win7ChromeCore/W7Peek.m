#import "Win7ChromeCore.h"
#import <objc/runtime.h>

static const void *kPeekAlphaKey = &kPeekAlphaKey;
static const CGFloat kPeekAlpha = 0.08;

@implementation W7PeekController {
    NSArray<NSWindow *> *(^_provider)(void);
    NSTimeInterval _timeout;
    NSTimer *_timer;
    NSHashTable<NSWindow *> *_peeked;
    BOOL _active;
}

- (instancetype)initWithWindowsProvider:(NSArray<NSWindow *> *(^)(void))provider timeout:(NSTimeInterval)timeout {
    if ((self = [super init])) {
        _provider = [provider copy];
        _timeout = timeout;
        _peeked = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)begin {
    @try {
        NSArray<NSWindow *> *windows = _provider ? _provider() : @[];
        for (NSWindow *w in windows) {
            // Already peeked: keep the stored original alpha.
            if (objc_getAssociatedObject(w, kPeekAlphaKey)) continue;
            objc_setAssociatedObject(w, kPeekAlphaKey, @(w.alphaValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [_peeked addObject:w];
            w.alphaValue = kPeekAlpha;
        }
        // A repeated begin keeps the first deadline.
        if (!_active) {
            _active = YES;
            __weak W7PeekController *weakSelf = self;
            _timer = [NSTimer timerWithTimeInterval:_timeout repeats:NO block:^(NSTimer *t) {
                [weakSelf end];
            }];
            [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "peek begin failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)end {
    @try {
        [_timer invalidate];
        _timer = nil;
        _active = NO;
        for (NSWindow *w in _peeked.allObjects) {
            NSNumber *orig = objc_getAssociatedObject(w, kPeekAlphaKey);
            if (orig) w.alphaValue = orig.doubleValue;
            objc_setAssociatedObject(w, kPeekAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [_peeked removeAllObjects];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "peek end failed: %{public}@", e.reason ?: @"unknown");
    }
}

// Distributed notifications may arrive off the main thread; hop before touching windows.
- (void)handleBeginNotification:(NSNotification *)n {
    void (^work)(void) = ^{
        @try { [self begin]; }
        @catch (NSException *e) { os_log_error(W7Log(), "peek begin handler failed: %{public}@", e.reason ?: @"unknown"); }
    };
    if (NSThread.isMainThread) work(); else dispatch_async(dispatch_get_main_queue(), work);
}

- (void)handleEndNotification:(NSNotification *)n {
    void (^work)(void) = ^{
        @try { [self end]; }
        @catch (NSException *e) { os_log_error(W7Log(), "peek end handler failed: %{public}@", e.reason ?: @"unknown"); }
    };
    if (NSThread.isMainThread) work(); else dispatch_async(dispatch_get_main_queue(), work);
}

+ (void)start {
    static dispatch_once_t once;
    static W7PeekController *shared;
    dispatch_once(&once, ^{
        @try {
            shared = [[W7PeekController alloc] initWithWindowsProvider:^NSArray<NSWindow *> * {
                NSMutableArray *vis = [NSMutableArray array];
                for (NSWindow *w in [NSApp.windows copy]) if (w.isVisible) [vis addObject:w];
                return vis;
            } timeout:30];
            // DeliverImmediately: background apps must still get begin/end while inactive.
            NSDistributedNotificationCenter *dc = NSDistributedNotificationCenter.defaultCenter;
            [dc addObserver:shared selector:@selector(handleBeginNotification:) name:@"com.win7mac.peek.begin"
                     object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
            [dc addObserver:shared selector:@selector(handleEndNotification:) name:@"com.win7mac.peek.end"
                     object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "peek start failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}

@end
