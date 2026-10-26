#import "Win7Theme.h"

// Procedural Windows 7 notification area icons. Everything is laid out on a 16 x 16 grid
// (bottom-left origin) and scaled to the target rect.

static CGColorSpaceRef W7TraySRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7TrayColor(uint32_t hex, CGFloat a) {
    W7RGBA c = W7RGBAFromHex(hex, a);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7TraySRGB(), v));
}

static const CGFloat W7TrayOutlineAlpha = 0.6;

/// Fills `path` with a dark outline around it: the stroke goes first so the fill covers its inner half.
static void W7TrayOutlinedFill(CGContextRef ctx, CGPathRef path, uint32_t fill, CGFloat alpha) {
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineWidth(ctx, 1.6);
    CGContextSetStrokeColorWithColor(ctx, W7TrayColor(0x000000, W7TrayOutlineAlpha * MAX(alpha, 0.5)));
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGContextSetFillColorWithColor(ctx, W7TrayColor(fill, alpha));
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
}

/// Strokes an open path as a light line with a dark outline.
static void W7TrayOutlinedLine(CGContextRef ctx, CGPathRef path, uint32_t color, CGFloat width) {
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineWidth(ctx, width + 1.4);
    CGContextSetStrokeColorWithColor(ctx, W7TrayColor(0x000000, W7TrayOutlineAlpha));
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGContextSetLineWidth(ctx, width);
    CGContextSetStrokeColorWithColor(ctx, W7TrayColor(color, 1));
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
}

static CGPathRef W7TrayRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat radius) {
    return (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), radius, radius, NULL));
}

static CGPathRef W7TrayOval(CGFloat x, CGFloat y, CGFloat d) {
    return (CGPathRef)CFAutorelease(CGPathCreateWithEllipseInRect(CGRectMake(x, y, d, d), NULL));
}

/// A red disc with a white mark: a cross (`slash` NO) or a diagonal bar (`slash` YES).
static void W7TrayRedBadge(CGContextRef ctx, CGFloat x, CGFloat y, CGFloat d, BOOL slash) {
    W7TrayOutlinedFill(ctx, W7TrayOval(x, y, d), 0xE0261E, 1);
    CGFloat in = d * 0.3;
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineWidth(ctx, 1.2);
    CGContextSetStrokeColorWithColor(ctx, W7TrayColor(0xFFFFFF, 1));
    CGContextMoveToPoint(ctx, x + in, y + d - in);
    CGContextAddLineToPoint(ctx, x + d - in, y + in);
    if (!slash) {
        CGContextMoveToPoint(ctx, x + in, y + in);
        CGContextAddLineToPoint(ctx, x + d - in, y + d - in);
    }
    CGContextStrokePath(ctx);
}

/// A yellow warning triangle with a dark "!" at the bottom left.
static void W7TrayWarning(CGContextRef ctx) {
    CGMutablePathRef t = CGPathCreateMutable();
    CGPathMoveToPoint(t, NULL, 0.8, 0.8);
    CGPathAddLineToPoint(t, NULL, 8.2, 0.8);
    CGPathAddLineToPoint(t, NULL, 4.5, 7.6);
    CGPathCloseSubpath(t);
    W7TrayOutlinedFill(ctx, t, 0xF5C518, 1);
    CGPathRelease(t);
    CGContextSetFillColorWithColor(ctx, W7TrayColor(0x000000, 0.85));
    CGContextFillRect(ctx, CGRectMake(4.0, 3.2, 1.0, 2.8));
    CGContextFillRect(ctx, CGRectMake(4.0, 1.7, 1.0, 1.0));
}

#pragma mark - Icons

static void W7TrayDrawWifi(CGContextRef ctx, NSInteger bars, BOOL warning) {
    // Four ascending bars; lit ones are white, unlit ones a faint ghost.
    for (NSInteger i = 0; i < 4; i++) {
        CGFloat x = 1.5 + 3.5 * i, h = 4 + 3 * i;
        BOOL lit = i < bars;
        W7TrayOutlinedFill(ctx, W7TrayRect(x, 1.5, 3, h, 0.5), 0xFFFFFF, lit ? 1 : 0.28);
    }
    if (warning) W7TrayWarning(ctx);
}

/// The Windows 7 network monitor: a light bezel round a screen, on a small stand.
static void W7TrayDrawMonitor(CGContextRef ctx, BOOL grey) {
    uint32_t bezel = grey ? 0xA8A8A8 : 0xF0F0F0;
    W7TrayOutlinedFill(ctx, W7TrayRect(5.5, 2.2, 6, 1.6, 0.4), bezel, 1);           // foot
    W7TrayOutlinedFill(ctx, W7TrayRect(7.6, 3.6, 1.8, 2.2, 0), bezel, 1);           // neck
    W7TrayOutlinedFill(ctx, W7TrayRect(2.5, 5.5, 12, 9, 1), bezel, 1);              // bezel
    CGRect screen = CGRectMake(3.8, 6.8, 9.4, 6.4);
    if (grey) {
        CGContextSetFillColorWithColor(ctx, W7TrayColor(0x6E6E6E, 1));
        CGContextFillRect(ctx, screen);
        return;
    }
    CGColorRef cols[2] = { W7TrayColor(0x8FD0FF, 1), W7TrayColor(0x2468C8, 1) };
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7TraySRGB(), arr, NULL);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, screen);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(screen)), CGPointMake(0, CGRectGetMinY(screen)), 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(g);
    CFRelease(arr);
}

