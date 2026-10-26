#import "Win7Theme.h"

// controls slice 2: text and search fields, pop-up buttons (combo), tabs, progress bars, sliders and
// group boxes, as Windows 7 draws them. All functions take a non-flipped context. The small colour helpers are
// this file's own (W7Drawing.m's are file-local).

static CGColorSpaceRef W7C2Space(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7C2Color(uint32_t hex, CGFloat a) {
    W7RGBA c = W7RGBAFromHex(hex, a);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7C2Space(), v));
}

static void W7C2Fill(CGContextRef ctx, CGRect r, uint32_t hex, CGFloat a) {
    CGContextSetFillColorWithColor(ctx, W7C2Color(hex, a));
    CGContextFillRect(ctx, r);
}

static void W7C2Vertical(CGContextRef ctx, CGRect r, uint32_t top, CGFloat ta, uint32_t bottom, CGFloat ba) {
    CGColorRef cols[2] = { W7C2Color(top, ta), W7C2Color(bottom, ba) };
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7C2Space(), arr, NULL);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, r);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(g);
    CFRelease(arr);
}

static CGPathRef W7C2Rounded(CGRect r, CGFloat radius) {
    radius = MAX(0, MIN(radius, MIN(r.size.width, r.size.height) / 2));
    return (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(r, radius, radius, NULL));
}

static void W7C2Stroke(CGContextRef ctx, CGPathRef path, uint32_t hex, CGFloat a) {
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    CGContextSetStrokeColorWithColor(ctx, W7C2Color(hex, a));
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

/// Two vertical gradients, one over each half of `r`, clipped to `clip`.
static void W7C2Bands(CGContextRef ctx, CGRect r, CGPathRef clip, uint32_t t0, uint32_t t1, uint32_t b0, uint32_t b1) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, clip);
    CGContextClip(ctx);
    CGFloat half = r.size.height / 2;
    W7C2Vertical(ctx, CGRectMake(r.origin.x, r.origin.y + half, r.size.width, half), t0, 1, t1, 1);
    W7C2Vertical(ctx, CGRectMake(r.origin.x, r.origin.y, r.size.width, half), b0, 1, b1, 1);
    CGContextRestoreGState(ctx);
}

#pragma mark - Text field

void W7DrawTextFieldBox(CGContextRef ctx, CGRect rect, BOOL focused, BOOL enabled) {
    CGContextSaveGState(ctx);
    W7C2Fill(ctx, rect, enabled ? 0xFFFFFF : 0xF4F4F4, 1);
    uint32_t border = !enabled ? 0xCBCBCB : (focused ? 0x3399FF : 0xABADB3);
    W7C2Stroke(ctx, (CGPathRef)CFAutorelease(CGPathCreateWithRect(CGRectInset(rect, 0.5, 0.5), NULL)), border, 1);
    CGContextRestoreGState(ctx);
}

#pragma mark - Combo (pop-up button)

void W7DrawComboBox(CGContextRef ctx, CGRect rect, W7ControlState state) {
    CGContextSaveGState(ctx);
    if (state == W7StateDisabled) CGContextSetAlpha(ctx, 0.5);
    uint32_t t0 = 0xF2F2F2, t1 = 0xEBEBEB, b0 = 0xDDDDDD, b1 = 0xCFCFCF, border = 0x707070;
    if (state == W7StateHover) { t0 = 0xEAF6FD; t1 = 0xD9F0FC; b0 = 0xBEE6FD; b1 = 0xA7D9F5; border = 0x3C7FB1; }
    else if (state == W7StatePressed) { t0 = 0xE5F4FC; t1 = 0xC4E5F6; b0 = 0x98D1EF; b1 = 0x68B3DB; border = 0x2C628B; }
    CGPathRef outer = W7C2Rounded(CGRectInset(rect, 0.5, 0.5), 3);
    W7C2Bands(ctx, rect, outer, t0, t1, b0, b1);
    W7C2Stroke(ctx, W7C2Rounded(CGRectInset(rect, 1.5, 1.5), 2), 0xFFFFFF, state == W7StatePressed ? 0.3 : 0.8);
    W7C2Stroke(ctx, outer, border, 1);
    // The ▾ well: a separator 17 pt from the right end and the arrow centred in the well.
    CGFloat wellX = CGRectGetMaxX(rect) - 17;
    W7C2Fill(ctx, CGRectMake(wellX, rect.origin.y + 3, 1, MAX(0, rect.size.height - 6)), 0x9A9A9A, 0.6);
    W7DrawChevron(ctx, CGPointMake(wellX + 8.5, round(CGRectGetMidY(rect))), W7ChevronDown, 0x000000, 1);
    CGContextRestoreGState(ctx);
}

#pragma mark - Tabs

void W7DrawTabItem(CGContextRef ctx, CGRect rect, BOOL selected, BOOL hover) {
    CGContextSaveGState(ctx);
    CGFloat x0 = CGRectGetMinX(rect), x1 = CGRectGetMaxX(rect), y0 = CGRectGetMinY(rect), y1 = CGRectGetMaxY(rect);
    CGMutablePathRef body = CGPathCreateMutable();
    CGPathMoveToPoint(body, NULL, x0, y0);
    CGPathAddArcToPoint(body, NULL, x0, y1, x1, y1, 2);
    CGPathAddArcToPoint(body, NULL, x1, y1, x1, y0, 2);
    CGPathAddLineToPoint(body, NULL, x1, y0);
    CGPathCloseSubpath(body);
    CGContextAddPath(ctx, body);
    CGContextClip(ctx);
    if (selected) W7C2Fill(ctx, rect, 0xFFFFFF, 1);
    else if (hover) W7C2Vertical(ctx, rect, 0xEAF6FD, 1, 0xD8EEF9, 1);
    else W7C2Fill(ctx, rect, 0xF0F0F0, 1);
    CGContextRestoreGState(ctx);
    // Top and sides only: the tab stands on the pane's top line (a selected tab covers it).
    CGMutablePathRef edge = CGPathCreateMutable();
    CGPathMoveToPoint(edge, NULL, x0 + 0.5, y0);
    CGPathAddArcToPoint(edge, NULL, x0 + 0.5, y1 - 0.5, x1 - 0.5, y1 - 0.5, 2);
    CGPathAddArcToPoint(edge, NULL, x1 - 0.5, y1 - 0.5, x1 - 0.5, y0, 2);
    CGPathAddLineToPoint(edge, NULL, x1 - 0.5, y0);
    W7C2Stroke(ctx, edge, 0x8C8C8C, 1);
    CGPathRelease(edge);
    CGPathRelease(body);
}

