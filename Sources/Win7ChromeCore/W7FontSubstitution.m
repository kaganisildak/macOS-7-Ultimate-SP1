#import "Win7ChromeCore.h"
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pwd.h>
#import <stdatomic.h>
#import <unistd.h>

// Segoe UI in place of the system font, only when the user imported it (Assets/fonts/segoeui.ttf from
// their own Windows install; never shipped). The files are registered for this process only
// (CTFontManagerRegisterFontsForURL, process scope) and NSFont's system font class methods return Segoe UI
// Regular or Bold at the same size. Monospaced requests, sizes under 9 pt and dark appearance keep the system
// font. Without the font nothing is registered or swizzled.

static NSInteger gDisabledOverride = -1;
static NSInteger gLightOverride = -1;
static atomic_bool gActive;
static atomic_bool gLight = true;
static BOOL gSwizzled;
static _Thread_local int tBypass;   // > 0 inside a monospaced request or our own font lookups
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSString *gRegularName, *gBoldName;   // under gLock
static NSMutableDictionary<NSNumber *, NSFont *> *gCache;   // under gLock; (size, bold) -> font

BOOL W7FontSubstitutionDisabled(void) {
    if (gDisabledOverride >= 0) return gDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7FontSubstitutionDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

void W7FontSubstitutionUseDisabledOverride(NSInteger value) { gDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

#pragma mark - Pure decisions

BOOL W7FontSubstitutionUsesBoldFace(CGFloat weight) {
    return weight >= NSFontWeightSemibold - 0.001;
}

NSString *W7FontSubstitutionFaceName(CGFloat weight, NSString *regular, NSString *bold) {
    if (!W7FontSubstitutionUsesBoldFace(weight)) return regular.length ? regular : nil;
    // Without the bold face a bold request keeps the system's bold font rather than losing its weight.
    return bold.length ? bold : nil;
}

BOOL W7ShouldSubstituteSystemFont(CGFloat pointSize, BOOL monospacedRequest, BOOL light, BOOL disabled) {
    return !disabled && light && !monospacedRequest && pointSize >= 9;
}

BOOL W7FontSubstitutionAppliesToBundlePath(NSString *bundlePath) {
    if (![bundlePath isKindOfClass:NSString.class]) return NO;
    // Apps only: extensions (.appex), XPC and view services run in processes of their own.
    return [bundlePath.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame;
}

#pragma mark - Font files

/// The real home folder (in a sandboxed app NSHomeDirectory is the container).
static NSString *W7RealHome(void) {
    struct passwd pw, *result = NULL;
    char buf[4096];
    if (getpwuid_r(getuid(), &pw, buf, sizeof buf, &result) == 0 && result && result->pw_dir) {
        return [NSFileManager.defaultManager stringWithFileSystemRepresentation:result->pw_dir length:strlen(result->pw_dir)];
    }
    return NSHomeDirectory();
}

NSString *W7FontSubstitutionFontDirectory(void) {
    return [W7RealHome() stringByAppendingPathComponent:@"Library/Application Support/Win7Mac/Assets/fonts"];
}

/// The PostScript name of the font in `file`, registered for this process (an already registered copy, the
/// user's ~/Library/Fonts one, counts), or nil when the file is missing or does not load.
static NSString *W7RegisterFontFile(NSString *file) {
    if (![NSFileManager.defaultManager isReadableFileAtPath:file]) return nil;
    NSURL *url = [NSURL fileURLWithPath:file];
    NSArray *descriptors = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
    if (descriptors.count == 0) {
        os_log_error(W7Log(), "font substitution: %{public}@ is not a font", file.lastPathComponent);
        return nil;
    }
    NSString *name = CFBridgingRelease(CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)descriptors[0], kCTFontNameAttribute));
    if (![name isKindOfClass:NSString.class] || !name.length) return nil;
    CFErrorRef cfError = NULL;
    if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &cfError)) {
        NSError *error = CFBridgingRelease(cfError);
        // Already registered (the same file installed for the user) is fine if the font resolves below.
        if (error.code != kCTFontManagerErrorAlreadyRegistered && error.code != kCTFontManagerErrorDuplicatedName) {
            os_log_error(W7Log(), "font substitution: registering %{public}@ failed (%ld)", file.lastPathComponent, (long)error.code);
        }
    }
    tBypass++;
    NSFont *probe = [NSFont fontWithName:name size:12];
    tBypass--;
    return probe ? name : nil;
}

/// `fileName` from `dir`; then, when `installedFallback`, from ~/Library/Fonts, where install.sh puts it, and last
/// by its PostScript name `installedName`: a sandboxed app can read neither folder, but fonts installed for the
/// user are available to it (Segoe UI is not part of macOS, so it is there only if the user installed it).
static NSString *W7FindFace(NSString *dir, NSString *fileName, BOOL installedFallback, NSString *installedName) {
    NSString *name = W7RegisterFontFile([dir stringByAppendingPathComponent:fileName]);
    if (name || !installedFallback) return name;
    name = W7RegisterFontFile([[W7RealHome() stringByAppendingPathComponent:@"Library/Fonts"] stringByAppendingPathComponent:fileName]);
    if (name) return name;
    tBypass++;
    NSFont *installed = [NSFont fontWithName:installedName size:12];
    tBypass--;
    return [installed.fontName isEqualToString:installedName] ? installedName : nil;
}

