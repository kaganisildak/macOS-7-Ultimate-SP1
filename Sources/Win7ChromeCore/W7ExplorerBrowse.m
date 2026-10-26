// Folder Options ▸ General ▸ Browse folders: "Open each folder in the same window" (Windows 7's
// default) or "in its own window". Explorer windows hide Finder's toolbar, and Finder opens a folder
// in a new window whenever a browser window's toolbar is hidden. In Finder only, the classes of Finder's
// own executable that answer -isToolbarVisible (TBrowserWindowController, found live) are hooked so an
// Explorer window reports a shown toolbar in same-window mode.
#import "W7ExplorerInternal.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <pthread.h>

NSString *const W7ExplorerBrowseSuiteName = @"com.win7mac.chrome";
NSString *const W7ExplorerOpenFoldersInNewWindowKey = @"ExplorerOpenFoldersInNewWindow";

static NSString *const kSameWindowTitle = @"Open each folder in the same window";
static NSString *const kOwnWindowTitle = @"Open each folder in its own window";

#pragma mark - Preference

/// One defaults suite and the cached preference, kept current by key-value observing the key (which
/// also reports writes from other processes, e.g. `defaults write com.win7mac.chrome …`).
@interface W7ExplorerBrowsePrefs : NSObject
- (instancetype)initWithSuiteName:(NSString *)suiteName;
@property (nonatomic, readonly) NSUserDefaults *defaults;
@property (atomic) BOOL openInNewWindow;
@end

static void *kBrowsePrefsKVOCtx = &kBrowsePrefsKVOCtx;

@implementation W7ExplorerBrowsePrefs

- (instancetype)initWithSuiteName:(NSString *)suiteName {
    if ((self = [super init])) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName] ?: NSUserDefaults.standardUserDefaults;
        self.openInNewWindow = [_defaults boolForKey:W7ExplorerOpenFoldersInNewWindowKey];
        [_defaults addObserver:self forKeyPath:W7ExplorerOpenFoldersInNewWindowKey options:0 context:kBrowsePrefsKVOCtx];
    }
    return self;
}

- (void)dealloc {
    @try {
        [_defaults removeObserver:self forKeyPath:W7ExplorerOpenFoldersInNewWindowKey context:kBrowsePrefsKVOCtx];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "browse prefs: KVO removal failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)ctx {
    if (ctx != kBrowsePrefsKVOCtx) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:ctx];
        return;
    }
    @try { self.openInNewWindow = [_defaults boolForKey:W7ExplorerOpenFoldersInNewWindowKey]; }
    @catch (NSException *e) { os_log_error(W7Log(), "browse prefs: refresh failed: %{public}@", e.reason ?: @"unknown"); }
}

@end

// Created and replaced on the main thread only; the hook reads it on the main thread only.
static W7ExplorerBrowsePrefs *gBrowsePrefs;

static W7ExplorerBrowsePrefs *W7BrowsePrefs(void) {
    if (!gBrowsePrefs) gBrowsePrefs = [[W7ExplorerBrowsePrefs alloc] initWithSuiteName:W7ExplorerBrowseSuiteName];
    return gBrowsePrefs;
}

void W7ExplorerUseBrowseDefaultsSuite(NSString *suiteName) {
    gBrowsePrefs = [[W7ExplorerBrowsePrefs alloc] initWithSuiteName:suiteName ?: W7ExplorerBrowseSuiteName];
}

BOOL W7ExplorerOpensFoldersInNewWindow(void) {
    return W7BrowsePrefs().openInNewWindow;
}

void W7ExplorerSetOpensFoldersInNewWindow(BOOL openInNewWindow) {
    @try {
        W7ExplorerBrowsePrefs *prefs = W7BrowsePrefs();
        [prefs.defaults setBool:openInNewWindow forKey:W7ExplorerOpenFoldersInNewWindowKey];
        prefs.openInNewWindow = openInNewWindow;
        os_log(W7Log(), "browse folders: open each folder in %{public}s", openInNewWindow ? "its own window" : "the same window");
    } @catch (NSException *e) {
        os_log_error(W7Log(), "browse prefs: write failed: %{public}@", e.reason ?: @"unknown");
    }
}

BOOL W7ExplorerReportedToolbarVisible(BOOL actualVisible, BOOL isExplorerWindow, BOOL openInNewWindow) {
    return isExplorerWindow && !openInNewWindow ? YES : actualVisible;
}

#pragma mark - Hook

static SEL W7ToolbarVisibleSelector(void) { return sel_registerName("isToolbarVisible"); }

