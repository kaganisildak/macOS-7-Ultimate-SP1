#import "Win7ChromeCore.h"
#import <objc/runtime.h>

// dialog-like panels (About, Preferences, Get Info) get the Aero frame like windows (decorateWindow,
// with a close-only caption) and a Windows 7 dialog body: a white window background and, when the content
// view's bottom strip holds only push buttons, the #F0F0F0 button strip behind them. As with the message
// box, nothing of the panel's own is changed except its background colour: a backdrop view goes under its views.

static const void *kDialogStyledKey = &kDialogStyledKey;
static NSInteger gDisabledOverride = -1;

const CGFloat W7DialogPanelStripBand = 48;

/// Views deeper than this, or more of them than kStripMaxViews, make the strip detection give up (no strip).
static const NSUInteger kStripMaxDepth = 8, kStripMaxViews = 400;

BOOL W7DialogPanelDisabled(void) {
    if (gDisabledOverride >= 0) return gDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7DialogPanelDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

void W7DialogPanelUseDisabledOverride(NSInteger value) { gDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

static BOOL W7DialogIsDark(NSAppearance *appearance) {
    NSAppearanceName best = [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [best isEqualToString:NSAppearanceNameDarkAqua];
}

static NSArray<NSString *> *W7ClassChain(Class cls) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (Class c = cls; c && c != NSWindow.class; c = class_getSuperclass(c)) [names addObject:NSStringFromClass(c)];
    return names;
}

/// Whether `view` is (a subclass of) AppKit's NSRemoteView: content drawn by another process (open/save panels).
static BOOL W7IsRemoteView(NSView *view) {
    for (Class c = view.class; c && c != NSView.class; c = class_getSuperclass(c)) {
        const char *name = class_getName(c);
        while (*name == '_') name++;
        if (strncmp(name, "NSRemoteView", 12) == 0) return YES;
    }
    return NO;
}

BOOL W7IsDialogPanelWindow(NSWindow *w) {
    @try {
        if (![w isKindOfClass:NSPanel.class] || W7DialogPanelDisabled()) return NO;
        NSPanel *p = (NSPanel *)w;
        if (p.contentView && W7IsRemoteView(p.contentView)) return NO;   // another process's panel, hosted here
        return W7IsDialogPanel(p.styleMask, p.level, p.isFloatingPanel, p.sheetParent != nil, W7WindowIsAlertPanel(p),
                               W7ClassChain(p.class));
    } @catch (NSException *e) {
        os_log_error(W7Log(), "dialog panel check failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Button strip detection

@interface W7DialogPanelBackdrop : NSView
@end

typedef struct {
    CGRect buttons;          // union of the push buttons in the band (content coordinates, bottom-up)
    CGFloat aboveMin;        // lowest bottom edge of the content above the band
    NSUInteger visited;
    const char *failure;     // why there is no strip, or NULL
} W7StripScan;

/// A bordered, momentary push (or help) button with a title. +buttonWithTitle: gives bezel 0 (automatic) on
/// macOS 26 and later, so it counts too; checkboxes, radio buttons and toggles show their state (showsStateBy),
/// and pop-up buttons and image-only buttons are not dialog buttons.
static BOOL W7IsPushButton(NSView *v) {
    if (![v isKindOfClass:NSButton.class] || [v isKindOfClass:NSPopUpButton.class]) return NO;
    NSButton *b = (NSButton *)v;
    NSBezelStyle bezel = b.bezelStyle;
    BOOL help = bezel == NSBezelStyleHelpButton;
    BOOL pushBezel = bezel == (NSBezelStyle)0 || bezel == NSBezelStylePush || help;
    if (!pushBezel || !b.isBordered) return NO;
    if (!help && (b.imagePosition == NSImageOnly || b.title.length == 0)) return NO;   // the help button has no title
    NSButtonCell *cell = [b.cell isKindOfClass:NSButtonCell.class] ? b.cell : nil;
    return cell && cell.showsStateBy == NSNoCellMask;
}

/// Views that draw nothing and can sit in the strip: plain NSView leaves and separator boxes.
static BOOL W7IsInertView(NSView *v) {
    if (v.class == NSView.class && v.subviews.count == 0) return YES;
    return [v isKindOfClass:NSBox.class] && ((NSBox *)v).boxType == NSBoxSeparator;
}

/// Containers whose children are looked at; controls, scroll views and text views are leaves.
static BOOL W7IsContainer(NSView *v) {
    if (v.subviews.count == 0) return NO;
    return ![v isKindOfClass:NSControl.class] && ![v isKindOfClass:NSScrollView.class] && ![v isKindOfClass:NSText.class];
}

static void W7ScanStrip(NSView *content, NSView *parent, CGFloat band, NSUInteger depth, W7StripScan *scan) {
    for (NSView *v in parent.subviews) {
        if (scan->failure) return;
        if (++scan->visited > kStripMaxViews) { scan->failure = "too many views"; return; }
        if (v.isHidden || v.alphaValue <= 0.01 || [v isKindOfClass:W7DialogPanelBackdrop.class]) continue;
        NSRect r = [content convertRect:v.bounds fromView:v];
        CGFloat lo = content.isFlipped ? NSHeight(content.bounds) - NSMaxY(r) : NSMinY(r);
        CGFloat hi = content.isFlipped ? NSHeight(content.bounds) - NSMinY(r) : NSMaxY(r);
        if (hi <= lo) continue;
        if (lo >= band) { scan->aboveMin = MIN(scan->aboveMin, lo); continue; }
        if (hi <= 0) continue;
        if (W7IsPushButton(v)) { scan->buttons = CGRectUnion(scan->buttons, CGRectMake(NSMinX(r), lo, NSWidth(r), hi - lo)); continue; }
        if (W7IsInertView(v)) continue;
        if (W7IsContainer(v)) {
            if (depth >= kStripMaxDepth) { scan->failure = "views nested too deep"; return; }
            W7ScanStrip(content, v, band, depth + 1, scan);
            continue;
        }
        scan->failure = "a non-button view in the bottom strip";
        return;
    }
}

/// The strip top in `content` (bottom-up), or 0 with the reason in `*reason`.
static CGFloat W7DetectStrip(NSView *content, const char **reason) {
    *reason = NULL;
    if (!content) { *reason = "no content view"; return 0; }
    if ([NSStringFromClass(content.class) containsString:@"HostingView"]) { *reason = "SwiftUI content"; return 0; }
    W7StripScan scan = { CGRectNull, CGFLOAT_MAX, 0, NULL };
    W7ScanStrip(content, content, W7DialogPanelStripBand, 0, &scan);
    if (scan.failure) { *reason = scan.failure; return 0; }
    if (CGRectIsNull(scan.buttons)) { *reason = "no push buttons in the bottom strip"; return 0; }
    return MIN(NSHeight(content.bounds), W7MessageBoxStripTop(scan.buttons, scan.aboveMin));
}

CGFloat W7DialogPanelStripTop(NSView *content) {
    @try {
        const char *reason;
        return W7DetectStrip(content, &reason);
    } @catch (NSException *e) {
        return 0;
    }
}

NSString *W7DialogPanelStripDiagnostics(NSView *content) {
    @try {
        const char *reason;
        CGFloat top = W7DetectStrip(content, &reason);
        return reason ? [NSString stringWithFormat:@"none (%s)", reason] : [NSString stringWithFormat:@"top=%.1f", top];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"failed (%@)", e.reason ?: @"unknown"];
    }
}

#pragma mark - Backdrop

/// Under the panel's views; transparent to events. Only the button strip, when one is detected (measured each time
/// it draws), so a content view that paints its own background keeps it above the strip (the white comes from the
/// window's background colour); nothing without a strip or in dark appearance.
///
/// The detection is not cached: a correct cache would have to see subviews added or moved anywhere under the
/// content view, which the backdrop cannot observe without hooks. Draws are rare (layer-backed content redraws on
/// resize or invalidation), and the walk stops at kStripMaxViews.
@implementation W7DialogPanelBackdrop
- (BOOL)isFlipped { return NO; }
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        NSWindow *w = self.window;
        if (!ctx || !w || W7DialogIsDark(self.effectiveAppearance)) return;
        const char *reason;
        CGFloat stripTop = W7DetectStrip(self.superview, &reason);
        if (stripTop <= 0) return;
        // The backdrop fills the content view, so its coordinates are the content view's (bottom-up). Clipped to the
        // strip and its 1 pt line, T32's drawer paints nothing of its white message area.
        NSRect b = self.bounds;
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, CGRectMake(NSMinX(b), NSMinY(b), NSWidth(b), MIN(NSHeight(b), stripTop + 1)));
        W7DrawMessageBoxBackground(ctx, b, stripTop, 0, w.isKeyWindow || w.isMainWindow);
        CGContextRestoreGState(ctx);
    } @catch (NSException *e) { os_log_error(W7Log(), "dialog panel draw failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

#pragma mark - Styling

/// White (#FFFFFF) in light appearance; the panel's own colour in dark.
static NSColor *W7DialogBackgroundColor(NSColor *original) {
    NSColor *white = [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1];
    NSColor *fallback = original ?: NSColor.windowBackgroundColor;
    return [NSColor colorWithName:@"W7DialogPanelBackground" dynamicProvider:^NSColor *(NSAppearance *a) {
        return W7DialogIsDark(a) ? fallback : white;
    }];
}

BOOL W7StyleDialogPanel(NSWindow *w) {
    @try {
        if (!w || objc_getAssociatedObject(w, kDialogStyledKey) || !W7IsDialogPanelWindow(w)) return NO;
        objc_setAssociatedObject(w, kDialogStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        w.backgroundColor = W7DialogBackgroundColor(w.backgroundColor);
        NSView *content = w.contentView;
        BOOL hosted = [NSStringFromClass(content.class) containsString:@"HostingView"];
        if (content && !hosted) {
            W7DialogPanelBackdrop *backdrop = [[W7DialogPanelBackdrop alloc] initWithFrame:content.bounds];
            backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [content addSubview:backdrop positioned:NSWindowBelow relativeTo:nil];
        }
        NSPanel *p = (NSPanel *)w;
        // Once per panel. The title is not logged (it may name a document).
        os_log(W7Log(), "dialog panel %{public}@ mask=0x%lx level=%ld floating=%d content=%{public}@ backdrop=%d strip=%{public}@",
               NSStringFromClass(p.class), (unsigned long)p.styleMask, (long)p.level, p.isFloatingPanel,
               content ? NSStringFromClass(content.class) : @"nil", content && !hosted, W7DialogPanelStripDiagnostics(content));
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "dialog panel styling failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

BOOL W7DialogPanelIsStyled(NSWindow *w) {
    return w && objc_getAssociatedObject(w, kDialogStyledKey) != nil;
}
