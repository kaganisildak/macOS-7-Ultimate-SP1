#import "Win7Theme.h"

// Procedural Windows 7 desktop gadget art: the analog clock, the CPU Meter dials and the
// gadget hover toolbar. Non-flipped contexts (bottom-left origin); angles are degrees clockwise from 12.

static CGColorSpaceRef W7GadgetSRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7GadgetColor(uint32_t hex, CGFloat a) {
    W7RGBA c = W7RGBAFromHex(hex, a);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7GadgetSRGB(), v));
}

static CGGradientRef W7GadgetGradient(uint32_t a, CGFloat aa, uint32_t b, CGFloat ba) {
    CGColorRef cols[2] = { W7GadgetColor(a, aa), W7GadgetColor(b, ba) };
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7GadgetSRGB(), arr, NULL);
    CFRelease(arr);
    return (CGGradientRef)CFAutorelease(g);
}

/// The point `length` from `c` at `degrees` clockwise from 12 o'clock.
static CGPoint W7Polar(CGPoint c, CGFloat degrees, CGFloat length) {
    CGFloat r = degrees * M_PI / 180;
    return CGPointMake(c.x + sin(r) * length, c.y + cos(r) * length);
}

static void W7Hand(CGContextRef ctx, CGPoint c, CGFloat degrees, CGFloat length, CGFloat tail, CGFloat width, uint32_t hex) {
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineWidth(ctx, width);
    CGContextSetStrokeColorWithColor(ctx, W7GadgetColor(hex, 1));
    CGPoint from = W7Polar(c, degrees + 180, tail), to = W7Polar(c, degrees, length);
    CGContextMoveToPoint(ctx, from.x, from.y);
    CGContextAddLineToPoint(ctx, to.x, to.y);
    CGContextStrokePath(ctx);
}

void W7DrawGadgetClock(CGContextRef ctx, CGRect rect, CGFloat hourDegrees, CGFloat minuteDegrees, CGFloat secondDegrees) {
    CGFloat side = MIN(rect.size.width, rect.size.height);
    if (side <= 0) return;
    CGPoint c = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat R = side / 2;
    CGContextSaveGState(ctx);
    // Soft shadow, then the chrome rim.
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 3, W7GadgetColor(0x000000, 0.45));
    CGContextSetFillColorWithColor(ctx, W7GadgetColor(0x8C99A6, 1));
    CGContextFillEllipseInRect(ctx, CGRectMake(c.x - R + 2, c.y - R + 2, 2 * R - 4, 2 * R - 4));
    CGContextRestoreGState(ctx);
    CGFloat rim = R - 2;
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - rim, c.y - rim, 2 * rim, 2 * rim));
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, W7GadgetGradient(0xF4F7FA, 1, 0x7D8995, 1), CGPointMake(0, c.y + rim), CGPointMake(0, c.y - rim), 0);
    CGContextRestoreGState(ctx);
    // The face: white to a cool grey at the edge.
    CGFloat face = rim - 5;
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - face, c.y - face, 2 * face, 2 * face));
    CGContextClip(ctx);
    CGContextDrawRadialGradient(ctx, W7GadgetGradient(0xFFFFFF, 1, 0xE3E9EF, 1), CGPointMake(c.x - face * 0.25, c.y + face * 0.3), 0,
                                c, face * 1.1, kCGGradientDrawsAfterEndLocation);
    CGContextRestoreGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    CGContextSetStrokeColorWithColor(ctx, W7GadgetColor(0x5E6A76, 0.8));
    CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - face, c.y - face, 2 * face, 2 * face));
    // Ticks: minutes thin and grey, hours thick and dark.
    CGContextSetLineCap(ctx, kCGLineCapButt);
    for (int i = 0; i < 60; i++) {
        BOOL hour = i % 5 == 0;
        CGPoint a = W7Polar(c, i * 6, face * (hour ? 0.80 : 0.88)), b = W7Polar(c, i * 6, face * 0.95);
        CGContextSetLineWidth(ctx, hour ? 2.4 : 1);
        CGContextSetStrokeColorWithColor(ctx, W7GadgetColor(hour ? 0x2B2F33 : 0x8A939C, 1));
        CGContextMoveToPoint(ctx, a.x, a.y);
        CGContextAddLineToPoint(ctx, b.x, b.y);
        CGContextStrokePath(ctx);
    }
    // Hands, with a faint shadow; the second hand is red.
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(1, -1), 1.5, W7GadgetColor(0x000000, 0.3));
    W7Hand(ctx, c, hourDegrees, face * 0.50, face * 0.10, 4, 0x1E2226);
    W7Hand(ctx, c, minuteDegrees, face * 0.76, face * 0.10, 3, 0x1E2226);
    W7Hand(ctx, c, secondDegrees, face * 0.86, face * 0.18, 2, 0xD42121);
    CGContextRestoreGState(ctx);
    CGContextSetFillColorWithColor(ctx, W7GadgetColor(0xD42121, 1));
    CGContextFillEllipseInRect(ctx, CGRectMake(c.x - 3.5, c.y - 3.5, 7, 7));
    CGContextSetFillColorWithColor(ctx, W7GadgetColor(0xF2F2F2, 1));
    CGContextFillEllipseInRect(ctx, CGRectMake(c.x - 1.2, c.y - 1.2, 2.4, 2.4));
    // Glass highlight over the top of the face.
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - face * 0.8, c.y + face * 0.05, face * 1.6, face * 0.9));
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, W7GadgetGradient(0xFFFFFF, 0.45, 0xFFFFFF, 0), CGPointMake(0, c.y + face * 0.95),
                                CGPointMake(0, c.y + face * 0.05), 0);
    CGContextRestoreGState(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawGadgetMeterBody(CGContextRef ctx, CGRect rect) {
    CGContextSaveGState(ctx);
    CGPathRef body = (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(CGRectInset(rect, 2, 2), 14, 14, NULL));
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 3, W7GadgetColor(0x000000, 0.5));
    CGContextSetFillColorWithColor(ctx, W7GadgetColor(0xB9C1C9, 1));
    CGContextAddPath(ctx, body);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
    CGContextAddPath(ctx, body);
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, W7GadgetGradient(0xF6F8FA, 1, 0xA4AEB8, 1), CGPointMake(0, CGRectGetMaxY(rect)),
                                CGPointMake(0, CGRectGetMinY(rect)), 0);
    CGContextRestoreGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    CGContextSetStrokeColorWithColor(ctx, W7GadgetColor(0x4F5964, 0.9));
    CGContextAddPath(ctx, (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(CGRectInset(rect, 2.5, 2.5), 13.5, 13.5, NULL)));
    CGContextStrokePath(ctx);
}

