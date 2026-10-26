// The shell's Windows 7 Calculator: the key faces, the display box with its memory indicator and
// the window's light body. Non-flipped contexts. Win7Shell's CalculatorWindow lays the keys out and feeds them.
#import "Win7Theme.h"

const CGFloat W7CalculatorDisplayHeight = 24;
const CGFloat W7CalculatorDisplayFontSize = 18;

static const CGFloat kMinFontSize = 8;
static const CGFloat kKeyRadius = 3;
static const CGFloat kDisplayRadius = 2;
static const CGFloat kTextInset = 6;
static const CGFloat kMemoryWidth = 22;

static const uint32_t kKeyTopHex = 0xF0F0F0;
static const uint32_t kKeyBottomHex = 0xE5E5E5;
static const uint32_t kKeyBorderHex = 0x8E8F8F;
static const uint32_t kKeyHoverHex = 0xDDE9F7;
static const uint32_t kKeyPressedHex = 0xC4D8EF;
static const uint32_t kKeyDisabledHex = 0xF4F4F4;
static const uint32_t kKeyDisabledBorderHex = 0xADB2B5;
static const uint32_t kDisabledTextHex = 0x8D8D8D;
static const uint32_t kBodyTopHex = 0xDDE7F3;
static const uint32_t kBodyBottomHex = 0xEEF3FA;

static void W7CalcSetFill(CGContextRef ctx, uint32_t hex, CGFloat alpha) {
    W7RGBA c = W7RGBAFromHex(hex, alpha);
    CGContextSetRGBFillColor(ctx, c.r, c.g, c.b, c.a);
}

static void W7CalcSetStroke(CGContextRef ctx, uint32_t hex, CGFloat alpha) {
    W7RGBA c = W7RGBAFromHex(hex, alpha);
    CGContextSetRGBStrokeColor(ctx, c.r, c.g, c.b, c.a);
}

static NSColor *W7CalcColor(uint32_t hex) {
    W7RGBA c = W7RGBAFromHex(hex, 1);
    return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:1];
}

/// A vertical two-stop gradient (top colour at maxY) filling the current clip over `r`.
static void W7CalcVertical(CGContextRef ctx, CGRect r, uint32_t top, uint32_t bottom) {
    W7RGBA a = W7RGBAFromHex(top, 1), b = W7RGBAFromHex(bottom, 1);
    CGFloat comps[8] = { a.r, a.g, a.b, 1, b.r, b.g, b.b, 1 };
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)),
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

static CGPathRef W7CalcRounded(CGRect r, CGFloat radius) {
    radius = MAX(0, MIN(radius, MIN(r.size.width, r.size.height) / 2));
    return (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(r, radius, radius, NULL));
}

/// `text` in `font`/`hex`, centred vertically in `rect`; horizontally centred, or right-aligned when `right`.
static void W7CalcDrawText(CGContextRef ctx, NSString *text, CGRect rect, NSFont *font, uint32_t hex, BOOL right) {
    if (text.length == 0 || CGRectIsEmpty(rect)) return;
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: W7CalcColor(hex) };
    NSSize size = [text sizeWithAttributes:attrs];
    CGFloat x = right ? CGRectGetMaxX(rect) - size.width : round(CGRectGetMidX(rect) - size.width / 2);
    CGFloat y = round(CGRectGetMidY(rect) - (font.ascender + font.descender) / 2 + font.descender);
    CGContextSaveGState(ctx);   // the clip belongs to ctx, which NSGraphicsContext's restore does not reset
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    NSRectClip(rect);
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(ctx);
}

