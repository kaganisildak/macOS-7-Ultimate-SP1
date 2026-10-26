#import "Win7Theme.h"

// Procedural Windows 7 Aero cursors: white shapes with a 1 px black outline and a soft drop
// shadow. Every shape is laid out on a 32 × 32 grid with a TOP-LEFT origin (as cursor hot spots are),
// and W7DrawCursor maps that grid onto the target rect of a non-flipped context.

const NSInteger W7CursorKindCount = W7CursorHelp + 1;
const CGFloat W7CursorSize = 32;
const NSInteger W7CursorBusyFrameCount = 18;

static CGColorSpaceRef W7CursorSRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7CursorColor(uint32_t hex, CGFloat a) {
    W7RGBA c = W7RGBAFromHex(hex, a);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7CursorSRGB(), v));
}

NSString *W7CursorKindName(W7CursorKind kind) {
    switch (kind) {
        case W7CursorArrow: return @"arrow";
        case W7CursorIBeam: return @"ibeam";
        case W7CursorHand: return @"hand";
        case W7CursorBusy: return @"busy";
        case W7CursorWorking: return @"working";
        case W7CursorResizeEW: return @"resize-ew";
        case W7CursorResizeNS: return @"resize-ns";
        case W7CursorResizeNWSE: return @"resize-nwse";
        case W7CursorResizeNESW: return @"resize-nesw";
        case W7CursorMove: return @"move";
        case W7CursorNotAllowed: return @"unavailable";
        case W7CursorCrosshair: return @"crosshair";
        case W7CursorHelp: return @"help";
    }
    return @"arrow";
}

CGPoint W7CursorHotSpot(W7CursorKind kind) {
    switch (kind) {
        case W7CursorArrow: case W7CursorWorking: case W7CursorHelp: return CGPointMake(1, 1);
        case W7CursorHand: return CGPointMake(10, 1);
        default: return CGPointMake(16, 16);
    }
}

#pragma mark - Shapes (top-left grid)

static CGPathRef W7Polygon(const CGPoint *pts, size_t n) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddLines(p, NULL, pts, n);
    CGPathCloseSubpath(p);
    return (CGPathRef)CFAutorelease(p);
}

static CGPathRef W7Union(CGPathRef a, CGPathRef b) {
    return (CGPathRef)CFAutorelease(CGPathCreateCopyByUnioningPath(a, b, false));
}

static CGPathRef W7Transformed(CGPathRef p, CGAffineTransform t) {
    return (CGPathRef)CFAutorelease(CGPathCreateCopyByTransformingPath(p, &t));
}

/// The Aero arrow (aero_arrow): tip at (1, 1), a straight left edge, the tail leaning down to the right.
static CGPathRef W7ArrowPath(void) {
    const CGPoint pts[] = { {1, 1}, {1, 18}, {5, 14}, {8, 21}, {10.6, 20}, {7.7, 13.2}, {13, 13} };
    return W7Polygon(pts, sizeof pts / sizeof pts[0]);
}

static CGPathRef W7IBeamPath(void) {
    const CGPoint pts[] = { {12, 5}, {20, 5}, {20, 7}, {17, 7}, {17, 25}, {20, 25}, {20, 27}, {12, 27}, {12, 25},
                            {15, 25}, {15, 7}, {12, 7} };
    return W7Polygon(pts, sizeof pts / sizeof pts[0]);
}

/// The link-select hand: index finger raised (tip at (10, 1)), three folded fingers, the thumb at left.
static CGPathRef W7HandPath(void) {
    CGPathRef shape = (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(CGRectMake(8, 1, 4, 15), 2, 2, NULL));
    const CGRect fingers[] = { {{12, 8}, {4, 9}}, {{16, 9}, {4, 8}}, {{20, 10}, {3.5, 7}} };
    for (size_t i = 0; i < 3; i++) {
        CGFloat r = fingers[i].size.width / 2;
        shape = W7Union(shape, (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(fingers[i], r, r, NULL)));
    }
    shape = W7Union(shape, (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(CGRectMake(8, 12, 15.5, 11), 3, 3, NULL)));
    const CGPoint thumb[] = { {8.5, 16.5}, {5.2, 13.3}, {3.4, 14.2}, {3.4, 16.4}, {9, 22.5} };
    shape = W7Union(shape, W7Polygon(thumb, sizeof thumb / sizeof thumb[0]));
    return W7Union(shape, (CGPathRef)CFAutorelease(CGPathCreateWithRect(CGRectMake(10, 22, 12, 4), NULL)));
}

