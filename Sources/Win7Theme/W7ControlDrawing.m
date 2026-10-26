// Windows 7 Aero standard controls: push buttons, check boxes, radio buttons, scroll bars.
// Every function draws into a non-flipped (bottom-left origin) context.
#import "Win7Theme.h"
#import <os/lock.h>

const CGFloat W7CheckBoxSize = 13;

static CGColorSpaceRef W7CtlRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

/// Colours and gradients are a fixed palette: each is created once and kept for the process (these run on
/// every control draw).
static os_unfair_lock gCtlCacheLock = OS_UNFAIR_LOCK_INIT;

static CGColorRef W7CtlColor(uint32_t hex, CGFloat a) {
    static CFMutableDictionaryRef cache;   // (hex << 8 | alpha byte) -> CGColor
    uintptr_t key = ((uintptr_t)hex << 8) | (uintptr_t)lround(a * 255);
    os_unfair_lock_lock(&gCtlCacheLock);
    if (!cache) cache = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    CGColorRef colour = (CGColorRef)CFDictionaryGetValue(cache, (const void *)key);
    if (!colour) {
        W7RGBA c = W7RGBAFromHex(hex, a);
        CGFloat v[4] = { c.r, c.g, c.b, c.a };
        colour = CGColorCreate(W7CtlRGB(), v);
        CFDictionarySetValue(cache, (const void *)key, colour);
        CGColorRelease(colour);   // the dictionary keeps it
    }
    os_unfair_lock_unlock(&gCtlCacheLock);
    return colour;
}

/// The two-stop gradient from `a` to `b`, created once per pair.
static CGGradientRef W7CtlGradientRef(uint32_t a, uint32_t b) {
    static CFMutableDictionaryRef cache;   // (a << 24 | b) -> CGGradient
    uintptr_t key = ((uintptr_t)a << 24) | b;
    CGColorRef cols[2] = { W7CtlColor(a, 1), W7CtlColor(b, 1) };
    os_unfair_lock_lock(&gCtlCacheLock);
    if (!cache) cache = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    CGGradientRef g = (CGGradientRef)CFDictionaryGetValue(cache, (const void *)key);
    if (!g) {
        CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
        g = CGGradientCreateWithColors(W7CtlRGB(), arr, NULL);
        CFRelease(arr);
        CFDictionarySetValue(cache, (const void *)key, g);
        CGGradientRelease(g);
    }
    os_unfair_lock_unlock(&gCtlCacheLock);
    return g;
}

static void W7CtlFill(CGContextRef ctx, uint32_t hex, CGFloat a) { CGContextSetFillColorWithColor(ctx, W7CtlColor(hex, a)); }
static void W7CtlStroke(CGContextRef ctx, uint32_t hex, CGFloat a) { CGContextSetStrokeColorWithColor(ctx, W7CtlColor(hex, a)); }

/// A two-stop linear gradient from `from` to `to`, opaque, clipped to `r` by the caller.
static void W7CtlGradient(CGContextRef ctx, CGPoint from, CGPoint to, uint32_t a, uint32_t b) {
    CGContextDrawLinearGradient(ctx, W7CtlGradientRef(a, b), from, to,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
}

/// Vertical gradient (top colour at maxY) filling `r`.
static void W7CtlFillVertical(CGContextRef ctx, CGRect r, uint32_t top, uint32_t bottom) {
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, r);
    W7CtlGradient(ctx, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), top, bottom);
    CGContextRestoreGState(ctx);
}

static CGPathRef W7CtlRounded(CGRect r, CGFloat radius) {
    radius = MAX(0, MIN(radius, MIN(r.size.width, r.size.height) / 2));
    return (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(r, radius, radius, NULL));
}

static void W7CtlStrokePath(CGContextRef ctx, CGPathRef path, uint32_t hex, CGFloat a) {
    CGContextSetLineWidth(ctx, 1);
    W7CtlStroke(ctx, hex, a);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
}

#pragma mark - Push button

void W7DrawPushButton(CGContextRef ctx, CGRect rect, W7ControlState state, BOOL isDefault) {
    if (rect.size.width < 2 || rect.size.height < 2) return;
    CGContextSaveGState(ctx);
    uint32_t border, top1, top2, bot1, bot2;
    switch (state) {
        case W7StateHover:
            border = 0x3C7FB1; top1 = 0xEAF6FD; top2 = 0xD9F0FC; bot1 = 0xBEE6FD; bot2 = 0xA7D9F5; break;
        case W7StatePressed:
            border = 0x2C628B; top1 = 0xE5F4FC; top2 = 0xC4E5F6; bot1 = 0x98D1EF; bot2 = 0x68B3DB; break;
        case W7StateDisabled:
            border = 0xADB2B5; top1 = top2 = bot1 = bot2 = 0xF4F4F4; break;
        default:
            border = isDefault ? 0x3C7FB1 : 0x707070; top1 = 0xF2F2F2; top2 = 0xEBEBEB; bot1 = 0xDDDDDD; bot2 = 0xCFCFCF; break;
    }
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, W7CtlRounded(rect, 3));
    CGContextClip(ctx);
    CGFloat mid = CGRectGetMidY(rect);
    W7CtlFillVertical(ctx, CGRectMake(rect.origin.x, mid, rect.size.width, CGRectGetMaxY(rect) - mid), top1, top2);
    W7CtlFillVertical(ctx, CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, mid - rect.origin.y), bot1, bot2);
    CGContextRestoreGState(ctx);

    CGPathRef inner = W7CtlRounded(CGRectInset(rect, 1.5, 1.5), 2);
    if (state == W7StateNormal && isDefault) W7CtlStrokePath(ctx, inner, 0x3399FF, 0.6);
    else if (state == W7StateNormal || state == W7StateHover) W7CtlStrokePath(ctx, inner, 0xFFFFFF, 0.8);
    W7CtlStrokePath(ctx, W7CtlRounded(CGRectInset(rect, 0.5, 0.5), 3), border, 1);
    CGContextRestoreGState(ctx);
}

