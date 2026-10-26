#import "Win7Theme.h"

static CGColorSpaceRef W7RGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7Color(uint32_t hex, CGFloat a) {
    W7RGBA c = W7RGBAFromHex(hex, a);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7RGB(), v));
}

static void W7SetFill(CGContextRef ctx, uint32_t hex, CGFloat a) { CGContextSetFillColorWithColor(ctx, W7Color(hex, a)); }
static void W7SetStroke(CGContextRef ctx, uint32_t hex, CGFloat a) { CGContextSetStrokeColorWithColor(ctx, W7Color(hex, a)); }

/// Vertical gradient from top color to bottom color within rect (non-flipped context).
static void W7FillVertical(CGContextRef ctx, CGRect r, uint32_t top, CGFloat ta, uint32_t bot, CGFloat ba) {
    CGColorRef cols[2] = { W7Color(top, ta), W7Color(bot, ba) };
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7RGB(), arr, NULL);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, r);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(g);
    CFRelease(arr);
}

static CGPathRef W7RoundedPath(CGRect r, CGFloat radius) {
    radius = MIN(radius, MIN(r.size.width, r.size.height) / 2);
    return (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(r, radius, radius, NULL));
}

#pragma mark - Glass frame

// Glass palette: an opaque-ish
// base keeps the glass blue over light vibrancy or a white desktop, then the Sky tint and a faint gloss over the top
// half. Over white (the opaque caption and frame) the active glass lands on the reference's #6A8FC6 (caption middle
// and bottom; #6C91C7 just under its highlight line), with the highlight line white 0.80 (#E1E9F3 there) under a
// #151C27 outer line.
static const uint32_t kGlassActiveTop = 0x546495, kGlassActiveBottom = 0x566697;
static const uint32_t kGlassInactiveTop = 0xC9CBD0, kGlassInactiveBottom = 0xCFD1D5;
static const CGFloat kGlassBaseAlpha = 0.92;
static const uint32_t kGlassTint = 0x74B8FC;
static const CGFloat kGlassTintActive = 0.42, kGlassTintInactive = 0.20;
static const CGFloat kGlassGloss = 0.03;
static const uint32_t kFrameOuterLine = 0x151C27;
static const CGFloat kFrameOuterActive = 1.0, kFrameOuterInactive = 0.6;
static const CGFloat kFrameInnerLine = 0.80;

const CGFloat W7FrameBorderWidth = 8;
const CGFloat W7FrameOuterRadius = 6;
const CGFloat W7FrameEdgeCover = 1;

/// What the opaque glass (the caption and the frame overlay) is drawn over: white, close to the light
/// title bar the caption glass showed through before, so the caption keeps its colour.
static const uint32_t kGlassBackdrop = 0xFFFFFF;

/// Base and tint over `fill`: the base gradient runs over `glassRect`, or, `flat`, is the gradient's bottom
/// colour (what the glass below a caption band continues with).
static void W7GlassBaseAndTint(CGContextRef ctx, CGRect fill, CGRect glassRect, BOOL active, BOOL flat) {
    uint32_t top = active ? kGlassActiveTop : kGlassInactiveTop, bottom = active ? kGlassActiveBottom : kGlassInactiveBottom;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, fill);
    if (flat) { W7SetFill(ctx, bottom, kGlassBaseAlpha); CGContextFillRect(ctx, fill); }
    else W7FillVertical(ctx, glassRect, top, kGlassBaseAlpha, bottom, kGlassBaseAlpha);
    W7SetFill(ctx, kGlassTint, active ? kGlassTintActive : kGlassTintInactive);
    CGContextFillRect(ctx, fill);
    CGContextRestoreGState(ctx);
}

void W7DrawGlassFill(CGContextRef ctx, CGRect glassRect, BOOL active) {
    CGContextSaveGState(ctx);
    W7GlassBaseAndTint(ctx, glassRect, glassRect, active, NO);
    CGRect top = CGRectMake(glassRect.origin.x, CGRectGetMidY(glassRect), glassRect.size.width, glassRect.size.height / 2);
    W7FillVertical(ctx, top, 0xFFFFFF, kGlassGloss, 0xFFFFFF, 0.0);
    CGContextRestoreGState(ctx);
}

/// The frame's outer line along `outer` and, when given, the white inner line along `inner`.
static void W7StrokeFrameLines(CGContextRef ctx, CGPathRef outer, CGPathRef _Nullable inner, BOOL active) {
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    W7SetStroke(ctx, kFrameOuterLine, active ? kFrameOuterActive : kFrameOuterInactive);
    CGContextAddPath(ctx, outer);
    CGContextStrokePath(ctx);
    if (inner) {
        W7SetStroke(ctx, 0xFFFFFF, kFrameInnerLine);
        CGContextAddPath(ctx, inner);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);
}

void W7DrawGlassFrame(CGContextRef ctx, CGRect rect, BOOL active) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, W7RoundedPath(rect, 6));
    CGContextClip(ctx);
    W7DrawGlassFill(ctx, rect, active);
    CGContextRestoreGState(ctx);
    W7StrokeFrameLines(ctx, W7RoundedPath(CGRectInset(rect, 0.5, 0.5), 6), W7RoundedPath(CGRectInset(rect, 1.5, 1.5), 5), active);
}

void W7DrawCaptionGlassSlice(CGContextRef ctx, CGRect slice, CGRect glassRect, BOOL active) {
    if (CGRectIsEmpty(slice)) return;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, slice);
    W7SetFill(ctx, kGlassBackdrop, 1);
    CGContextFillRect(ctx, slice);
    W7DrawGlassFill(ctx, glassRect, active);
    W7SetFill(ctx, 0xFFFFFF, kFrameInnerLine);
    CGContextFillRect(ctx, CGRectMake(glassRect.origin.x, CGRectGetMaxY(glassRect) - 2, glassRect.size.width, 1));
    CGContextRestoreGState(ctx);
}

void W7DrawGlassCaption(CGContextRef ctx, CGRect glassRect, BOOL active) {
    W7DrawCaptionGlassSlice(ctx, glassRect, glassRect, active);
}

/// Adds a rect whose top corners are rounded by `top` and bottom corners by `bottom` (each clamped to half
/// the shorter side), non-flipped.
static void W7AddRoundedRect(CGMutablePathRef p, CGRect r, CGFloat top, CGFloat bottom) {
    CGFloat lim = MIN(r.size.width, r.size.height) / 2;
    top = MAX(0, MIN(top, lim));
    bottom = MAX(0, MIN(bottom, lim));
    CGFloat x0 = CGRectGetMinX(r), x1 = CGRectGetMaxX(r), y0 = CGRectGetMinY(r), y1 = CGRectGetMaxY(r);
    CGPathMoveToPoint(p, NULL, x0 + bottom, y0);
    CGPathAddArcToPoint(p, NULL, x1, y0, x1, y1, bottom);
    CGPathAddArcToPoint(p, NULL, x1, y1, x0, y1, top);
    CGPathAddArcToPoint(p, NULL, x0, y1, x0, y0, top);
    CGPathAddArcToPoint(p, NULL, x0, y0, x1, y0, bottom);
    CGPathCloseSubpath(p);
}


#pragma mark - Window corners