static void W7TrayDrawWired(CGContextRef ctx, BOOL warning) {
    W7TrayDrawMonitor(ctx, NO);
    // The cable runs from the monitor's foot to the left edge, ending in a plug.
    CGMutablePathRef cable = CGPathCreateMutable();
    CGPathMoveToPoint(cable, NULL, 5.5, 3.0);
    CGPathAddLineToPoint(cable, NULL, 2.6, 3.0);
    CGPathAddLineToPoint(cable, NULL, 2.6, 1.2);
    W7TrayOutlinedLine(ctx, cable, 0xF0F0F0, 1.1);
    CGPathRelease(cable);
    if (warning) W7TrayWarning(ctx);
}

static void W7TrayDrawDisconnected(CGContextRef ctx) {
    W7TrayDrawMonitor(ctx, NO);
    W7TrayRedBadge(ctx, 0.6, 0.6, 7.4, NO);
}

static void W7TrayDrawNoNetwork(CGContextRef ctx) {
    W7TrayDrawMonitor(ctx, YES);
}

static void W7TrayDrawVolume(CGContextRef ctx, NSInteger level) {
    // Speaker: a box with a flared cone, facing right.
    CGMutablePathRef sp = CGPathCreateMutable();
    CGPathMoveToPoint(sp, NULL, 1.5, 5.5);
    CGPathAddLineToPoint(sp, NULL, 4.2, 5.5);
    CGPathAddLineToPoint(sp, NULL, 7.8, 2.2);
    CGPathAddLineToPoint(sp, NULL, 7.8, 13.8);
    CGPathAddLineToPoint(sp, NULL, 4.2, 10.5);
    CGPathAddLineToPoint(sp, NULL, 1.5, 10.5);
    CGPathCloseSubpath(sp);
    W7TrayOutlinedFill(ctx, sp, 0xF0F0F0, 1);
    CGPathRelease(sp);
    if (level <= 0) {
        W7TrayRedBadge(ctx, 8.4, 0.8, 7.0, YES);
        return;
    }
    // Sound waves: level 1 (silent) none, 2 one, 3 two, 4 three.
    for (NSInteger i = 0; i < level - 1 && i < 3; i++) {
        CGFloat r = 2.4 + 2.2 * i;
        CGMutablePathRef arc = CGPathCreateMutable();
        CGPathAddArc(arc, NULL, 8.4, 8, r, -M_PI / 3.2, M_PI / 3.2, false);
        W7TrayOutlinedLine(ctx, arc, 0xFFFFFF, 1.1);
        CGPathRelease(arc);
    }
}

static void W7TrayDrawBattery(CGContextRef ctx, NSInteger level, BOOL pluggedIn) {
    // A horizontal cell with its terminal on the right, filled left to right.
    W7TrayOutlinedFill(ctx, W7TrayRect(13.6, 6.5, 1.6, 3, 0.3), 0xD8D8D8, 1);       // terminal
    W7TrayOutlinedFill(ctx, W7TrayRect(1.2, 4.2, 12.6, 7.6, 1), 0x3A3A3A, 0.9);     // body
    CGFloat fractions[5] = { 0.12, 0.3, 0.55, 0.78, 1.0 };
    CGFloat f = fractions[MAX(0, MIN(4, level))];
    uint32_t fill = level <= 0 ? 0xE0261E : (level == 1 ? 0xF5C518 : 0x5CCF4E);
    CGRect inner = CGRectMake(2.4, 5.4, 10.2 * f, 5.2);
    CGContextSetFillColorWithColor(ctx, W7TrayColor(fill, 1));
    CGContextFillRect(ctx, inner);
    CGContextSetFillColorWithColor(ctx, W7TrayColor(0xFFFFFF, 0.35));                // gloss
    CGContextFillRect(ctx, CGRectMake(inner.origin.x, 8.4, inner.size.width, 2.2));
    if (pluggedIn) {
        // A lightning bolt across the cell.
        CGMutablePathRef bolt = CGPathCreateMutable();
        CGPathMoveToPoint(bolt, NULL, 8.6, 13.4);
        CGPathAddLineToPoint(bolt, NULL, 4.6, 7.6);
        CGPathAddLineToPoint(bolt, NULL, 7.4, 7.6);
        CGPathAddLineToPoint(bolt, NULL, 6.0, 2.6);
        CGPathAddLineToPoint(bolt, NULL, 10.4, 9.0);
        CGPathAddLineToPoint(bolt, NULL, 7.6, 9.0);
        CGPathCloseSubpath(bolt);
        W7TrayOutlinedFill(ctx, bolt, 0xFFFFFF, 1);
        CGPathRelease(bolt);
    }
}

