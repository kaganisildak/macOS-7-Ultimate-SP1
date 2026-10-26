#import "Win7ChromeCore.h"

BOOL W7ShouldDecorateWindow(NSWindowStyleMask mask, BOOL isPanel, BOOL titlebarTransparent, BOOL isSheet) {
    return W7ShouldDecorateWindowOrDialog(mask, isPanel, NO, titlebarTransparent, isSheet);
}

BOOL W7ShouldDecorateWindowOrDialog(NSWindowStyleMask mask, BOOL isPanel, BOOL isDialogPanel, BOOL titlebarTransparent,
                                    BOOL isSheet) {
    if (!(mask & NSWindowStyleMaskTitled)) return NO;
    if (isSheet) return NO;
    if (mask & (NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskFullScreen)) return NO;
    // A dialog panel's transparent title bar (the standard About panel has one) is safe without
    // FullSizeContentView: its content stays below the title bar, so nothing ends up under the Aero bar.
    if (isDialogPanel) return YES;
    return !isPanel && !titlebarTransparent;
}

BOOL W7IsSystemPanelClassName(NSString *className) {
    if (![className isKindOfClass:NSString.class]) return NO;
    NSUInteger i = 0;
    while (i < className.length && [className characterAtIndex:i] == '_') i++;
    NSString *name = [className substringFromIndex:i];
    // AppKit's shared and remote-hosted panels keep their own look (the alert is the message box).
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[ @"NSColorPanel", @"NSFontPanel", @"NSSavePanel", @"NSOpenPanel", @"NSRemoteSavePanel",
                      @"NSRemoteOpenPanel", @"NSLocalSavePanel", @"NSLocalOpenPanel", @"NSPrintPanel", @"NSPageLayout",
                      @"NSSharingServicePicker", @"NSAlertPanel", @"NSSpellingPanel" ];
    });
    for (NSString *prefix in prefixes) {
        if ([name hasPrefix:prefix]) return YES;
    }
    return NO;
}

BOOL W7IsDialogPanel(NSWindowStyleMask mask, NSInteger level, BOOL isFloatingPanel, BOOL isSheet, BOOL ownedByAlert,
                     NSArray<NSString *> *classChain) {
    const NSWindowStyleMask required = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
    if ((mask & required) != required) return NO;
    if (mask & (NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskHUDWindow | NSWindowStyleMaskNonactivatingPanel |
                NSWindowStyleMaskDocModalWindow)) return NO;
    if (level != NSNormalWindowLevel || isFloatingPanel || isSheet || ownedByAlert) return NO;
    for (NSString *name in classChain) {
        if (W7IsSystemPanelClassName(name)) return NO;
    }
    return YES;
}

NSUInteger W7CaptionVisibleButtons(BOOL dialog, NSWindowStyleMask mask) {
    NSUInteger close = (NSUInteger)1 << W7CaptionClose, maximize = (NSUInteger)1 << W7CaptionMaximize;
    if (!dialog) return close | maximize | ((NSUInteger)1 << W7CaptionMinimize);
    // Windows 7 dialogs have a close button only; a resizable one keeps maximize.
    return close | ((mask & NSWindowStyleMaskResizable) ? maximize : 0);
}

NSInteger W7CaptionHitTestVisible(W7CaptionRects r, CGPoint p, NSUInteger visibleButtons) {
    NSInteger hit = W7CaptionHitTest(r, p);
    if (hit == W7CaptionHitNone) return hit;
    return (visibleButtons & ((NSUInteger)1 << hit)) ? hit : W7CaptionHitNone;
}

CGFloat W7CaptionTitleMaxX(W7CaptionRects r, NSUInteger visibleButtons) {
    if (visibleButtons & ((NSUInteger)1 << W7CaptionMinimize)) return CGRectGetMinX(r.minimize);
    if (visibleButtons & ((NSUInteger)1 << W7CaptionMaximize)) return CGRectGetMinX(r.maximize);
    return CGRectGetMinX(r.close);
}

W7CaptionRects W7CaptionLayout(CGRect b) {
    CGFloat y = CGRectGetMaxY(b) - 1 - W7CaptionHeight;
    CGFloat closeX = CGRectGetMaxX(b) - 6 - W7CaptionCloseWidth;
    W7CaptionRects r;
    r.close = CGRectMake(closeX, y, W7CaptionCloseWidth, W7CaptionHeight);
    r.maximize = CGRectMake(closeX - W7CaptionSmallWidth, y, W7CaptionSmallWidth, W7CaptionHeight);
    r.minimize = CGRectMake(closeX - 2 * W7CaptionSmallWidth, y, W7CaptionSmallWidth, W7CaptionHeight);
    return r;
}