/// How far inside the window's top corner arcs the overlay paints: more than along the straight edges, so the
/// antialiased rim of the window's arc and the edge line WindowServer draws on it stay clear of the overlay's
/// own antialiased rim (at 1× both are a pixel wide), where caption glass meets caption glass. At the bottom
/// corners, glass meets the window's content, an edge anyway: there the arcs keep W7FrameEdgeCover, with no step.
static const CGFloat kFrameTopArcCover = 2;

/// One corner of the window's inside, continuing a counter-clockwise path: `corner` is the window's corner point,
/// (`sx`, `sy`) point inwards from it, `r` is the window's radius there and `from` the angle (degrees) where
/// its arc starts. From the straight edge W7FrameEdgeCover in, a step to `k` in, the arc concentric with the
/// window's, and a step back out; a corner too small for that is square, W7FrameEdgeCover in.
static void W7AddInnerCorner(CGMutablePathRef p, CGPoint corner, CGFloat sx, CGFloat sy, CGFloat r, CGFloat from, CGFloat k) {
    CGFloat e = W7FrameEdgeCover;
    if (r <= k) {
        CGPathAddLineToPoint(p, NULL, corner.x + sx * e, corner.y + sy * e);
        return;
    }
    CGPoint c = CGPointMake(corner.x + sx * r, corner.y + sy * r);
    CGFloat a0 = from * M_PI / 180, a1 = (from + 90) * M_PI / 180;
    // The window's arc runs from c + r·(cos a0, sin a0) to c + r·(cos a1, sin a1).
    CGPathAddLineToPoint(p, NULL, c.x + (r - e) * cos(a0), c.y + (r - e) * sin(a0));
    CGPathAddArc(p, NULL, c.x, c.y, r - k, a0, a1, false);
    CGPathAddLineToPoint(p, NULL, c.x + (r - e) * cos(a1), c.y + (r - e) * sin(a1));
}

/// The window's inside, which the overlay leaves alone: `hole` inset by W7FrameEdgeCover, its corners inside
/// the window's own corner arcs, concentric (radii clamped as the window's shape clamps them).
static void W7AddFrameInnerPath(CGMutablePathRef p, CGRect hole, CGFloat top, CGFloat bottom) {
    CGFloat lim = MIN(hole.size.width, hole.size.height) / 2, e = W7FrameEdgeCover, kt = kFrameTopArcCover;
    CGFloat t = MAX(0, MIN(top, lim)), b = MAX(0, MIN(bottom, lim));
    CGFloat x0 = CGRectGetMinX(hole), x1 = CGRectGetMaxX(hole), y0 = CGRectGetMinY(hole), y1 = CGRectGetMaxY(hole);
    if (CGRectIsEmpty(CGRectInset(hole, e, e))) return;
    CGPathMoveToPoint(p, NULL, x0 + (b > e ? b : e), y0 + e);
    W7AddInnerCorner(p, CGPointMake(x1, y0), -1, 1, b, 270, e);    // bottom right
    W7AddInnerCorner(p, CGPointMake(x1, y1), -1, -1, t, 0, kt);    // top right
    W7AddInnerCorner(p, CGPointMake(x0, y1), 1, -1, t, 90, kt);    // top left
    W7AddInnerCorner(p, CGPointMake(x0, y0), 1, 1, b, 180, e);     // bottom left
    CGPathCloseSubpath(p);
}

W7FrameCornerWedges W7FrameCornerWedgeRects(CGRect hole, CGFloat top, CGFloat bottom, BOOL maximized) {
    W7FrameCornerWedges w = { CGRectNull, CGRectNull, CGRectNull, CGRectNull };
    if (CGRectIsEmpty(hole)) return w;
    CGFloat lim = MIN(hole.size.width, hole.size.height) / 2;
    top = MIN(top, lim);
    bottom = maximized ? 0 : MIN(bottom, lim);
    CGFloat x0 = CGRectGetMinX(hole), x1 = CGRectGetMaxX(hole), y0 = CGRectGetMinY(hole), y1 = CGRectGetMaxY(hole);
    if (top > 0) {
        CGFloat s = top + W7FrameEdgeCover;
        w.topLeft = CGRectMake(x0, y1 - s, s, s);
        w.topRight = CGRectMake(x1 - s, y1 - s, s, s);
    }
    if (bottom > 0) {
        CGFloat s = bottom + W7FrameEdgeCover;
        w.bottomLeft = CGRectMake(x0, y0, s, s);
        w.bottomRight = CGRectMake(x1 - s, y0, s, s);
    }
    return w;
}

CGPathRef W7CreateFrameCoverPath(CGRect hole, CGFloat top, CGFloat bottom, BOOL maximized) {
    if (CGRectIsEmpty(hole)) return CGPathCreateMutable();
    CGRect outer = hole;
    if (maximized) {
        CGFloat rows = MIN(hole.size.height, MAX(0, MIN(top, MIN(hole.size.width, hole.size.height) / 2)) + W7FrameEdgeCover);
        outer = CGRectMake(hole.origin.x, CGRectGetMaxY(hole) - rows, hole.size.width, rows);
    }
    CGPathRef outerPath = CGPathCreateWithRect(outer, NULL);
    CGMutablePathRef innerPath = CGPathCreateMutable();
    W7AddFrameInnerPath(innerPath, hole, top, bottom);
    CGPathRef cover = CGPathCreateCopyBySubtractingPath(outerPath, innerPath, false);
    CGPathRelease(outerPath);
    CGPathRelease(innerPath);
    return cover ?: CGPathCreateMutable();
}

/// Erases from the current transparency layer everything outside `keep` and inside `cut` (both filled
/// non-zero). Cutting a layer drawn whole, rather than clipping each fill, keeps antialiased edge pixels the
/// colour of the glass (each clipped fill would blend in its own share at the edge), so the overlay's rim over
/// the window's own glass leaves no lighter line.
static void W7CutLayer(CGContextRef ctx, CGRect bounds, CGPathRef keep, CGPathRef _Nullable cut) {
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeDestinationOut);
    CGContextSetGrayFillColor(ctx, 0, 1);
    CGContextAddRect(ctx, CGRectInset(bounds, -1, -1));
    CGContextAddPath(ctx, keep);
    CGContextEOFillPath(ctx);
    if (cut && !CGPathIsEmpty(cut)) {
        CGContextAddPath(ctx, cut);
        CGContextFillPath(ctx);
    }
    CGContextRestoreGState(ctx);
}

void W7DrawMaximizedFrameCorners(CGContextRef ctx, CGRect hole, CGFloat top, CGFloat captionHeight, BOOL active) {
    if (CGRectIsEmpty(hole)) return;
    CGFloat lim = MIN(hole.size.width, hole.size.height) / 2;
    CGFloat rows = MIN(hole.size.height, MAX(0, MIN(top, lim)) + W7FrameEdgeCover);
    CGRect band = CGRectMake(hole.origin.x, CGRectGetMaxY(hole) - rows, hole.size.width, rows);
    captionHeight = MAX(0, MIN(captionHeight, hole.size.height));
    CGRect glass = CGRectMake(hole.origin.x, CGRectGetMaxY(hole) - captionHeight, hole.size.width, captionHeight);
    CGMutablePathRef inside = CGPathCreateMutable();
    W7AddFrameInnerPath(inside, hole, top, 0);
    CGPathRef keep = CGPathCreateWithRect(band, NULL);
    CGContextSaveGState(ctx);
    CGContextBeginTransparencyLayerWithRect(ctx, band, NULL);
    W7DrawCaptionGlassSlice(ctx, glass, glass, active);
    W7CutLayer(ctx, glass, keep, inside);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
    CGPathRelease(keep);
    CGPathRelease(inside);
}

