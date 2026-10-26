#import "Win7ChromeCore.h"

NSString * W7ChromeCoreName(void) { return @"Win7ChromeCore"; }

NSArray<NSString *> *W7DefaultDenylist(void) {
    return [@[
        @"com.apple.loginwindow", @"com.apple.dock", @"com.apple.WindowManager",
        @"com.apple.controlcenter", @"com.apple.systemuiserver",
        @"com.apple.notificationcenterui", @"com.apple.Spotlight",
        @"com.apple.SecurityAgent", @"com.apple.screensaver.engine",
        @"com.apple.osascript",   // osascript tools run by the Explorer location query
        @"com.win7mac.shell",
    ] arrayByAddingObjectsFromArray:W7SettingsExcludedExtensionIDs()];
}

NSArray<NSString *> *W7SettingsExcludedExtensionIDs(void) {
    // System Settings security panes: each is an .appex process; they stay fully native.
    return @[
        @"com.apple.settings.PrivacySecurity.extension", @"com.apple.Home.PrivacySettingsExtension",
        @"com.apple.SecurityImprovements-Settings.extension", @"com.apple.Touch-ID-Settings.extension",
        @"com.apple.Users-Groups-Settings.extension", @"com.apple.Lock-Screen-Settings.extension",
        @"com.apple.Passwords-Settings.extension",
    ];
}

static BOOL W7PlistTruthy(id value) {
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

BOOL W7ShouldLoadInProcess(NSString *bundleID, NSDictionary *info,
                           NSArray<NSString *> *extraDenylist, BOOL disabled) {
    if (disabled) return NO;
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return NO;
    if ([W7DefaultDenylist() containsObject:bundleID]) return NO;
    if ([extraDenylist isKindOfClass:[NSArray class]] && [extraDenylist containsObject:bundleID]) return NO;
    if ([info isKindOfClass:[NSDictionary class]]) {
        if (W7PlistTruthy(info[@"LSUIElement"])) return NO;
        if (W7PlistTruthy(info[@"LSBackgroundOnly"])) return NO;
    }
    return YES;
}

os_log_t W7Log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.win7mac.chrome", "chrome"); });
    return log;
}
