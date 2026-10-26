#import "Win7Theme.h"

// The default wallpaper: an original, procedural composition in the mood of the Windows 7
// default desktop — deep blue, brighter in the middle, with broad light ribbons sweeping from the
// lower left to the upper right and converging right of centre. No logo and no Microsoft artwork.
//
// Everything is laid out in unit coordinates of the rect (u to the right, v down from the top), so the
// picture is the same at any size and is drawn at whatever pixel size the context has. Nothing is random.

static CGColorSpaceRef W7WallpaperSRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7WallpaperColor(uint32_t hex, CGFloat a) {
    W7RGBA c = W7RGBAFromHex(hex, a);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7WallpaperSRGB(), v));
}

/// A gradient through `count` colours at `locations` (NULL: evenly spaced). The caller releases it.
static CGGradientRef W7WallpaperGradient(const uint32_t *hex, const CGFloat *alpha, const CGFloat *locations, size_t count) {
    CGColorRef cols[8];
    for (size_t i = 0; i < count; i++) cols[i] = W7WallpaperColor(hex[i], alpha[i]);
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, (CFIndex)count, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7WallpaperSRGB(), arr, locations);
    CFRelease(arr);
    return g;
}

/// Unit coordinates (v from the top) to the rect's user space (y up).
static CGPoint W7WallpaperPoint(CGRect r, CGFloat u, CGFloat v) {
    return CGPointMake(r.origin.x + u * r.size.width, CGRectGetMaxY(r) - v * r.size.height);
}

/// A soft radial glow: `hex` at `alpha` in the centre, fading linearly to nothing at `radius`.
static void W7WallpaperGlow(CGContextRef ctx, CGPoint center, CGFloat radius, uint32_t hex, CGFloat alpha) {
    const uint32_t hexes[2] = { hex, hex };
    const CGFloat alphas[2] = { alpha, 0 };
    CGGradientRef g = W7WallpaperGradient(hexes, alphas, NULL, 2);
    CGContextDrawRadialGradient(ctx, g, center, 0, center, radius, 0);
    CGGradientRelease(g);
}

/// One light ribbon: a cubic Bézier centre line in unit coordinates and its width as a fraction of the
/// rect's height. `hairline` puts a thin bright line along its upper edge.
typedef struct {
    CGFloat p0u, p0v, c1u, c1v, c2u, c2v, p3u, p3v;
    CGFloat width;
    BOOL hairline;
} W7Ribbon;

// Broadest first. The ribbons enter off the left or bottom edge, bend through the middle and converge
// around (0.62, 0.40) before fanning out off the right or top edge.
static const W7Ribbon W7Ribbons[] = {
    { -0.10, 0.92,  0.25, 0.70,  0.48, 0.42,  1.10, 0.18,  0.09, YES },
    { -0.10, 0.78,  0.28, 0.62,  0.50, 0.44,  1.10, 0.02,  0.06, NO  },
    {  0.00, 1.10,  0.32, 0.82,  0.52, 0.34,  1.10, 0.34,  0.07, YES },
    { -0.10, 0.60,  0.30, 0.56,  0.54, 0.47,  1.05, -0.10, 0.04, NO  },
    {  0.18, 1.10,  0.42, 0.78,  0.58, 0.44,  1.10, 0.52,  0.05, YES },
    { -0.10, 1.04,  0.38, 0.90,  0.56, 0.48,  0.98, -0.10, 0.03, NO  },
};

static CGPathRef W7RibbonPath(CGPoint p0, CGPoint c1, CGPoint c2, CGPoint p3) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, p0.x, p0.y);
    CGPathAddCurveToPoint(path, NULL, c1.x, c1.y, c2.x, c2.y, p3.x, p3.y);
    return (CGPathRef)CFAutorelease(path);
}

/// `p` moved `distance` along the left-hand normal of the direction `from` → `to` (up and to the left
/// for a ribbon travelling to the upper right).
static CGPoint W7OffsetPoint(CGPoint p, CGPoint from, CGPoint to, CGFloat distance) {
    CGFloat dx = to.x - from.x, dy = to.y - from.y, len = hypot(dx, dy);
    if (len == 0) return p;
    return CGPointMake(p.x - dy / len * distance, p.y + dx / len * distance);
}