size_t W7FrameRingStrips(CGRect bounds, CGRect hole, CGFloat top, CGFloat bottom, CGRect strips[4]) {
    CGFloat lim = MIN(hole.size.width, hole.size.height) / 2, e = W7FrameEdgeCover;
    CGFloat t = MAX(0, MIN(top, lim)), b = MAX(0, MIN(bottom, lim));
    // Top: the outer rounded corners, the inner line's arcs, the window's top edge and top wedges.
    CGFloat yTop = floor(MIN(CGRectGetMaxY(hole) - t - 2 * e, CGRectGetMaxY(bounds) - W7FrameOuterRadius - 2));
    // Bottom: the frame below the window, its bottom edge and bottom wedges.
    CGFloat yBottom = ceil(MAX(CGRectGetMinY(hole) + b + 2 * e, CGRectGetMinY(bounds) + 2));
    // Sides: the frame and the window's side edges.
    CGFloat xLeft = ceil(CGRectGetMinX(hole) + e), xRight = floor(CGRectGetMaxX(hole) - e);
    if (CGRectIsEmpty(hole) || yBottom >= yTop || xLeft >= xRight || yTop >= CGRectGetMaxY(bounds)
        || yBottom <= CGRectGetMinY(bounds) || xLeft <= CGRectGetMinX(bounds) || xRight >= CGRectGetMaxX(bounds)) {
        strips[0] = bounds;
        return 1;
    }
    CGFloat x0 = CGRectGetMinX(bounds), x1 = CGRectGetMaxX(bounds), y0 = CGRectGetMinY(bounds), y1 = CGRectGetMaxY(bounds);
    strips[0] = CGRectMake(x0, yTop, x1 - x0, y1 - yTop);
    strips[1] = CGRectMake(x0, y0, x1 - x0, yBottom - y0);
    strips[2] = CGRectMake(x0, yBottom, xLeft - x0, yTop - yBottom);
    strips[3] = CGRectMake(xRight, yBottom, x1 - xRight, yTop - yBottom);
    return 4;
}

void W7DrawFrameBorder(CGContextRef ctx, CGRect bounds, CGRect hole, CGFloat holeTopRadius, CGFloat holeBottomRadius,
                       CGFloat captionHeight, BOOL active) {
    // The ring: `bounds` less the window's inside, so it reaches W7FrameEdgeCover into the window and over its
    // corner wedges.
    CGMutablePathRef outside = CGPathCreateMutable(), inside = CGPathCreateMutable();
    W7AddRoundedRect(outside, bounds, W7FrameOuterRadius, 0);
    if (!CGRectIsEmpty(hole)) W7AddFrameInnerPath(inside, hole, holeTopRadius, holeBottomRadius);
    captionHeight = MAX(0, MIN(captionHeight, bounds.size.height));
    CGRect band = CGRectMake(bounds.origin.x, CGRectGetMaxY(bounds) - captionHeight, bounds.size.width, captionHeight);
    CGRect below = CGRectMake(bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height - captionHeight);
    CGMutablePathRef innerLine = CGPathCreateMutable();
    W7AddRoundedRect(innerLine, CGRectInset(bounds, 1.5, 1.5), W7FrameOuterRadius - 1, 0);

    // The glass and the white inner line (just inside the outer one), drawn whole into a layer cut to the ring,
    // one small layer per strip of the ring (never one the size of the window: the overlay redraws on every
    // live-resize frame). The strips meet on whole points, so their edges need no antialiasing.
    CGRect strips[4];
    size_t count = W7FrameRingStrips(bounds, hole, holeTopRadius, holeBottomRadius, strips);
    for (size_t i = 0; i < count; i++) {
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, strips[i]);
        CGContextBeginTransparencyLayerWithRect(ctx, strips[i], NULL);
        W7SetFill(ctx, kGlassBackdrop, 1);
        CGContextFillRect(ctx, strips[i]);
        if (captionHeight > 0) {
            // Row for row the caption's glass: the base gradient and the gloss run over the caption band only.
            W7DrawGlassFill(ctx, band, active);
            W7GlassBaseAndTint(ctx, below, band, active, YES);
        } else {
            W7GlassBaseAndTint(ctx, bounds, bounds, active, NO);
        }
        CGContextSetLineWidth(ctx, 1);
        W7SetStroke(ctx, 0xFFFFFF, kFrameInnerLine);
        CGContextAddPath(ctx, innerLine);
        CGContextStrokePath(ctx);
        W7CutLayer(ctx, strips[i], outside, inside);
        CGContextEndTransparencyLayer(ctx);
        CGContextRestoreGState(ctx);
    }

    // The outer line runs round the whole outside, across the window's top edge too.
    CGMutablePathRef outerLine = CGPathCreateMutable();
    W7AddRoundedRect(outerLine, CGRectInset(bounds, 0.5, 0.5), W7FrameOuterRadius, 0);
    W7StrokeFrameLines(ctx, outerLine, NULL, active);
    CGPathRelease(outerLine);
    CGPathRelease(innerLine);
    CGPathRelease(outside);
    CGPathRelease(inside);
}

