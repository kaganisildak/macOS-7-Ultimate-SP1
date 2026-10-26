// Windows 7 folder icons in Finder's browser views. Finder's icon, list, column and gallery
// view controllers fill every cell with [self iconImageForNode:node] and then -setIconImage: on the cell
// (static analysis of Finder: configureIconView:forNode:, updateIconForNameCellView:node:,
// updateColumnCellView:…, configureGalleryIconView:forNode: and their reloadIconsInView blocks). So,
// in Finder only, every class of Finder's image that owns -iconImageForNode: is hooked (TBaseBrowser-,
// TBrowser-, TGalleryCollection- and TAirDropCollectionViewController; not TDesktopViewController),
// and the views already filled at launch are reloaded once. The replacement keeps Finder's
// own icon for everything but a plain folder: packages, volumes, aliases, symlinks, locked folders,
// folders the user can't read (drop boxes, other users' folders), folders with a pasted icon or macOS
// folder customization (tint, symbol, emoji), and folders showing copy or download progress. Finder
// composes badges into the icon it returns; a plain folder with another badge (shared) loses it,
// because the composed image can't be told apart.
//
// Files: a plain file (a readable regular file, no alias, symlink, pasted icon, lock, package or
// copy in progress) gets the user's icon of its type (file-text, file-image, file-audio, file-video, file,
// from the extension through UTType, never by reading the file) when that PNG exists; otherwise, and for
// every special file, Finder's icon stays: there is no drawn stand-in for files. As in Windows 7, which shows
// thumbnails from Medium icons (48) up, pictures, videos, audio and generic files keep Finder's image (its Quick
// Look thumbnail, album art, PDF page) at 48 pt and more and get the type icon only below (
// W7FileIconOverrideAppliesAtSize); text files get it at every size.
#import "Win7ChromeCore.h"
#import "W7ExplorerInternal.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <sys/attr.h>
#import <sys/stat.h>
#import <sys/vnode.h>
#import <sys/xattr.h>
#import <unistd.h>

const char *const W7FolderIconNodeMethodTypes = "@24@0:8r^{TFENode=^{OpaqueNodeRef}}16";

static NSString *const kFolderIconsDisabledKey = @"W7FolderIconsDisabled";
/// The macOS folder customization (tint, symbol, emoji) lives in this extended attribute (IconServices'
/// ISFolderIconConfiguration reads it).
static const char *const kFolderCustomizationXattr = "com.apple.icon.folder#S";
/// File-system traits are re-read after this long, so a pasted icon or a customization made while
/// Finder runs is respected the next time Finder asks for the icon.
static const CFTimeInterval kTraitsLifetime = 5;

// FinderInfo flags (big-endian, bytes 8-9 of a file's or a folder's Finder info).
enum { kW7IsAlias = 0x8000, kW7HasBundle = 0x2000, kW7HasCustomIcon = 0x0400 };

// gLock guards the two pointers below. Only pointer loads and stores happen under it (the ARC retain or
// release of a value the global still holds, never a dealloc), no messages: a value being replaced is
// released after the unlock.
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSString *gAssetRoot;                           // nil: the default root
static NSDictionary<NSString *, NSNumber *> *gSpecialPathsOverride;

/// Hooked classes, under gHookLock. Installing runs ObjC work, so that lock is released in @finally.
static os_unfair_lock gHookLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSValue *> *gHookedClasses;

/// Hooked classes whose first call was logged, claimed lock-free; the table is small because Finder
/// has a handful of browser view controller classes (later ones are simply not logged).
enum { kLoggedClassSlots = 16 };
static _Atomic(uintptr_t) gLoggedClasses[kLoggedClassSlots];
static atomic_bool gLoggedFirstReplacement;

/// Classes whose receivers keep Finder's icon (TDesktopViewController), as Class pointers (classes are
/// never deallocated), read lock-free on every icon request.
enum { kSkippedClassSlots = 4 };
static _Atomic(uintptr_t) gSkippedClasses[kSkippedClassSlots];

/// Hooked iconImageForNode: levels running on this thread. Finder's implementations call super into
/// other hooked ones (TGalleryCollection → TBrowser → TBaseBrowser); only the outermost level decides,
/// on the image Finder finally returns, so an icon is evaluated and replaced once per request.
static _Thread_local unsigned gHookDepth;

#pragma mark - Decisions

BOOL W7ShouldReplaceFolderIcon(W7FolderNodeTraits traits) {
    return traits == W7FolderNodeIsFolder;
}

BOOL W7FolderIconHookShouldInstall(NSString *bundleID, BOOL disabled) {
    return !disabled && [bundleID isEqualToString:@"com.apple.finder"];
}

