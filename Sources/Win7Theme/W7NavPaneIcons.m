// Explorer navigation pane glyphs: the Favorites star, the tree expander and the procedural
// fallbacks for the row and section icons (computer, drives, network, tag, cloud, application badge; removable
// and optical drives for the Computer view).
// Everything is drawn in a non-flipped context, scaled from a 16 pt design to the rect's shorter side.
#import "Win7Theme.h"

static CGColorRef W7NavColor(uint32_t hex, CGFloat alpha) {
    W7RGBA c = W7RGBAFromHex(hex, alpha);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[] = { c.r, c.g, c.b, c.a };
    CGColorRef color = CGColorCreate(cs, comps);
    CGColorSpaceRelease(cs);
    return color;
}

static void W7NavSetFill(CGContextRef ctx, uint32_t hex, CGFloat alpha) {
    W7RGBA c = W7RGBAFromHex(hex, alpha);
    CGContextSetRGBFillColor(ctx, c.r, c.g, c.b, c.a);
}

static void W7NavSetStroke(CGContextRef ctx, uint32_t hex, CGFloat alpha) {
    W7RGBA c = W7RGBAFromHex(hex, alpha);
    CGContextSetRGBStrokeColor(ctx, c.r, c.g, c.b, c.a);
}

/// Fills the current path with a vertical gradient from `top` to `bottom` across `rect` (clipped to it).
static void W7NavFillGradient(CGContextRef ctx, CGRect rect, uint32_t top, uint32_t bottom) {
    CGColorRef colors[2] = { W7NavColor(top, 1), W7NavColor(bottom, 1) };
    CFArrayRef array = CFArrayCreate(NULL, (const void **)colors, 2, &kCFTypeArrayCallBacks);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef g = CGGradientCreateWithColors(cs, array, NULL);
    CGContextSaveGState(ctx);
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(rect)), CGPointMake(0, CGRectGetMinY(rect)), 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
    CFRelease(array);
    CGColorRelease(colors[0]);
    CGColorRelease(colors[1]);
}

/// Moves the context so a 16 × 16 design drawn from (0, 0) fills the centred square of `rect`.
static void W7NavEnterDesign(CGContextRef ctx, CGRect rect) {
    CGFloat side = MIN(CGRectGetWidth(rect), CGRectGetHeight(rect));
    CGContextTranslateCTM(ctx, CGRectGetMidX(rect) - side / 2, CGRectGetMidY(rect) - side / 2);
    CGContextScaleCTM(ctx, side / 16, side / 16);
}

#pragma mark - Star and expander

static void W7NavAddStar(CGContextRef ctx, CGFloat cx, CGFloat cy, CGFloat outer, CGFloat inner) {
    for (int i = 0; i < 10; i++) {
        CGFloat a = M_PI / 2 + i * M_PI / 5, r = (i % 2) ? inner : outer;
        CGFloat x = cx + r * cos(a), y = cy + r * sin(a);
        if (i == 0) CGContextMoveToPoint(ctx, x, y); else CGContextAddLineToPoint(ctx, x, y);
    }
    CGContextClosePath(ctx);
}

