#import "Win7ChromeCore.h"
#import <objc/runtime.h>

// NSAlert windows as Windows 7 message boxes. No NSAlert method is swizzled: when an alert window
// becomes key, a backdrop view goes under the alert's own views (white message area, the grey button strip,
// the caption glass with the title). The alert's layout, buttons and text are left as they are.
// on the same path, an alert still showing the application icon gets the user's Windows 7 icon (critical →
// msgbox-warning.png, informational → msgbox-info.png, else the app icon W7AppIconOverrideInstall applied), through
// the public `alert.icon`; never in Safari. Kill switch: `defaults write -g W7MessageBoxIconsDisabled -bool YES`.
// A critical alert shows msgbox-warning as its main picture with the application's icon as AppKit's small badge on it
// (the live crop). The applied app icon is used only while NSApp.applicationIconImage is still it.

static const void *kMessageBoxStyledKey = &kMessageBoxStyledKey;
static NSInteger gDisabledOverride = -1;

CGFloat W7MessageBoxStripTop(CGRect buttons, CGFloat contentAboveMinY) {
    if (CGRectIsNull(buttons) || CGRectIsEmpty(buttons)) return 0;
    CGFloat top = CGRectGetMaxY(buttons), gap = contentAboveMinY - top;
    return top + (gap > 0 ? MIN(16, gap / 2) : 0);
}

CGFloat W7MessageBoxCaptionHeight(CGFloat contentHeight, CGFloat topmostContentMaxY) {
    CGFloat gap = contentHeight - topmostContentMaxY;
    return gap < 16 ? 0 : MIN(30, gap - 2);
}

BOOL W7ShouldStyleMessageBox(BOOL isPanel, BOOL ownedByAlert, BOOL buttonsInContent, BOOL dark, BOOL disabled) {
    return isPanel && ownedByAlert && buttonsInContent && !dark && !disabled;
}