static void W7TrayDrawChevron(CGContextRef ctx) {
    CGMutablePathRef t = CGPathCreateMutable();
    CGPathMoveToPoint(t, NULL, 3.5, 5.5);
    CGPathAddLineToPoint(t, NULL, 12.5, 5.5);
    CGPathAddLineToPoint(t, NULL, 8, 10.5);
    CGPathCloseSubpath(t);
    W7TrayOutlinedFill(ctx, t, 0xFFFFFF, 1);
    CGPathRelease(t);
}

void W7DrawTrayIcon(CGContextRef ctx, CGRect rect, W7TrayIcon kind, NSInteger level, BOOL flag) {
    CGFloat side = MIN(rect.size.width, rect.size.height);
    if (side <= 0) return;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, CGRectGetMidX(rect) - side / 2, CGRectGetMidY(rect) - side / 2);
    CGContextScaleCTM(ctx, side / 16, side / 16);
    switch (kind) {
        case W7TrayIconWifi: W7TrayDrawWifi(ctx, level, flag); break;
        case W7TrayIconWired: W7TrayDrawWired(ctx, flag); break;
        case W7TrayIconDisconnected: W7TrayDrawDisconnected(ctx); break;
        case W7TrayIconNoNetwork: W7TrayDrawNoNetwork(ctx); break;
        case W7TrayIconVolume: W7TrayDrawVolume(ctx, level); break;
        case W7TrayIconBattery: W7TrayDrawBattery(ctx, level, flag); break;
        case W7TrayIconChevron: W7TrayDrawChevron(ctx); break;
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Action Center flag and signal bars

static void W7TrayDrawActionCenterFlag(CGContextRef ctx, BOOL hasMessages) {
    CGMutablePathRef pole = CGPathCreateMutable();
    CGPathMoveToPoint(pole, NULL, 3.4, 1.2);
    CGPathAddLineToPoint(pole, NULL, 3.4, 14.8);
    W7TrayOutlinedLine(ctx, pole, 0xF0F0F0, 1.2);
    CGPathRelease(pole);
    // The cloth flies right of the pole with a gentle wave along its top and bottom edges.
    CGMutablePathRef cloth = CGPathCreateMutable();
    CGPathMoveToPoint(cloth, NULL, 4.0, 14.2);
    CGPathAddCurveToPoint(cloth, NULL, 7.0, 15.4, 10.0, 12.4, 13.6, 13.6);
    CGPathAddLineToPoint(cloth, NULL, 13.6, 7.8);
    CGPathAddCurveToPoint(cloth, NULL, 10.0, 6.6, 7.0, 9.6, 4.0, 8.4);
    CGPathCloseSubpath(cloth);
    W7TrayOutlinedFill(ctx, cloth, 0xFFFFFF, 1);
    CGPathRelease(cloth);
    if (hasMessages) W7TrayRedBadge(ctx, 8.4, 0.6, 7.0, NO);
}

void W7DrawActionCenterFlag(CGContextRef ctx, CGRect rect, BOOL hasMessages) {
    CGFloat side = MIN(rect.size.width, rect.size.height);
    if (side <= 0) return;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, CGRectGetMidX(rect) - side / 2, CGRectGetMidY(rect) - side / 2);
    CGContextScaleCTM(ctx, side / 16, side / 16);
    W7TrayDrawActionCenterFlag(ctx, hasMessages);
    CGContextRestoreGState(ctx);
}

void W7DrawSignalBars(CGContextRef ctx, CGRect rect, NSInteger bars) {
    if (rect.size.width <= 0 || rect.size.height <= 0) return;
    const NSInteger count = 5;
    CGFloat step = rect.size.width / count;
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    for (NSInteger i = 0; i < count; i++) {
        CGFloat h = rect.size.height * (0.2 + 0.2 * i);
        CGRect bar = CGRectMake(rect.origin.x + step * i + 0.5, rect.origin.y + 0.5, step - 1, h - 1);
        BOOL lit = i < bars;
        if (lit) {
            CGColorRef cols[2] = { W7TrayColor(0x9AE66A, 1), W7TrayColor(0x2E9B1E, 1) };
            CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
            CGGradientRef g = CGGradientCreateWithColors(W7TraySRGB(), arr, NULL);
            CGContextSaveGState(ctx);
            CGContextClipToRect(ctx, bar);
            CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(bar)), CGPointMake(0, CGRectGetMinY(bar)),
                                        kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
            CGContextRestoreGState(ctx);
            CGGradientRelease(g);
            CFRelease(arr);
            CGContextSetStrokeColorWithColor(ctx, W7TrayColor(0x1F6A14, 1));
        } else {
            CGContextSetFillColorWithColor(ctx, W7TrayColor(0xDADADA, 1));
            CGContextFillRect(ctx, bar);
            CGContextSetStrokeColorWithColor(ctx, W7TrayColor(0x9A9A9A, 1));
        }
        CGContextStrokeRect(ctx, bar);
    }
    CGContextRestoreGState(ctx);
}
