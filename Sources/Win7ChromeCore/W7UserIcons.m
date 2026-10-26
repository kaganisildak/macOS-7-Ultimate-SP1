// The dylib's loader for the user's imported icons: for a
// catalogue name, `<asset root>/icons/<name>.png` (W7FolderIconAssetRootPath, so tests can point it at a
// temp folder), else the PNG `make chrome` embedded in the `__DATA,__w7icons` section (sandboxed apps such
// as Safari and TextEdit cannot read ~/Library/Application Support), else nil. Callers keep their drawn or
// system fallback for nil.
//
// The files are user data: a name is a plain file name, a symlink, a non-regular file, a file over 2 MB, a
// non-PNG or a PNG over 1024 px counts as absent (checked before decoding, from the PNG header). Each name
// is decoded at most once and remembered (NSNull when absent) until W7FolderIconUseAssetRoot or
// W7UserIconsUseEmbedded resets the caches (the rendered folder bitmaps too); the section is parsed lazily on
// first use.
#import "Win7ChromeCore.h"
#import "W7ExplorerInternal.h"
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/getsect.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <unistd.h>

static const off_t kMaxFileBytes = 2 * 1024 * 1024;
static const NSUInteger kMaxEmbeddedBytes = 512 * 1024;
static const uint32_t kMaxSourcePixels = 1024;
static const CGFloat kMaxPoints = 512;
static const size_t kMaxBitmapPixels = 1024;
static const NSUInteger kMaxNameLength = 128;
/// Each cache holds at most this many bitmap bytes (as the folder-icon cache, W7ExplorerFolderIcons.m).
static const NSUInteger kCacheCostLimit = 64 * 1024 * 1024;

// gLock guards the three pointers below. Only pointer loads and stores happen under it (an ARC retain of a
// value a global still holds, never a dealloc), no messages: a value being replaced is released after the
// unlock. A reset swaps in new caches, so a decode that was running during the reset fills the old ones,
// which nothing reads any more.
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary<NSString *, NSData *> *gEmbedded;   // nil: the section is read on next use
static NSCache *gSources;                               // name → CGImage object or NSNull
static NSCache *gImages;                                // "name|points" → NSImage or NSNull
static _Atomic(NSUInteger) gDecodeCount;
static _Atomic(NSUInteger) gGeneration;                 // bumped on every reset

NSArray<NSString *> *W7UserIconNames(void) {
    // Exactly the lines of scripts/chrome-icon-names.txt (UserIconTests compares them).
    return @[
        @"app-com.apple.ActivityMonitor", @"app-com.apple.Music", @"app-com.apple.Notes", @"app-com.apple.Preview",
        @"app-com.apple.Safari", @"app-com.apple.Terminal", @"app-com.apple.TextEdit", @"app-com.apple.calculator",
        @"app-com.apple.finder", @"app-com.apple.systempreferences", @"computer", @"drive", @"drive-optical",
        @"drive-removable", @"drive-system",
        @"favorites", @"file", @"file-audio", @"file-image", @"file-text", @"file-video", @"folder",
        @"folder-desktop", @"folder-documents", @"folder-downloads", @"folder-music", @"folder-pictures",
        @"folder-user", @"folder-videos", @"help", @"ie-add-favorite", @"ie-help", @"ie-home", @"ie-page",
        @"ie-print", @"msgbox-info", @"msgbox-warning", @"network", @"recent-places", @"recycle-bin-empty",
        @"recycle-bin-full", @"shared", @"user",
    ];
}

/// `[A-Za-z0-9][A-Za-z0-9._-]*` (IconOverrideNames.isSafeName without the extension): never a path, never
/// hidden.
static BOOL W7UserIconIsSafeName(id name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    NSString *s = name;
    NSUInteger n = s.length;
    if (n == 0 || n > kMaxNameLength) return NO;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        if (!alnum && (i == 0 || (c != '.' && c != '-' && c != '_'))) return NO;
    }
    return YES;
}