#pragma mark - Check box and radio button

typedef struct { uint32_t border, wellA, wellB, glyph; } W7CheckColors;

/// Border, well (top-left → bottom-right) and glyph colours shared by check boxes and radio buttons.
static W7CheckColors W7CheckColorsForState(W7ControlState state) {
    switch (state) {
        case W7StateHover: return (W7CheckColors){ 0x3C7FB1, 0xDEF9FA, 0xBFEBFF, 0x4D6185 };
        case W7StatePressed: return (W7CheckColors){ 0x3C7FB1, 0xC2E4F6, 0x9CD6F2, 0x4D6185 };
        case W7StateDisabled: return (W7CheckColors){ 0xB1B1B1, 0xF4F4F4, 0xF4F4F4, 0x8D8D8D };
        default: return (W7CheckColors){ 0x8E8F8F, 0xDFDFDF, 0xFFFFFF, 0x4D6185 };
    }
}

/// The 13×13 box centred in `rect` (the caller usually passes exactly 13×13).
static CGRect W7CheckBox13(CGRect rect) {
    return CGRectMake(CGRectGetMidX(rect) - W7CheckBoxSize / 2, CGRectGetMidY(rect) - W7CheckBoxSize / 2,
                      W7CheckBoxSize, W7CheckBoxSize);
}

/// The well gradient inside the current clip, from the top-left corner of `well` to its bottom-right.
static void W7CheckWell(CGContextRef ctx, CGRect well, W7CheckColors c) {
    W7CtlGradient(ctx, CGPointMake(CGRectGetMinX(well), CGRectGetMaxY(well)),
                  CGPointMake(CGRectGetMaxX(well), CGRectGetMinY(well)), c.wellA, c.wellB);
}

void W7DrawCheckBox(CGContextRef ctx, CGRect rect13, W7ControlState state, W7CheckValue value) {
    CGRect b = W7CheckBox13(rect13);
    W7CheckColors c = W7CheckColorsForState(state);
    CGContextSaveGState(ctx);
    W7CtlFill(ctx, 0xFFFFFF, 1);
    CGContextFillRect(ctx, CGRectInset(b, 1, 1));
    CGRect well = CGRectInset(b, 2, 2);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, well);
    W7CheckWell(ctx, well, c);
    CGContextRestoreGState(ctx);
    W7CtlStrokePath(ctx, (CGPathRef)CFAutorelease(CGPathCreateWithRect(CGRectInset(b, 0.5, 0.5), NULL)), c.border, 1);

    CGFloat x = b.origin.x, y = b.origin.y;
    if (value == W7CheckOn) {
        // The Windows 7 check: from the left, down to the bottom vertex, up to the top right. In the
        // box's top-left-origin pixel grid (as Windows draws it) that is (3,7) → (5.5,9.5) → (10,3.5);
        // here y runs up, so each y is 13 - y.
        CGContextSetLineWidth(ctx, 2);
        CGContextSetLineCap(ctx, kCGLineCapButt);
        CGContextSetLineJoin(ctx, kCGLineJoinMiter);
        W7CtlStroke(ctx, c.glyph, 1);
        CGContextMoveToPoint(ctx, x + 3, y + W7CheckBoxSize - 7);
        CGContextAddLineToPoint(ctx, x + 5.5, y + W7CheckBoxSize - 9.5);
        CGContextAddLineToPoint(ctx, x + 10, y + W7CheckBoxSize - 3.5);
        CGContextStrokePath(ctx);
    } else if (value == W7CheckMixed) {
        W7CtlFill(ctx, c.glyph, 0.85);
        CGContextFillRect(ctx, CGRectMake(x + 3, y + 3, 7, 7));
    }
    CGContextRestoreGState(ctx);
}

