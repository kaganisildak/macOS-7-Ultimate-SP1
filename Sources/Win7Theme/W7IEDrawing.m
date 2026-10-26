#import "Win7Theme.h"

// Internet Explorer 7/8 chrome pieces for Safari: the pale band behind the favourites and tab rows,
// the tabs (and the IE8 facsimile tab drawn over each invisible Safari tab: shape, favicon, title, close glyph), the
// status bar with its progress trough, and the back/forward orbs (the Explorer orbs at IE7's sizes). Non-flipped
// contexts (bottom-left origin).

const CGFloat W7IETabRadius = 2;
const CGFloat W7IEStatusBarHeight = 22;
const CGFloat W7IEProgressWidth = 100;
const CGFloat W7IEBackOrbSize = 28;
const CGFloat W7IEForwardOrbSize = 24;

static CGColorSpaceRef W7IESRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7IEColor(uint32_t hex, CGFloat a) {
    W7RGBA c = W7RGBAFromHex(hex, a);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7IESRGB(), v));
}

/// A vertical gradient `top`→`bottom` over `r`, clipped to the current clip.
static void W7IEFillVertical(CGContextRef ctx, CGRect r, uint32_t top, uint32_t bottom) {
    CGColorRef cols[2] = { W7IEColor(top, 1), W7IEColor(bottom, 1) };
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7IESRGB(), arr, NULL);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, r);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(g);
    CFRelease(arr);
}

static void W7IEFillRect(CGContextRef ctx, CGRect r, uint32_t hex) {
    CGContextSetFillColorWithColor(ctx, W7IEColor(hex, 1));
    CGContextFillRect(ctx, r);
}

#pragma mark - Band and tabs

W7IETabColors W7IETabColorsForState(W7IETabState state) {
    switch (state) {
        // sampled from the IE8 reference (x 150 / 340, y 108-135): a #A3A7AC outline with a white inner line;
        // the selected tab #C3DDFB → #F0F4FB, full height, open at the bottom; unselected tabs (and the new-tab stub)
        // the row's own #E3EEFB, 2 px lower, on the #8B919F row line. Hover (not in the reference) a little lighter.
        case W7IETabSelected: return (W7IETabColors){ 0xC3DDFB, 0xF0F4FB, 0xA3A7AC, 0x8B919F, NO, 0, YES };
        case W7IETabHover: return (W7IETabColors){ 0xF7FAFE, 0xE9F1FB, 0xA3A7AC, 0x8B919F, YES, 2, YES };
        default: return (W7IETabColors){ 0xE3EEFB, 0xE3EEFB, 0xA3A7AC, 0x8B919F, YES, 2, YES };
    }
}

void W7DrawIETabRowBand(CGContextRef ctx, CGRect rect, CGFloat lineY) {
    if (CGRectIsEmpty(rect)) return;
    // Sampled from the IE8 reference: the rows under the navigation row are an opaque pale band.
    CGFloat y = MAX(CGRectGetMinY(rect), MIN(floor(lineY), CGRectGetMaxY(rect) - 1));
    CGFloat top = CGRectGetMaxY(rect), x = rect.origin.x, w = rect.size.width;
    W7IEFillRect(ctx, CGRectMake(x, y + 1, w, MAX(0, top - y - 1)), 0xE3EEFB);
    CGFloat fade = MIN(12, MAX(0, top - y - 2));
    if (fade > 0) W7IEFillVertical(ctx, CGRectMake(x, top - 1 - fade, w, fade), 0xF2F7FD, 0xE3EEFB);
    if (top - y > 2) W7IEFillRect(ctx, CGRectMake(x, top - 1, w, 1), 0xFFFFFF);
    W7IEFillRect(ctx, CGRectMake(x, CGRectGetMinY(rect), w, y - CGRectGetMinY(rect)), 0xF2F6FB);   // the strip above the page
    W7IEFillRect(ctx, CGRectMake(x, y, w, 1), 0x8B919F);
}

/// A rect with only its top corners rounded; `closed` NO leaves the bottom edge out (for stroking).
static CGPathRef W7IETabPath(CGRect r, CGFloat radius, BOOL closed) {
    radius = MAX(0, MIN(radius, MIN(r.size.width, r.size.height) / 2));
    CGMutablePathRef p = CGPathCreateMutable();
    CGFloat minX = CGRectGetMinX(r), maxX = CGRectGetMaxX(r), minY = CGRectGetMinY(r), maxY = CGRectGetMaxY(r);
    CGPathMoveToPoint(p, NULL, minX, minY);
    CGPathAddLineToPoint(p, NULL, minX, maxY - radius);
    CGPathAddArcToPoint(p, NULL, minX, maxY, minX + radius, maxY, radius);
    CGPathAddLineToPoint(p, NULL, maxX - radius, maxY);
    CGPathAddArcToPoint(p, NULL, maxX, maxY, maxX, maxY - radius, radius);
    CGPathAddLineToPoint(p, NULL, maxX, minY);
    if (closed) CGPathCloseSubpath(p);
    return (CGPathRef)CFAutorelease(p);
}