void W7DrawFavoritesStar(CGContextRef ctx, CGRect rect) {
    if (!ctx || CGRectIsEmpty(rect)) return;
    CGContextSaveGState(ctx);
    W7NavEnterDesign(ctx, rect);
    // Centred a little low so the points sit evenly in the square.
    CGFloat cx = 8, cy = 7.6, outer = 7.4, inner = 3.1;
    W7NavAddStar(ctx, cx, cy, outer, inner);
    W7NavFillGradient(ctx, CGRectMake(0, cy - outer, 16, 2 * outer), 0xFFEB73, 0xEDA814);
    W7NavAddStar(ctx, cx, cy, outer - 0.35, inner - 0.15);
    W7NavSetStroke(ctx, 0xB8800D, 1);
    CGContextSetLineWidth(ctx, 0.7);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawTreeExpander(CGContextRef ctx, CGRect rect, BOOL expanded, BOOL hover) {
    if (!ctx || CGRectIsEmpty(rect)) return;
    CGFloat cx = CGRectGetMidX(rect), cy = CGRectGetMidY(rect);
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    CGContextSetLineJoin(ctx, kCGLineJoinMiter);
    if (expanded) {
        // ◢: the right angle at the lower right.
        CGContextMoveToPoint(ctx, cx + 3, cy + 3);
        CGContextAddLineToPoint(ctx, cx + 3, cy - 3);
        CGContextAddLineToPoint(ctx, cx - 3, cy - 3);
        CGContextClosePath(ctx);
        W7NavSetFill(ctx, hover ? 0x82DFFB : 0x262626, 1);
        if (hover) {
            W7NavSetStroke(ctx, 0x1CC4F7, 1);
            CGContextDrawPath(ctx, kCGPathFillStroke);
        } else {
            CGContextFillPath(ctx);
        }
    } else {
        // ▷: outlined, pointing right; its left edge on a pixel column.
        CGFloat left = floor(cx) - 1.5;
        CGContextMoveToPoint(ctx, left, cy + 4);
        CGContextAddLineToPoint(ctx, left + 4, cy);
        CGContextAddLineToPoint(ctx, left, cy - 4);
        CGContextClosePath(ctx);
        W7NavSetStroke(ctx, hover ? 0x1CC4F7 : 0x8A8A8A, 1);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Glyphs (16 × 16 designs)

static void W7NavRoundRect(CGContextRef ctx, CGRect r, CGFloat radius) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
    CGContextAddPath(ctx, p);
    CGPathRelease(p);
}

static void W7NavStrokeRoundRect(CGContextRef ctx, CGRect r, CGFloat radius, uint32_t hex) {
    W7NavRoundRect(ctx, CGRectInset(r, 0.5, 0.5), radius);
    W7NavSetStroke(ctx, hex, 1);
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokePath(ctx);
}

static void W7NavDrawComputer(CGContextRef ctx) {
    // Stand and foot.
    CGContextAddRect(ctx, CGRectMake(6.5, 2.5, 3, 2));
    W7NavSetFill(ctx, 0x7D8A99, 1);
    CGContextFillPath(ctx);
    W7NavRoundRect(ctx, CGRectMake(3.5, 1, 9, 1.8), 0.8);
    W7NavFillGradient(ctx, CGRectMake(3.5, 1, 9, 1.8), 0xB9C4D0, 0x5E6B7A);
    // Monitor: a dark bezel round a blue screen.
    CGRect bezel = CGRectMake(1, 4.5, 14, 10.5);
    W7NavRoundRect(ctx, bezel, 1.2);
    W7NavFillGradient(ctx, bezel, 0x4A5A6E, 0x232C38);
    CGRect screen = CGRectInset(bezel, 1.5, 1.5);
    CGContextAddRect(ctx, screen);
    W7NavFillGradient(ctx, screen, 0x5FB6EE, 0x1A5FA8);
    // A gloss across the screen's top half.
    CGContextAddRect(ctx, CGRectMake(CGRectGetMinX(screen), CGRectGetMidY(screen), CGRectGetWidth(screen), CGRectGetHeight(screen) / 2));
    W7NavSetFill(ctx, 0xFFFFFF, 0.18);
    CGContextFillPath(ctx);
}

static void W7NavDrawDrive(CGContextRef ctx, BOOL system) {
    // A flat box seen slightly from above: top face, then the front with a light.
    CGRect front = CGRectMake(1, 3, 14, 6);
    CGRect top = CGRectMake(2, 9, 12, 3.5);
    W7NavRoundRect(ctx, top, 1);
    W7NavFillGradient(ctx, top, 0xF4F4F4, 0xD2D2D2);
    W7NavStrokeRoundRect(ctx, top, 1, 0x8C8C8C);
    W7NavRoundRect(ctx, front, 1.2);
    W7NavFillGradient(ctx, front, 0xE2E2E2, 0xA9A9A9);
    W7NavStrokeRoundRect(ctx, front, 1.2, 0x6B6B6B);
    CGContextAddEllipseInRect(ctx, CGRectMake(11.5, 5, 2, 2));
    W7NavSetFill(ctx, 0x3CC23C, 1);
    CGContextFillPath(ctx);
    if (system) {
        // Four small blue panes on the top face.
        uint32_t panes[4] = { 0x3C8FE0, 0x2F7BD0, 0x2F7BD0, 0x1F63B5 };
        for (int i = 0; i < 4; i++) {
            CGFloat x = 6.2 + (i % 2) * 1.9, y = 9.6 + (i / 2) * 1.3;
            CGContextAddRect(ctx, CGRectMake(x, y, 1.6, 1.1));
            W7NavSetFill(ctx, panes[i], 1);
            CGContextFillPath(ctx);
        }
    }
}

static void W7NavDrawGlobe(CGContextRef ctx) {
    CGRect ball = CGRectMake(1, 1, 14, 14);
    CGContextAddEllipseInRect(ctx, ball);
    W7NavFillGradient(ctx, ball, 0x6CC4F5, 0x1B5FAE);
    // Meridians and parallels.
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, ball);
    CGContextClip(ctx);
    W7NavSetStroke(ctx, 0xFFFFFF, 0.65);
    CGContextSetLineWidth(ctx, 0.8);
    CGContextAddEllipseInRect(ctx, CGRectMake(4.5, 1, 7, 14));
    CGContextMoveToPoint(ctx, 8, 1);
    CGContextAddLineToPoint(ctx, 8, 15);
    CGContextMoveToPoint(ctx, 1, 8);
    CGContextAddLineToPoint(ctx, 15, 8);
    CGContextMoveToPoint(ctx, 2, 11.5);
    CGContextAddLineToPoint(ctx, 14, 11.5);
    CGContextMoveToPoint(ctx, 2, 4.5);
    CGContextAddLineToPoint(ctx, 14, 4.5);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
    CGContextAddEllipseInRect(ctx, CGRectInset(ball, 0.5, 0.5));
    W7NavSetStroke(ctx, 0x174A86, 1);
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokePath(ctx);
}

static void W7NavDrawTag(CGContextRef ctx) {
    // A label tag pointing left, with a hole near its point.
    CGContextMoveToPoint(ctx, 1.5, 8);
    CGContextAddLineToPoint(ctx, 6, 13);
    CGContextAddLineToPoint(ctx, 14.5, 13);
    CGContextAddLineToPoint(ctx, 14.5, 3);
    CGContextAddLineToPoint(ctx, 6, 3);
    CGContextClosePath(ctx);
    W7NavFillGradient(ctx, CGRectMake(0, 3, 16, 10), 0xE6E6E6, 0xB4B4B4);
    CGContextMoveToPoint(ctx, 1.5, 8);
    CGContextAddLineToPoint(ctx, 6, 13);
    CGContextAddLineToPoint(ctx, 14.5, 13);
    CGContextAddLineToPoint(ctx, 14.5, 3);
    CGContextAddLineToPoint(ctx, 6, 3);
    CGContextClosePath(ctx);
    W7NavSetStroke(ctx, 0x6E6E6E, 1);
    CGContextSetLineWidth(ctx, 1);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextStrokePath(ctx);
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeClear);
    CGContextAddEllipseInRect(ctx, CGRectMake(5, 7, 2, 2));
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
}