/// The entries of `icons` with a safe name and PNG data of 1 byte to 512 KB.
static NSDictionary<NSString *, NSData *> *W7UserIconsFiltered(NSDictionary *icons) {
    NSMutableDictionary<NSString *, NSData *> *out = [NSMutableDictionary dictionary];
    [icons enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (!W7UserIconIsSafeName(key) || ![value isKindOfClass:NSData.class]) return;
        NSUInteger length = ((NSData *)value).length;
        if (length == 0 || length > kMaxEmbeddedBytes) return;
        out[key] = [value copy];
    }];
    return [out copy];
}

NSDictionary<NSString *, NSData *> *W7UserIconsFromPlistData(NSData *data) {
    @try {
        if (![data isKindOfClass:NSData.class] || !data.length) return @{};
        id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
        if (![plist isKindOfClass:NSDictionary.class]) return @{};
        return W7UserIconsFiltered(plist);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "icon plist parse failed: %{public}@", e.reason ?: @"unknown");
        return @{};
    }
}

/// The `__DATA,__w7icons` section of the image this code is in, decoded; empty when there is none (a dylib
/// built before the import, or the SwiftPM test binary).
static NSDictionary<NSString *, NSData *> *W7ReadIconSection(void) {
    Dl_info info;
    if (!dladdr((const void *)&W7UserIconImage, &info) || !info.dli_fbase) return @{};
    unsigned long size = 0;
    uint8_t *bytes = getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__DATA", "__w7icons", &size);
    if (!bytes || !size) return @{};
    // The section stays mapped for the life of the process (the dylib is never unloaded).
    return W7UserIconsFromPlistData([NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:NO]);
}

static NSDictionary<NSString *, NSData *> *W7EmbeddedIcons(void) {
    os_unfair_lock_lock(&gLock);
    NSDictionary *icons = gEmbedded;
    os_unfair_lock_unlock(&gLock);
    if (icons) return icons;
    NSDictionary *read = W7ReadIconSection();
    os_unfair_lock_lock(&gLock);
    if (!gEmbedded) gEmbedded = read;   // a concurrent first use may have stored it already
    icons = gEmbedded;
    os_unfair_lock_unlock(&gLock);
    return icons;
}

/// The current caches (created on first use).
static void W7UserIconCaches(NSCache *__strong *sources, NSCache *__strong *images) {
    os_unfair_lock_lock(&gLock);
    *sources = gSources;
    *images = gImages;
    os_unfair_lock_unlock(&gLock);
    if (*sources && *images) return;
    NSCache *newSources = [NSCache new], *newImages = [NSCache new];
    newSources.countLimit = 128;
    newImages.countLimit = 256;
    // Costs are bitmap bytes: a 1024 px source is 4 MB, a 512 pt image (1x + 2x) about 5 MB.
    newSources.totalCostLimit = kCacheCostLimit;
    newImages.totalCostLimit = kCacheCostLimit;
    os_unfair_lock_lock(&gLock);
    if (!gSources) gSources = newSources;
    if (!gImages) gImages = newImages;
    *sources = gSources;
    *images = gImages;
    os_unfair_lock_unlock(&gLock);
}

/// Drops both caches (and, with `setEmbedded`, replaces the embedded icons; nil re-reads the section).
static void W7UserIconsReset(BOOL setEmbedded, NSDictionary<NSString *, NSData *> *embedded) {
    os_unfair_lock_lock(&gLock);
    // Keep the old values alive past the unlock: they are released at the end of scope.
    NSCache *oldSources = gSources, *oldImages = gImages;
    NSDictionary *oldEmbedded = gEmbedded;
    gSources = nil;
    gImages = nil;
    if (setEmbedded) gEmbedded = embedded;
    os_unfair_lock_unlock(&gLock);
    atomic_fetch_add_explicit(&gGeneration, 1, memory_order_release);
    // The folder bitmaps are keyed by generation: the old ones would only sit in that cache's budget.
    W7FolderIconClearBitmapCache();
    (void)oldSources;
    (void)oldImages;
    (void)oldEmbedded;
}

void W7UserIconsClearCaches(void) {
    @try {
        W7UserIconsReset(NO, nil);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "icon cache reset failed: %{public}@", e.reason ?: @"unknown");
    }
}