W7FolderNodeTraits W7FolderFileTraits(NSString *path) {
    if (path.length == 0) return 0;
    const char *fs = path.fileSystemRepresentation;
    // Attributes come back in bit order: OBJTYPE (0x8), FNDRINFO (0x4000), FLAGS (0x40000), then dirattr.
    struct attrlist request = { .bitmapcount = ATTR_BIT_MAP_COUNT,
                                .commonattr = ATTR_CMN_OBJTYPE | ATTR_CMN_FNDRINFO | ATTR_CMN_FLAGS,
                                .dirattr = ATTR_DIR_MOUNTSTATUS };
    struct __attribute__((packed)) {
        uint32_t length;
        fsobj_type_t type;
        uint8_t finderInfo[32];
        uint32_t bsdFlags;      // chflags(2) flags
        uint32_t mountStatus;   // returned for directories only
    } reply = { 0 };
    if (getattrlist(fs, &request, &reply, sizeof reply, FSOPT_NOFOLLOW) != 0) return 0;
    if (reply.type == VLNK) return W7FolderNodeIsSymlink;
    W7FolderNodeTraits traits = 0;
    uint16_t flags = (uint16_t)((reply.finderInfo[8] << 8) | reply.finderInfo[9]);
    if (flags & kW7IsAlias) traits |= W7FolderNodeIsAlias;
    if (flags & kW7HasCustomIcon) traits |= W7FolderNodeHasCustomIcon;
    if (reply.bsdFlags & (UF_IMMUTABLE | SF_IMMUTABLE)) traits |= W7FolderNodeIsLocked;
    if (reply.type == VREG) {
        // A file without read permission: Finder may badge it, so it keeps Finder's icon.
        if (access(fs, R_OK) != 0) return traits | W7FolderNodeIsUnreadable;
        return traits ? traits : W7FolderNodeIsPlainFile;
    }
    if (reply.type != VDIR) return traits;
    traits |= W7FolderNodeIsFolder;
    // No read permission (a drop box, someone else's folder): Finder badges these, so keep its icon.
    if (access(fs, R_OK) != 0) traits |= W7FolderNodeIsUnreadable;
    if (reply.length >= sizeof reply && (reply.mountStatus & DIR_MNTSTATUS_MNTPOINT)) traits |= W7FolderNodeIsVolume;
    if (getxattr(fs, kFolderCustomizationXattr, NULL, 0, 0, XATTR_NOFOLLOW) >= 0) traits |= W7FolderNodeIsCustomized;
    // A package has the bundle bit or a package extension (.app, .bundle, document packages); only a
    // name with an extension needs the Launch Services lookup.
    if (flags & kW7HasBundle) {
        traits |= W7FolderNodeIsPackage;
    } else if (path.pathExtension.length) {
        NSNumber *package = nil;
        [[NSURL fileURLWithPath:path isDirectory:YES] getResourceValue:&package forKey:NSURLIsPackageKey error:NULL];
        if (package.boolValue) traits |= W7FolderNodeIsPackage;
    }
    return traits;
}

@interface W7FolderTraitsEntry : NSObject
@property (nonatomic) W7FolderNodeTraits traits;
@property (nonatomic) CFAbsoluteTime time;
@end
@implementation W7FolderTraitsEntry
@end

/// W7FolderFileTraits through a short-lived per-path cache: Finder asks for many icons while scrolling.
static W7FolderNodeTraits W7CachedFileTraits(NSString *path) {
    static NSCache<NSString *, W7FolderTraitsEntry *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 16384;   // entries are tiny: a big folder scrolls without re-reading every item
    });
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    W7FolderTraitsEntry *hit = [cache objectForKey:path];
    if (hit && now - hit.time < kTraitsLifetime) return hit.traits;
    W7FolderTraitsEntry *entry = [W7FolderTraitsEntry new];
    entry.traits = W7FolderFileTraits(path);
    entry.time = now;
    [cache setObject:entry forKey:path];
    return entry.traits;
}

#pragma mark - Special folders

NSDictionary<NSString *, NSNumber *> *W7FolderIconSpecialPaths(void) {
    static NSDictionary *paths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        NSString *home = NSHomeDirectory().stringByStandardizingPath;
        if (home.length) map[home] = @(W7FolderIconUser);
        const struct { NSSearchPathDirectory dir; W7FolderIconKind kind; } dirs[] = {
            { NSDesktopDirectory, W7FolderIconDesktop }, { NSDocumentDirectory, W7FolderIconDocuments },
            { NSDownloadsDirectory, W7FolderIconDownloads }, { NSMusicDirectory, W7FolderIconMusic },
            { NSPicturesDirectory, W7FolderIconPictures }, { NSMoviesDirectory, W7FolderIconVideos },
        };
        NSFileManager *fm = NSFileManager.defaultManager;
        for (size_t i = 0; i < sizeof dirs / sizeof dirs[0]; i++) {
            NSString *path = [fm URLsForDirectory:dirs[i].dir inDomains:NSUserDomainMask].firstObject.path.stringByStandardizingPath;
            if (path.length) map[path] = @(dirs[i].kind);
        }
        paths = [map copy];
    });
    return paths;
}

void W7FolderIconUseSpecialPaths(NSDictionary<NSString *, NSNumber *> *specialPaths) {
    NSDictionary *copy = [specialPaths copy];
    os_unfair_lock_lock(&gLock);
    NSDictionary *old = gSpecialPathsOverride;   // keeps the old value alive past the unlock
    gSpecialPathsOverride = copy;
    os_unfair_lock_unlock(&gLock);
    (void)old;   // released at the end of scope, outside the lock
}

static NSDictionary<NSString *, NSNumber *> *W7CurrentSpecialPaths(void) {
    os_unfair_lock_lock(&gLock);
    NSDictionary *override = gSpecialPathsOverride;
    os_unfair_lock_unlock(&gLock);
    return override ?: W7FolderIconSpecialPaths();
}