static void W7NavAddCloud(CGContextRef ctx) {
    CGContextAddEllipseInRect(ctx, CGRectMake(1, 3, 6, 6));
    CGContextAddEllipseInRect(ctx, CGRectMake(4, 5, 8, 8));
    CGContextAddEllipseInRect(ctx, CGRectMake(9, 3, 6, 6));
    CGContextAddRect(ctx, CGRectMake(4, 3, 8, 4));
}

static void W7NavDrawCloud(CGContextRef ctx) {
    // The outline: the same shape filled darker, 1 pt larger round.
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 8, 8);
    CGContextScaleCTM(ctx, 1.08, 1.1);
    CGContextTranslateCTM(ctx, -8, -8);
    W7NavAddCloud(ctx);
    W7NavSetFill(ctx, 0x3F86C9, 1);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
    W7NavAddCloud(ctx);
    W7NavFillGradient(ctx, CGRectMake(0, 3, 16, 10), 0xEAF6FF, 0x8CC8F2);
}

static void W7NavDrawAppBadge(CGContextRef ctx) {
    // A small application window: white body, blue title strip, dark border.
    CGRect body = CGRectMake(1.5, 2.5, 13, 11);
    W7NavRoundRect(ctx, body, 1.2);
    W7NavSetFill(ctx, 0xFFFFFF, 1);
    CGContextFillPath(ctx);
    CGRect title = CGRectMake(1.5, 10.5, 13, 3);
    CGContextAddRect(ctx, title);
    W7NavFillGradient(ctx, title, 0x5FA9EC, 0x2D6FC0);
    CGContextAddRect(ctx, CGRectMake(4, 5, 8, 1));
    CGContextAddRect(ctx, CGRectMake(4, 7.5, 5, 1));
    W7NavSetFill(ctx, 0x9AB5D6, 1);
    CGContextFillPath(ctx);
    W7NavStrokeRoundRect(ctx, body, 1.2, 0x1F4F8F);
}