/// `cls`'s own (not inherited) argument-free BOOL method for `sel`, or NULL.
static Method W7OwnBoolGetter(Class cls, SEL sel, BOOL *ownsWrongType) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) != sel) continue;
        const char *types = method_getTypeEncoding(methods[i]);
        BOOL boolReturn = types && (types[0] == 'B' || types[0] == 'c');
        if (boolReturn && method_getNumberOfArguments(methods[i]) == 2) found = methods[i];
        else if (ownsWrongType) *ownsWrongType = YES;
        break;
    }
    free(methods);
    return found;
}

/// The window a -isToolbarVisible receiver stands for; never loads a window or a view.
static NSWindow *W7BrowseWindowForReceiver(id receiver) {
    if ([receiver isKindOfClass:NSWindow.class]) return receiver;
    if ([receiver isKindOfClass:NSWindowController.class]) {
        NSWindowController *wc = receiver;
        return wc.isWindowLoaded ? wc.window : nil;
    }
    if ([receiver isKindOfClass:NSViewController.class]) return ((NSViewController *)receiver).viewIfLoaded.window;
    SEL windowSel = @selector(window);
    Method m = class_getInstanceMethod(object_getClass(receiver), windowSel);
    const char *types = m ? method_getTypeEncoding(m) : NULL;
    if (!types || types[0] != '@' || method_getNumberOfArguments(m) != 2) return nil;
    id window = ((id (*)(id, SEL))objc_msgSend)(receiver, windowSel);
    return [window isKindOfClass:NSWindow.class] ? window : nil;
}

static NSMutableSet<NSValue *> *gHookedClasses;   // main thread only

BOOL W7ExplorerHookToolbarVisibleOnClass(Class cls) {
    @try {
        if (!cls) return NO;
        SEL sel = W7ToolbarVisibleSelector();
        Method method = W7OwnBoolGetter(cls, sel, NULL);
        if (!method) return NO;
        if (!gHookedClasses) gHookedClasses = [NSMutableSet set];
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cls];
        if ([gHookedClasses containsObject:key]) return YES;
        // Each class keeps its own original: a subclass's and its superclass's hooks never mix.
        BOOL (*original)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^BOOL(id receiver) {
            BOOL actual = original(receiver, sel);
            @try {
                if (!pthread_main_np()) return actual;
                BOOL newWindow = W7ExplorerOpensFoldersInNewWindow();
                if (newWindow) return actual;   // nothing to change: skip the window lookup
                return W7ExplorerReportedToolbarVisible(actual, W7IsExplorerWindow(W7BrowseWindowForReceiver(receiver)), newWindow);
            } @catch (NSException *e) {
                os_log_error(W7Log(), "browse hook failed: %{public}@", e.reason ?: @"unknown");
                return actual;
            }
        });
        method_setImplementation(method, replacement);
        [gHookedClasses addObject:key];
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "browse hook install on a class failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

/// A guard only: the installer already runs in Finder alone (bundle ID check in W7MaybeAdoptExplorer).
BOOL W7ExplorerBrowseImageIsFinder(const char *imagePath) {
    if (!imagePath) return NO;
    NSString *path = @(imagePath);
    return [path hasSuffix:@"/Finder.app/Contents/MacOS/Finder"];
}

NSArray<Class> *W7ExplorerBrowseHookCandidates(NSString *imagePath) {
    NSMutableArray<Class> *found = [NSMutableArray array];
    @try {
        if (imagePath.length == 0) return found;
        SEL sel = W7ToolbarVisibleSelector();
        unsigned int count = 0;
        const char **names = objc_copyClassNamesForImage(imagePath.fileSystemRepresentation, &count);
        for (unsigned int i = 0; i < count; i++) {
            Class cls = objc_getClass(names[i]);
            if (!cls) continue;
            BOOL wrongType = NO;
            if (W7OwnBoolGetter(cls, sel, &wrongType)) [found addObject:cls];
            else if (wrongType)
                os_log(W7Log(), "browse hook: %{public}@ (%{public}s)", NSStringFromClass(cls), "skipped, not a BOOL getter");
        }
        free(names);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "browse hook scan failed: %{public}@", e.reason ?: @"unknown");
    }
    return found;
}

NSString *W7ExplorerExecutableImageName(NSArray<NSNumber *> *fileTypes, NSArray<NSString *> *imageNames) {
    if (fileTypes.count != imageNames.count) return nil;
    for (NSUInteger i = 0; i < fileTypes.count; i++)
        if (fileTypes[i].unsignedIntValue == MH_EXECUTE && imageNames[i].length) return imageNames[i];
    return nil;
}

/// Comparison form of an image path: standardized, symlinks resolved, /private dropped from the
/// system folders that /var, /tmp and /etc link to.
static NSString *W7ImagePathKey(NSString *path) {
    NSString *key = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    for (NSString *prefix in @[ @"/private/var/", @"/private/tmp/", @"/private/etc/" ])
        if ([key hasPrefix:prefix]) return [key substringFromIndex:@"/private".length];
    return key;
}