void W7DrawRadioButton(CGContextRef ctx, CGRect rect13, W7ControlState state, BOOL selected) {
    CGRect b = W7CheckBox13(rect13);
    W7CheckColors c = W7CheckColorsForState(state);
    CGContextSaveGState(ctx);
    W7CtlFill(ctx, 0xFFFFFF, 1);
    CGContextFillEllipseInRect(ctx, CGRectInset(b, 1, 1));
    CGRect well = CGRectInset(b, 2, 2);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, well);
    CGContextClip(ctx);
    W7CheckWell(ctx, well, c);
    CGContextRestoreGState(ctx);
    W7CtlStroke(ctx, c.border, 1);
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(b, 0.5, 0.5));

    if (selected) {
        CGRect dot = CGRectMake(b.origin.x + 4, b.origin.y + 4, 5, 5);
        CGContextSaveGState(ctx);
        CGContextAddEllipseInRect(ctx, dot);
        CGContextClip(ctx);
        BOOL disabled = state == W7StateDisabled;
        CGGradientRef g = W7CtlGradientRef(disabled ? 0x8D8D8D : 0x2A628F, disabled ? 0xD0D0D0 : 0x8CD1F2);
        CGPoint centre = CGPointMake(CGRectGetMidX(dot), CGRectGetMidY(dot));
        CGContextDrawRadialGradient(ctx, g, centre, 0, centre, 2.5, kCGGradientDrawsAfterEndLocation);
        CGContextRestoreGState(ctx);
        W7CtlStroke(ctx, disabled ? 0x8D8D8D : 0x1D5281, 1);
        CGContextStrokeEllipseInRect(ctx, CGRectInset(dot, 0.5, 0.5));
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Scroll bar

void W7DrawScrollerTrack(CGContextRef ctx, CGRect rect, BOOL vertical) {
    CGContextSaveGState(ctx);
    W7CtlFill(ctx, 0xF0F0F0, 1);
    CGContextFillRect(ctx, rect);
    W7CtlFill(ctx, 0xE3E3E3, 1);
    if (vertical) {
        CGContextFillRect(ctx, CGRectMake(CGRectGetMinX(rect), rect.origin.y, 1, rect.size.height));
        CGContextFillRect(ctx, CGRectMake(CGRectGetMaxX(rect) - 1, rect.origin.y, 1, rect.size.height));
    } else {
        CGContextFillRect(ctx, CGRectMake(rect.origin.x, CGRectGetMinY(rect), rect.size.width, 1));
        CGContextFillRect(ctx, CGRectMake(rect.origin.x, CGRectGetMaxY(rect) - 1, rect.size.width, 1));
    }
    CGContextRestoreGState(ctx);
}

void W7DrawScrollerThumb(CGContextRef ctx, CGRect rect, BOOL vertical, W7ControlState state) {
    CGRect t = vertical ? CGRectInset(rect, 1, 0) : CGRectInset(rect, 0, 1);
    if (t.size.width < 2 || t.size.height < 2) return;
    uint32_t border = 0x979797, a = 0xF3F3F3, b = 0xDBDBDB;
    if (state == W7StateHover) { border = 0x3C7FB1; a = 0xE3F4FC; b = 0xA9DEF6; }
    else if (state == W7StatePressed) { border = 0x3C7FB1; a = 0xCEECF9; b = 0x86C6E8; }
    CGContextSaveGState(ctx);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, W7CtlRounded(t, 2));
    CGContextClip(ctx);
    // Across the short axis: left→right on a vertical thumb, top→bottom on a horizontal one.
    if (vertical) W7CtlGradient(ctx, CGPointMake(CGRectGetMinX(t), 0), CGPointMake(CGRectGetMaxX(t), 0), a, b);
    else W7CtlGradient(ctx, CGPointMake(0, CGRectGetMaxY(t)), CGPointMake(0, CGRectGetMinY(t)), a, b);
    CGContextRestoreGState(ctx);
    W7CtlStrokePath(ctx, W7CtlRounded(CGRectInset(t, 0.5, 0.5), 2), border, 1);

    CGFloat length = vertical ? t.size.height : t.size.width;
    if (length >= 16) {
        // Three 1 pt lines, 2 pt apart, centred on whole points, each with a white line below / right.
        CGFloat across = vertical ? t.size.width : t.size.height;
        CGFloat gripLength = MAX(0, across - 8);
        for (int i = -1; i <= 1; i++) {
            if (vertical) {
                CGFloat y = floor(CGRectGetMidY(t)) + 2 * i;
                CGFloat x = round(CGRectGetMidX(t) - gripLength / 2);
                W7CtlFill(ctx, 0xB2B2B2, 1);
                CGContextFillRect(ctx, CGRectMake(x, y, gripLength, 1));
                W7CtlFill(ctx, 0xFFFFFF, 1);
                CGContextFillRect(ctx, CGRectMake(x, y - 1, gripLength, 1));
            } else {
                CGFloat x = floor(CGRectGetMidX(t)) + 2 * i;
                CGFloat y = round(CGRectGetMidY(t) - gripLength / 2);
                W7CtlFill(ctx, 0xB2B2B2, 1);
                CGContextFillRect(ctx, CGRectMake(x, y, 1, gripLength));
                W7CtlFill(ctx, 0xFFFFFF, 1);
                CGContextFillRect(ctx, CGRectMake(x + 1, y, 1, gripLength));
            }
        }
    }
    CGContextRestoreGState(ctx);
}