void W7DrawTabPane(CGContextRef ctx, CGRect rect) {
    CGContextSaveGState(ctx);
    W7C2Fill(ctx, rect, 0xFFFFFF, 1);
    W7C2Stroke(ctx, (CGPathRef)CFAutorelease(CGPathCreateWithRect(CGRectInset(rect, 0.5, 0.5), NULL)), 0x8C8C8C, 1);
    CGContextRestoreGState(ctx);
}

#pragma mark - Progress bar

void W7DrawProgressBar(CGContextRef ctx, CGRect rect, CGFloat fraction) {
    CGContextSaveGState(ctx);
    CGPathRef trough = W7C2Rounded(CGRectInset(rect, 0.5, 0.5), 2);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, trough);
    CGContextClip(ctx);
    W7C2Vertical(ctx, rect, 0xE6E6E6, 1, 0xF7F7F7, 1);
    CGFloat f = isfinite(fraction) ? MAX(0, MIN(1, fraction)) : 0;
    CGRect inner = CGRectInset(rect, 1, 1);
    CGFloat w = round(inner.size.width * f);
    if (w > 0) {
        CGRect bar = CGRectMake(inner.origin.x, inner.origin.y, w, inner.size.height);
        W7C2Fill(ctx, bar, 0x06B025, 1);
        CGRect top = CGRectMake(bar.origin.x, CGRectGetMidY(bar), bar.size.width, bar.size.height / 2);
        W7C2Vertical(ctx, top, 0xFFFFFF, 0.55, 0xFFFFFF, 0.10);
    }
    CGContextRestoreGState(ctx);
    W7C2Stroke(ctx, trough, 0xBCBCBC, 1);
    CGContextRestoreGState(ctx);
}

#pragma mark - Slider

void W7DrawSliderTrack(CGContextRef ctx, CGRect rect) {
    CGContextSaveGState(ctx);
    CGRect ch = CGRectMake(rect.origin.x, round(CGRectGetMidY(rect) - 2), rect.size.width, 4);
    W7C2Fill(ctx, ch, 0xE7EAEA, 1);
    W7C2Fill(ctx, CGRectMake(ch.origin.x, CGRectGetMaxY(ch) - 1, ch.size.width, 1), 0xB0B0B0, 1);
    W7C2Fill(ctx, CGRectMake(ch.origin.x, ch.origin.y, 1, ch.size.height), 0xB0B0B0, 1);
    W7C2Fill(ctx, CGRectMake(CGRectGetMaxX(ch) - 1, ch.origin.y, 1, ch.size.height), 0xB0B0B0, 1);
    W7C2Fill(ctx, CGRectMake(ch.origin.x + 1, ch.origin.y, ch.size.width - 2, 1), 0xFFFFFF, 1);
    CGContextRestoreGState(ctx);
}

void W7DrawSliderThumb(CGContextRef ctx, CGRect rect, W7ControlState state) {
    CGContextSaveGState(ctx);
    if (state == W7StateDisabled) CGContextSetAlpha(ctx, 0.5);
    uint32_t top = 0xF2F2F2, bottom = 0xD6D6D6, border = 0x707070;
    if (state == W7StateHover) { top = 0xE5F4FC; bottom = 0xB3DCF4; border = 0x3C7FB1; }
    else if (state == W7StatePressed) { top = 0xCDE9F8; bottom = 0x8CC7EA; border = 0x2C628B; }
    CGPathRef outer = W7C2Rounded(CGRectInset(rect, 0.5, 0.5), 2);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, outer);
    CGContextClip(ctx);
    W7C2Vertical(ctx, rect, top, 1, bottom, 1);
    CGContextRestoreGState(ctx);
    W7C2Stroke(ctx, W7C2Rounded(CGRectInset(rect, 1.5, 1.5), 1), 0xFFFFFF, 0.8);
    W7C2Stroke(ctx, outer, border, 1);
    CGContextRestoreGState(ctx);
}

#pragma mark - Group box

void W7DrawGroupBox(CGContextRef ctx, CGRect rect, CGFloat titleWidth) {
    CGContextSaveGState(ctx);
    if (titleWidth > 0) {
        // Everything but the gap in the top edge where the title goes.
        CGContextAddRect(ctx, CGRectInset(rect, -1, -1));
        CGContextAddRect(ctx, CGRectMake(rect.origin.x + 6, CGRectGetMaxY(rect) - 3, titleWidth + 4, 4));
        CGContextEOClip(ctx);
    }
    W7C2Stroke(ctx, W7C2Rounded(CGRectInset(rect, 1.5, 1.5), 2), 0xFFFFFF, 1);
    W7C2Stroke(ctx, W7C2Rounded(CGRectInset(rect, 0.5, 0.5), 3), 0xD5DFE5, 1);
    CGContextRestoreGState(ctx);
}