W7FolderIconKind W7FolderIconKindForPath(NSString *path, NSDictionary<NSString *, NSNumber *> *specialPaths) {
    if (path.length == 0) return W7FolderIconPlain;
    NSNumber *kind = specialPaths[path.stringByStandardizingPath];
    NSInteger value = kind.integerValue;
    return kind && value >= 0 && value < W7FolderIconKindCount ? (W7FolderIconKind)value : W7FolderIconPlain;
}

#pragma mark - Images

NSString *W7FolderIconAssetName(W7FolderIconKind kind) {
    switch (kind) {
        case W7FolderIconDocuments: return @"folder-documents";
        case W7FolderIconPictures: return @"folder-pictures";
        case W7FolderIconMusic: return @"folder-music";
        case W7FolderIconVideos: return @"folder-videos";
        case W7FolderIconDownloads: return @"folder-downloads";
        case W7FolderIconDesktop: return @"folder-desktop";
        case W7FolderIconUser: return @"folder-user";
        case W7FolderIconPlain: break;
    }
    return @"folder";
}

/// How many bitmaps W7IconCache holds (tests): counted up on insertion, down on every eviction or removal.
static _Atomic(NSInteger) gCachedBitmaps;

@interface W7IconCacheCounter : NSObject <NSCacheDelegate>
@end
@implementation W7IconCacheCounter
- (void)cache:(NSCache *)cache willEvictObject:(id)obj {
    atomic_fetch_sub_explicit(&gCachedBitmaps, 1, memory_order_relaxed);
}
@end

/// Rendered bitmaps by "generation:kind:points:scale" (CGImage objects); the override sources live in the
/// user-icon loader's cache. Emptied on every loader reset (W7FolderIconClearBitmapCache).
static NSCache *W7IconCache(void) {
    static NSCache *cache;
    static W7IconCacheCounter *counter;   // NSCache does not retain its delegate
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.totalCostLimit = 64 * 1024 * 1024;
        counter = [W7IconCacheCounter new];
        cache.delegate = counter;
    });
    return cache;
}

void W7FolderIconClearBitmapCache(void) {
    @try {
        [W7IconCache() removeAllObjects];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "folder icon cache reset failed: %{public}@", e.reason ?: @"unknown");
    }
}

NSUInteger W7FolderIconCachedBitmapCount(void) {
    NSInteger n = atomic_load_explicit(&gCachedBitmaps, memory_order_relaxed);
    return n > 0 ? (NSUInteger)n : 0;
}

void W7FolderIconUseAssetRoot(NSString *root) {
    NSString *copy = [root copy];
    os_unfair_lock_lock(&gLock);
    NSString *old = gAssetRoot;   // keeps the old value alive past the unlock
    gAssetRoot = copy;
    os_unfair_lock_unlock(&gLock);
    (void)old;   // released at the end of scope, outside the lock
    W7UserIconsClearCaches();   // the folder bitmaps too
}

static NSString *W7AssetRoot(void) {
    os_unfair_lock_lock(&gLock);
    NSString *root = gAssetRoot;
    os_unfair_lock_unlock(&gLock);
    return root ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Win7Mac/Assets"];
}

/// The user's icon for `kind` as a CGImage object, or nil: read through the user-icon loader, so its caps
/// (no symlink, 2 MB, 1024 px, checked before decoding) and the embedded `__w7icons` section apply, and the
/// absence is remembered there. Objects, not CGImageRefs, so a cache eviction can't free a bitmap in use.
static id W7OverrideImage(W7FolderIconKind kind) {
    return W7UserIconSourceImage(W7FolderIconAssetName(kind));
}

/// `override` drawn aspect-fit into a square `pixels` bitmap, +1 retained.
static CGImageRef W7CreateScaledImage(CGImageRef override, size_t pixels) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixels, pixels, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGFloat w = CGImageGetWidth(override), h = CGImageGetHeight(override), side = pixels;
    CGFloat s = MIN(side / MAX(w, 1), side / MAX(h, 1));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake((side - w * s) / 2, (side - h * s) / 2, w * s, h * s), override);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

/// The icon bitmap for `kind` at `points` × `scale` pixels, as a CGImage object.
static id W7CachedIconBitmap(W7FolderIconKind kind, CGFloat points, CGFloat scale) {
    NSCache *cache = W7IconCache();
    // The loader's generation is read first and keys the bitmap, so new embedded icons (or a reset racing
    // this render) never leave a stale bitmap where the next request looks.
    NSString *key = [NSString stringWithFormat:@"%lu:%ld:%.0f:%.0f", (unsigned long)W7UserIconsGeneration(), (long)kind, points, scale];
    id hit = [cache objectForKey:key];
    if (hit) return hit;
    __attribute__((objc_precise_lifetime)) id override = W7OverrideImage(kind);
    CGImageRef img = override ? W7CreateScaledImage((__bridge CGImageRef)override, (size_t)(points * scale))
                              : W7CreateFolderIconImage(kind, points, scale);
    if (!img) return nil;
    id object = CFBridgingRelease(img);
    atomic_fetch_add_explicit(&gCachedBitmaps, 1, memory_order_relaxed);
    [cache setObject:object forKey:key cost:(NSUInteger)(points * scale * points * scale * 4)];
    return object;
}

CGFloat W7FolderIconBucketPoints(CGFloat points) {
    CGFloat whole = ceil(points);
    return whole > 64 ? ceil(whole / 8) * 8 : whole;
}