void W7UserIconsUseEmbedded(NSDictionary<NSString *, NSData *> *icons) {
    @try {
        W7UserIconsReset(YES, icons ? W7UserIconsFiltered(icons) : nil);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "icon embedded override failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark - Decoding

/// The bytes of the regular file at `path` (not a symlink, FIFO or folder; 1 byte to 2 MB), or nil. The
/// checks are made on the opened descriptor too, so a file swapped for a symlink after lstat is refused.
static NSData *W7ReadIconFile(NSString *path) {
    const char *p = path.fileSystemRepresentation;
    struct stat st;
    if (!p || lstat(p, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > kMaxFileBytes) return nil;
    int fd = open(p, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    NSMutableData *data = nil;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size <= kMaxFileBytes) {
        data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
        NSUInteger got = 0;
        while (got < data.length) {
            ssize_t r = read(fd, (uint8_t *)data.mutableBytes + got, data.length - got);
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) break;
            got += (NSUInteger)r;
        }
        data.length = got;
    }
    close(fd);
    return data.length ? data : nil;
}

/// `png` decoded as a CGImage object, or nil when it is not a PNG or is over 1024 px either way (read from
/// the IHDR chunk, before anything is decoded).
static id W7DecodeIcon(NSData *png) {
    static const uint8_t kSignature[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    if (png.length < 24 || png.length > (NSUInteger)kMaxFileBytes) return nil;
    const uint8_t *b = png.bytes;
    if (memcmp(b, kSignature, sizeof kSignature) != 0 || memcmp(b + 12, "IHDR", 4) != 0) return nil;
    uint32_t w = OSReadBigInt32(b, 16), h = OSReadBigInt32(b, 20);
    if (w == 0 || h == 0 || w > kMaxSourcePixels || h > kMaxSourcePixels) return nil;
    atomic_fetch_add_explicit(&gDecodeCount, 1, memory_order_relaxed);
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:png];
    if (!rep || rep.pixelsWide <= 0 || rep.pixelsHigh <= 0 || rep.pixelsWide > (NSInteger)kMaxSourcePixels ||
        rep.pixelsHigh > (NSInteger)kMaxSourcePixels)
        return nil;
    // The rep is held while its CGImage is taken; the caller's cache then owns the CGImage.
    return (__bridge id)rep.CGImage;
}

/// The source bitmap for `name` (the asset file, else the embedded PNG), cached in `sources` (NSNull when
/// there is none, so an absent icon costs one lookup until the next reset).
static id W7UserIconSource(NSString *name, NSCache *sources) {
    id hit = [sources objectForKey:name];
    if (hit) return hit == NSNull.null ? nil : hit;
    NSString *file = [[W7FolderIconAssetRootPath() stringByAppendingPathComponent:@"icons"]
                      stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    NSData *data = W7ReadIconFile(file);
    id image = data ? W7DecodeIcon(data) : nil;
    if (!image) {
        NSData *embedded = W7EmbeddedIcons()[name];
        if (embedded) image = W7DecodeIcon(embedded);
    }
    NSUInteger cost = image ? CGImageGetWidth((__bridge CGImageRef)image) * CGImageGetHeight((__bridge CGImageRef)image) * 4 : 0;
    [sources setObject:image ?: NSNull.null forKey:name cost:cost];
    return image;
}

/// `src` drawn aspect-fit and centred into a `pixels` square sRGB bitmap, as a CGImage object (moved from
/// the navigation pane's W7NavAssetBitmap).
static id W7ScaledBitmap(CGImageRef src, size_t pixels) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixels, pixels, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGFloat w = CGImageGetWidth(src), h = CGImageGetHeight(src), side = pixels;
    CGFloat s = MIN(side / MAX(w, 1), side / MAX(h, 1));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake((side - w * s) / 2, (side - h * s) / 2, w * s, h * s), src);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return CFBridgingRelease(img);
}

#pragma mark - Entry points

id W7UserIconBitmap(NSString *name, size_t pixels) {
    @try {
        if (!W7UserIconIsSafeName(name) || pixels == 0 || pixels > kMaxBitmapPixels) return nil;
        NSCache *sources, *images;
        W7UserIconCaches(&sources, &images);
        // Held until the bitmap is drawn: a cache eviction meanwhile must not free it.
        __attribute__((objc_precise_lifetime)) id src = W7UserIconSource(name, sources);
        return src ? W7ScaledBitmap((__bridge CGImageRef)src, pixels) : nil;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "user icon %{public}@ failed: %{public}@", name, e.reason ?: @"unknown");
        return nil;
    }
}