BOOL W7MessageBoxDisabled(void) {
    if (gDisabledOverride >= 0) return gDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7MessageBoxDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

void W7MessageBoxUseDisabledOverride(NSInteger value) { gDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

static BOOL W7IsDarkAppearance(NSAppearance *appearance) {
    NSAppearanceName best = [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [best isEqualToString:NSAppearanceNameDarkAqua];
}

/// The NSAlert that owns `w` (its delegate, whose window `w` is), or nil.
static NSAlert *W7AlertOwning(NSWindow *w) {
    id delegate = w.delegate;
    if (![delegate isKindOfClass:NSAlert.class]) return nil;
    NSAlert *alert = delegate;
    return alert.window == w ? alert : nil;
}

BOOL W7WindowIsAlertPanel(NSWindow *w) {
    @try { return w && W7AlertOwning(w) != nil; }
    @catch (NSException *e) { return NO; }
}

static BOOL W7AlertButtonsIn(NSAlert *alert, NSView *content) {
    if (!content || alert.buttons.count == 0) return NO;
    for (NSButton *b in alert.buttons) if (![b isDescendantOf:content]) return NO;
    return YES;
}

/// A frame's bottom and top measured from the bottom of `content`, whether or not it is flipped.
static void W7VerticalExtent(NSView *content, NSRect r, CGFloat *minY, CGFloat *maxY) {
    if (content.isFlipped) { *minY = NSHeight(content.bounds) - NSMaxY(r); *maxY = NSHeight(content.bounds) - NSMinY(r); }
    else { *minY = NSMinY(r); *maxY = NSMaxY(r); }
}

static W7MessageBoxLayout W7ComputeMessageBoxLayout(NSAlert *alert, NSView *content, NSView *_Nullable backdrop) {
    W7MessageBoxLayout layout = { 0, 0 };
    if (!alert || !content) return layout;
    CGRect buttons = CGRectNull;
    for (NSButton *b in alert.buttons) {
        if (b.isHiddenOrHasHiddenAncestor || ![b isDescendantOf:content]) continue;
        CGFloat lo, hi;
        NSRect r = [content convertRect:b.bounds fromView:b];
        W7VerticalExtent(content, r, &lo, &hi);
        buttons = CGRectUnion(buttons, CGRectMake(NSMinX(r), lo, NSWidth(r), hi - lo));
    }
    CGFloat aboveMin = CGFLOAT_MAX, topmost = 0;
    for (NSView *v in content.subviews) {
        if (v == backdrop || v.isHidden) continue;
        CGFloat lo, hi;
        W7VerticalExtent(content, v.frame, &lo, &hi);
        topmost = MAX(topmost, hi);
        BOOL holdsButton = NO;
        for (NSButton *b in alert.buttons) if ([b isDescendantOf:v]) { holdsButton = YES; break; }
        if (holdsButton || CGRectIsNull(buttons)) continue;
        if (lo >= CGRectGetMaxY(buttons) - 0.5) aboveMin = MIN(aboveMin, lo);
    }
    layout.stripTop = W7MessageBoxStripTop(buttons, aboveMin);
    layout.captionHeight = W7MessageBoxCaptionHeight(NSHeight(content.bounds), topmost);
    return layout;
}

/// The program name for the caption: the running app's localized name, else the bundle's name.
static NSString *W7MessageBoxAppName(void) {
    static NSString *name;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *n = NSRunningApplication.currentApplication.localizedName;
        if (!n.length) n = NSBundle.mainBundle.infoDictionary[@"CFBundleName"];
        name = [n isKindOfClass:NSString.class] ? [n copy] : @"";
    });
    return name;
}

/// Under the alert's views; transparent to events. Draws nothing in dark appearance (the native look stays).
/// The strip and caption are measured from the alert's views each time it draws. A relayout that moves the
/// buttons without redrawing the content view (an accessory view resized after the alert is shown) keeps the
/// old strip until the next redraw; nothing observes the alert's layout.
@interface W7MessageBoxBackdrop : NSView
@property (nonatomic, weak) NSAlert *alert;
@end

@implementation W7MessageBoxBackdrop
- (BOOL)isFlipped { return NO; }
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        NSWindow *w = self.window;
        if (!ctx || !w || W7IsDarkAppearance(self.effectiveAppearance)) return;
        NSView *content = self.superview;
        W7MessageBoxLayout g = W7ComputeMessageBoxLayout(self.alert, content, self);
        // The backdrop fills the content view, so its coordinates are the content view's (bottom-up).
        NSRect b = self.bounds;
        BOOL active = w.isKeyWindow || w.isMainWindow || w.sheetParent != nil;
        W7DrawMessageBoxBackground(ctx, b, g.stripTop, g.captionHeight, active);
        if (g.captionHeight > 0) {
            NSFont *font = W7UIFont(12);
            CGFloat h = ceil(font.ascender - font.descender);
            NSRect tr = NSMakeRect(10, NSMaxY(b) - g.captionHeight / 2 - h / 2, MAX(0, NSWidth(b) - 20), h);
            W7DrawGlassText(W7CaptionTitle(w.title, W7MessageBoxAppName()), tr, font, NSTextAlignmentLeft);
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "message box draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

static W7MessageBoxBackdrop *W7BackdropIn(NSView *content) {
    for (NSView *v in content.subviews) if ([v isKindOfClass:W7MessageBoxBackdrop.class]) return (W7MessageBoxBackdrop *)v;
    return nil;
}

BOOL W7StyleMessageBoxIfNeeded(NSWindow *w) {
    @try {
        if (!w || objc_getAssociatedObject(w, kMessageBoxStyledKey)) return NO;
        NSAlert *alert = W7AlertOwning(w);
        NSView *content = w.contentView;
        if (!W7ShouldStyleMessageBox([w isKindOfClass:NSPanel.class], alert != nil, alert && W7AlertButtonsIn(alert, content),
                                     W7IsDarkAppearance(w.effectiveAppearance), W7MessageBoxDisabled())) return NO;
        W7MessageBoxBackdrop *backdrop = [[W7MessageBoxBackdrop alloc] initWithFrame:content.bounds];
        backdrop.alert = alert;
        backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [content addSubview:backdrop positioned:NSWindowBelow relativeTo:nil];
        objc_setAssociatedObject(w, kMessageBoxStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "message box styling failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Message box icons from the user's set

static NSInteger gIconsDisabledOverride = -1;

NSString *W7MessageBoxIconName(NSAlertStyle style) {
    switch (style) {
        case NSAlertStyleCritical: return @"msgbox-warning";
        case NSAlertStyleInformational: return @"msgbox-info";
        default: return nil;   // .warning: the app's own icon
    }
}

BOOL W7MessageBoxShouldReplaceIcon(NSAlert *alert, BOOL disabled) {
    @try {
        if (disabled || ![alert isKindOfClass:NSAlert.class]) return NO;
        NSImage *icon = alert.icon;
        if (!icon) return NO;
        NSImage *app = NSApp.applicationIconImage;
        return (app && icon == app) || [icon.name isEqualToString:NSImageNameApplicationIcon];
    } @catch (NSException *e) {
        return NO;
    }
}

BOOL W7MessageBoxIconsApplyInApp(NSString *bundleID) {
    return ![bundleID isEqualToString:@"com.apple.Safari"];
}

NSImage *W7MessageBoxIconImage(NSAlertStyle style, NSImage *appIcon) {
    @try {
        NSString *name = W7MessageBoxIconName(style);
        NSImage *image = name ? W7UserIconImageSized(name, NSMakeSize(64, 64)) : nil;   // a new image: AppKit may resize it
        return image ?: [appIcon copy];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "message box icon failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

NSImage *W7MessageBoxAppIcon(NSImage *applied, NSImage *current) {
    return applied && current == applied ? applied : nil;
}

BOOL W7MessageBoxIconsDisabled(void) {
    if (gIconsDisabledOverride >= 0) return gIconsDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7MessageBoxIconsDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

void W7MessageBoxIconsUseDisabledOverride(NSInteger value) { gIconsDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

BOOL W7MessageBoxApplyUserIcon(NSWindow *w) {
    @try {
        NSAlert *alert = w ? W7AlertOwning(w) : nil;
        if (!alert || !W7MessageBoxShouldReplaceIcon(alert, W7MessageBoxIconsDisabled())) return NO;
        static BOOL applies, known;
        if (!known) {
            applies = W7MessageBoxIconsApplyInApp(NSBundle.mainBundle.bundleIdentifier);
            known = YES;
        }
        if (!applies) return NO;
        // Our app icon only while the app still shows it (an app may set its own, e.g. Activity Monitor's Dock graph).
        NSImage *appIcon = W7MessageBoxAppIcon(W7AppIconOverrideAppliedImage(), NSApp.applicationIconImage);
        NSImage *icon = W7MessageBoxIconImage(alert.alertStyle, appIcon);
        if (!icon) return NO;   // no PNG and no app icon override: AppKit's icon stays
        alert.icon = icon;      // NSAlert updates its icon view even while shown
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "message box icon failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

W7MessageBoxLayout W7MessageBoxGeometry(NSWindow *w) {
    @try {
        NSAlert *alert = w ? W7AlertOwning(w) : nil;
        NSView *content = w.contentView;
        return W7ComputeMessageBoxLayout(alert, content, content ? W7BackdropIn(content) : nil);
    } @catch (NSException *e) {
        return (W7MessageBoxLayout){ 0, 0 };
    }
}

void W7InstallMessageBoxes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidBecomeKeyNotification object:nil
                                                             queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                if (![n.object isKindOfClass:NSWindow.class]) return;
                W7StyleMessageBoxIfNeeded(n.object);
                W7MessageBoxApplyUserIcon(n.object);   // the user's Windows 7 icon (its own switch)
            }];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "message box install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}