NSString *W7ExplorerMainImageName(NSString *mainExecutablePath, NSArray<NSString *> *loadedImages) {
    if (mainExecutablePath.length == 0) return nil;
    NSString *mainKey = W7ImagePathKey(mainExecutablePath);
    // Exact spellings first (the usual case), without touching the file system per image.
    for (NSString *image in loadedImages)
        if ([image isEqualToString:mainExecutablePath] || [image isEqualToString:mainKey]) return image;
    // Then resolve only images named like the executable (either side may be spelled through a link).
    NSSet<NSString *> *names = [NSSet setWithObjects:mainExecutablePath.lastPathComponent, mainKey.lastPathComponent, nil];
    for (NSString *image in loadedImages) {
        if (image.length == 0 || ![names containsObject:image.lastPathComponent]) continue;
        if ([W7ImagePathKey(image) isEqualToString:mainKey]) return image;
    }
    return nil;
}

void W7ExplorerInstallBrowseHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            // The runtime registers classes under dyld's image name, which objc_copyClassNamesForImage
            // needs verbatim. Image 0 is not the executable under injection (Ammonia's loader is), so
            // take the MH_EXECUTE image; the executable path match is only a fallback.
            NSString *executable = NSBundle.mainBundle.executablePath;
            NSMutableArray<NSString *> *loaded = [NSMutableArray array];
            NSMutableArray<NSNumber *> *types = [NSMutableArray array];
            uint32_t imageCount = _dyld_image_count();
            for (uint32_t i = 0; i < imageCount; i++) {
                const char *name = _dyld_get_image_name(i);
                const struct mach_header *header = _dyld_get_image_header(i);
                if (!name || !header) continue;
                [loaded addObject:@(name)];
                [types addObject:@(header->filetype)];
            }
            NSString *image = W7ExplorerExecutableImageName(types, loaded);
            if (!image) {
                image = W7ExplorerMainImageName(executable, loaded);
                os_log(W7Log(), "browse hook: no MH_EXECUTE image; executable path match gave %{public}@",
                       image ?: @"nothing");
            }
            if (!image) {
                os_log(W7Log(), "browse hook: main executable %{public}@ not among %u loaded images; not hooked",
                       executable ?: @"(unknown)", imageCount);
                return;
            }
            if (!W7ExplorerBrowseImageIsFinder(image.fileSystemRepresentation)) {
                os_log(W7Log(), "browse hook: main image %{public}@ is not Finder; not hooked", image ?: @"(unknown)");
                return;
            }
            NSArray<Class> *candidates = W7ExplorerBrowseHookCandidates(image);
            NSUInteger hooked = 0;
            for (Class cls in candidates) {
                BOOL ok = W7ExplorerHookToolbarVisibleOnClass(cls);
                if (ok) hooked++;
                os_log(W7Log(), "browse hook: %{public}@ (%{public}s)", NSStringFromClass(cls),
                       [(ok ? @"hooked: " : @"hook failed: ") stringByAppendingString:image].UTF8String);
            }
            double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000;
            if (candidates.count == 0)
                os_log(W7Log(), "browse hook: no class in %{public}@ owns isToolbarVisible; not hooked (%.0f ms)", image, ms);
            else
                os_log(W7Log(), "browse hook: %lu of %lu classes hooked in %{public}@ in %.0f ms", (unsigned long)hooked,
                       (unsigned long)candidates.count, image, ms);
        } @catch (NSException *e) {
            os_log_error(W7Log(), "browse hook install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}

#pragma mark - Organize menu items

@interface W7ExplorerBrowseMenuTarget : NSObject
+ (instancetype)shared;
- (void)w7ChooseBrowseMode:(NSMenuItem *)sender;
@end

@implementation W7ExplorerBrowseMenuTarget

+ (instancetype)shared {
    static W7ExplorerBrowseMenuTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [W7ExplorerBrowseMenuTarget new]; });
    return target;
}

/// Tag 1: its own window; 0: the same window.
- (void)w7ChooseBrowseMode:(NSMenuItem *)sender {
    @try { W7ExplorerSetOpensFoldersInNewWindow(sender.tag == 1); }
    @catch (NSException *e) { os_log_error(W7Log(), "browse option failed: %{public}@", e.reason ?: @"unknown"); }
}

@end

void W7ExplorerAppendBrowseItems(NSMenu *menu) {
    BOOL newWindow = W7ExplorerOpensFoldersInNewWindow();
    [menu addItem:NSMenuItem.separatorItem];
    NSString *titles[] = { kSameWindowTitle, kOwnWindowTitle };
    for (NSInteger tag = 0; tag < 2; tag++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:titles[tag] action:@selector(w7ChooseBrowseMode:) keyEquivalent:@""];
        item.target = W7ExplorerBrowseMenuTarget.shared;
        item.tag = tag;
        item.enabled = YES;
        item.state = (tag == 1) == newWindow ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
}