/// A horizontal double-headed arrow through (16, 16), rotated by `degrees` about the centre.
static CGPathRef W7DoubleArrowPath(CGFloat degrees) {
    const CGPoint pts[] = { {5, 16}, {10, 11}, {10, 15}, {22, 15}, {22, 11}, {27, 16}, {22, 21}, {22, 17}, {10, 17}, {10, 21} };
    CGPathRef p = W7Polygon(pts, sizeof pts / sizeof pts[0]);
    if (degrees == 0) return p;
    CGAffineTransform t = CGAffineTransformMakeTranslation(16, 16);
    t = CGAffineTransformRotate(t, degrees * M_PI / 180);
    t = CGAffineTransformTranslate(t, -16, -16);
    return W7Transformed(p, t);
}

/// The four-headed move arrow through (16, 16), as one outline.
static CGPathRef W7MovePath(void) {
    const CGPoint pts[] = { {4, 16}, {9, 12}, {9, 15}, {15, 15}, {15, 9}, {12, 9}, {16, 4}, {20, 9}, {17, 9}, {17, 15},
                            {23, 15}, {23, 12}, {28, 16}, {23, 20}, {23, 17}, {17, 17}, {17, 23}, {20, 23}, {16, 28},
                            {12, 23}, {15, 23}, {15, 17}, {9, 17}, {9, 20} };
    return W7Polygon(pts, sizeof pts / sizeof pts[0]);
}

static CGPathRef W7NotAllowedPath(void) {
    CGMutablePathRef ring = CGPathCreateMutable();
    CGPathAddEllipseInRect(ring, NULL, CGRectMake(7, 7, 18, 18));
    CGPathAddEllipseInRect(ring, NULL, CGRectMake(10, 10, 12, 12));
    CGPathRef annulus = (CGPathRef)CFAutorelease(CGPathCreateCopyByUnioningPath(ring, ring, true));
    CGPathRelease(ring);
    CGAffineTransform t = CGAffineTransformMakeTranslation(16, 16);
    t = CGAffineTransformRotate(t, M_PI / 4);
    CGPathRef bar = (CGPathRef)CFAutorelease(CGPathCreateWithRect(CGRectMake(-7.5, -1.5, 15, 3), &t));
    return W7Union(annulus, bar);
}

static CGPathRef W7CrosshairPath(void) {
    return W7Union((CGPathRef)CFAutorelease(CGPathCreateWithRect(CGRectMake(5, 15, 22, 2), NULL)),
                   (CGPathRef)CFAutorelease(CGPathCreateWithRect(CGRectMake(15, 5, 2, 22), NULL)));
}

/// The "?" of the help cursor, an open path stroked as a glyph, right of the arrow.
static CGPathRef W7QuestionPath(void) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddArc(p, NULL, 19, 10, 3.5, M_PI, M_PI * 2.35, false);
    CGPathAddLineToPoint(p, NULL, 19, 15.5);
    CGPathAddLineToPoint(p, NULL, 19, 16.5);
    return (CGPathRef)CFAutorelease(p);
}

#pragma mark - Painting

/// Device pixels per grid unit, for the shadow (its offset and blur ignore the CTM).
static CGFloat W7DeviceUnit(CGContextRef ctx) {
    CGSize s = CGContextConvertSizeToDeviceSpace(ctx, CGSizeMake(1, 1));
    return MAX(fabs(s.width), 0.01);
}

