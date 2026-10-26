#import "Win7ChromeCore.h"
#import <dlfcn.h>
#import <mach-o/getsect.h>
#import <mach-o/dyld.h>

NSDictionary<NSString *, NSCursor *> *W7CursorsFromPlistData(NSData *data) {
    @try {
        if (!data.length) return @{};
        id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                              format:NULL error:NULL];
        if (![plist isKindOfClass:NSDictionary.class]) return @{};
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"arrow", @"ibeam", @"hand"]) {
            NSDictionary *d = plist[key];
            if (![d isKindOfClass:NSDictionary.class]) continue;
            NSData *png = d[@"png"];
            if (![png isKindOfClass:NSData.class] || !png.length) continue;
            NSImage *img = [[NSImage alloc] initWithData:png];
            if (!img || img.size.width <= 0 || img.size.height <= 0) continue;
            NSNumber *x = [d[@"x"] isKindOfClass:NSNumber.class] ? d[@"x"] : @0;
            NSNumber *y = [d[@"y"] isKindOfClass:NSNumber.class] ? d[@"y"] : @0;
            out[key] = [[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(x.doubleValue, y.doubleValue)];
        }
        return out;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "cursor plist parse failed: %{public}@", e.reason ?: @"unknown");
        return @{};
    }
}

// imported cursors by kind name ("arrow", "ibeam", "hand"); the others procedural unless
// W7ProceduralCursorsDisabled. sSwizzled lists the selectors currently swizzled (for W7UninstallCursors).
static NSDictionary<NSString *, NSCursor *> *sImported;
static BOOL sAllowProcedural = YES;
static NSMutableArray<NSString *> *sSwizzled;

NSDictionary<NSString *, NSNumber *> *W7SwizzledCursorKinds(void) {
    return @{
        @"arrowCursor": @(W7CursorArrow),
        @"IBeamCursor": @(W7CursorIBeam),
        @"pointingHandCursor": @(W7CursorHand),
        @"resizeLeftRightCursor": @(W7CursorResizeEW),
        @"resizeLeftCursor": @(W7CursorResizeEW),
        @"resizeRightCursor": @(W7CursorResizeEW),
        @"resizeUpDownCursor": @(W7CursorResizeNS),
        @"resizeUpCursor": @(W7CursorResizeNS),
        @"resizeDownCursor": @(W7CursorResizeNS),
        @"crosshairCursor": @(W7CursorCrosshair),
        @"operationNotAllowedCursor": @(W7CursorNotAllowed),
    };
}

NSCursor *W7ResolveCursor(NSDictionary<NSString *, NSCursor *> *imported, W7CursorKind kind, BOOL allowProcedural) {
    NSCursor *c = imported[W7CursorKindName(kind)];
    if ([c isKindOfClass:NSCursor.class]) return c;
    return allowProcedural ? W7ProceduralCursor(kind, 0) : nil;
}

NSCursor *W7CursorForKind(NSDictionary<NSString *, NSCursor *> *imported, W7CursorKind kind) {
    return W7ResolveCursor(imported, kind, YES);
}

BOOL W7ProceduralCursorsDisabled(void) {
    @try {
        CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("W7ProceduralCursorsDisabled"), kCFPreferencesAnyApplication);
        if (!v) return NO;
        BOOL on = CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)v)
                : CFGetTypeID(v) == CFNumberGetTypeID() ? [(__bridge NSNumber *)v boolValue] : NO;
        CFRelease(v);
        return on;
    } @catch (NSException *e) {
        return NO;
    }
}

@interface NSCursor (W7Cursors)
@end

// After the swizzle each system selector runs these, and each w7_ selector holds the ORIGINAL
// implementation, used when a kind has neither an imported nor (allowed) procedural cursor.
#define W7_CURSOR(sel, kind) \
    + (NSCursor *)w7_##sel { return W7ResolveCursor(sImported, kind, sAllowProcedural) ?: [self w7_##sel]; }
@implementation NSCursor (W7Cursors)
W7_CURSOR(arrowCursor, W7CursorArrow)
W7_CURSOR(IBeamCursor, W7CursorIBeam)
W7_CURSOR(pointingHandCursor, W7CursorHand)
W7_CURSOR(resizeLeftRightCursor, W7CursorResizeEW)
W7_CURSOR(resizeLeftCursor, W7CursorResizeEW)
W7_CURSOR(resizeRightCursor, W7CursorResizeEW)
W7_CURSOR(resizeUpDownCursor, W7CursorResizeNS)
W7_CURSOR(resizeUpCursor, W7CursorResizeNS)
W7_CURSOR(resizeDownCursor, W7CursorResizeNS)
W7_CURSOR(crosshairCursor, W7CursorCrosshair)
W7_CURSOR(operationNotAllowedCursor, W7CursorNotAllowed)
@end
#undef W7_CURSOR

static NSObject *W7CursorLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

void W7InstallCursorsWithImported(NSDictionary<NSString *, NSCursor *> *imported) {
    @synchronized (W7CursorLock()) {
        @try {
            if (sSwizzled) return;
            sImported = [imported copy] ?: @{};
            sAllowProcedural = !W7ProceduralCursorsDisabled();
            sSwizzled = [NSMutableArray array];
            if (!sAllowProcedural && !sImported.count) return;   // nothing to replace
            for (NSString *name in W7SwizzledCursorKinds()) {
                SEL original = NSSelectorFromString(name);
                SEL replacement = NSSelectorFromString([@"w7_" stringByAppendingString:name]);
                if (W7SwizzleClassMethod(NSCursor.class, original, replacement)) [sSwizzled addObject:name];
                else os_log_error(W7Log(), "swizzle of %{public}@ failed", name);
            }
        } @catch (NSException *e) {
            os_log_error(W7Log(), "cursor install failed: %{public}@", e.reason ?: @"unknown");
        }
    }
}

void W7UninstallCursors(void) {
    @synchronized (W7CursorLock()) {
        @try {
            for (NSString *name in sSwizzled) {
                // Swizzling the same pair again exchanges the implementations back.
                W7SwizzleClassMethod(NSCursor.class, NSSelectorFromString(name),
                                     NSSelectorFromString([@"w7_" stringByAppendingString:name]));
            }
            sSwizzled = nil;
            sImported = nil;
            sAllowProcedural = YES;
        } @catch (NSException *e) {
            os_log_error(W7Log(), "cursor uninstall failed: %{public}@", e.reason ?: @"unknown");
        }
    }
}

void W7InstallCursors(void) {
    @try {
        NSDictionary *cursors = @{};
        Dl_info info;
        if (dladdr((const void *)&W7InstallCursors, &info) && info.dli_fbase) {
            unsigned long size = 0;
            uint8_t *bytes = getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__DATA", "__w7cursors", &size);
            if (bytes && size) cursors = W7CursorsFromPlistData([NSData dataWithBytes:bytes length:size]);
        }
        W7InstallCursorsWithImported(cursors);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "cursor install failed: %{public}@", e.reason ?: @"unknown");
    }
}