void W7DrawGadgetMeterDial(CGContextRef ctx, CGRect rect, CGFloat fraction) {
    CGFloat side = MIN(rect.size.width, rect.size.height);
    if (side <= 0) return;
    CGPoint c = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat R = side / 2 - 1;
    CGContextSaveGState(ctx);
    // Silver bezel, then the black face.
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - R, c.y - R, 2 * R, 2 * R));
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, W7GadgetGradient(0xFAFBFC, 1, 0x69737D, 1), CGPointMake(0, c.y + R), CGPointMake(0, c.y - R), 0);
    CGContextRestoreGState(ctx);
    CGFloat f = R * 0.86;
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - f, c.y - f, 2 * f, 2 * f));
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, W7GadgetGradient(0x3A3F44, 1, 0x0E1012, 1), CGPointMake(0, c.y + f), CGPointMake(0, c.y - f), 0);
    CGContextRestoreGState(ctx);
    // Scale from -135° (0 %) to +135° (100 %): white ticks, the last fifth red.
    for (int i = 0; i <= 20; i++) {
        CGFloat deg = -135 + i * 13.5;
        BOOL major = i % 2 == 0;
        CGPoint a = W7Polar(c, deg, f * (major ? 0.74 : 0.82)), b = W7Polar(c, deg, f * 0.92);
        CGContextSetLineWidth(ctx, major ? 1.6 : 0.8);
        CGContextSetStrokeColorWithColor(ctx, W7GadgetColor(i >= 16 ? 0xFFA040 : 0xF0F4F8, 1));
        CGContextMoveToPoint(ctx, a.x, a.y);
        CGContextAddLineToPoint(ctx, b.x, b.y);
        CGContextStrokePath(ctx);
    }
    CGFloat clamped = MIN(MAX(fraction, 0), 1);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeZero, 2, W7GadgetColor(0xFF2A10, 0.6));
    W7Hand(ctx, c, -135 + clamped * 270, f * 0.80, f * 0.12, MAX(1.6, side / 36), 0xF0321E);
    CGContextRestoreGState(ctx);
    CGContextSetFillColorWithColor(ctx, W7GadgetColor(0xC8CED4, 1));
    CGContextFillEllipseInRect(ctx, CGRectMake(c.x - side / 16, c.y - side / 16, side / 8, side / 8));
    // Glass over the upper half.
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - f * 0.85, c.y, f * 1.7, f * 0.95));
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, W7GadgetGradient(0xFFFFFF, 0.28, 0xFFFFFF, 0), CGPointMake(0, c.y + f), CGPointMake(0, c.y), 0);
    CGContextRestoreGState(ctx);
    CGContextRestoreGState(ctx);
}