void W7DrawIETab(CGContextRef ctx, CGRect rect, W7IETabState state) {
    if (CGRectIsEmpty(rect)) return;
    W7IETabColors c = W7IETabColorsForState(state);
    rect.size.height = MAX(0, rect.size.height - c.topInset);   // unselected tabs stand lower than the selected one
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, W7IETabPath(rect, W7IETabRadius, YES));
    CGContextClip(ctx);
    // The fill's `top` starts under the border and the white line (as in the reference), when there is a white line.
    CGFloat lines = c.innerLine ? MIN(2, rect.size.height) : 0;
    W7IEFillVertical(ctx, CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height - lines), c.top, c.bottom);
    if (lines > 0) W7IEFillRect(ctx, CGRectMake(rect.origin.x, CGRectGetMaxY(rect) - lines, rect.size.width, lines), c.top);
    CGContextRestoreGState(ctx);

    CGContextSaveGState(ctx);
    CGContextSetStrokeColorWithColor(ctx, W7IEColor(c.border, 1));
    CGContextSetLineWidth(ctx, 1);
    // Inset by half a line so the 1 pt border lies inside `rect`: sides and top in `border`, the bottom line (when
    // there is one) in `bottomBorder`, the line the tab row's band continues under the tabs.
    CGRect inner = CGRectMake(rect.origin.x + 0.5, rect.origin.y, rect.size.width - 1, rect.size.height - 0.5);
    CGContextAddPath(ctx, W7IETabPath(inner, W7IETabRadius - 0.5, NO));
    CGContextStrokePath(ctx);
    if (c.innerLine && rect.size.width > 3 && rect.size.height > 2) {   // the white line just inside the border
        CGContextSetStrokeColorWithColor(ctx, W7IEColor(0xFFFFFF, 1));
        CGRect white = CGRectMake(rect.origin.x + 1.5, rect.origin.y, rect.size.width - 3, rect.size.height - 1.5);
        CGContextAddPath(ctx, W7IETabPath(white, MAX(0, W7IETabRadius - 1.5), NO));
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);
    if (c.bottomLine) W7IEFillRect(ctx, CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, 1), c.bottomBorder);
}

#pragma mark - Status bar

void W7DrawIEStatusBar(CGContextRef ctx, CGRect rect) {
    if (CGRectIsEmpty(rect)) return;
    CGFloat line = MIN(1, rect.size.height);
    W7IEFillVertical(ctx, CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height - line), 0xF0F0F0, 0xE3E3E3);
    W7IEFillRect(ctx, CGRectMake(rect.origin.x, CGRectGetMaxY(rect) - line, rect.size.width, line), 0xA0A0A0);
}

void W7DrawIEProgress(CGContextRef ctx, CGRect rect, CGFloat fraction) {
    if (CGRectIsEmpty(rect)) return;
    CGFloat f = isnan(fraction) ? 0 : MAX(0, MIN(1, fraction));
    W7IEFillRect(ctx, rect, 0xA5A5A5);
    CGRect inner = CGRectInset(rect, 1, 1);
    if (CGRectIsEmpty(inner)) return;
    W7IEFillVertical(ctx, inner, 0xF3F3F3, 0xE6E6E6);
    CGFloat w = round(inner.size.width * f);
    if (w <= 0) return;
    CGRect bar = CGRectMake(inner.origin.x, inner.origin.y, w, inner.size.height);
    W7IEFillVertical(ctx, bar, 0x6EDB5A, 0x06B025);
    // The Windows 7 bar's lighter upper half.
    CGRect gloss = CGRectMake(bar.origin.x, CGRectGetMidY(bar), bar.size.width, bar.size.height / 2);
    CGContextSaveGState(ctx);
    CGContextSetFillColorWithColor(ctx, W7IEColor(0xFFFFFF, 0.25));
    CGContextFillRect(ctx, gloss);
    CGContextRestoreGState(ctx);
}

#pragma mark - Back and forward orbs