/// Steps in the ribbon's cross profile: each is a centred stroke a little narrower than the last, so
/// with additive blending the light adds up to a peak in the middle and falls to nothing at the edges.
static const int W7RibbonSteps = 24;
static const CGFloat W7RibbonPeak = 0.22;
static const CGFloat W7HairlineAlpha = 0.35;

static void W7DrawRibbon(CGContextRef ctx, CGRect rect, const W7Ribbon *rb) {
    CGPoint p0 = W7WallpaperPoint(rect, rb->p0u, rb->p0v), c1 = W7WallpaperPoint(rect, rb->c1u, rb->c1v);
    CGPoint c2 = W7WallpaperPoint(rect, rb->c2u, rb->c2v), p3 = W7WallpaperPoint(rect, rb->p3u, rb->p3v);
    CGFloat width = rb->width * rect.size.height;

    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModePlusLighter);
    CGContextSetLineCap(ctx, kCGLineCapButt);
    CGContextSetStrokeColorWithColor(ctx, W7WallpaperColor(0xFFFFFF, W7RibbonPeak / W7RibbonSteps));
    CGPathRef centre = W7RibbonPath(p0, c1, c2, p3);
    for (int i = W7RibbonSteps; i >= 1; i--) {
        CGContextSetLineWidth(ctx, width * i / W7RibbonSteps);
        CGContextAddPath(ctx, centre);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);

    if (!rb->hairline) return;
    // A 1.5 px line at 1080 px high, scaled with the height, along the upper edge. Brightest where the
    // ribbons converge, fading out towards both ends.
    CGFloat half = width / 2;
    CGPoint e0 = W7OffsetPoint(p0, p0, c1, half), e1 = W7OffsetPoint(c1, p0, c2, half);
    CGPoint e2 = W7OffsetPoint(c2, c1, p3, half), e3 = W7OffsetPoint(p3, c2, p3, half);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, W7RibbonPath(e0, e1, e2, e3));
    CGContextSetLineWidth(ctx, 1.5 * rect.size.height / 1080);
    CGContextReplacePathWithStrokedPath(ctx);
    CGContextClip(ctx);
    const uint32_t hexes[4] = { 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF };
    const CGFloat alphas[4] = { 0, W7HairlineAlpha, W7HairlineAlpha, 0 };
    const CGFloat locations[4] = { 0.08, 0.45, 0.70, 1.0 };
    CGGradientRef g = W7WallpaperGradient(hexes, alphas, locations, 4);
    CGContextDrawLinearGradient(ctx, g, e0, e3, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGContextRestoreGState(ctx);
}

void W7DrawWallpaper(CGContextRef ctx, CGRect rect) {
    if (rect.size.width <= 0 || rect.size.height <= 0) return;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);

    // Base: deep blue, brightest at 60% down.
    const uint32_t base[3] = { 0x0B3D91, 0x1A64C8, 0x0E4FA8 };
    const CGFloat opaque[3] = { 1, 1, 1 };
    const CGFloat stops[3] = { 0, 0.6, 1 };
    CGGradientRef g = W7WallpaperGradient(base, opaque, stops, 3);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(rect)), CGPointMake(0, CGRectGetMinY(rect)),
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);

    // A large soft brightening just left of and above the centre.
    W7WallpaperGlow(ctx, W7WallpaperPoint(rect, 0.52, 0.46), 0.65 * rect.size.width, 0x3D8BEA, 0.55);

    for (size_t i = 0; i < sizeof W7Ribbons / sizeof W7Ribbons[0]; i++) W7DrawRibbon(ctx, rect, &W7Ribbons[i]);

    // A subtle bloom where the ribbons converge.
    W7WallpaperGlow(ctx, W7WallpaperPoint(rect, 0.62, 0.40), 0.25 * rect.size.width, 0xFFFFFF, 0.18);

    CGContextRestoreGState(ctx);
}
