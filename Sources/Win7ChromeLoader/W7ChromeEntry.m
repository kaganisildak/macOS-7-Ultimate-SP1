// Constructor only. Built by `make chrome`; NOT part of Package.swift.
#import <Foundation/Foundation.h>
#import <os/log.h>
#import "Win7ChromeCore.h"

__attribute__((constructor))
static void W7ChromeInit(void) {
    @try {
        NSBundle *main = [NSBundle mainBundle];
        NSString *bundleID = main.bundleIdentifier;
        NSDictionary *info = main.infoDictionary;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        BOOL disabled = [defaults boolForKey:@"W7ChromeDisabled"];
        NSArray *extra = [defaults arrayForKey:@"W7ChromeDenylist"] ?: @[];
        if (!W7ShouldLoadInProcess(bundleID, info, extra, disabled)) return;
        os_log(W7Log(), "W7Chrome loaded in %{public}@", bundleID);
        // AppKit is loaded (the dylib links it): swizzle the cursors before the app asks for any, so
        // views that cache NSCursor.arrow at launch get the Aero ones. The cursor is set in start.
        W7InstallCursors();
        if (NSApp != nil && NSApp.isRunning) {
            [W7ChromeController start];
        } else {
            [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                              object:nil queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *n) {
                @try { [W7ChromeController start]; }
                @catch (NSException *e) {
                    os_log_error(W7Log(), "W7ChromeController start failed: %{public}@", e.reason ?: @"unknown");
                }
            }];
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "W7ChromeInit failed: %{public}@", e.reason ?: @"unknown");
    }
}