CGSize W7IENavOrbsSize(void) { return CGSizeMake(W7IEBackOrbSize + W7IEForwardOrbSize - 1, W7IEBackOrbSize); }

void W7DrawIENavOrbs(CGContextRef ctx, CGRect rect, BOOL backEnabled, BOOL forwardEnabled) {
    CGSize s = W7IENavOrbsSize();
    CGFloat x = rect.origin.x, y = rect.origin.y;
    W7DrawNavTrough(ctx, CGRectMake(x + 2, y + floor((s.height - 22) / 2), s.width - 3, 22));
    W7DrawNavButton(ctx, CGRectMake(x + W7IEBackOrbSize - 1, y + floor((s.height - W7IEForwardOrbSize) / 2),
                                    W7IEForwardOrbSize, W7IEForwardOrbSize),
                    YES, forwardEnabled ? W7StateNormal : W7StateDisabled);
    W7DrawNavButton(ctx, CGRectMake(x, y, W7IEBackOrbSize, W7IEBackOrbSize), NO, backEnabled ? W7StateNormal : W7StateDisabled);
}

void W7DrawIENavCapsule(CGContextRef ctx, CGRect rect) {
    if (CGRectIsEmpty(rect)) return;
    CGFloat r = rect.size.height / 2;
    CGPathRef path = (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(rect, MIN(r, rect.size.width / 2), MIN(r, rect.size.width / 2), NULL));
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    W7IEFillVertical(ctx, rect, 0xE4EDF8, 0xC3D5EA);   // opaque, pale Aero blue
    CGContextRestoreGState(ctx);
    W7DrawNavTrough(ctx, rect);
}