static void W7NavDrawRemovableDrive(CGContextRef ctx) {
    // A smaller drive box (the removable disk of Windows 7's Computer view) with a dark slot on its front.
    CGRect front = CGRectMake(2, 3, 12, 6.5);
    CGRect top = CGRectMake(3, 9.5, 10, 3);
    W7NavRoundRect(ctx, top, 1);
    W7NavFillGradient(ctx, top, 0xF4F4F4, 0xD6D6D6);
    W7NavStrokeRoundRect(ctx, top, 1, 0x8C8C8C);
    W7NavRoundRect(ctx, front, 1.2);
    W7NavFillGradient(ctx, front, 0xDCE3EA, 0x9FAAB6);
    W7NavStrokeRoundRect(ctx, front, 1.2, 0x5E6B7A);
    CGContextAddRect(ctx, CGRectMake(4, 5.6, 6, 1.2));
    W7NavSetFill(ctx, 0x2E3742, 1);
    CGContextFillPath(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(11, 5.2, 1.8, 1.8));
    W7NavSetFill(ctx, 0x3CC23C, 1);
    CGContextFillPath(ctx);
}

static void W7NavDrawOpticalDisc(CGContextRef ctx) {
    // A silver disc with a soft blue sheen, a clear hole and a grey rim.
    CGRect disc = CGRectMake(1, 1, 14, 14);
    CGContextAddEllipseInRect(ctx, disc);
    W7NavFillGradient(ctx, disc, 0xF7FAFD, 0xB8C7D8);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, disc);
    CGContextClip(ctx);
    CGContextMoveToPoint(ctx, 8, 8);
    CGContextAddLineToPoint(ctx, 15, 13);
    CGContextAddLineToPoint(ctx, 15, 9);
    CGContextClosePath(ctx);
    W7NavSetFill(ctx, 0x8FD3F5, 0.55);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
    CGContextAddEllipseInRect(ctx, CGRectInset(disc, 0.5, 0.5));
    W7NavSetStroke(ctx, 0x7E8C9C, 1);
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokePath(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(6, 6, 4, 4));
    W7NavSetStroke(ctx, 0x9AA7B5, 1);
    CGContextStrokePath(ctx);
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeClear);
    CGContextAddEllipseInRect(ctx, CGRectMake(7, 7, 2, 2));
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawNavPaneGlyph(CGContextRef ctx, CGRect rect, W7NavPaneGlyph glyph) {
    if (!ctx || CGRectIsEmpty(rect)) return;
    CGContextSaveGState(ctx);
    // The designs stay inside the square; clip so a stroke's half-pixel never spills out.
    CGFloat side = MIN(CGRectGetWidth(rect), CGRectGetHeight(rect));
    CGContextClipToRect(ctx, CGRectMake(CGRectGetMidX(rect) - side / 2, CGRectGetMidY(rect) - side / 2, side, side));
    W7NavEnterDesign(ctx, rect);
    switch (glyph) {
        case W7NavPaneGlyphComputer: W7NavDrawComputer(ctx); break;
        case W7NavPaneGlyphDrive: W7NavDrawDrive(ctx, NO); break;
        case W7NavPaneGlyphSystemDrive: W7NavDrawDrive(ctx, YES); break;
        case W7NavPaneGlyphNetwork: W7NavDrawGlobe(ctx); break;
        case W7NavPaneGlyphTag: W7NavDrawTag(ctx); break;
        case W7NavPaneGlyphCloud: W7NavDrawCloud(ctx); break;
        case W7NavPaneGlyphAppBadge: W7NavDrawAppBadge(ctx); break;
        case W7NavPaneGlyphRemovableDrive: W7NavDrawRemovableDrive(ctx); break;
        case W7NavPaneGlyphOpticalDrive: W7NavDrawOpticalDisc(ctx); break;
    }
    CGContextRestoreGState(ctx);
}
