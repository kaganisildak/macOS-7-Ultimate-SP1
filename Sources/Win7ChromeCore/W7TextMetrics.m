#import "Win7ChromeCore.h"
#import <os/lock.h>

/// text sizes per (text, font). Each font gets its own NSCache (the menu fonts are a handful of
/// static instances), so a lookup is two hash probes instead of a CoreText layout.
NSSize W7TextSize(NSString *text, NSFont *font) {
    if (!text || !font) return NSZeroSize;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableDictionary<NSFont *, NSCache<NSString *, NSValue *> *> *caches;
    os_unfair_lock_lock(&lock);
    if (!caches) caches = [NSMutableDictionary new];
    NSCache<NSString *, NSValue *> *cache = caches[font];
    if (!cache) {
        // Fonts are few; a runaway set (a caller creating fonts per call) is simply reset.
        if (caches.count >= 32) [caches removeAllObjects];
        cache = [NSCache new];
        cache.countLimit = 1024;
        caches[font] = cache;
    }
    NSValue *hit = [cache objectForKey:text];
    os_unfair_lock_unlock(&lock);
    if (hit) return hit.sizeValue;
    NSString *key = [text copy];
    NSSize size = [key sizeWithAttributes:@{ NSFontAttributeName: font }];
    [cache setObject:[NSValue valueWithSize:size] forKey:key];   // NSCache is thread-safe
    return size;
}