static void W7BeginShadowed(CGContextRef ctx) {
    CGFloat u = W7DeviceUnit(ctx);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(1 * u, -1.5 * u), 2 * u, W7CursorColor(0x000000, 0.45));
    CGContextBeginTransparencyLayer(ctx, NULL);
}

static void W7EndShadowed(CGContextRef ctx) {
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

/// A white shape with a 1 px black outline outside it: a 2 px stroke centred on the edge, then the fill.
static void W7OutlinedShape(CGContextRef ctx, CGPathRef path) {
    CGContextSetLineJoin(ctx, kCGLineJoinMiter);
    CGContextSetMiterLimit(ctx, 3);
    CGContextSetLineWidth(ctx, 2);
    CGContextSetStrokeColorWithColor(ctx, W7CursorColor(0x000000, 1));
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGContextSetFillColorWithColor(ctx, W7CursorColor(0xFFFFFF, 1));
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
}

/// The busy ring: a pale track with a bright blue segment that turns one step per frame.
static void W7BusyRing(CGContextRef ctx, CGPoint c, CGFloat radius, CGFloat width, NSInteger frame) {
    CGFloat inner = radius - width / 2, outer = radius + width / 2;
    CGContextSetLineWidth(ctx, 1);
    CGContextSetStrokeColorWithColor(ctx, W7CursorColor(0x1B3F66, 0.85));
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - outer - 0.5, c.y - outer - 0.5, 2 * outer + 1, 2 * outer + 1));
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - inner + 0.5, c.y - inner + 0.5, 2 * inner - 1, 2 * inner - 1));
    CGContextStrokePath(ctx);
    CGContextSetLineWidth(ctx, width);
    CGContextSetStrokeColorWithColor(ctx, W7CursorColor(0xD6E6F5, 1));
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - radius, c.y - radius, 2 * radius, 2 * radius));
    CGContextStrokePath(ctx);
    // Top-left grid: angles grow clockwise on screen. The head is lighter than the tail.
    NSInteger f = ((frame % W7CursorBusyFrameCount) + W7CursorBusyFrameCount) % W7CursorBusyFrameCount;
    CGFloat start = -M_PI / 2 + f * (2 * M_PI / W7CursorBusyFrameCount);
    CGContextSetLineCap(ctx, kCGLineCapButt);
    CGContextSetStrokeColorWithColor(ctx, W7CursorColor(0x2F7FD6, 1));
    CGContextAddArc(ctx, c.x, c.y, radius, start, start + M_PI * 0.55, false);
    CGContextStrokePath(ctx);
    CGContextSetStrokeColorWithColor(ctx, W7CursorColor(0x8ED4FF, 1));
    CGContextAddArc(ctx, c.x, c.y, radius, start + M_PI * 0.55, start + M_PI * 0.75, false);
    CGContextStrokePath(ctx);
}

