#import "Win7Theme.h"
#import <os/lock.h>
#import <sys/stat.h>
#import <time.h>

NSString * const W7ThemeName = @"Win7";

W7RGBA W7RGBAFromHex(uint32_t rgb, CGFloat alpha) {
    W7RGBA c = { ((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0, alpha };
    return c;
}

const CGFloat W7TaskbarHeight = 40;
const CGFloat W7TitlebarHeight = 30;
const CGFloat W7CaptionCloseWidth = 43;
const CGFloat W7CaptionSmallWidth = 26;
const CGFloat W7CaptionHeight = 18;
const CGFloat W7MenuStripHeight = 20;
const CGFloat W7MenuItemHeight = 22;
const CGFloat W7MenuSeparatorHeight = 7;
const CGFloat W7MenuGutterWidth = 28;
const CGFloat W7MenuMinWidth = 160;
const CGFloat W7SnapPreviewInset = 8;

/// Whether a Segoe UI file is in `dir` (a directory listing).
static BOOL W7SegoeInstalled(NSString *dir) {
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    for (NSString *f in files) {
        NSString *lower = [f lowercaseString];
        if ([lower hasPrefix:@"segoeui"] || [lower hasPrefix:@"segoe ui"]) return YES;
    }
    return NO;
}

/// W7UIFont is called from draw methods, so the directory listing and the fonts are cached.
/// The folder's modification time is checked at most once a second; a font installed or removed
/// there is picked up by the first call after that.
NSFont *W7UIFont(CGFloat size) {
    static NSString *const kName = @"Segoe UI";
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableDictionary<NSNumber *, NSFont *> *fonts;
    static NSString *dir;
    static struct timespec dirTime;
    static uint64_t checkedAt;
    static BOOL checked;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    os_unfair_lock_lock(&lock);
    if (!fonts) {
        fonts = [NSMutableDictionary new];
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Fonts"];
    }
    if (!checked || now - checkedAt >= NSEC_PER_SEC) {
        struct stat st;
        struct timespec t = stat(dir.fileSystemRepresentation, &st) == 0 ? st.st_mtimespec : (struct timespec){ 0, 0 };
        if (t.tv_sec != dirTime.tv_sec || t.tv_nsec != dirTime.tv_nsec) [fonts removeAllObjects];
        dirTime = t;
        checkedAt = now;
        checked = YES;
    }
    NSFont *font = fonts[@(size)];
    NSString *fontDir = dir;
    os_unfair_lock_unlock(&lock);
    if (font) return font;

    // Built outside the lock (a directory listing and a font lookup, which may take locks of their
    // own); a concurrent caller may build the same font, and the first one stored wins.
    NSFont *made = W7SegoeInstalled(fontDir) ? [NSFont fontWithName:kName size:size] : nil;
    // A Segoe file that does not load as "Segoe UI" falls back to the system font, as before.
    if (!made) made = [NSFont systemFontOfSize:size];
    os_unfair_lock_lock(&lock);
    font = fonts[@(size)];
    if (!font) { fonts[@(size)] = made; font = made; }
    os_unfair_lock_unlock(&lock);
    return font;
}