void W7DrawMessageBoxBackground(CGContextRef ctx, CGRect bounds, CGFloat stripTop, CGFloat captionHeight, BOOL active) {
    CGContextSaveGState(ctx);
    W7SetFill(ctx, 0xFFFFFF, 1);
    CGContextFillRect(ctx, bounds);
    stripTop = MAX(0, MIN(stripTop, bounds.size.height));
    if (stripTop > 0) {
        W7SetFill(ctx, 0xF0F0F0, 1);
        CGContextFillRect(ctx, CGRectMake(bounds.origin.x, bounds.origin.y, bounds.size.width, stripTop));
        W7SetFill(ctx, 0xDFDFDF, 1);
        CGContextFillRect(ctx, CGRectMake(bounds.origin.x, bounds.origin.y + stripTop, bounds.size.width, 1));
    }
    if (captionHeight > 0) {
        CGRect band = CGRectMake(bounds.origin.x, CGRectGetMaxY(bounds) - captionHeight, bounds.size.width, captionHeight);
        W7DrawGlassFill(ctx, band, active);
        W7SetFill(ctx, kFrameOuterLine, active ? kFrameOuterActive : kFrameOuterInactive);
        CGContextFillRect(ctx, CGRectMake(band.origin.x, band.origin.y, band.size.width, 1));
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Caption buttons

// Caption glyphs, as Windows 7 Aero draws them on every caption button: white, 1.8 pt, with a 1 pt dark
// outline all round (#1F2F45 at 0.8).
static const CGFloat kGlyphWidth = 1.8, kGlyphOutline = 1;
static const uint32_t kGlyphOutlineColor = 0x1F2F45;
static const CGFloat kGlyphOutlineAlpha = 0.8;

/// Strokes `path` twice: the outline (the glyph width plus 1 pt on each side), then the white glyph on top.
static void W7StrokeGlyph(CGContextRef ctx, void (^path)(CGFloat dx, CGFloat dy)) {
    CGContextSetLineCap(ctx, kCGLineCapSquare);
    CGContextSetLineJoin(ctx, kCGLineJoinMiter);
    CGContextSetLineWidth(ctx, kGlyphWidth + 2 * kGlyphOutline);
    W7SetStroke(ctx, kGlyphOutlineColor, kGlyphOutlineAlpha);
    path(0, 0);
    CGContextStrokePath(ctx);
    CGContextSetLineWidth(ctx, kGlyphWidth);
    W7SetStroke(ctx, 0xFFFFFF, 1);
    path(0, 0);
    CGContextStrokePath(ctx);
}

/// The button's outline: the caption buttons hang from the frame top as one strip, so the top corners
/// are square and only the group's outer bottom corners (minimize bottom-left, close bottom-right) round.
static CGPathRef W7CaptionShape(CGRect r, W7CaptionKind kind) {
    CGFloat bl = kind == W7CaptionMinimize ? 4 : 0, br = kind == W7CaptionClose ? 4 : 0;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, CGRectGetMinX(r), CGRectGetMaxY(r));
    CGPathAddLineToPoint(p, NULL, CGRectGetMaxX(r), CGRectGetMaxY(r));
    CGPathAddArcToPoint(p, NULL, CGRectGetMaxX(r), CGRectGetMinY(r), CGRectGetMinX(r), CGRectGetMinY(r), br);
    CGPathAddArcToPoint(p, NULL, CGRectGetMinX(r), CGRectGetMinY(r), CGRectGetMinX(r), CGRectGetMaxY(r), bl);
    CGPathCloseSubpath(p);
    return (CGPathRef)CFAutorelease(p);
}

void W7DrawCaptionButton(CGContextRef ctx, CGRect rect, W7CaptionKind kind, W7ControlState state) {
    CGContextSaveGState(ctx);
    if (state == W7StateDisabled) CGContextSetAlpha(ctx, 0.4);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, W7CaptionShape(rect, kind));
    CGContextClip(ctx);
    BOOL close = kind == W7CaptionClose;
    if (close) {
        // #C75050 → #D7584B (top → bottom) under a light gloss on the top half; hover brighter,
        // pressed darker.
        if (state == W7StatePressed) W7FillVertical(ctx, rect, 0x9E3A32, 1, 0xB0463A, 1);
        else if (state == W7StateHover) W7FillVertical(ctx, rect, 0xE3695C, 1, 0xF0745A, 1);
        else W7FillVertical(ctx, rect, 0xC75050, 1, 0xD7584B, 1);
        CGRect top = CGRectMake(rect.origin.x, CGRectGetMidY(rect), rect.size.width, rect.size.height / 2);
        W7FillVertical(ctx, top, 0xFFFFFF, state == W7StatePressed ? 0.15 : 0.32, 0xFFFFFF, 0.05);
    } else {
        if (state == W7StatePressed) { W7SetFill(ctx, 0x1E5F9E, 1); CGContextFillRect(ctx, rect); }
        else if (state == W7StateHover) W7FillVertical(ctx, rect, 0xBCE1FA, 1, 0x4AA2DE, 1);
        else W7FillVertical(ctx, rect, 0xFFFFFF, 0.25, 0xFFFFFF, 0.05);
    }
    CGContextRestoreGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    W7SetStroke(ctx, 0xFFFFFF, 0.35);
    CGContextAddPath(ctx, W7CaptionShape(CGRectInset(rect, 1.5, 1.5), kind));
    CGContextStrokePath(ctx);
    if (close) W7SetStroke(ctx, 0x4C1F1F, 1);
    else W7SetStroke(ctx, 0x000000, 0.4);
    CGContextAddPath(ctx, W7CaptionShape(CGRectInset(rect, 0.5, 0.5), kind));
    CGContextStrokePath(ctx);

    CGFloat cx = CGRectGetMidX(rect), cy = CGRectGetMidY(rect);
    switch (kind) {
        case W7CaptionClose:
            W7StrokeGlyph(ctx, ^(CGFloat dx, CGFloat dy) {
                CGContextMoveToPoint(ctx, cx - 4 + dx, cy + 3.5 + dy);
                CGContextAddLineToPoint(ctx, cx + 4 + dx, cy - 3.5 + dy);
                CGContextMoveToPoint(ctx, cx - 4 + dx, cy - 3.5 + dy);
                CGContextAddLineToPoint(ctx, cx + 4 + dx, cy + 3.5 + dy);
            });
            break;
        case W7CaptionMinimize:
            W7StrokeGlyph(ctx, ^(CGFloat dx, CGFloat dy) {
                CGContextMoveToPoint(ctx, cx - 4 + dx, cy - 2.5 + dy);
                CGContextAddLineToPoint(ctx, cx + 4 + dx, cy - 2.5 + dy);
            });
            break;
        case W7CaptionMaximize:
            W7StrokeGlyph(ctx, ^(CGFloat dx, CGFloat dy) {
                CGContextAddRect(ctx, CGRectMake(cx - 4 + dx, cy - 3 + dy, 8, 6));
            });
            break;
        case W7CaptionRestore:
            W7StrokeGlyph(ctx, ^(CGFloat dx, CGFloat dy) {
                CGContextAddRect(ctx, CGRectMake(cx - 4 + dx, cy - 3 + dy, 5.5, 4.5));
                CGContextMoveToPoint(ctx, cx - 2 + dx, cy + 3 + dy);
                CGContextAddLineToPoint(ctx, cx + 4 + dx, cy + 3 + dy);
                CGContextAddLineToPoint(ctx, cx + 4 + dx, cy - 1.5 + dy);
            });
            break;
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Taskbar

void W7DrawTaskbarBackground(CGContextRef ctx, CGRect rect) {
    // Light glass, flat (no gloss), with a dark top line and a light line under it. The taskbar window
    // puts a dark HUD blur under this drawing, so what is behind the bar never shows sharply; the tint
    // is calibrated on that blur (see DrawingTests.taskbarOverBlurredWallpaperMatchesReference).
    CGContextSaveGState(ctx);
    W7SetFill(ctx, 0x3B97DB, 0.50);
    CGContextFillRect(ctx, rect);
    W7SetFill(ctx, 0x000000, 0.80);
    CGContextFillRect(ctx, CGRectMake(rect.origin.x, CGRectGetMaxY(rect) - 1, rect.size.width, 1));
    W7SetFill(ctx, 0xFFFFFF, 0.50);
    CGContextFillRect(ctx, CGRectMake(rect.origin.x, CGRectGetMaxY(rect) - 2, rect.size.width, 1));
    CGContextRestoreGState(ctx);
}

static void W7TaskbarButtonBody(CGContextRef ctx, CGRect rect, BOOL active, BOOL hover, CGColorRef _Nullable glow);

void W7DrawTaskbarButton(CGContextRef ctx, CGRect rect, BOOL running, BOOL active, BOOL hover) {
    W7DrawTaskbarGroupButton(ctx, rect, running, active, hover, 1, NULL);
}

void W7DrawTaskbarGroupButton(CGContextRef ctx, CGRect rect, BOOL running, BOOL active, BOOL hover,
                              NSInteger windowCount, CGColorRef glow) {
    if (!running && !active && !hover) return;
    // Windows 7's grouped look: the front button narrows and one edge (two windows) or two edges
    // (three or more) of the buttons "behind" it show 3 pt apart to its right.
    NSInteger depth = running ? MIN(2, MAX(0, windowCount - 1)) : 0;
    CGRect front = rect;
    front.size.width -= 3 * depth;
    for (NSInteger k = depth; k >= 1; k--) {
        CGRect edge = CGRectOffset(front, 3 * k, 0);
        CGContextSaveGState(ctx);
        // Only the part outside the button in front of it.
        CGContextAddRect(ctx, edge);
        CGPathRef inFront = W7RoundedPath(CGRectOffset(front, 3 * (k - 1), 0), 3);
        CGContextAddPath(ctx, inFront);
        CGContextEOClip(ctx);
        W7TaskbarButtonBody(ctx, edge, NO, NO, NULL);
        CGContextRestoreGState(ctx);
    }
    W7TaskbarButtonBody(ctx, front, active, hover, glow);
}

static void W7TaskbarButtonBody(CGContextRef ctx, CGRect rect, BOOL active, BOOL hover, CGColorRef glow) {
    // Framed glass: a white gloss fading down over the top three quarters, a dark outer line and a
    // light inner line. Active is brightest, hover next, an idle running button faintest.
    CGFloat glossTop = active ? 0.73 : (hover ? 0.42 : 0.22);
    CGFloat glossBottom = active ? 0.08 : (hover ? 0.10 : 0.04);
    CGFloat outer = active ? 0.60 : (hover ? 0.50 : 0.42);
    CGFloat inner = active ? 0.55 : (hover ? 0.45 : 0.32);
    CGContextSaveGState(ctx);
    CGPathRef body = W7RoundedPath(rect, 3);
    CGContextAddPath(ctx, body);
    CGContextClip(ctx);
    CGFloat fadeH = rect.size.height * 0.75;
    W7SetFill(ctx, 0xFFFFFF, glossBottom);
    CGContextFillRect(ctx, CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height - fadeH));
    W7FillVertical(ctx, CGRectMake(rect.origin.x, CGRectGetMaxY(rect) - fadeH, rect.size.width, fadeH),
                   0xFFFFFF, glossTop, 0xFFFFFF, glossBottom);
    if (hover && glow) {
        // Hot-track: a glow in the icon's colour rising from the bottom middle.
        CGColorRef from = CGColorCreateCopyWithAlpha(glow, 0.75), to = CGColorCreateCopyWithAlpha(glow, 0);
        if (from && to) {
            CGColorRef cs[2] = { from, to };
            CFArrayRef arr = CFArrayCreate(NULL, (const void **)cs, 2, &kCFTypeArrayCallBacks);
            CGGradientRef g = CGGradientCreateWithColors(W7RGB(), arr, NULL);
            CGPoint c = CGPointMake(CGRectGetMidX(rect), rect.origin.y);
            CGContextDrawRadialGradient(ctx, g, c, 0, c, MAX(rect.size.width, rect.size.height) * 0.8, 0);
            CGGradientRelease(g);
            CFRelease(arr);
        }
        if (from) CGColorRelease(from);
        if (to) CGColorRelease(to);
    }
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    W7SetStroke(ctx, 0xFFFFFF, inner);
    CGContextAddPath(ctx, W7RoundedPath(CGRectInset(rect, 1.5, 1.5), 2));
    CGContextStrokePath(ctx);
    W7SetStroke(ctx, 0x000000, outer);
    CGContextAddPath(ctx, W7RoundedPath(CGRectInset(rect, 0.5, 0.5), 3));
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawStartOrb(CGContextRef ctx, CGRect rect, W7ControlState state, CGImageRef customOrb) {
    if (customOrb) {
        CGContextSaveGState(ctx);
        CGContextSetAlpha(ctx, state == W7StateDisabled ? 0.4 : 1);
        // Orb frames are square: aspect-fit in the middle of the (wider) hit rect.
        CGFloat side = MIN(rect.size.width, rect.size.height);
        CGContextDrawImage(ctx, CGRectMake(CGRectGetMidX(rect) - side / 2, CGRectGetMidY(rect) - side / 2, side, side), customOrb);
        CGContextRestoreGState(ctx);
        return;
    }
    // Windows 7's orb is 0.9 of the bar height: a deep blue glass body, a cyan glow rising from the
    // bottom, a white gloss cap over the top half and a dark rim with a faint light halo.
    CGFloat d = round(MIN(rect.size.width, rect.size.height) * 0.9);
    CGRect o = CGRectMake(round(CGRectGetMidX(rect) - d / 2), round(CGRectGetMidY(rect) - d / 2), d, d);
    CGPoint c = CGPointMake(CGRectGetMidX(o), CGRectGetMidY(o));
    uint32_t top = 0x1B5486, bottom = 0x062F55, glow = 0x22E2FF;
    CGFloat glowR = 0.55;
    if (state == W7StateHover) { top = 0x2A6FA8; bottom = 0x0B4475; glow = 0x7CF3FF; glowR = 0.66; }
    else if (state == W7StatePressed) { top = 0x123F68; bottom = 0x03203C; glow = 0x0FB0E0; glowR = 0.45; }
    CGContextSaveGState(ctx);
    if (state == W7StateDisabled) CGContextSetAlpha(ctx, 0.4);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, o);
    CGContextClip(ctx);
    W7FillVertical(ctx, o, top, 1, bottom, 1);
    CGColorRef gc[2] = { W7Color(glow, 1), W7Color(glow, 0) };
    CFArrayRef garr = CFArrayCreate(NULL, (const void **)gc, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7RGB(), garr, NULL);
    CGPoint gcenter = CGPointMake(c.x, o.origin.y + d * 0.04);
    CGContextDrawRadialGradient(ctx, g, gcenter, 0, gcenter, d * glowR, 0);
    CGGradientRelease(g);
    CFRelease(garr);
    CGRect gloss = CGRectMake(o.origin.x + d * 0.08, c.y - d * 0.02, d * 0.84, d * 0.49);
    CGContextAddEllipseInRect(ctx, gloss);
    CGContextClip(ctx);
    W7FillVertical(ctx, gloss, 0xFFFFFF, state == W7StatePressed ? 0.55 : 0.80, 0xFFFFFF, 0.12);
    CGContextRestoreGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    W7SetStroke(ctx, 0x022A4A, 0.9);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(o, 0.5, 0.5));
    W7SetStroke(ctx, 0xFFFFFF, 0.35);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(o, -0.5, -0.5));

    // Four-pane flag glyph, about half the orb.
    CGFloat s = d * 0.21, gap = d * 0.035;
    CGFloat x0 = c.x - s - gap / 2, y0 = c.y - s - gap / 2;
    uint32_t cols[4] = { 0xF25022, 0x7FBA00, 0x00A4EF, 0xFFB900 };   // TL, TR, BL, BR
    for (int i = 0; i < 4; i++) {
        int col = i % 2, row = i / 2;   // row 0 = top
        CGRect p = CGRectMake(x0 + col * (s + gap), y0 + (1 - row) * (s + gap), s, s);
        W7SetFill(ctx, cols[i], 1);
        CGContextFillRect(ctx, p);
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Menus

void W7DrawMenuBackground(CGContextRef ctx, CGRect rect, CGFloat gutterWidth) {
    CGContextSaveGState(ctx);
    W7SetFill(ctx, 0xF0F0F0, 1);
    CGContextFillRect(ctx, rect);
    if (gutterWidth > 0) {
        CGRect g = CGRectMake(rect.origin.x, rect.origin.y, gutterWidth, rect.size.height);
        W7SetFill(ctx, 0xF1F1F1, 1);
        CGContextFillRect(ctx, g);
        W7SetFill(ctx, 0xE2E3E3, 1);
        CGContextFillRect(ctx, CGRectMake(CGRectGetMaxX(g), rect.origin.y, 1, rect.size.height));
    }
    CGContextRestoreGState(ctx);
}

void W7DrawMenuHighlight(CGContextRef ctx, CGRect rect) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, W7RoundedPath(rect, 3));
    CGContextClip(ctx);
    W7FillVertical(ctx, rect, 0xF2F8FD, 1, 0xDCEBFC, 1);
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    W7SetStroke(ctx, 0xAECFF7, 1);
    CGContextAddPath(ctx, W7RoundedPath(CGRectInset(rect, 0.5, 0.5), 3));
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawMenuStripBackground(CGContextRef ctx, CGRect rect) {
    W7FillVertical(ctx, rect, 0xF5F6F7, 1, 0xDDE4EE, 1);
}