void W7DrawCursor(CGContextRef ctx, CGRect rect, W7CursorKind kind, NSInteger frame) {
    if (rect.size.width <= 0 || rect.size.height <= 0) return;
    CGContextSaveGState(ctx);
    // Top-left 32-unit grid onto `rect`.
    CGContextTranslateCTM(ctx, rect.origin.x, CGRectGetMaxY(rect));
    CGContextScaleCTM(ctx, rect.size.width / W7CursorSize, -rect.size.height / W7CursorSize);
    W7BeginShadowed(ctx);
    switch (kind) {
        case W7CursorArrow: W7OutlinedShape(ctx, W7ArrowPath()); break;
        case W7CursorIBeam: W7OutlinedShape(ctx, W7IBeamPath()); break;
        case W7CursorHand: {
            W7OutlinedShape(ctx, W7HandPath());
            // The gaps between the folded fingers.
            CGContextSetLineWidth(ctx, 1);
            CGContextSetStrokeColorWithColor(ctx, W7CursorColor(0x000000, 1));
            const CGFloat gaps[][3] = { {12, 9.5, 14}, {16, 10.5, 14.5}, {20, 11.5, 15} };
            for (int i = 0; i < 3; i++) {
                CGContextMoveToPoint(ctx, gaps[i][0], gaps[i][1]);
                CGContextAddLineToPoint(ctx, gaps[i][0], gaps[i][2]);
            }
            CGContextStrokePath(ctx);
            break;
        }
        case W7CursorBusy: W7BusyRing(ctx, CGPointMake(16, 16), 8, 4, frame); break;
        case W7CursorWorking:
            W7OutlinedShape(ctx, W7ArrowPath());
            W7BusyRing(ctx, CGPointMake(20, 23), 5, 3, frame);
            break;
        case W7CursorResizeEW: W7OutlinedShape(ctx, W7DoubleArrowPath(0)); break;
        case W7CursorResizeNS: W7OutlinedShape(ctx, W7DoubleArrowPath(90)); break;
        case W7CursorResizeNWSE: W7OutlinedShape(ctx, W7DoubleArrowPath(45)); break;
        case W7CursorResizeNESW: W7OutlinedShape(ctx, W7DoubleArrowPath(-45)); break;
        case W7CursorMove: W7OutlinedShape(ctx, W7MovePath()); break;
        case W7CursorNotAllowed: W7OutlinedShape(ctx, W7NotAllowedPath()); break;
        case W7CursorCrosshair: W7OutlinedShape(ctx, W7CrosshairPath()); break;
        case W7CursorHelp: {
            W7OutlinedShape(ctx, W7ArrowPath());
            CGContextSetLineCap(ctx, kCGLineCapRound);
            CGContextSetLineJoin(ctx, kCGLineJoinRound);
            for (int pass = 0; pass < 2; pass++) {
                CGContextSetLineWidth(ctx, pass == 0 ? 4.2 : 2.2);
                CGContextSetStrokeColorWithColor(ctx, W7CursorColor(pass == 0 ? 0x000000 : 0xFFFFFF, 1));
                CGContextAddPath(ctx, W7QuestionPath());
                CGContextStrokePath(ctx);
                CGContextSetFillColorWithColor(ctx, W7CursorColor(pass == 0 ? 0x000000 : 0xFFFFFF, 1));
                CGFloat r = pass == 0 ? 2.1 : 1.1;
                CGContextFillEllipseInRect(ctx, CGRectMake(19 - r, 20 - r, 2 * r, 2 * r));
            }
            break;
        }
    }
    W7EndShadowed(ctx);
    CGContextRestoreGState(ctx);
}

CGImageRef W7CreateCursorImage(W7CursorKind kind, CGFloat scale, NSInteger frame) {
    size_t side = (size_t)llround(W7CursorSize * scale);
    if (scale <= 0 || side == 0) return NULL;
    CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, 0, W7CursorSRGB(), (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (!ctx) return NULL;
    W7DrawCursor(ctx, CGRectMake(0, 0, side, side), kind, frame);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

NSCursor *W7ProceduralCursor(W7CursorKind kind, NSInteger frame) {
    static NSMutableDictionary<NSNumber *, NSCursor *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    BOOL animated = kind == W7CursorBusy || kind == W7CursorWorking;
    NSInteger f = animated ? ((frame % W7CursorBusyFrameCount) + W7CursorBusyFrameCount) % W7CursorBusyFrameCount : 0;
    NSNumber *key = @(kind * 100 + f);
    @synchronized (cache) {
        NSCursor *hit = cache[key];
        if (hit) return hit;
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(W7CursorSize, W7CursorSize)];
        for (CGFloat scale = 1; scale <= 2; scale++) {
            CGImageRef cg = W7CreateCursorImage(kind, scale, f);
            if (!cg) continue;
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
            rep.size = NSMakeSize(W7CursorSize, W7CursorSize);
            [image addRepresentation:rep];
            CGImageRelease(cg);
        }
        CGPoint hot = W7CursorHotSpot(kind);
        NSCursor *cursor = [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(hot.x, hot.y)];
        cache[key] = cursor;
        return cursor;
    }
}