NSInteger W7CaptionHitTest(W7CaptionRects r, CGPoint p) {
    if (CGRectContainsPoint(r.close, p)) return W7CaptionClose;
    if (CGRectContainsPoint(r.maximize, p)) return W7CaptionMaximize;
    if (CGRectContainsPoint(r.minimize, p)) return W7CaptionMinimize;
    return W7CaptionHitNone;
}

CGRect W7MaximizedFrame(CGRect s, CGFloat taskbar, BOOL primary) {
    if (!primary) return s;
    return CGRectMake(s.origin.x, s.origin.y + taskbar, s.size.width, s.size.height - taskbar);
}

NSArray<NSString *> *W7AppleFullSizeConversionExceptions(void) {
    // Apple apps whose toolbar-less full-size windows put their own content in the title area and so must
    // not be converted. None known yet; add bundle IDs here when one is found.
    return @[];
}

BOOL W7IsAppleAppForFullSizeConversion(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || ![bundleID hasPrefix:@"com.apple."]) return NO;
    return ![W7AppleFullSizeConversionExceptions() containsObject:bundleID];
}

BOOL W7ShouldConvertFullSizeWindow(NSWindowStyleMask mask, BOOL isPanel, BOOL isSheet, BOOL hasToolbar,
                                   BOOL isAppleApp, NSString *windowClassName) {
    if (!(mask & NSWindowStyleMaskTitled) || (mask & NSWindowStyleMaskFullScreen)) return NO;
    if (!(mask & NSWindowStyleMaskFullSizeContentView)) return NO;
    if (isPanel || isSheet) return NO;
    // A toolbar-less full-size window usually means the app draws its own caption (Electron, Chromium);
    // Apple apps (Terminal) don't, so theirs are converted too.
    if (!hasToolbar && !isAppleApp) return NO;
    // Chromium and Electron draw their own caption controls even with a toolbar.
    static NSArray<NSString *> *selfDrawn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        selfDrawn = @[ @"BrowserNativeWidgetWindow", @"NativeWidgetMacNSWindow", @"ElectronNSWindow", @"AtomNSWindow" ];
    });
    for (NSString *prefix in selfDrawn) {
        if ([windowClassName hasPrefix:prefix]) return NO;
    }
    return YES;
}

NSWindowStyleMask W7GuardedStyleMask(NSWindowStyleMask mask, BOOL converted) {
    if (!converted || (mask & NSWindowStyleMaskFullScreen)) return mask;
    return mask & ~NSWindowStyleMaskFullSizeContentView;
}

NSWindowToolbarStyle W7GuardedToolbarStyle(NSWindowToolbarStyle style, BOOL converted) {
    return converted ? NSWindowToolbarStyleExpanded : style;
}

NSString *W7CaptionTitle(NSString *windowTitle, NSString *appName) {
    if (windowTitle.length) return windowTitle;
    return appName ?: @"";
}

NSWindowTitleVisibility W7GuardedTitleVisibility(NSWindowTitleVisibility visibility, BOOL decorated) {
    return decorated ? NSWindowTitleHidden : visibility;
}

BOOL W7GuardedTitlebarAppearsTransparent(BOOL transparent, BOOL decorated) {
    return decorated ? YES : transparent;
}

BOOL W7IsNativeTitleViewClassCName(const char *name) {
    if (!name) return NO;
    while (*name == '_') name++;
    if (strncmp(name, "NS", 2) != 0) return NO;
    static const char *const suffixes[] = { "ToolbarTitleView", "TitlebarTitleView", "ToolbarTitleField" };
    size_t len = strlen(name);
    for (size_t i = 0; i < sizeof suffixes / sizeof suffixes[0]; i++) {
        size_t s = strlen(suffixes[i]);
        if (len >= s && strcmp(name + len - s, suffixes[i]) == 0) return YES;
    }
    return NO;
}

BOOL W7IsNativeTitleViewClassName(NSString *className) {
    if (![className isKindOfClass:NSString.class]) return NO;
    return W7IsNativeTitleViewClassCName(className.UTF8String);
}