/// `square` drawn into a `size` × `scale` bitmap as a centred square of `side` points, +1 retained (a
/// non-square image Finder asks for; not cached, as Finder's icon sizes are square).
static CGImageRef W7CreateCentredBitmap(CGImageRef square, NSSize size, CGFloat side, CGFloat scale) {
    size_t w = (size_t)ceil(size.width * scale), h = (size_t)ceil(size.height * scale);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGFloat px = side * scale;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(round((w - px) / 2), round((h - px) / 2), px, px), square);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

NSImage *W7FolderIconImage(W7FolderIconKind kind, NSSize size) {
    if (!(size.width > 0) || !(size.height > 0)) return nil;
    CGFloat side = MIN(size.width, size.height);
    CGFloat bucket = W7FolderIconBucketPoints(side);
    if (bucket > 2048) return nil;
    BOOL square = size.width == size.height;
    NSImage *image = [[NSImage alloc] initWithSize:size];
    for (CGFloat scale = 1; scale <= 2; scale++) {
        id bitmap = W7CachedIconBitmap(kind, bucket, scale);
        if (!bitmap) return nil;
        // A square image draws the bucket bitmap scaled uniformly to `size`; a non-square one gets the
        // icon centred at its shorter side, so nothing is stretched.
        id rendered = square ? bitmap
                             : CFBridgingRelease(W7CreateCentredBitmap((__bridge CGImageRef)bitmap, size, side, scale));
        if (!rendered) return nil;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)rendered];
        rep.size = size;
        [image addRepresentation:rep];
    }
    return image;
}

#pragma mark - Files

/// UTType is linked into the dylib but not into the SwiftPM target: looked up at run time.
static BOOL W7UTTypeConforms(id type, NSString *identifier) {
    Class cls = NSClassFromString(@"UTType");
    if (!type || !cls) return NO;
    UTType *other = [cls typeWithIdentifier:identifier];
    return other && [(UTType *)type conformsToType:other];
}

/// The type icon name for `path`'s extension, as IconOverrideNames.fileType maps it; cached per extension.
static NSString *W7FileTypeIconName(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    if (ext.length == 0) return @"file";
    static NSCache<NSString *, NSString *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 512;
    });
    NSString *hit = [cache objectForKey:ext];
    if (hit) return hit;
    Class cls = NSClassFromString(@"UTType");
    id type = cls ? [cls typeWithFilenameExtension:ext] : nil;
    NSString *name = W7UTTypeConforms(type, @"public.image")   ? @"file-image"
                   : W7UTTypeConforms(type, @"public.movie")   ? @"file-video"
                   : W7UTTypeConforms(type, @"public.audio")   ? @"file-audio"
                   : W7UTTypeConforms(type, @"public.text")    ? @"file-text"
                                                               : @"file";
    [cache setObject:name forKey:ext];
    return name;
}