#pragma mark - Substitution

static BOOL W7IsDarkAppearance(NSAppearance *appearance) {
    NSAppearanceName best = [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [best isEqualToString:NSAppearanceNameDarkAqua];
}

void W7FontSubstitutionUseLightOverride(NSInteger value) { gLightOverride = value < 0 ? -1 : (value ? 1 : 0); }

static BOOL W7FontSubstitutionLight(void) {
    if (gLightOverride >= 0) return gLightOverride == 1;
    return atomic_load(&gLight);
}

/// The weight trait of `font` (NAN-safe: 0 when it has none; bold symbolic trait counts as bold).
static CGFloat W7FontWeight(NSFont *font) {
    NSDictionary *traits = [font.fontDescriptor objectForKey:NSFontTraitsAttribute];
    NSNumber *weight = [traits isKindOfClass:NSDictionary.class] ? traits[NSFontWeightTrait] : nil;
    if ([weight isKindOfClass:NSNumber.class]) return weight.doubleValue;
    return (font.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold) ? NSFontWeightBold : NSFontWeightRegular;
}

/// Segoe UI for `original` (a system font), or `original`. `weight` NAN reads it from the font.
static NSFont *W7Substitute(NSFont *original, CGFloat weight) {
    if (!original || !atomic_load(&gActive) || tBypass > 0) return original;
    @try {
        CGFloat size = original.pointSize;
        if (!W7ShouldSubstituteSystemFont(size, NO, W7FontSubstitutionLight(), W7FontSubstitutionDisabled())) return original;
        tBypass++;
        @try {
            if (isnan(weight)) weight = W7FontWeight(original);
            BOOL bold = W7FontSubstitutionUsesBoldFace(weight);
            NSNumber *key = @(llround(size * 100) * 2 + (bold ? 1 : 0));
            os_unfair_lock_lock(&gLock);
            NSFont *cached = gCache[key];
            NSString *face = W7FontSubstitutionFaceName(weight, gRegularName, gBoldName);
            os_unfair_lock_unlock(&gLock);
            if (cached) return cached;
            NSFont *made = face ? [NSFont fontWithName:face size:size] : nil;
            if (!made) return original;
            os_unfair_lock_lock(&gLock);
            if (!gCache[key]) gCache[key] = made;
            made = gCache[key];
            os_unfair_lock_unlock(&gLock);
            return made;
        } @finally {
            tBypass--;
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "font substitution failed: %{public}@", e.reason ?: @"unknown");
        return original;
    }
}

@interface NSFont (W7FontSubstitution)
@end

@implementation NSFont (W7FontSubstitution)
// After the swizzle, the w7_ selectors hold the ORIGINAL class methods; the original runs outside our @try.
+ (NSFont *)w7_systemFontOfSize:(CGFloat)size { return W7Substitute([self w7_systemFontOfSize:size], NSFontWeightRegular); }
+ (NSFont *)w7_systemFontOfSize:(CGFloat)size weight:(NSFontWeight)weight {
    return W7Substitute([self w7_systemFontOfSize:size weight:weight], weight);
}
+ (NSFont *)w7_boldSystemFontOfSize:(CGFloat)size { return W7Substitute([self w7_boldSystemFontOfSize:size], NSFontWeightBold); }
+ (NSFont *)w7_messageFontOfSize:(CGFloat)size { return W7Substitute([self w7_messageFontOfSize:size], NSFontWeightRegular); }
+ (NSFont *)w7_menuFontOfSize:(CGFloat)size { return W7Substitute([self w7_menuFontOfSize:size], NSFontWeightRegular); }
+ (NSFont *)w7_titleBarFontOfSize:(CGFloat)size { return W7Substitute([self w7_titleBarFontOfSize:size], NAN); }
+ (NSFont *)w7_labelFontOfSize:(CGFloat)size { return W7Substitute([self w7_labelFontOfSize:size], NSFontWeightRegular); }
+ (NSFont *)w7_controlContentFontOfSize:(CGFloat)size {
    return W7Substitute([self w7_controlContentFontOfSize:size], NSFontWeightRegular);
}
// Monospaced requests keep the system font, even if AppKit builds them from the system font methods above.
+ (NSFont *)w7_monospacedSystemFontOfSize:(CGFloat)size weight:(NSFontWeight)weight {
    tBypass++;
    @try { return [self w7_monospacedSystemFontOfSize:size weight:weight]; }
    @finally { tBypass--; }
}
+ (NSFont *)w7_monospacedDigitSystemFontOfSize:(CGFloat)size weight:(NSFontWeight)weight {
    tBypass++;
    @try { return [self w7_monospacedDigitSystemFontOfSize:size weight:weight]; }
    @finally { tBypass--; }
}
@end

static void W7SwizzleFontMethods(void) {
    if (gSwizzled) return;
    gSwizzled = YES;
    static const char *const pairs[][2] = {
        { "systemFontOfSize:", "w7_systemFontOfSize:" },
        { "systemFontOfSize:weight:", "w7_systemFontOfSize:weight:" },
        { "boldSystemFontOfSize:", "w7_boldSystemFontOfSize:" },
        { "messageFontOfSize:", "w7_messageFontOfSize:" },
        { "menuFontOfSize:", "w7_menuFontOfSize:" },
        { "titleBarFontOfSize:", "w7_titleBarFontOfSize:" },
        { "labelFontOfSize:", "w7_labelFontOfSize:" },
        { "controlContentFontOfSize:", "w7_controlContentFontOfSize:" },
        { "monospacedSystemFontOfSize:weight:", "w7_monospacedSystemFontOfSize:weight:" },
        { "monospacedDigitSystemFontOfSize:weight:", "w7_monospacedDigitSystemFontOfSize:weight:" },
    };
    for (size_t i = 0; i < sizeof pairs / sizeof pairs[0]; i++) {
        if (!W7SwizzleClassMethod(NSFont.class, sel_registerName(pairs[i][0]), sel_registerName(pairs[i][1]))) {
            os_log_error(W7Log(), "swizzle of +[NSFont %{public}s] failed", pairs[i][0]);
        }
    }
}

BOOL W7FontSubstitutionIsSwizzled(void) { return gSwizzled; }

BOOL W7FontSubstitutionIsActive(void) { return atomic_load(&gActive); }

void W7FontSubstitutionDeactivate(void) {
    atomic_store(&gActive, false);
    os_unfair_lock_lock(&gLock);
    [gCache removeAllObjects];
    os_unfair_lock_unlock(&gLock);
}

/// Registers the faces from `dir` and, when the regular face resolves, swizzles (once) and turns substitution on.
static BOOL W7InstallFrom(NSString *dir, BOOL installedFallback) {
    @try {
        if (W7FontSubstitutionDisabled()) {
            os_log(W7Log(), "font substitution off: W7FontSubstitutionDisabled");
            return NO;
        }
        NSString *regular = W7FindFace(dir, @"segoeui.ttf", installedFallback, @"SegoeUI");
        if (!regular) {
            os_log(W7Log(), "font substitution off: segoeui.ttf not imported (looked in %{public}@%{public}s)",
                   dir, installedFallback ? ", ~/Library/Fonts and the installed fonts" : "");
            return NO;
        }
        NSString *bold = W7FindFace(dir, @"segoeuib.ttf", installedFallback, @"SegoeUI-Bold");
        os_unfair_lock_lock(&gLock);
        gRegularName = [regular copy];
        gBoldName = [bold copy];
        if (!gCache) gCache = [NSMutableDictionary dictionary];
        [gCache removeAllObjects];
        os_unfair_lock_unlock(&gLock);
        W7SwizzleFontMethods();
        atomic_store(&gActive, true);
        os_log(W7Log(), "font substitution on: regular %{public}@, bold %{public}@", regular, bold ?: @"(system bold)");
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "font substitution install failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

BOOL W7FontSubstitutionInstallFromDirectory(NSString *dir) {
    return W7InstallFrom(dir, NO);
}

/// Keeps gLight in step with the app's appearance (read on the main thread, used from any thread).
@interface W7FontAppearanceObserver : NSObject
@end

@implementation W7FontAppearanceObserver
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx {
    @try {
        BOOL light = !W7IsDarkAppearance(NSApp.effectiveAppearance);
        if (light != atomic_load(&gLight)) {
            atomic_store(&gLight, light);
            os_log(W7Log(), "font substitution: appearance now %{public}s", light ? "light" : "dark");
        }
    } @catch (NSException *e) { os_log_error(W7Log(), "font appearance update failed: %{public}@", e.reason ?: @"unknown"); }
}
@end

void W7InstallFontSubstitution(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            if (!W7FontSubstitutionAppliesToBundlePath(NSBundle.mainBundle.bundlePath)) {
                os_log(W7Log(), "font substitution off: not an app bundle");
                return;
            }
            if (!W7InstallFrom(W7FontSubstitutionFontDirectory(), YES) || !NSApp) return;
            static W7FontAppearanceObserver *observer;
            observer = [W7FontAppearanceObserver new];
            atomic_store(&gLight, !W7IsDarkAppearance(NSApp.effectiveAppearance));
            [NSApp addObserver:observer forKeyPath:@"effectiveAppearance" options:0 context:NULL];
        } @catch (NSException *e) {
            os_log_error(W7Log(), "font substitution start failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}
