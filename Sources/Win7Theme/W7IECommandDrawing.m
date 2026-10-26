#import "Win7Theme.h"
#import <CoreText/CoreText.h>

// Internet Explorer 8 on Windows 7: the tab row's line (test-only now),
// the command bar's buttons (text and glyph on the row; a flat 1 px #A0B4CC frame under the pointer),
// their drop arrows and glyphs (Favorites star, Add to Favorites, Home, Print, Help), and the blank new-tab stub.
// Non-flipped contexts (bottom-left origin).

static CGColorSpaceRef W7IECmdSRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7IECmdColor(uint32_t hex) {
    W7RGBA c = W7RGBAFromHex(hex, 1);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7IECmdSRGB(), v));
}

static void W7IECmdFill(CGContextRef ctx, CGRect r, uint32_t hex) {
    CGContextSetFillColorWithColor(ctx, W7IECmdColor(hex));
    CGContextFillRect(ctx, r);
}

static void W7IECmdGradient(CGContextRef ctx, CGRect r, uint32_t top, uint32_t bottom) {
    CGColorRef cols[2] = { W7IECmdColor(top), W7IECmdColor(bottom) };
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7IECmdSRGB(), arr, NULL);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, r);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(g);
    CFRelease(arr);
}

void W7DrawIETabRowLine(CGContextRef ctx, CGRect row, CGFloat lineY) {
    if (CGRectIsEmpty(row)) return;
    CGFloat y = MAX(CGRectGetMinY(row), MIN(lineY, CGRectGetMaxY(row) - 1));
    W7IECmdFill(ctx, CGRectMake(row.origin.x, y, row.size.width, 1), 0x8DA7C8);
}

void W7DrawIECommandButtonFace(CGContextRef ctx, CGRect rect, W7ControlState state) {
    if (CGRectIsEmpty(rect) || (state != W7StateHover && state != W7StatePressed)) return;   // text and glyph on the row
    // IE8: a flat 1 px frame under the pointer, no face; pressed adds a pale fill.
    CGPathRef path = (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(CGRectInset(rect, 0.5, 0.5), 2, 2, NULL));
    if (state == W7StatePressed) {
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, path);
        CGContextSetFillColorWithColor(ctx, W7IECmdColor(0xDCE6F2));
        CGContextFillPath(ctx);
        CGContextRestoreGState(ctx);
    }
    CGContextSaveGState(ctx);
    CGContextSetStrokeColorWithColor(ctx, W7IECmdColor(0xA0B4CC));
    CGContextSetLineWidth(ctx, 1);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawIEDropArrow(CGContextRef ctx, CGPoint center) {
    CGContextSaveGState(ctx);
    CGContextSetFillColorWithColor(ctx, W7IECmdColor(0x1E1E1E));
    CGContextMoveToPoint(ctx, center.x - 3, center.y + 1.5);
    CGContextAddLineToPoint(ctx, center.x + 3, center.y + 1.5);
    CGContextAddLineToPoint(ctx, center.x, center.y - 1.5);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
}

/// A five-pointed star in `r`, gold with a darker edge.
static void W7IECmdStar(CGContextRef ctx, CGRect r) {
    CGFloat cx = CGRectGetMidX(r), cy = CGRectGetMidY(r) - r.size.height * 0.04, R = MIN(r.size.width, r.size.height) / 2, ri = R * 0.45;
    CGContextBeginPath(ctx);
    for (int i = 0; i < 10; i++) {
        CGFloat a = M_PI / 2 + i * M_PI / 5, rad = (i % 2) ? ri : R;
        CGPoint p = CGPointMake(cx + rad * cos(a), cy + rad * sin(a));
        if (i == 0) CGContextMoveToPoint(ctx, p.x, p.y);
        else CGContextAddLineToPoint(ctx, p.x, p.y);
    }
    CGContextClosePath(ctx);
    CGContextSetFillColorWithColor(ctx, W7IECmdColor(0xF6C342));
    CGContextSetStrokeColorWithColor(ctx, W7IECmdColor(0xB07C12));
    CGContextSetLineWidth(ctx, 1);
    CGContextDrawPath(ctx, kCGPathFillStroke);
}

