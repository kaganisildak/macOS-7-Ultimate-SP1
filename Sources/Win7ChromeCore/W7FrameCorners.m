#import "Win7ChromeCore.h"
#import <objc/message.h>
#import <objc/runtime.h>

// the window's own corner radii. macOS 27 gives every titled window 16 pt corners; Windows 7 has 6 pt
// top corners and square bottom ones. AppKit keeps the radii in an NSViewCornerRadii (-[NSWindow _cornerRadii],
// -_setCornerRadii:, nil = AppKit's default), and WindowServer shapes the window and its shadow from them.
// Every private selector is called only when it exists with the exact type encoding measured on macOS 27.0.1
// (26A434), inside @try; anything else leaves the window alone and the frame overlay's wedges cover the corners.
// Restoring sets nil (AppKit's default) on purpose rather than a saved copy of the radii read before: the getter
// returns the effective radii, so a saved copy would freeze today's default into the window for good.

static NSInteger gRadiusDisabledOverride = -1;

/// Whether `cls` has the instance method `name` with exactly the type encoding `types`.
static BOOL W7HasMethod(Class cls, NSString *name, const char *types) {
    Method m = cls ? class_getInstanceMethod(cls, NSSelectorFromString(name)) : NULL;
    const char *t = m ? method_getTypeEncoding(m) : NULL;
    return t && strcmp(t, types) == 0;
}

static Class W7CornerRadiiClass(void) { return NSClassFromString(@"NSViewCornerRadii"); }

/// The four radius getters and setters of NSViewCornerRadii (doubles). The last class that passed is remembered
/// (the frame overlay reads the radii on every move of its window).
static BOOL W7CornerRadiiClassUsable(Class c) {
    static Class checked;
    if (c && c == checked) return YES;
    NSArray<NSString *> *getters = @[ @"topLeft", @"topRight", @"bottomLeft", @"bottomRight" ];
    NSArray<NSString *> *setters = @[ @"setTopLeft:", @"setTopRight:", @"setBottomLeft:", @"setBottomRight:" ];
    for (NSUInteger i = 0; i < getters.count; i++) {
        if (!W7HasMethod(c, getters[i], "d16@0:8") || !W7HasMethod(c, setters[i], "v24@0:8d16")) return NO;
    }
    checked = c;
    return YES;
}

BOOL W7CornerRadiusHookDisabled(void) {
    if (gRadiusDisabledOverride >= 0) return gRadiusDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7CornerRadiusHookDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

void W7CornerRadiusUseDisabledOverride(NSInteger value) { gRadiusDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

BOOL W7CornerRadiusSetterAvailable(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            Class radii = W7CornerRadiiClass();
            available = radii && W7CornerRadiiClassUsable(radii)
                && W7HasMethod(NSWindow.class, @"_cornerRadii", "@16@0:8")
                && W7HasMethod(NSWindow.class, @"_setCornerRadii:", "v24@0:8@16");
        } @catch (NSException *e) { available = NO; }
        os_log(W7Log(), "frame corners: corner radius setter %{public}s", available ? "available" : "not available");
    });
    return available;
}

/// The window's top-left and bottom-left radii from -_cornerRadii (the window's own class checked too).
static BOOL W7ReadCornerRadii(NSWindow *w, CGFloat *top, CGFloat *bottom) {
    if (!w || !W7CornerRadiusSetterAvailable() || !W7HasMethod(object_getClass(w), @"_cornerRadii", "@16@0:8")) return NO;
    id r = ((id (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"_cornerRadii"));
    Class c = W7CornerRadiiClass();
    if (!c || ![r isKindOfClass:c] || !W7CornerRadiiClassUsable(object_getClass(r))) return NO;
    double t = ((double (*)(id, SEL))objc_msgSend)(r, NSSelectorFromString(@"topLeft"));
    double b = ((double (*)(id, SEL))objc_msgSend)(r, NSSelectorFromString(@"bottomLeft"));
    if (!isfinite(t) || !isfinite(b) || t < 0 || b < 0 || t > 40 || b > 40) return NO;
    *top = t;
    *bottom = b;
    return YES;
}

CGFloat W7WindowCornerRadius(NSWindow *w, BOOL top) {
    const CGFloat fallback = 16;
    @try {
        CGFloat t, b;
        if (W7ReadCornerRadii(w, &t, &b)) return top ? t : b;
        // Older AppKit: one radius per edge. (On 27 -_bottomCornerRadius ignores a square bottom set through
        // -_setCornerRadii:, so it is only the fallback.)
        SEL sel = top ? NSSelectorFromString(@"_topCornerRadius") : NSSelectorFromString(@"_bottomCornerRadius");
        if (!w || !W7HasMethod(object_getClass(w), NSStringFromSelector(sel), "d16@0:8")) return fallback;
        double r = ((double (*)(id, SEL))objc_msgSend)(w, sel);
        return (isfinite(r) && r >= 0 && r <= 40) ? r : fallback;
    } @catch (NSException *e) {
        return fallback;
    }
}

BOOL W7WindowCornerRadiiAre(NSWindow *w, CGFloat top, CGFloat bottom) {
    @try {
        CGFloat t, b;
        return W7ReadCornerRadii(w, &t, &b) && fabs(t - top) < 0.01 && fabs(b - bottom) < 0.01;
    } @catch (NSException *e) {
        return NO;
    }
}

BOOL W7SetWindowCornerRadii(NSWindow *w, CGFloat top, CGFloat bottom) {
    if (!w || W7CornerRadiusHookDisabled() || !W7CornerRadiusSetterAvailable()) return NO;
    @try {
        if (!W7HasMethod(object_getClass(w), @"_setCornerRadii:", "v24@0:8@16")) return NO;
        // The `@` encoding does not say which class the setter takes: the getter must give an NSViewCornerRadii.
        CGFloat t0, b0;
        if (!W7ReadCornerRadii(w, &t0, &b0)) return NO;
        Class c = W7CornerRadiiClass();
        id r = [c new];
        if (!r || !W7CornerRadiiClassUsable(object_getClass(r))) return NO;
        void (*set)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
        set(r, NSSelectorFromString(@"setTopLeft:"), top);
        set(r, NSSelectorFromString(@"setTopRight:"), top);
        set(r, NSSelectorFromString(@"setBottomLeft:"), bottom);
        set(r, NSSelectorFromString(@"setBottomRight:"), bottom);
        ((void (*)(id, SEL, id))objc_msgSend)(w, NSSelectorFromString(@"_setCornerRadii:"), r);
        return W7WindowCornerRadiiAre(w, top, bottom);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "frame corners: setting the radius failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

void W7RestoreWindowCornerRadii(NSWindow *w) {
    @try {
        if (!w || !W7CornerRadiusSetterAvailable() || !W7HasMethod(object_getClass(w), @"_setCornerRadii:", "v24@0:8@16")) return;
        ((void (*)(id, SEL, id))objc_msgSend)(w, NSSelectorFromString(@"_setCornerRadii:"), nil);   // AppKit's default
    } @catch (NSException *e) {
        os_log_error(W7Log(), "frame corners: restoring the radius failed: %{public}@", e.reason ?: @"unknown");
    }
}