CGRect W7GadgetToolbarButtonRect(CGRect toolbar, NSInteger index) {
    return CGRectMake(CGRectGetMinX(toolbar) + 1, CGRectGetMaxY(toolbar) - 1 - 16 - index * 18, 16, 16);
}

void W7DrawGadgetToolbar(CGContextRef ctx, CGRect rect, NSInteger hoverIndex) {
    W7DrawGadgetToolbarWithOptions(ctx, rect, hoverIndex, NO);
}

void W7DrawGadgetToolbarWithOptions(CGContextRef ctx, CGRect rect, NSInteger hoverIndex, BOOL optionsEnabled) {
    CGContextSaveGState(ctx);
    for (NSInteger i = 0; i < 2; i++) {
        CGRect r = W7GadgetToolbarButtonRect(rect, i);
        BOOL enabled = i == 0 || optionsEnabled;
        BOOL hover = enabled && hoverIndex == i;
        CGContextSaveGState(ctx);
        if (!enabled) CGContextSetAlpha(ctx, 0.4);
        CGPathRef box = (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(CGRectInset(r, 0.5, 0.5), 3, 3, NULL));
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, box);
        CGContextClip(ctx);
        if (hover && i == 0) {
            CGContextDrawLinearGradient(ctx, W7GadgetGradient(0xF2A797, 1, 0xC74040, 1), CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 0);
        } else if (hover) {
            CGContextDrawLinearGradient(ctx, W7GadgetGradient(0xBCE1FA, 1, 0x4AA2DE, 1), CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 0);
        } else {
            CGContextDrawLinearGradient(ctx, W7GadgetGradient(0x5E7C99, 0.95, 0x22354A, 0.95), CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 0);
        }
        CGContextRestoreGState(ctx);
        CGContextSetLineWidth(ctx, 1);
        CGContextSetStrokeColorWithColor(ctx, W7GadgetColor(0x000000, 0.55));
        CGContextAddPath(ctx, box);
        CGContextStrokePath(ctx);
        CGContextSetStrokeColorWithColor(ctx, W7GadgetColor(0xFFFFFF, 0.35));
        CGContextAddPath(ctx, (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(CGRectInset(r, 1.5, 1.5), 2, 2, NULL)));
        CGContextStrokePath(ctx);
        CGFloat cx = CGRectGetMidX(r), cy = CGRectGetMidY(r);
        CGContextSetStrokeColorWithColor(ctx, W7GadgetColor(0xFFFFFF, 1));
        CGContextSetLineCap(ctx, kCGLineCapRound);
        if (i == 0) {   // ×
            CGContextSetLineWidth(ctx, 1.8);
            CGContextMoveToPoint(ctx, cx - 3.5, cy - 3.5); CGContextAddLineToPoint(ctx, cx + 3.5, cy + 3.5);
            CGContextMoveToPoint(ctx, cx - 3.5, cy + 3.5); CGContextAddLineToPoint(ctx, cx + 3.5, cy - 3.5);
            CGContextStrokePath(ctx);
        } else {        // a small gear: ring with teeth
            CGContextSetLineWidth(ctx, 1.6);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - 3, cy - 3, 6, 6));
            for (int t = 0; t < 8; t++) {
                CGPoint a = W7Polar(CGPointMake(cx, cy), t * 45, 3.6), b = W7Polar(CGPointMake(cx, cy), t * 45, 5.4);
                CGContextMoveToPoint(ctx, a.x, a.y); CGContextAddLineToPoint(ctx, b.x, b.y);
            }
            CGContextStrokePath(ctx);
        }
        CGContextRestoreGState(ctx);
    }
    // Drag grip: two columns of dots under the buttons.
    CGRect below = W7GadgetToolbarButtonRect(rect, 1);
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 2; col++) {
            CGFloat x = CGRectGetMidX(rect) - 2.5 + col * 4, y = CGRectGetMinY(below) - 6 - row * 4;
            if (y < CGRectGetMinY(rect) + 1) continue;
            CGContextSetFillColorWithColor(ctx, W7GadgetColor(0x000000, 0.45));
            CGContextFillRect(ctx, CGRectMake(x, y - 1, 2, 2));
            CGContextSetFillColorWithColor(ctx, W7GadgetColor(0xFFFFFF, 0.9));
            CGContextFillRect(ctx, CGRectMake(x - 1, y, 2, 2));
        }
    }
    CGContextRestoreGState(ctx);
}