CGImageRef W7CreateIENavOrbImage(BOOL forward, CGFloat scale) {
    if (!(scale > 0)) return NULL;
    CGFloat side = forward ? W7IEForwardOrbSize : W7IEBackOrbSize;
    size_t px = (size_t)ceil(side * scale);
    CGContextRef ctx = CGBitmapContextCreate(NULL, px, px, 8, 0, W7IESRGB(), (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (!ctx) return NULL;
    CGContextScaleCTM(ctx, scale, scale);
    W7DrawNavButton(ctx, CGRectMake(0, 0, side, side), forward, W7StateNormal);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

#pragma mark - IE8 facsimile tab

W7IETabFacsimileLayout W7IETabFacsimileLayoutFor(CGRect bounds, W7IETabState state, BOOL pinned, CGRect closeRect, BOOL closeShown) {
    W7IETabFacsimileLayout l = { CGRectZero, CGRectZero, CGRectZero, CGRectZero };
    if (CGRectIsEmpty(bounds)) return l;
    CGFloat inset = MIN(W7IETabColorsForState(state).topInset, MAX(0, bounds.size.height - 1));
    l.tab = CGRectMake(bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height - inset);
    CGFloat side = MIN(16, MIN(l.tab.size.width, l.tab.size.height));
    CGFloat iconX = pinned ? CGRectGetMidX(l.tab) - side / 2 : CGRectGetMinX(l.tab) + MIN(6, MAX(0, l.tab.size.width - side));
    l.icon = CGRectMake(round(iconX), round(CGRectGetMidY(l.tab) - side / 2), side, side);
    if (closeShown && !CGRectIsEmpty(closeRect)) {
        CGRect c = CGRectIntersection(closeRect, l.tab);
        l.close = CGRectIsNull(c) ? CGRectZero : c;
    }
    if (!pinned) {
        CGFloat x0 = CGRectGetMaxX(l.icon) + 4, x1 = CGRectGetMaxX(l.tab) - 6;
        if (!CGRectIsEmpty(l.close)) {
            if (CGRectGetMinX(l.close) >= x0) {
                x1 = CGRectGetMinX(l.close) - 4;   // the × at the right (moved there): the title ends before it
            } else {   // the × left of the title start (Safari's own place, over the favicon): the title starts after it
                x0 = MAX(x0, CGRectGetMaxX(l.close) + 4);
                if (CGRectIntersectsRect(l.close, l.icon)) l.icon = CGRectZero;   // the × wins over the icon, as in Safari
            }
        }
        if (x1 > x0) l.title = CGRectMake(x0, l.tab.origin.y, x1 - x0, l.tab.size.height);
    }
    return l;
}

NSString *W7IEMiddleTruncatedTitle(NSString *title, CGFloat maxWidth, NSFont *font) {
    if (![title isKindOfClass:NSString.class] || !title.length || !font) return @"";
    NSDictionary *attrs = @{ NSFontAttributeName: font };
    if ([title sizeWithAttributes:attrs].width <= maxWidth) return title;
    NSString *ellipsis = @"…";
    if ([ellipsis sizeWithAttributes:attrs].width > maxWidth) return @"";
    // The longest head + "…" + tail (the head one character longer when odd) that fits: binary search on the kept length.
    NSInteger lo = 0, hi = (NSInteger)title.length - 1;
    NSString *best = ellipsis;
    while (lo <= hi) {
        NSUInteger keep = (NSUInteger)(lo + hi) / 2, head = (keep + 1) / 2, tail = keep / 2;
        NSRange h = [title rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, head)];
        NSRange t = tail ? [title rangeOfComposedCharacterSequencesForRange:NSMakeRange(title.length - tail, tail)]
                         : NSMakeRange(title.length, 0);
        NSString *candidate = [NSString stringWithFormat:@"%@%@%@", [title substringWithRange:h], ellipsis, [title substringWithRange:t]];
        if ([candidate sizeWithAttributes:attrs].width <= maxWidth) { best = candidate; lo = (NSInteger)keep + 1; }
        else hi = (NSInteger)keep - 1;
    }
    return best;
}

void W7DrawIETabCloseGlyph(CGContextRef ctx, CGRect rect, BOOL hover) {
    if (CGRectIsEmpty(rect)) return;
    CGFloat d = MIN(10, MIN(rect.size.width, rect.size.height) - 2);   // a 10 pt ×
    if (d <= 0) return;
    CGFloat cx = round(CGRectGetMidX(rect)), cy = round(CGRectGetMidY(rect));
    CGContextSaveGState(ctx);
    CGContextSetStrokeColorWithColor(ctx, W7IEColor(hover ? 0xC75050 : 0x6E6E6E, 1));
    CGContextSetLineWidth(ctx, 1.5);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, cx - d / 2, cy - d / 2);
    CGContextAddLineToPoint(ctx, cx + d / 2, cy + d / 2);
    CGContextMoveToPoint(ctx, cx - d / 2, cy + d / 2);
    CGContextAddLineToPoint(ctx, cx + d / 2, cy - d / 2);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

CGRect W7IETabTitleRectAvoiding(CGRect title, const CGRect *rects, NSInteger count) {
    if (CGRectIsEmpty(title) || !rects) return title;
    CGFloat x0 = CGRectGetMinX(title), x1 = CGRectGetMaxX(title), mid = CGRectGetMidX(title);
    for (NSInteger i = 0; i < count; i++) {
        CGRect r = rects[i];
        if (CGRectIsEmpty(r) || CGRectGetMaxX(r) <= x0 || CGRectGetMinX(r) >= x1) continue;
        if (CGRectGetMidX(r) < mid) x0 = MAX(x0, CGRectGetMaxX(r) + 4);   // a control at the left: start after it
        else x1 = MIN(x1, CGRectGetMinX(r) - 4);                          // at the right: end before it
    }
    return x1 > x0 ? CGRectMake(x0, title.origin.y, x1 - x0, title.size.height) : CGRectZero;
}

void W7DrawIETabAccessoryGlyph(CGContextRef ctx, CGRect rect, W7IETabAccessory kind) {
    if (!ctx || CGRectIsEmpty(rect)) return;
    CGFloat s = MIN(12, MIN(rect.size.width, rect.size.height));
    CGRect g = CGRectMake(round(CGRectGetMidX(rect) - s / 2), round(CGRectGetMidY(rect) - s / 2), s, s);
    CGContextSaveGState(ctx);
    CGContextSetFillColorWithColor(ctx, W7IEColor(0x4A4A4A, 1));
    CGContextSetStrokeColorWithColor(ctx, W7IEColor(0x4A4A4A, 1));
    CGContextSetLineWidth(ctx, 1.2);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGFloat x = g.origin.x, cy = CGRectGetMidY(g);
    if (kind == W7IETabAccessorySpeaker) {
        CGContextMoveToPoint(ctx, x, cy - s * 0.17);   // the speaker: box and cone
        CGContextAddLineToPoint(ctx, x + s * 0.22, cy - s * 0.17);
        CGContextAddLineToPoint(ctx, x + s * 0.5, cy - s * 0.42);
        CGContextAddLineToPoint(ctx, x + s * 0.5, cy + s * 0.42);
        CGContextAddLineToPoint(ctx, x + s * 0.22, cy + s * 0.17);
        CGContextAddLineToPoint(ctx, x, cy + s * 0.17);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
        for (int i = 1; i <= 2; i++) {   // two sound waves
            CGFloat r = s * (0.18 + 0.17 * i);
            CGContextAddArc(ctx, x + s * 0.42, cy, r, -M_PI / 4, M_PI / 4, 0);
            CGContextStrokePath(ctx);
        }
    } else {
        CGContextStrokeEllipseInRect(ctx, CGRectInset(g, 1, 1));   // a generic control: a ring with a dot
        CGContextFillEllipseInRect(ctx, CGRectMake(CGRectGetMidX(g) - 1.5, cy - 1.5, 3, 3));
    }
    CGContextRestoreGState(ctx);
}

void W7DrawIETabFacsimile(CGContextRef ctx, CGRect bounds, W7IETabState state, BOOL pinned, NSImage *icon, NSString *title,
                          CGRect titleRect, CGRect closeRect, W7IETabCloseState close) {
    if (!ctx || CGRectIsEmpty(bounds)) return;
    W7IETabFacsimileLayout l = W7IETabFacsimileLayoutFor(bounds, state, pinned, closeRect, close != W7IETabCloseHidden);
    CGRect titleIn = CGRectIsNull(titleRect) ? l.title : titleRect;
    W7DrawIETab(ctx, bounds, state);   // insets an unselected tab itself, exactly as the layout's `tab`
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    if (icon && !CGRectIsEmpty(l.icon)) {
        // A template image is one of Safari's symbol placeholders (the Start Page star, …): IE's page icon instead.
        if (icon.isTemplate) W7DrawIEPageIcon(ctx, l.icon);
        else [icon drawInRect:l.icon fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    if (!CGRectIsEmpty(titleIn) && title.length) {   // as given (the caller shortens it), clipped to its room
        static NSDictionary *attrs;
        static NSFont *font;
        if (!attrs) {
            font = W7UIFont(12);
            NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
            ps.lineBreakMode = NSLineBreakByClipping;
            attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor, NSParagraphStyleAttributeName: ps };
        }
        CGFloat h = ceil(font.ascender - font.descender);
        NSRect r = NSMakeRect(titleIn.origin.x, round(CGRectGetMidY(l.tab) - h / 2), titleIn.size.width, h);
        [title drawInRect:r withAttributes:attrs];
    }
    [NSGraphicsContext restoreGraphicsState];
    if (close != W7IETabCloseHidden) W7DrawIETabCloseGlyph(ctx, l.close, close == W7IETabCloseHover);
}

#pragma mark - IE's generic page icon

void W7DrawIEPageIcon(CGContextRef ctx, CGRect rect) {
    if (!ctx || CGRectIsEmpty(rect)) return;
    // Drawn for 16 pt and scaled into `rect`: a 10 × 14 page with a 4 pt folded top-right corner, on half-pixel
    // centres so the 1 px outline is crisp at 1×. Our own drawing: no Microsoft artwork.
    CGFloat s = MIN(rect.size.width, rect.size.height) / 16;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, round(CGRectGetMidX(rect) - 8 * s), round(CGRectGetMidY(rect) - 8 * s));
    CGContextScaleCTM(ctx, s, s);
    const CGFloat left = 3.5, right = 12.5, bottom = 1.5, top = 14.5, fold = 4;
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, left, bottom);
    CGContextAddLineToPoint(ctx, right, bottom);
    CGContextAddLineToPoint(ctx, right, top - fold);
    CGContextAddLineToPoint(ctx, right - fold, top);
    CGContextAddLineToPoint(ctx, left, top);
    CGContextClosePath(ctx);
    CGContextSetFillColorWithColor(ctx, W7IEColor(0xFFFFFF, 1));
    CGContextSetStrokeColorWithColor(ctx, W7IEColor(0x7A8A9E, 1));
    CGContextSetLineWidth(ctx, 1);
    CGContextDrawPath(ctx, kCGPathFillStroke);
    CGContextBeginPath(ctx);   // the fold: a pale triangle with the same outline
    CGContextMoveToPoint(ctx, right - fold, top);
    CGContextAddLineToPoint(ctx, right - fold, top - fold);
    CGContextAddLineToPoint(ctx, right, top - fold);
    CGContextClosePath(ctx);
    CGContextSetFillColorWithColor(ctx, W7IEColor(0xE4E9F0, 1));
    CGContextDrawPath(ctx, kCGPathFillStroke);
    for (int i = 0; i < 3; i++) W7IEFillRect(ctx, CGRectMake(5, 8 - 2 * i, i == 2 ? 4 : 6, 1), 0xA0A4A8);   // three text lines
    CGContextRestoreGState(ctx);
}