void W7DrawCalculatorKey(CGContextRef ctx, CGRect rect, NSString *label, W7ControlState state) {
    if (rect.size.width < 4 || rect.size.height < 4) return;
    CGContextSaveGState(ctx);
    CGPathRef face = W7CalcRounded(rect, kKeyRadius);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, face);
    CGContextClip(ctx);
    switch (state) {
        case W7StateHover: W7CalcSetFill(ctx, kKeyHoverHex, 1); CGContextFillRect(ctx, rect); break;
        case W7StatePressed: W7CalcSetFill(ctx, kKeyPressedHex, 1); CGContextFillRect(ctx, rect); break;
        case W7StateDisabled: W7CalcSetFill(ctx, kKeyDisabledHex, 1); CGContextFillRect(ctx, rect); break;
        default: W7CalcVertical(ctx, rect, kKeyTopHex, kKeyBottomHex); break;
    }
    CGContextRestoreGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    if (state == W7StateNormal || state == W7StateHover) {
        // The white inner line along the top edge, as Windows 7's raised keys have it.
        W7CalcSetStroke(ctx, 0xFFFFFF, 0.7);
        CGFloat y = CGRectGetMaxY(rect) - 1.5;
        CGContextMoveToPoint(ctx, CGRectGetMinX(rect) + 2, y);
        CGContextAddLineToPoint(ctx, CGRectGetMaxX(rect) - 2, y);
        CGContextStrokePath(ctx);
    }
    W7CalcSetStroke(ctx, state == W7StateDisabled ? kKeyDisabledBorderHex : kKeyBorderHex, 1);
    CGContextAddPath(ctx, W7CalcRounded(CGRectInset(rect, 0.5, 0.5), kKeyRadius));
    CGContextStrokePath(ctx);
    CGRect text = rect;
    if (state == W7StatePressed) text = CGRectOffset(text, 0, -1);   // the label sinks with the key
    W7CalcDrawText(ctx, label ?: @"", text, W7UIFont(12), state == W7StateDisabled ? kDisabledTextHex : 0x000000, NO);
    CGContextRestoreGState(ctx);
}

CGFloat W7CalculatorDisplayFontSizeFitting(NSString *text, CGFloat width) {
    CGFloat size = W7CalculatorDisplayFontSize;
    while (size > kMinFontSize) {
        NSSize s = [text ?: @"" sizeWithAttributes:@{ NSFontAttributeName: W7UIFont(size) }];
        if (s.width <= width) break;
        size -= 1;
    }
    return size;
}

void W7DrawCalculatorDisplay(CGContextRef ctx, CGRect rect, NSString *text, BOOL memory) {
    if (rect.size.width < 4 || rect.size.height < 4) return;
    CGContextSaveGState(ctx);
    CGPathRef box = W7CalcRounded(CGRectInset(rect, 0.5, 0.5), kDisplayRadius);
    W7CalcSetFill(ctx, 0xFFFFFF, 1);
    CGContextAddPath(ctx, W7CalcRounded(rect, kDisplayRadius));
    CGContextFillPath(ctx);
    CGContextSetLineWidth(ctx, 1);
    W7CalcSetStroke(ctx, kKeyBorderHex, 1);
    CGContextAddPath(ctx, box);
    CGContextStrokePath(ctx);
    CGRect inner = CGRectInset(rect, kTextInset, 1);
    if (memory) {
        CGRect m = CGRectMake(inner.origin.x, inner.origin.y, kMemoryWidth - 6, inner.size.height);
        W7CalcDrawText(ctx, @"M", m, W7UIFont(12), 0x000000, NO);
    }
    CGRect number = CGRectMake(inner.origin.x + kMemoryWidth, inner.origin.y, MAX(0, inner.size.width - kMemoryWidth),
                               inner.size.height);
    CGFloat size = W7CalculatorDisplayFontSizeFitting(text, number.size.width);
    W7CalcDrawText(ctx, text ?: @"", number, W7UIFont(size), 0x000000, YES);
    CGContextRestoreGState(ctx);
}

void W7DrawCalculatorBody(CGContextRef ctx, CGRect rect) {
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    W7CalcVertical(ctx, rect, kBodyTopHex, kBodyBottomHex);
    CGContextRestoreGState(ctx);
}