#pragma mark - Explorer

const uint32_t W7ExplorerTextHex = 0x1E395B;
const uint32_t W7ColumnHeaderTextHex = 0x4C607A;

/// Fills `path` (already in the context's coordinates) with a vertical two-stop gradient over `r`.
static void W7FillPathVertical(CGContextRef ctx, CGPathRef path, CGRect r, uint32_t top, CGFloat ta, uint32_t bot, CGFloat ba) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    W7FillVertical(ctx, r, top, ta, bot, ba);
    CGContextRestoreGState(ctx);
}

static void W7StrokePath(CGContextRef ctx, CGPathRef path, uint32_t hex, CGFloat a, CGFloat width) {
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, width);
    W7SetStroke(ctx, hex, a);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawNavButton(CGContextRef ctx, CGRect rect, BOOL forward, W7ControlState state) {
    CGFloat d = MIN(rect.size.width, rect.size.height);
    CGRect o = CGRectMake(CGRectGetMidX(rect) - d / 2, CGRectGetMidY(rect) - d / 2, d, d);
    CGPoint c = CGPointMake(CGRectGetMidX(o), CGRectGetMidY(o));
    // Windows 7's glossy orb: a vertical blue body, a cyan glow rising from the bottom, a bright gloss
    // cap over the top, and a dark rim. Disabled orbs are grey.
    uint32_t top = 0x3F7FCB, bottom = 0x1B4F9C, glow = 0x5CC8FF, rim = 0x1A3F73;
    CGFloat glowA = 0.85;
    switch (state) {
        case W7StateHover: top = 0x5196E0; bottom = 0x2264B8; glow = 0x8BE0FF; glowA = 1; break;
        case W7StatePressed: top = 0x2A62A8; bottom = 0x123C78; glow = 0x3FA6E8; glowA = 0.7; break;
        case W7StateDisabled: top = 0xC4CCD6; bottom = 0x96A2B2; glow = 0xD8DEE6; rim = 0x7D8898; glowA = 0.6; break;
        default: break;
    }
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, o);
    CGContextClip(ctx);
    W7FillVertical(ctx, o, top, 1, bottom, 1);
    // Glow from the bottom centre.
    CGColorRef cols[2] = { W7Color(glow, glowA), W7Color(glow, 0) };
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7RGB(), arr, NULL);
    CGPoint gc = CGPointMake(c.x, o.origin.y);
    CGContextDrawRadialGradient(ctx, g, gc, 0, gc, d * 0.62, 0);
    CGGradientRelease(g);
    CFRelease(arr);
    // Gloss cap; a pressed orb loses most of it.
    CGRect gloss = CGRectMake(o.origin.x + d * 0.12, c.y - d * 0.02, d * 0.76, d * 0.5);
    CGContextAddEllipseInRect(ctx, gloss);
    CGContextClip(ctx);
    W7FillVertical(ctx, gloss, 0xFFFFFF, state == W7StatePressed ? 0.35 : 0.75, 0xFFFFFF, 0.08);
    CGContextRestoreGState(ctx);
    W7StrokePath(ctx, (CGPathRef)CFAutorelease(CGPathCreateWithEllipseInRect(CGRectInset(o, 0.5, 0.5), NULL)), rim, 0.9, 1);

    // Arrow: shaft plus head, pointing left (back) or right (forward), with a soft dark shadow.
    CGFloat dir = forward ? 1 : -1, len = d * 0.2, head = d * 0.17;
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, MAX(1.8, d * 0.11));
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    for (int pass = 0; pass < 2; pass++) {
        CGFloat dy = pass == 0 ? -0.8 : 0;
        if (pass == 0) W7SetStroke(ctx, 0x0B2850, state == W7StateDisabled ? 0.15 : 0.35);
        else W7SetStroke(ctx, 0xFFFFFF, state == W7StateDisabled ? 0.9 : 1);
        CGContextMoveToPoint(ctx, c.x - dir * len, c.y + dy);
        CGContextAddLineToPoint(ctx, c.x + dir * len, c.y + dy);
        CGContextMoveToPoint(ctx, c.x + dir * (len - head), c.y + head + dy);
        CGContextAddLineToPoint(ctx, c.x + dir * len, c.y + dy);
        CGContextAddLineToPoint(ctx, c.x + dir * (len - head), c.y - head + dy);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);
}

