#import "Win7ChromeCore.h"

/// signposts (subsystem com.win7mac.chrome, category "perf") and the W7PerfLog debug log.

static const double kMainThreadBudget = 0.016;

os_log_t W7PerfLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.win7mac.chrome", "perf"); });
    return log;
}

BOOL W7PerfLogEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7PerfLog"]; }
        @catch (NSException *e) { enabled = NO; }
    });
    return enabled;
}

BOOL W7PerfShouldLog(double seconds, BOOL isMainThread, BOOL enabled) {
    return enabled && isMainThread && seconds > kMainThreadBudget;
}

void W7PerfFinish(const char *name, uint64_t startNanos) {
    if (!W7PerfLogEnabled()) return;
    double seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNanos) / 1e9;
    if (W7PerfShouldLog(seconds, NSThread.isMainThread, YES)) {
        os_log(W7PerfLog(), "slow main-thread interval %{public}s: %.1f ms", name, seconds * 1000);
    }
}