NSString *W7FileIconOverrideName(W7FolderNodeTraits traits, NSString *path) {
    @try {
        if (traits != W7FolderNodeIsPlainFile) return nil;
        return W7FileTypeIconName(path ?: @"");
    } @catch (NSException *e) {
        os_log_error(W7Log(), "file icon type lookup failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

/// Windows 7's Medium icons: from this size up it shows thumbnails rather than type icons.
static const CGFloat kThumbnailMinPoints = 48;

BOOL W7FileIconOverrideAppliesAtSize(NSString *name, NSSize size) {
    if (name.length == 0 || !(size.width > 0) || !(size.height > 0)) return NO;
    if (MIN(size.width, size.height) < kThumbnailMinPoints) return YES;
    // Finder's image may be a Quick Look thumbnail, album art or a PDF page for these: it stays.
    static NSSet<NSString *> *thumbnailed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ thumbnailed = [NSSet setWithObjects:@"file-image", @"file-video", @"file-audio", @"file", nil]; });
    return ![thumbnailed containsObject:name];
}

NSImage *W7ExplorerIconForPath(NSString *path, CGFloat points) {
    @try {
        if (path.length == 0 || !(points > 0)) return nil;
        NSSize size = NSMakeSize(points, points);
        W7FolderNodeTraits traits = W7CachedFileTraits(path);
        if (traits & W7FolderNodeIsVolume) {
            if (traits & (W7FolderNodeIsUnreadable | W7FolderNodeHasCustomIcon)) return nil;
            BOOL system = [path.stringByStandardizingPath isEqualToString:@"/"];
            return W7UserIconImageSized(system ? @"drive-system" : @"drive", size);
        }
        if (traits & W7FolderNodeIsFolder) {
            if (!W7ShouldReplaceFolderIcon(traits)) return nil;
            return W7FolderIconImage(W7FolderIconKindForPath(path, W7CurrentSpecialPaths()), size);
        }
        NSString *name = W7FileIconOverrideName(traits, path);
        return name ? W7UserIconImageSized(name, size) : nil;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer location icon failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}

/// Whether `path`'s extension names a package type (`.app`, `.photoslibrary`): no file-system access.
static BOOL W7PathExtensionIsPackage(NSString *path) {
    NSString *ext = path.pathExtension;
    if (ext.length == 0) return NO;
    Class cls = NSClassFromString(@"UTType");
    UTType *package = [cls typeWithIdentifier:@"com.apple.package"];
    if (!package) return NO;
    // The plain extension lookup assumes public.data, which a package type (a directory) does not conform to.
    UTType *type = [cls typeWithFilenameExtension:ext conformingToType:package];
    return type && !type.dynamic && [type conformsToType:package];
}

NSImage *W7ExplorerMenuIconForPath(NSString *path) {
    NSSize size = NSMakeSize(16, 16);
    @try {
        // Judged by the path alone: the menu is built on the main thread.
        if (W7NavPanePathIsMountPoint(path)) {
            BOOL system = [path.stringByStandardizingPath isEqualToString:@"/"];
            NSImage *drive = W7UserIconImageSized(system ? @"drive-system" : @"drive", size);
            if (drive) return drive;
        }
        NSImage *icon = W7PathExtensionIsPackage(path ?: @"") ? nil
                      : W7FolderIconImage(W7FolderIconKindForPath(path ?: @"", W7CurrentSpecialPaths()), size);
        if (icon) return icon;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer menu icon failed: %{public}@", e.reason ?: @"unknown");
    }
    NSImage *folder = [[NSImage imageNamed:NSImageNameFolder] copy] ?: [[NSImage alloc] initWithSize:size];
    folder.size = size;
    return folder;
}

#pragma mark - Hook

static BOOL W7Responds(id object, SEL sel) {
    return [object respondsToSelector:sel];
}

static BOOL W7SendBool(id object, const char *name) {
    SEL sel = sel_registerName(name);
    return W7Responds(object, sel) && ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

/// Whether Finder shows copy or download progress on the node's icon. `copyProgress` is read without
/// taking ownership (its name is in the copy family, so its return convention can't be trusted): only
/// its presence counts.
static BOOL W7NodeShowsProgress(id node) {
    SEL download = sel_registerName("downloadProgress"), copy = sel_registerName("copyProgress");
    if (W7Responds(node, download) && ((id (*)(id, SEL))objc_msgSend)(node, download)) return YES;
    return W7Responds(node, copy) && ((void *(*)(id, SEL))objc_msgSend)(node, copy) != NULL;
}

/// YES exactly once per class (lock-free: atomic loads on every later call, no strings or locks).
static BOOL W7ClaimFirstCall(Class cls) {
    uintptr_t key = (uintptr_t)(__bridge const void *)cls;
    if (!key) return NO;
    for (int i = 0; i < kLoggedClassSlots; i++) {
        uintptr_t seen = atomic_load_explicit(&gLoggedClasses[i], memory_order_acquire);
        if (seen == key) return NO;
        if (seen != 0) continue;
        uintptr_t expected = 0;
        if (atomic_compare_exchange_strong_explicit(&gLoggedClasses[i], &expected, key, memory_order_acq_rel,
                                                    memory_order_acquire)) return YES;
        if (expected == key) return NO;   // another thread claimed this class in this slot
    }
    return NO;   // table full: further classes are not logged
}

typedef NS_ENUM(NSInteger, W7IconOutcome) {
    W7IconOutcomeKept,      // Finder's icon stays (not a plain folder, or no node / URL / size)
    W7IconOutcomeReplaced,
    W7IconOutcomeNested,    // an inner level: the outermost hooked level decides
    W7IconOutcomeSkipped,   // the receiver is a skipped class (the desktop)
};

/// YES when `receiver` is an instance of a skipped class (lock-free).
static BOOL W7IsSkippedReceiver(id receiver) {
    for (int i = 0; i < kSkippedClassSlots; i++) {
        uintptr_t cls = atomic_load_explicit(&gSkippedClasses[i], memory_order_acquire);
        if (cls && [receiver isKindOfClass:(__bridge Class)(void *)cls]) return YES;
    }
    return NO;
}

/// One diagnostic line per hooked class, on its first call: which implementation ran, for which
/// receiver (its class as it reports itself, not a KVO subclass), at what size, and what happened.
static void W7LogFirstCall(Class hookedClass, id receiver, id original, W7IconOutcome outcome, W7FolderNodeTraits traits) {
    if (!W7ClaimFirstCall(hookedClass)) return;
    NSImage *image = [original isKindOfClass:NSImage.class] ? original : nil;
    const char *what = outcome == W7IconOutcomeReplaced ? "replaced"
                     : outcome == W7IconOutcomeNested ? "inner level, the outer level decides"
                     : outcome == W7IconOutcomeSkipped ? "kept, skipped class" : "kept";
    os_log(W7Log(), "folder icons: first call to -[%{public}@ iconImageForNode:] from %{public}@: %.0fx%.0f pt, %{public}s "
           "(traits 0x%lx), main thread %d", NSStringFromClass(hookedClass) ?: @"?",
           NSStringFromClass([receiver class]) ?: @"?", image.size.width, image.size.height, what,
           (unsigned long)traits, NSThread.isMainThread);
}

static atomic_bool gLoggedFirstFileReplacement;

/// The user's type icon for a file node, or nil to keep `original`: only a plain file (W7FileIconOverrideName)
/// whose type PNG exists, at a size W7FileIconOverrideAppliesAtSize allows (Finder's thumbnails stay at 48 pt and
/// more). The type name, the size rule and the PNG (all cached or pure) come before the file system is asked, so
/// a type without a PNG, or a thumbnail size, costs no system call.
static NSImage *W7FileIconReplacement(NSImage *original, id node, W7IconOutcome *outcome, W7FolderNodeTraits *traits) {
    if (W7SendBool(node, "isPackage")) *traits |= W7FolderNodeIsPackage;
    if (W7NodeShowsProgress(node)) *traits |= W7FolderNodeInProgress;
    if (*traits) return nil;
    SEL fileURL = sel_registerName("fileURL");
    NSURL *url = W7Responds(node, fileURL) ? ((id (*)(id, SEL))objc_msgSend)(node, fileURL) : nil;
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL || url.path.length == 0) return nil;
    NSSize size = original.size;
    if (!(size.width > 0) || !(size.height > 0)) return nil;
    NSString *path = url.path;
    NSString *name = W7FileIconOverrideName(W7FolderNodeIsPlainFile, path);
    if (!W7FileIconOverrideAppliesAtSize(name, size)) return nil;
    NSImage *icon = W7UserIconImageSized(name, size);
    if (!icon) return nil;
    *traits = W7CachedFileTraits(path);
    if (!W7FileIconOverrideName(*traits, path)) return nil;
    *outcome = W7IconOutcomeReplaced;
    if (!atomic_load_explicit(&gLoggedFirstFileReplacement, memory_order_relaxed) &&
        !atomic_exchange(&gLoggedFirstFileReplacement, true)) {
        // The type name only: never the file's name or path.
        os_log(W7Log(), "file icons: first replacement, %{public}@ at %.0fx%.0f pt (1x and 2x)", name, size.width, size.height);
    }
    return icon;
}

/// The Windows 7 icon for the node `nodePtr` points at, or nil to keep `original`. `outcome` and
/// `traits` (what is known when the decision was made) are for the diagnostic log.
static NSImage *W7FolderIconReplacement(id original, const void *nodePtr, Class nodeClass, W7IconOutcome *outcome,
                                        W7FolderNodeTraits *traits) {
    *outcome = W7IconOutcomeKept;
    *traits = 0;
    if (![original isKindOfClass:NSImage.class] || !nodePtr) return nil;
    void *ref = *(void *const *)nodePtr;
    if (!ref) return nil;
    id node = ((id (*)(id, SEL, void *))objc_msgSend)(nodeClass, sel_registerName("nodeFromNodeRef:"), ref);
    if (!node) return nil;
    if (!W7SendBool(node, "isFolder")) return W7FileIconReplacement(original, node, outcome, traits);
    *traits = W7FolderNodeIsFolder;
    if (W7SendBool(node, "isPackage")) *traits |= W7FolderNodeIsPackage;
    if (W7NodeShowsProgress(node)) *traits |= W7FolderNodeInProgress;
    if (!W7ShouldReplaceFolderIcon(*traits)) return nil;
    SEL fileURL = sel_registerName("fileURL");
    NSURL *url = W7Responds(node, fileURL) ? ((id (*)(id, SEL))objc_msgSend)(node, fileURL) : nil;
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL || url.path.length == 0) return nil;
    NSString *path = url.path;
    W7FolderNodeTraits fs = W7CachedFileTraits(path);
    *traits |= fs;
    if (!(fs & W7FolderNodeIsFolder) || !W7ShouldReplaceFolderIcon(*traits)) return nil;
    NSSize size = ((NSImage *)original).size;
    if (!(size.width > 0) || !(size.height > 0)) return nil;
    W7FolderIconKind kind = W7FolderIconKindForPath(path, W7CurrentSpecialPaths());
    NSImage *icon = W7FolderIconImage(kind, size);
    if (!icon) return nil;
    *outcome = W7IconOutcomeReplaced;
    if (!atomic_load_explicit(&gLoggedFirstReplacement, memory_order_relaxed) && !atomic_exchange(&gLoggedFirstReplacement, true)) {
        os_log(W7Log(), "folder icons: first replacement, kind %ld at %.0fx%.0f pt (1x and 2x)", (long)kind, size.width, size.height);
    }
    return icon;
}

/// `cls`'s own (not inherited) method for `sel`, or NULL.
static Method W7OwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count && !found; i++)
        if (method_getName(methods[i]) == sel) found = methods[i];
    free(methods);
    return found;
}