void W7DrawIEGlyph(CGContextRef ctx, CGRect r, W7IEGlyph glyph) {
    if (CGRectIsEmpty(r)) return;
    CGContextSaveGState(ctx);
    CGFloat x = r.origin.x, y = r.origin.y, w = r.size.width, h = r.size.height;
    switch (glyph) {
        case W7IEGlyphFavorites:
            W7IECmdStar(ctx, CGRectInset(r, 1, 1));
            break;
        case W7IEGlyphAddFavorite: {
            W7IECmdStar(ctx, CGRectMake(x, y + h * 0.15, w * 0.85, h * 0.85));
            CGRect plus = CGRectMake(x + w * 0.5, y, w * 0.5, h * 0.5);   // green plus at the bottom right
            W7IECmdFill(ctx, CGRectMake(CGRectGetMidX(plus) - 1.5, plus.origin.y, 3, plus.size.height), 0x3C9A2E);
            W7IECmdFill(ctx, CGRectMake(plus.origin.x, CGRectGetMidY(plus) - 1.5, plus.size.width, 3), 0x3C9A2E);
            break;
        }
        case W7IEGlyphHome: {
            CGContextSetFillColorWithColor(ctx, W7IECmdColor(0x2F6DB5));   // roof
            CGContextMoveToPoint(ctx, x, y + h * 0.55);
            CGContextAddLineToPoint(ctx, x + w / 2, y + h);
            CGContextAddLineToPoint(ctx, x + w, y + h * 0.55);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
            CGRect walls = CGRectMake(x + w * 0.18, y, w * 0.64, h * 0.58);
            W7IECmdFill(ctx, walls, 0xE9EEF5);
            W7IECmdFill(ctx, CGRectMake(x + w * 0.42, y, w * 0.18, h * 0.32), 0x8A5A2B);   // door
            CGContextSetStrokeColorWithColor(ctx, W7IECmdColor(0x5A6B80));
            CGContextStrokeRect(ctx, CGRectInset(walls, 0.5, 0.5));
            break;
        }
        case W7IEGlyphPrint: {
            CGRect paper = CGRectMake(x + w * 0.22, y + h * 0.55, w * 0.56, h * 0.42);
            W7IECmdFill(ctx, paper, 0xFFFFFF);
            W7IECmdGradient(ctx, CGRectMake(x, y + h * 0.18, w, h * 0.45), 0x8C96A3, 0x5D6672);   // body
            W7IECmdFill(ctx, CGRectMake(x + w * 0.22, y, w * 0.56, h * 0.3), 0xF4F4F4);           // printout
            CGContextSetStrokeColorWithColor(ctx, W7IECmdColor(0x4A525C));
            CGContextStrokeRect(ctx, CGRectInset(paper, 0.5, 0.5));
            break;
        }
        case W7IEGlyphHelp: {
            CGRect c = CGRectInset(r, 0.5, 0.5);
            CGContextSetFillColorWithColor(ctx, W7IECmdColor(0x2F6DB5));
            CGContextFillEllipseInRect(ctx, c);
            CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, h * 0.7, NULL);
            CFStringRef keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
            CFTypeRef values[] = { font, W7IECmdColor(0xFFFFFF) };
            CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)keys, (const void **)values, 2,
                                                       &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFAttributedStringRef q = CFAttributedStringCreate(NULL, CFSTR("?"), attrs);
            CTLineRef line = CTLineCreateWithAttributedString(q);
            CGRect b = CTLineGetImageBounds(line, ctx);
            CGContextSetTextPosition(ctx, CGRectGetMidX(c) - CGRectGetMidX(b), CGRectGetMidY(c) - CGRectGetMidY(b));
            CTLineDraw(line, ctx);
            CFRelease(line);
            CFRelease(q);
            CFRelease(attrs);
            CFRelease(font);
            break;
        }
    }
    CGContextRestoreGState(ctx);
}

void W7DrawIEGlyphDisabled(CGContextRef ctx, CGRect r, W7IEGlyph glyph) {
    if (CGRectIsEmpty(r)) return;
    // the same shape, greyed (a #6D6D6D wash over it, only where it is painted) and at 40 % alpha.
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, 0.4);
    CGContextBeginTransparencyLayerWithRect(ctx, r, NULL);
    W7DrawIEGlyph(ctx, r, glyph);
    CGContextSetBlendMode(ctx, kCGBlendModeSourceAtop);
    W7RGBA grey = W7RGBAFromHex(0x6D6D6D, 0.7);
    CGFloat v[4] = { grey.r, grey.g, grey.b, grey.a };
    CGContextSetFillColorWithColor(ctx, (CGColorRef)CFAutorelease(CGColorCreate(W7IECmdSRGB(), v)));
    CGContextFillRect(ctx, r);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawIENewTabStub(CGContextRef ctx, CGRect rect, BOOL hover) {
    W7DrawIETab(ctx, rect, hover ? W7IETabHover : W7IETabNormal);   // a blank tab: IE7/8's "new tab" slot
}
