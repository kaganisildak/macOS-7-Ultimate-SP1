#import "Win7Theme.h"

CGImageRef W7CreateTaskbarButtonImage(CGSize size, CGFloat scale, BOOL running, BOOL active, BOOL hover,
                                      NSInteger windowCount, CGColorRef glow) {
    size_t w = (size_t)llround(size.width * scale), h = (size_t)llround(size.height * scale);
    if (w == 0 || h == 0 || scale <= 0) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextScaleCTM(ctx, scale, scale);
    W7DrawTaskbarGroupButton(ctx, CGRectMake(0, 0, size.width, size.height), running, active, hover, windowCount, glow);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}