BOOL W7FolderIconHookClass(Class cls, Class nodeClass) {
    @try {
        if (!cls || !nodeClass) return NO;
        NSString *name = NSStringFromClass(cls);
        if (![nodeClass respondsToSelector:sel_registerName("nodeFromNodeRef:")]) {
            os_log(W7Log(), "folder icons: %{public}@ skipped, %{public}@ has no +nodeFromNodeRef:", name, NSStringFromClass(nodeClass));
            return NO;
        }
        SEL sel = sel_registerName("iconImageForNode:");
        Method method = W7OwnMethod(cls, sel);
        if (!method) {
            os_log(W7Log(), "folder icons: %{public}@ skipped, it does not implement iconImageForNode:", name);
            return NO;
        }
        const char *types = method_getTypeEncoding(method);
        if (!types || strcmp(types, W7FolderIconNodeMethodTypes) != 0) {
            os_log(W7Log(), "folder icons: %{public}@ skipped, iconImageForNode: has types %{public}s", name, types ?: "(none)");
            return NO;
        }
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cls];
        // The check, the swap and the record must be one step, so they run under gHookLock; it guards only
        // installation (never the icon path), and @finally releases it if anything in between throws.
        BOOL hooked = NO;
        os_unfair_lock_lock(&gHookLock);
        @try {
            if (!gHookedClasses) gHookedClasses = [NSMutableSet set];
            hooked = [gHookedClasses containsObject:key];
            if (!hooked) {
                id (*original)(id, SEL, const void *) = (id (*)(id, SEL, const void *))method_getImplementation(method);
                IMP replacement = imp_implementationWithBlock(^id(id receiver, const void *node) {
                    // A skipped class's receiver (the desktop, which calls super into a hooked class) and
                    // every inner level get Finder's own result, untouched and unevaluated.
                    BOOL skipped = W7IsSkippedReceiver(receiver), nested = gHookDepth > 0;
                    if (skipped || nested) {
                        id image = original(receiver, sel, node);
                        @try {
                            W7LogFirstCall(cls, receiver, image, skipped ? W7IconOutcomeSkipped : W7IconOutcomeNested, 0);
                        } @catch (NSException *e) {
                            os_log_error(W7Log(), "folder icon log failed: %{public}@", e.reason ?: @"unknown");
                        }
                        return image;
                    }
                    // The outermost level: the depth is raised around Finder's call, so the hooked
                    // implementations it calls into stay out of the way, and lowered even if it throws.
                    id image = nil;
                    gHookDepth++;
                    @try {
                        image = original(receiver, sel, node);
                    } @finally {
                        gHookDepth--;
                    }
                    @try {
                        W7IconOutcome outcome = W7IconOutcomeKept;
                        W7FolderNodeTraits traits = 0;
                        NSImage *icon = W7FolderIconReplacement(image, node, nodeClass, &outcome, &traits);
                        W7LogFirstCall(cls, receiver, image, outcome, traits);
                        return icon ?: image;
                    } @catch (NSException *e) {
                        os_log_error(W7Log(), "folder icon replacement failed: %{public}@", e.reason ?: @"unknown");
                        return image;
                    }
                });
                method_setImplementation(method, replacement);
                [gHookedClasses addObject:key];
            }
        } @finally {
            os_unfair_lock_unlock(&gHookLock);
        }
        if (!hooked) os_log(W7Log(), "folder icons: %{public}@ hooked", name);
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "folder icon hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Discovery

NSSet<NSString *> *W7FolderIconSkippedClassNames(void) {
    return [NSSet setWithObject:@"TDesktopViewController"];
}

void W7FolderIconUseSkippedClasses(NSArray<Class> *classes) {
    if (classes.count > kSkippedClassSlots)
        os_log_error(W7Log(), "folder icons: %lu skipped classes, only %d kept", (unsigned long)classes.count, kSkippedClassSlots);
    for (NSUInteger i = 0; i < kSkippedClassSlots; i++) {
        uintptr_t cls = i < classes.count ? (uintptr_t)(__bridge const void *)classes[i] : 0;
        atomic_store_explicit(&gSkippedClasses[i], cls, memory_order_release);
    }
}

NSArray<Class> *W7FolderIconHookCandidates(NSArray<Class> *classes, NSSet<NSString *> *skippedNames) {
    NSMutableArray<Class> *found = [NSMutableArray array];
    @try {
        SEL sel = sel_registerName("iconImageForNode:");
        for (Class cls in classes) {
            Method method = W7OwnMethod(cls, sel);
            if (!method) continue;
            NSString *name = NSStringFromClass(cls);
            const char *types = method_getTypeEncoding(method);
            if (!types || strcmp(types, W7FolderIconNodeMethodTypes) != 0) {
                os_log(W7Log(), "folder icons: %{public}@ skipped, iconImageForNode: has types %{public}s", name, types ?: "(none)");
            } else if ([skippedNames containsObject:name]) {
                os_log(W7Log(), "folder icons: %{public}@ skipped by name", name);
            } else {
                [found addObject:cls];
            }
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "folder icon class scan failed: %{public}@", e.reason ?: @"unknown");
    }
    return found;
}

NSArray<Class> *W7FolderIconHookCandidatesInImage(NSString *imageName, NSSet<NSString *> *skippedNames) {
    NSMutableArray<Class> *classes = [NSMutableArray array];
    if (imageName.length) {
        unsigned int count = 0;
        const char **names = objc_copyClassNamesForImage(imageName.fileSystemRepresentation, &count);
        for (unsigned int i = 0; i < count; i++) {
            Class cls = objc_getClass(names[i]);
            if (cls) [classes addObject:cls];
        }
        free(names);
    }
    return W7FolderIconHookCandidates(classes, skippedNames);
}

#pragma mark - Refresh

/// Collects `candidate` when it is a `base` and not a skipped class (the desktop is left alone).
static void W7CollectController(id candidate, Class base, NSHashTable *found) {
    if (candidate && [candidate isKindOfClass:base] && !W7IsSkippedReceiver(candidate)) [found addObject:candidate];
}

static void W7CollectFromViewControllers(NSViewController *vc, Class base, NSHashTable *found, NSUInteger depth) {
    if (!vc || depth > 32) return;
    W7CollectController(vc, base, found);
    for (NSViewController *child in [vc.childViewControllers copy]) W7CollectFromViewControllers(child, base, found, depth + 1);
}

/// A view controller's view has the controller as its next responder; collection and table views name
/// their controllers as delegate and data source. `budget` caps the walk on huge view trees.
static void W7CollectFromViews(NSView *view, Class base, NSHashTable *found, NSUInteger depth, NSInteger *budget) {
    if (!view || depth > 64 || --*budget < 0) return;
    W7CollectController(view.nextResponder, base, found);
    if ([view isKindOfClass:NSCollectionView.class]) {
        W7CollectController(((NSCollectionView *)view).delegate, base, found);
        W7CollectController(((NSCollectionView *)view).dataSource, base, found);
    } else if ([view isKindOfClass:NSTableView.class]) {   // outline views too
        W7CollectController(((NSTableView *)view).delegate, base, found);
        W7CollectController(((NSTableView *)view).dataSource, base, found);
    }
    for (NSView *sub in [view.subviews copy]) W7CollectFromViews(sub, base, found, depth + 1, budget);
}

NSArray *W7FolderIconBrowserControllers(NSArray<NSWindow *> *windows, Class baseClass) {
    if (!baseClass) return @[];
    NSHashTable *found = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
    for (NSWindow *w in windows) {
        W7CollectFromViewControllers(w.contentViewController, baseClass, found, 0);
        NSInteger budget = 20000;
        W7CollectFromViews(w.contentView, baseClass, found, 0, &budget);
    }
    return found.allObjects;
}

NSUInteger W7FolderIconReloadBrowserViews(NSArray<NSWindow *> *windows, Class baseClass) {
    SEL reload = sel_registerName("reloadIconsInView");
    NSUInteger reloaded = 0;
    for (id vc in W7FolderIconBrowserControllers(windows, baseClass)) {
        @try {
            if (![vc respondsToSelector:reload]) continue;
            ((void (*)(id, SEL))objc_msgSend)(vc, reload);
            reloaded++;
        } @catch (NSException *e) {
            os_log_error(W7Log(), "folder icons: reloading %{public}@ failed: %{public}@", NSStringFromClass([vc class]),
                         e.reason ?: @"unknown");
        }
    }
    return reloaded;
}

/// Finder fills the restored windows' icons before the hook is installed (at the first decoration,
/// after launch), so their browser views are reloaded once, wherever their controllers sit (skipped
/// classes, the desktop, are left out by W7CollectController).
static void W7ReloadOpenBrowserViews(void) {
    @try {
        Class base = NSClassFromString(@"TBaseBrowserViewController");
        if (!base) return;
        NSArray<NSWindow *> *windows = [NSApp.windows copy];
        NSUInteger reloaded = W7FolderIconReloadBrowserViews(windows, base);
        os_log(W7Log(), "folder icons: reloaded %lu open browser views in %lu windows", (unsigned long)reloaded,
               (unsigned long)windows.count);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "folder icon reload failed: %{public}@", e.reason ?: @"unknown");
    }
}

void W7ExplorerInstallFolderIconHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
            BOOL disabled = [NSUserDefaults.standardUserDefaults boolForKey:kFolderIconsDisabledKey];
            if (!W7FolderIconHookShouldInstall(bundleID, disabled)) {
                os_log(W7Log(), "folder icons: not installed in %{public}@ (%{public}s)", bundleID ?: @"(none)",
                       disabled ? "W7FolderIconsDisabled" : "not Finder");
                return;
            }
            Class browser = NSClassFromString(@"TBrowserViewController"), node = NSClassFromString(@"FINode");
            if (!browser || !node) {
                os_log(W7Log(), "folder icons: not installed, %{public}s missing", !browser ? "TBrowserViewController" : "FINode");
                return;
            }
            // Every class of Finder's own image that implements the method, not only TBrowserViewController:
            // the image name comes from the runtime, so it is exactly what objc_copyClassNamesForImage takes.
            const char *imageName = class_getImageName(browser);
            if (!W7ExplorerBrowseImageIsFinder(imageName)) {
                os_log(W7Log(), "folder icons: not installed, TBrowserViewController is in %{public}s, not Finder",
                       imageName ?: "(no image)");
                return;
            }
            // Skipping a class's own method is not enough: TDesktopViewController calls super into the
            // hooked TBaseBrowserViewController. So its instances are recognised in every hook, resolved
            // once here, before any hook is live.
            NSMutableArray<Class> *skipped = [NSMutableArray array];
            for (NSString *name in W7FolderIconSkippedClassNames()) {
                Class cls = NSClassFromString(name);
                if (cls) [skipped addObject:cls];
                else os_log(W7Log(), "folder icons: skipped class %{public}@ not found", name);
            }
            W7FolderIconUseSkippedClasses(skipped);
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            NSArray<Class> *candidates = W7FolderIconHookCandidatesInImage(@(imageName), W7FolderIconSkippedClassNames());
            NSMutableArray<NSString *> *hooked = [NSMutableArray array];
            for (Class cls in candidates)
                if (W7FolderIconHookClass(cls, node)) [hooked addObject:NSStringFromClass(cls)];
            os_log(W7Log(), "folder icons: hooked %lu of %lu classes in %.0f ms: %{public}@", (unsigned long)hooked.count,
                   (unsigned long)candidates.count, (CFAbsoluteTimeGetCurrent() - start) * 1000,
                   [hooked componentsJoinedByString:@", "]);
            if (hooked.count) dispatch_async(dispatch_get_main_queue(), ^{ W7ReloadOpenBrowserViews(); });
        } @catch (NSException *e) {
            os_log_error(W7Log(), "folder icon hook install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}

#pragma mark - Shared asset root

NSString *W7FolderIconAssetRootPath(void) {
    return W7AssetRoot();
}