void W7DrawNavTrough(CGContextRef ctx, CGRect rect) {
    CGFloat r = rect.size.height / 2;
    CGPathRef path = W7RoundedPath(CGRectInset(rect, 0.5, 0.5), r);
    W7FillPathVertical(ctx, path, rect, 0x0E2A4F, 0.28, 0xFFFFFF, 0.30);
    W7StrokePath(ctx, path, 0x0E2A4F, 0.35, 1);
    // Light lower lip, as if the trough were pressed into the glass.
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(rect.origin.x, rect.origin.y - 1, rect.size.width, r));
    W7StrokePath(ctx, W7RoundedPath(CGRectOffset(CGRectInset(rect, 0.5, 0.5), 0, -1), r), 0xFFFFFF, 0.55, 1);
    CGContextRestoreGState(ctx);
}

void W7DrawChevron(CGContextRef ctx, CGPoint center, W7ChevronDirection direction, uint32_t hex, CGFloat alpha) {
    CGContextSaveGState(ctx);
    W7SetFill(ctx, hex, alpha);
    if (direction == W7ChevronDown) {   // ▾ 7×4
        CGContextMoveToPoint(ctx, center.x - 3.5, center.y + 2);
        CGContextAddLineToPoint(ctx, center.x + 3.5, center.y + 2);
        CGContextAddLineToPoint(ctx, center.x, center.y - 2);
    } else if (direction == W7ChevronUp) {   // ▴ 7×4
        CGContextMoveToPoint(ctx, center.x - 3.5, center.y - 2);
        CGContextAddLineToPoint(ctx, center.x + 3.5, center.y - 2);
        CGContextAddLineToPoint(ctx, center.x, center.y + 2);
    } else if (direction == W7ChevronLeft) {   // ◂ 4×7
        CGContextMoveToPoint(ctx, center.x + 2, center.y + 3.5);
        CGContextAddLineToPoint(ctx, center.x - 2, center.y);
        CGContextAddLineToPoint(ctx, center.x + 2, center.y - 3.5);
    } else {      // ▸ 4×7
        CGContextMoveToPoint(ctx, center.x - 2, center.y + 3.5);
        CGContextAddLineToPoint(ctx, center.x + 2, center.y);
        CGContextAddLineToPoint(ctx, center.x - 2, center.y - 3.5);
    }
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawAddressBar(CGContextRef ctx, CGRect rect, BOOL focused) {
    CGContextSaveGState(ctx);
    CGPathRef path = W7RoundedPath(CGRectInset(rect, 0.5, 0.5), 2);
    W7SetFill(ctx, 0xFFFFFF, 1);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGContextSetLineWidth(ctx, 1);
    W7SetStroke(ctx, focused ? 0x3C7FB1 : 0x8E9AAF, 1);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawAddressButton(CGContextRef ctx, CGRect rect, W7ControlState state) {
    if (state == W7StateHover || state == W7StatePressed) {
        CGContextSaveGState(ctx);
        CGRect r = CGRectInset(rect, 1, 1);
        BOOL pressed = state == W7StatePressed;
        W7FillVertical(ctx, r, pressed ? 0xC2E4F6 : 0xEAF6FD, 1, pressed ? 0xA9D9F2 : 0xBEE6FD, 1);
        W7SetFill(ctx, pressed ? 0x2C628B : 0x3C7FB1, 1);
        CGContextFillRect(ctx, CGRectMake(r.origin.x, r.origin.y, 1, r.size.height));
        CGContextFillRect(ctx, CGRectMake(CGRectGetMaxX(r) - 1, r.origin.y, 1, r.size.height));
        CGContextRestoreGState(ctx);
    }
}

void W7DrawRefreshGlyph(CGContextRef ctx, CGRect rect, BOOL enabled) {
    CGPoint c = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat r = 4.5;
    uint32_t col = enabled ? 0x2B70C4 : 0x9AA7B7;
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 1.6);
    W7SetStroke(ctx, col, 1);
    W7SetFill(ctx, col, 1);
    // Two arcs, each ending in an arrowhead (clockwise, like Windows 7's refresh).
    for (int i = 0; i < 2; i++) {
        CGFloat a0 = M_PI * (i == 0 ? 0.95 : -0.05), a1 = a0 - M_PI * 0.72;
        CGContextAddArc(ctx, c.x, c.y, r, a0, a1, 1);
        CGContextStrokePath(ctx);
        CGPoint tip = CGPointMake(c.x + r * cos(a1), c.y + r * sin(a1));
        CGFloat t = a1 - M_PI / 2;   // tangent direction of travel (clockwise)
        CGPoint dirv = CGPointMake(cos(t), sin(t)), norm = CGPointMake(-dirv.y, dirv.x);
        CGContextMoveToPoint(ctx, tip.x + dirv.x * 2.6, tip.y + dirv.y * 2.6);
        CGContextAddLineToPoint(ctx, tip.x + norm.x * 2.4 - dirv.x * 0.6, tip.y + norm.y * 2.4 - dirv.y * 0.6);
        CGContextAddLineToPoint(ctx, tip.x - norm.x * 2.4 - dirv.x * 0.6, tip.y - norm.y * 2.4 - dirv.y * 0.6);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    }
    CGContextRestoreGState(ctx);
}

void W7DrawCommandBar(CGContextRef ctx, CGRect rect) {
    // Windows 7's command bar: a light blue gradient with a brighter top half and a white top line.
    CGRect upper = CGRectMake(rect.origin.x, CGRectGetMidY(rect), rect.size.width, rect.size.height / 2);
    CGRect lower = CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height / 2);
    W7FillVertical(ctx, upper, 0xF5F9FD, 1, 0xE9F0F8, 1);
    W7FillVertical(ctx, lower, 0xDFE9F5, 1, 0xDAE5F3, 1);
    CGContextSaveGState(ctx);
    W7SetFill(ctx, 0xFFFFFF, 0.8);
    CGContextFillRect(ctx, CGRectMake(rect.origin.x, CGRectGetMaxY(rect) - 1, rect.size.width, 1));
    W7SetFill(ctx, 0xA0AFC3, 1);
    CGContextFillRect(ctx, CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, 1));
    CGContextRestoreGState(ctx);
}