NSImage *W7UserIconImage(NSString *name, CGFloat points) {
    @try {
        if (!W7UserIconIsSafeName(name) || !(points > 0) || points > kMaxPoints) return nil;
        NSCache *sources, *images;
        W7UserIconCaches(&sources, &images);
        NSString *key = [NSString stringWithFormat:@"%@|%g", name, points];
        id hit = [images objectForKey:key];
        if (hit) return hit == NSNull.null ? nil : hit;
        __attribute__((objc_precise_lifetime)) id src = W7UserIconSource(name, sources);
        NSImage *image = nil;
        NSUInteger cost = 0;
        if (src) {
            image = [[NSImage alloc] initWithSize:NSMakeSize(points, points)];
            for (CGFloat scale = 1; scale <= 2; scale++) {
                id bitmap = W7ScaledBitmap((__bridge CGImageRef)src, (size_t)ceil(points * scale));
                if (!bitmap) {
                    image = nil;
                    break;
                }
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)bitmap];
                rep.size = NSMakeSize(points, points);
                [image addRepresentation:rep];
                cost += (NSUInteger)(rep.pixelsWide * rep.pixelsHigh * 4);
            }
        }
        [images setObject:image ?: NSNull.null forKey:key cost:image ? cost : 0];
        return image;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "user icon %{public}@ failed: %{public}@", name, e.reason ?: @"unknown");
        return nil;
    }
}

/// `square` drawn into a `size` × `scale` bitmap as a centred square of `side` points (a non-square size).
static id W7CentredBitmap(CGImageRef square, NSSize size, CGFloat side, CGFloat scale) {
    size_t w = (size_t)ceil(size.width * scale), h = (size_t)ceil(size.height * scale);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGFloat px = side * scale;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(round((w - px) / 2), round((h - px) / 2), px, px), square);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return CFBridgingRelease(img);
}

NSImage *W7UserIconImageSized(NSString *name, NSSize size) {
    @try {
        if (!(size.width > 0) || !(size.height > 0) || size.width > kMaxPoints || size.height > kMaxPoints) return nil;
        CGFloat side = MIN(size.width, size.height);
        CGFloat bucket = MIN(W7FolderIconBucketPoints(side), kMaxPoints);
        NSImage *shared = W7UserIconImage(name, bucket);
        if (!shared) return nil;
        BOOL square = size.width == size.height;
        NSImage *image = [[NSImage alloc] initWithSize:size];
        for (NSImageRep *candidate in shared.representations) {
            if (![candidate isKindOfClass:NSBitmapImageRep.class]) continue;
            CGImageRef cg = ((NSBitmapImageRep *)candidate).CGImage;
            if (!cg) return nil;
            CGFloat scale = candidate.pixelsWide / bucket;
            id rendered = square ? (__bridge id)cg : W7CentredBitmap(cg, size, side, scale);
            if (!rendered) return nil;
            // A new rep over the shared CGImage: sizing it never touches the cached image.
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)rendered];
            rep.size = size;
            [image addRepresentation:rep];
        }
        return image.representations.count ? image : nil;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "user icon %{public}@ failed: %{public}@", name, e.reason ?: @"unknown");
        return nil;
    }
}

id W7UserIconSourceImage(NSString *name) {
    @try {
        if (!W7UserIconIsSafeName(name)) return nil;
        NSCache *sources, *images;
        W7UserIconCaches(&sources, &images);
        return W7UserIconSource(name, sources);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "user icon %{public}@ failed: %{public}@", name, e.reason ?: @"unknown");
        return nil;
    }
}

NSUInteger W7UserIconsGeneration(void) {
    return atomic_load_explicit(&gGeneration, memory_order_acquire);
}

NSUInteger W7UserIconDecodeCount(void) {
    return atomic_load_explicit(&gDecodeCount, memory_order_relaxed);
}