void W7DrawCommandButton(CGContextRef ctx, CGRect rect, W7ControlState state) {
    if (state != W7StateHover && state != W7StatePressed) return;
    BOOL pressed = state == W7StatePressed;
    CGPathRef outer = W7RoundedPath(CGRectInset(rect, 0.5, 0.5), 3);
    W7FillPathVertical(ctx, outer, rect, pressed ? 0xDDE8F4 : 0xFCFDFE, pressed ? 1 : 0.95,
                       pressed ? 0xC9D9EC : 0xE2ECF8, pressed ? 1 : 0.95);
    W7StrokePath(ctx, W7RoundedPath(CGRectInset(rect, 1.5, 1.5), 2), 0xFFFFFF, pressed ? 0.3 : 0.75, 1);
    W7StrokePath(ctx, outer, pressed ? 0x6E8FB8 : 0x95AFD3, 1, 1);
}

void W7DrawNavPaneRow(CGContextRef ctx, CGRect rect, BOOL selected, BOOL hover) {
    if (!selected && !hover) return;
    CGPathRef path = W7RoundedPath(CGRectInset(rect, 0.5, 0.5), 2);
    CGContextSaveGState(ctx);
    W7SetFill(ctx, selected ? 0xCCE8FF : 0xE5F3FB, 1);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
    W7StrokePath(ctx, path, selected ? (hover ? 0x70C0E7 : 0x99D1FF) : 0x70C0E7, 1, 1);
}

void W7DrawColumnHeader(CGContextRef ctx, CGRect rect) {
    W7FillVertical(ctx, rect, 0xFFFFFF, 1, 0xF2F2F2, 1);
    CGContextSaveGState(ctx);
    W7SetFill(ctx, 0xD5D5D5, 1);
    CGContextFillRect(ctx, CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, 1));
    CGContextRestoreGState(ctx);
}

void W7DrawColumnHeaderSeparator(CGContextRef ctx, CGFloat x, CGRect rect) {
    CGContextSaveGState(ctx);
    CGRect line = CGRectMake(floor(x), rect.origin.y + 2, 1, rect.size.height - 4);
    W7FillVertical(ctx, line, 0xE3E8EE, 1, 0xD5DCE5, 1);
    CGContextRestoreGState(ctx);
}

void W7DrawDetailsPane(CGContextRef ctx, CGRect rect) {
    W7FillVertical(ctx, rect, 0xFDFEFF, 1, 0xE6EEF7, 1);
    CGContextSaveGState(ctx);
    W7SetFill(ctx, 0xD5DFE5, 1);
    CGContextFillRect(ctx, CGRectMake(rect.origin.x, CGRectGetMaxY(rect) - 1, rect.size.width, 1));
    CGContextRestoreGState(ctx);
}

void W7DrawHelpButton(CGContextRef ctx, CGRect rect) {
    CGFloat d = MIN(rect.size.width, rect.size.height);
    CGRect o = CGRectMake(CGRectGetMidX(rect) - d / 2, CGRectGetMidY(rect) - d / 2, d, d);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, o);
    CGContextClip(ctx);
    W7FillVertical(ctx, o, 0x5C9DE6, 1, 0x1D5BB0, 1);
    CGRect gloss = CGRectMake(o.origin.x + d * 0.15, CGRectGetMidY(o), d * 0.7, d * 0.45);
    CGContextAddEllipseInRect(ctx, gloss);
    CGContextClip(ctx);
    W7FillVertical(ctx, gloss, 0xFFFFFF, 0.6, 0xFFFFFF, 0.05);
    CGContextRestoreGState(ctx);
    W7StrokePath(ctx, (CGPathRef)CFAutorelease(CGPathCreateWithEllipseInRect(CGRectInset(o, 0.5, 0.5), NULL)), 0x1A4A8C, 0.9, 1);
    // The "?" in bold white.
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:round(d * 0.68)],
                             NSForegroundColorAttributeName: NSColor.whiteColor };
    NSSize s = [@"?" sizeWithAttributes:attrs];
    [@"?" drawAtPoint:NSMakePoint(CGRectGetMidX(o) - s.width / 2, CGRectGetMidY(o) - s.height / 2) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
}

void W7DrawSearchBox(CGContextRef ctx, CGRect rect, BOOL focused, BOOL showsClear) {
    W7DrawAddressBar(ctx, rect, focused);
    CGFloat cx = CGRectGetMaxX(rect) - 11, cy = CGRectGetMidY(rect);
    CGContextSaveGState(ctx);
    W7SetStroke(ctx, 0x1E395B, 0.8);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    if (showsClear) {
        CGContextSetLineWidth(ctx, 1.5);
        CGContextMoveToPoint(ctx, cx - 3.5, cy - 3.5);
        CGContextAddLineToPoint(ctx, cx + 3.5, cy + 3.5);
        CGContextMoveToPoint(ctx, cx - 3.5, cy + 3.5);
        CGContextAddLineToPoint(ctx, cx + 3.5, cy - 3.5);
        CGContextStrokePath(ctx);
    } else {
        // Magnifier, its handle down-left as in Windows 7.
        cy += 1.5;
        CGContextSetLineWidth(ctx, 1.5);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - 4, cy - 4, 8, 8));
        CGContextSetLineWidth(ctx, 2);
        CGContextMoveToPoint(ctx, cx - 2.8, cy - 2.8);
        CGContextAddLineToPoint(ctx, cx - 6, cy - 6);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Start menu

CGRect W7StartMenuProgramsRect(CGRect bounds, CGFloat leftPaneWidth) {
    return CGRectMake(bounds.origin.x + 8, bounds.origin.y + 8, leftPaneWidth - 8, bounds.size.height - 18);
}

const CGFloat W7StartMenuSearchBandHeight = 44;

CGRect W7StartMenuSearchBoxRect(CGRect bounds, CGFloat leftPaneWidth) {
    CGRect pane = W7StartMenuProgramsRect(bounds, leftPaneWidth);
    const CGFloat h = 24;
    return CGRectMake(pane.origin.x + 8, pane.origin.y + (W7StartMenuSearchBandHeight - h) / 2, pane.size.width - 16, h);
}

CGRect W7StartMenuUserTileRect(CGRect bounds, CGFloat leftPaneWidth) {
    const CGFloat side = 48;
    CGFloat x = round(bounds.origin.x + leftPaneWidth + (bounds.size.width - leftPaneWidth - side) / 2);
    return CGRectMake(x, CGRectGetMaxY(bounds) - 14 - side, side, side);
}

CGFloat W7StartMenuPlacesTop(BOOL hasUserPicture) { return hasUserPicture ? 78 : 16; }

void W7DrawStartMenuBackground(CGContextRef ctx, CGRect bounds, CGFloat leftPaneWidth, CGFloat searchBandHeight) {
    // Dark glass under everything (the right column and the margins round the programs pane).
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, W7RoundedPath(bounds, 6));
    CGContextClip(ctx);
    W7SetFill(ctx, 0x28465A, 0.85);
    CGContextFillRect(ctx, bounds);
    CGFloat glossH = round(bounds.size.height / 5);
    W7FillVertical(ctx, CGRectMake(bounds.origin.x, CGRectGetMaxY(bounds) - glossH, bounds.size.width, glossH),
                   0xFFFFFF, 0.12, 0xFFFFFF, 0.0);
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx);
    CGContextSetLineWidth(ctx, 1);
    W7SetStroke(ctx, 0x000000, 0.55);
    CGContextAddPath(ctx, W7RoundedPath(CGRectInset(bounds, 0.5, 0.5), 6));
    CGContextStrokePath(ctx);
    W7SetStroke(ctx, 0xFFFFFF, 0.30);
    CGContextAddPath(ctx, W7RoundedPath(CGRectInset(bounds, 1.5, 1.5), 5));
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);

    // The white programs pane, with the light search band along its bottom.
    CGRect pane = W7StartMenuProgramsRect(bounds, leftPaneWidth);
    CGPathRef panePath = W7RoundedPath(pane, 3);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, panePath);
    CGContextClip(ctx);
    W7SetFill(ctx, 0xFFFFFF, 1);
    CGContextFillRect(ctx, pane);
    CGRect band = CGRectMake(pane.origin.x, pane.origin.y, pane.size.width, searchBandHeight);
    W7SetFill(ctx, 0xF1F5FB, 1);
    CGContextFillRect(ctx, band);
    W7SetFill(ctx, 0xD3DEED, 1);
    CGContextFillRect(ctx, CGRectMake(band.origin.x, CGRectGetMaxY(band) - 1, band.size.width, 1));
    CGContextRestoreGState(ctx);
    W7StrokePath(ctx, W7RoundedPath(CGRectInset(pane, 0.5, 0.5), 3), 0x9DB2BF, 1, 1);
}

void W7DrawStartMenuSeparator(CGContextRef ctx, CGFloat minX, CGFloat maxX, CGFloat y) {
    CGContextSaveGState(ctx);
    W7SetFill(ctx, 0x000000, 0.30);
    CGContextFillRect(ctx, CGRectMake(minX, floor(y), maxX - minX, 1));
    W7SetFill(ctx, 0xFFFFFF, 0.15);
    CGContextFillRect(ctx, CGRectMake(minX, floor(y) - 1, maxX - minX, 1));
    CGContextRestoreGState(ctx);
}

void W7DrawUserTileFrame(CGContextRef ctx, CGRect pictureRect) {
    CGRect outer = CGRectInset(pictureRect, -6, -6);
    W7FillPathVertical(ctx, W7RoundedPath(outer, 5), outer, 0xFFFFFF, 0.70, 0xFFFFFF, 0.30);
    W7StrokePath(ctx, W7RoundedPath(CGRectInset(outer, 0.5, 0.5), 5), 0x000000, 0.45, 1);
    W7StrokePath(ctx, W7RoundedPath(CGRectInset(pictureRect, -0.5, -0.5), 2), 0xFFFFFF, 0.8, 1);
}

#pragma mark - Glass text

void W7DrawGlassText(NSString *text, CGRect rect, NSFont *font, NSTextAlignment alignment) {
    if (text.length == 0) return;
    NSShadow *glow = [NSShadow new];
    glow.shadowColor = [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.7];
    glow.shadowBlurRadius = 8;
    glow.shadowOffset = NSZeroSize;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = alignment;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor,
                             NSShadowAttributeName: glow, NSParagraphStyleAttributeName: ps };
    [text drawInRect:rect withAttributes:attrs];
}

#pragma mark - Misc

void W7DrawSnapPreview(CGContextRef ctx, CGRect rect) {
    CGContextSaveGState(ctx);
    CGPathRef path = W7RoundedPath(CGRectInset(rect, 0.5, 0.5), 6);
    W7SetFill(ctx, 0xFFFFFF, 0.25);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGContextSetLineWidth(ctx, 1);
    W7SetStroke(ctx, 0xFFFFFF, 0.6);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

// W7DrawWallpaper lives in W7Wallpaper.m.
