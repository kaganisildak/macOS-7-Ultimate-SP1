#import "Win7Theme.h"

// Procedural Windows 7 folder icons, drawn rather than copied. Everything is laid out on a
// unit square (bottom-left origin) that the bitmap context scales to the icon's pixel size.

const NSInteger W7FolderIconKindCount = W7FolderIconUser + 1;

typedef NS_ENUM(NSInteger, W7FolderSizeClass) { W7FolderSmall, W7FolderMedium, W7FolderLarge };

/// Per-icon drawing state: the pixel size, so lines and edges can be kept on whole pixels.
typedef struct {
    CGContextRef ctx;
    CGFloat pixels;        // icon side in pixels
    CGFloat line;          // border width in units: 1 px up to 96 px icons, then growing slowly
    W7FolderSizeClass size;
} W7FolderPen;

static CGColorSpaceRef W7FolderSRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7FolderColor(uint32_t hex, CGFloat a) {
    W7RGBA c = W7RGBAFromHex(hex, a);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7FolderSRGB(), v));
}

/// `v` (units) moved to the nearest pixel edge.
static CGFloat W7Snap(const W7FolderPen *pen, CGFloat v) { return round(v * pen->pixels) / pen->pixels; }

static void W7FolderFill(const W7FolderPen *pen, CGPathRef path, uint32_t hex, CGFloat a) {
    CGContextSetFillColorWithColor(pen->ctx, W7FolderColor(hex, a));
    CGContextAddPath(pen->ctx, path);
    CGContextFillPath(pen->ctx);
}

static void W7FolderStroke(const W7FolderPen *pen, CGPathRef path, uint32_t hex, CGFloat a, CGFloat width) {
    CGContextSetStrokeColorWithColor(pen->ctx, W7FolderColor(hex, a));
    CGContextSetLineWidth(pen->ctx, width);
    CGContextSetLineJoin(pen->ctx, kCGLineJoinRound);
    CGContextAddPath(pen->ctx, path);
    CGContextStrokePath(pen->ctx);
}

/// Fills `path` with a vertical gradient from `top` at y = `yTop` to `bottom` at y = `yBottom`.
static void W7FolderGradient(const W7FolderPen *pen, CGPathRef path, uint32_t top, CGFloat ta, uint32_t bottom, CGFloat ba,
                             CGFloat yTop, CGFloat yBottom) {
    CGColorRef cols[2] = { W7FolderColor(top, ta), W7FolderColor(bottom, ba) };
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7FolderSRGB(), arr, NULL);
    CGContextSaveGState(pen->ctx);
    CGContextAddPath(pen->ctx, path);
    CGContextClip(pen->ctx);
    CGContextDrawLinearGradient(pen->ctx, g, CGPointMake(0, yTop), CGPointMake(0, yBottom),
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGContextRestoreGState(pen->ctx);
    CGGradientRelease(g);
    CFRelease(arr);
}

static CGPathRef W7FolderRect(CGRect r, CGFloat radius) {
    radius = MIN(radius, MIN(r.size.width, r.size.height) / 2);
    return (CGPathRef)CFAutorelease(CGPathCreateWithRoundedRect(r, radius, radius, NULL));
}

/// A closed polygon through `points` with every corner rounded by `radius`.
static CGPathRef W7FolderPolygon(const CGPoint *points, size_t count, CGFloat radius) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPoint last = points[count - 1], first = points[0];
    CGPathMoveToPoint(p, NULL, (last.x + first.x) / 2, (last.y + first.y) / 2);
    for (size_t i = 0; i < count; i++) {
        CGPoint next = points[(i + 1) % count];
        CGPathAddArcToPoint(p, NULL, points[i].x, points[i].y, next.x, next.y, radius);
    }
    CGPathCloseSubpath(p);
    return (CGPathRef)CFAutorelease(p);
}

#pragma mark - Folder body

/// The back panel with its tab top-left: `top` is the panel's top edge, `tabTop` the tab's.
static void W7DrawBackPanel(const W7FolderPen *pen, CGFloat top, CGFloat tabTop) {
    CGFloat x0 = W7Snap(pen, 0.06), x1 = W7Snap(pen, 0.94), y0 = W7Snap(pen, 0.12);
    top = W7Snap(pen, top);
    tabTop = W7Snap(pen, tabTop);
    CGFloat tabEnd = W7Snap(pen, 0.40), slope = MAX(W7Snap(pen, 0.06), 1 / pen->pixels);
    CGPoint pts[] = { { x0, y0 }, { x0, tabTop }, { tabEnd, tabTop }, { tabEnd + slope, top }, { x1, top }, { x1, y0 } };
    CGPathRef back = W7FolderPolygon(pts, sizeof pts / sizeof pts[0], pen->size == W7FolderSmall ? 0.02 : 0.03);
    W7FolderGradient(pen, back, 0xE9C46A, 1, 0xD9A93C, 1, tabTop, y0);
    // The tab, darker, as Windows 7's folder shows the back's top edge.
    CGContextSaveGState(pen->ctx);
    CGContextClipToRect(pen->ctx, CGRectMake(0, top - pen->line, 1, 1));
    W7FolderGradient(pen, back, 0xDDB04A, 1, 0xCFA23A, 1, tabTop, top);
    CGContextRestoreGState(pen->ctx);
    W7FolderStroke(pen, back, 0xC99A2E, 1, pen->line);
}

/// One cream paper sheet, rotated by `degrees` about its centre, with a thin edge and, when large,
/// faint text lines.
static void W7DrawPaper(const W7FolderPen *pen, CGRect r, CGFloat degrees, uint32_t fill) {
    CGContextSaveGState(pen->ctx);
    CGContextTranslateCTM(pen->ctx, CGRectGetMidX(r), CGRectGetMidY(r));
    CGContextRotateCTM(pen->ctx, degrees * M_PI / 180);
    CGRect local = CGRectOffset(r, -CGRectGetMidX(r), -CGRectGetMidY(r));
    CGPathRef sheet = W7FolderRect(local, 0.008);
    W7FolderFill(pen, sheet, fill, 1);
    W7FolderStroke(pen, sheet, 0xC8C2B0, 1, pen->line * 0.8);
    if (pen->size == W7FolderLarge) {
        CGContextSetFillColorWithColor(pen->ctx, W7FolderColor(0xDCD6C6, 1));
        for (CGFloat y = CGRectGetMaxY(local) - 0.06; y > CGRectGetMinY(local) + 0.04; y -= 0.045)
            CGContextFillRect(pen->ctx, CGRectMake(CGRectGetMinX(local) + 0.06, y, local.size.width - 0.12, 0.012));
    }
    CGContextRestoreGState(pen->ctx);
}

/// The front panel; returns the emblem box centre for it.
static CGPoint W7DrawFrontPanel(const W7FolderPen *pen) {
    CGPathRef front;
    CGFloat top, bottom = W7Snap(pen, 0.12);
    CGPoint centre;
    if (pen->size == W7FolderLarge) {
        // Open: tilted forward, its top edge rising from the lower left to the upper right.
        bottom = 0.10;
        top = 0.62;
        CGPoint pts[] = { { 0.04, bottom }, { 0.14, 0.56 }, { 0.98, top }, { 0.92, bottom } };
        front = W7FolderPolygon(pts, 4, 0.025);
        centre = CGPointMake(0.53, 0.34);
    } else {
        top = W7Snap(pen, 0.72);
        front = W7FolderRect(CGRectMake(W7Snap(pen, 0.06), bottom, W7Snap(pen, 0.94) - W7Snap(pen, 0.06), top - bottom),
                             pen->size == W7FolderSmall ? 0.02 : 0.03);
        centre = CGPointMake(0.50, 0.41);
    }
    CGContextSaveGState(pen->ctx);
    if (pen->size == W7FolderLarge)
        CGContextSetShadowWithColor(pen->ctx, CGSizeMake(0, -pen->pixels * 0.008), pen->pixels * 0.02, W7FolderColor(0x000000, 0.30));
    W7FolderGradient(pen, front, 0xF7DE8B, pen->size == W7FolderLarge ? 0.94 : 0.97, 0xE8BE55, 0.97, top, bottom);
    CGContextRestoreGState(pen->ctx);
    // Gloss over the top of the front panel, and its lit top edge.
    W7FolderGradient(pen, front, 0xFFFFFF, 0.30, 0xFFFFFF, 0.0, top, top - (top - bottom) * 0.45);
    CGContextSaveGState(pen->ctx);
    CGContextAddPath(pen->ctx, front);
    CGContextClip(pen->ctx);
    CGContextSetStrokeColorWithColor(pen->ctx, W7FolderColor(0xFFFFFF, 0.45));
    CGContextSetLineWidth(pen->ctx, pen->line * 2);
    CGContextMoveToPoint(pen->ctx, pen->size == W7FolderLarge ? 0.14 : 0.06, pen->size == W7FolderLarge ? 0.56 - pen->line : top - pen->line);
    CGContextAddLineToPoint(pen->ctx, pen->size == W7FolderLarge ? 0.98 : 0.94, top - pen->line);
    CGContextStrokePath(pen->ctx);
    CGContextRestoreGState(pen->ctx);
    W7FolderStroke(pen, front, 0xC99A2E, 1, pen->line);
    return centre;
}

#pragma mark - Emblems

/// Documents: a white page with blue text lines.
static void W7EmblemDocuments(const W7FolderPen *pen, CGRect b) {
    CGRect page = CGRectInset(b, b.size.width * 0.16, 0);
    CGPathRef p = W7FolderRect(page, b.size.width * 0.04);
    W7FolderFill(pen, p, 0xFFFFFF, 1);
    W7FolderStroke(pen, p, 0x8E9AAF, 1, pen->line);
    NSInteger lines = pen->size == W7FolderSmall ? 2 : 4;
    CGFloat thick = MAX(b.size.height * 0.08, 1 / pen->pixels);
    CGFloat gap = page.size.height / (lines + 1);
    CGContextSetFillColorWithColor(pen->ctx, W7FolderColor(0x3D6FB6, 1));
    for (NSInteger i = 1; i <= lines; i++) {
        CGFloat y = W7Snap(pen, CGRectGetMaxY(page) - gap * i - thick / 2);
        CGFloat inset = page.size.width * 0.18;
        CGFloat w = page.size.width - inset * 2 - (i == lines ? page.size.width * 0.2 : 0);
        CGContextFillRect(pen->ctx, CGRectMake(CGRectGetMinX(page) + inset, y, w, MAX(W7Snap(pen, thick), 1 / pen->pixels)));
    }
}

/// Pictures: a small landscape photo, sky, sun and green hills in a white frame.
static void W7EmblemPictures(const W7FolderPen *pen, CGRect b) {
    CGRect frame = CGRectInset(b, 0, b.size.height * 0.14);
    CGPathRef f = W7FolderRect(frame, b.size.width * 0.03);
    W7FolderFill(pen, f, 0xFFFFFF, 1);
    W7FolderStroke(pen, f, 0x8E9AAF, 1, pen->line);
    CGRect photo = CGRectInset(frame, MAX(frame.size.width * 0.08, 1 / pen->pixels), MAX(frame.size.height * 0.10, 1 / pen->pixels));
    CGPathRef ph = W7FolderRect(photo, 0);
    W7FolderGradient(pen, ph, 0x9AD4F5, 1, 0x4C9FE0, 1, CGRectGetMaxY(photo), CGRectGetMinY(photo));
    CGContextSaveGState(pen->ctx);
    CGContextAddPath(pen->ctx, ph);
    CGContextClip(pen->ctx);
    CGFloat d = photo.size.height * 0.30;
    W7FolderFill(pen, W7FolderRect(CGRectMake(CGRectGetMaxX(photo) - d * 1.6, CGRectGetMaxY(photo) - d * 1.4, d, d), d / 2), 0xFFD23F, 1);
    CGMutablePathRef hills = CGPathCreateMutable();
    CGPathMoveToPoint(hills, NULL, CGRectGetMinX(photo), CGRectGetMinY(photo));
    CGPathAddLineToPoint(hills, NULL, CGRectGetMinX(photo), CGRectGetMinY(photo) + photo.size.height * 0.45);
    CGPathAddQuadCurveToPoint(hills, NULL, photo.origin.x + photo.size.width * 0.30, photo.origin.y + photo.size.height * 0.75,
                              photo.origin.x + photo.size.width * 0.55, photo.origin.y + photo.size.height * 0.40);
    CGPathAddQuadCurveToPoint(hills, NULL, photo.origin.x + photo.size.width * 0.80, photo.origin.y + photo.size.height * 0.62,
                              CGRectGetMaxX(photo), photo.origin.y + photo.size.height * 0.38);
    CGPathAddLineToPoint(hills, NULL, CGRectGetMaxX(photo), CGRectGetMinY(photo));
    CGPathCloseSubpath(hills);
    W7FolderGradient(pen, hills, 0x6CC04A, 1, 0x2F8A22, 1, photo.origin.y + photo.size.height * 0.7, CGRectGetMinY(photo));
    CGPathRelease(hills);
    CGContextRestoreGState(pen->ctx);
}

/// Music: a blue double note (♫) with a dark outline.
static void W7EmblemMusic(const W7FolderPen *pen, CGRect b) {
    CGFloat w = b.size.width, h = b.size.height;
    CGFloat stem = MAX(w * 0.10, 1 / pen->pixels);
    CGFloat headW = w * 0.34, headH = h * 0.24;
    CGPoint left = CGPointMake(b.origin.x + w * 0.08, b.origin.y + h * 0.04);
    CGPoint right = CGPointMake(b.origin.x + w * 0.56, b.origin.y + h * 0.14);
    CGMutablePathRef note = CGPathCreateMutable();
    CGPathAddEllipseInRect(note, NULL, CGRectMake(left.x, left.y, headW, headH));
    CGPathAddEllipseInRect(note, NULL, CGRectMake(right.x, right.y, headW, headH));
    CGFloat lx = left.x + headW - stem, rx = right.x + headW - stem;
    CGPathAddRect(note, NULL, CGRectMake(lx, left.y + headH / 2, stem, h * 0.78));
    CGPathAddRect(note, NULL, CGRectMake(rx, right.y + headH / 2, stem, h * 0.72));
    // The beam, rising to the right like the heads.
    CGFloat beam = MAX(h * 0.16, 1.5 / pen->pixels);
    CGFloat ly = left.y + headH / 2 + h * 0.78, ry = right.y + headH / 2 + h * 0.72;
    CGPathMoveToPoint(note, NULL, lx, ly - beam);
    CGPathAddLineToPoint(note, NULL, rx + stem, ry - beam);
    CGPathAddLineToPoint(note, NULL, rx + stem, ry);
    CGPathAddLineToPoint(note, NULL, lx, ly);
    CGPathCloseSubpath(note);
    if (pen->size != W7FolderSmall) W7FolderStroke(pen, note, 0x1C4A94, 1, pen->line * 1.5);
    W7FolderFill(pen, note, 0x2F6FD0, 1);
    CGPathRelease(note);
}

/// Videos: a dark film strip with sprocket holes and a blue frame.
static void W7EmblemVideos(const W7FolderPen *pen, CGRect b) {
    CGRect strip = CGRectInset(b, 0, b.size.height * 0.12);
    CGPathRef s = W7FolderRect(strip, b.size.width * 0.03);
    W7FolderFill(pen, s, 0x343A40, 1);
    CGFloat band = strip.size.height * 0.2;
    CGRect frame = CGRectInset(strip, strip.size.width * 0.12, band);
    W7FolderGradient(pen, W7FolderRect(frame, 0), 0x8CC8F2, 1, 0x3D86CC, 1, CGRectGetMaxY(frame), CGRectGetMinY(frame));
    NSInteger holes = pen->size == W7FolderSmall ? 3 : 5;
    CGFloat step = strip.size.width / holes, hole = MAX(step * 0.45, 1 / pen->pixels), hh = MAX(band * 0.5, 1 / pen->pixels);
    CGContextSetFillColorWithColor(pen->ctx, W7FolderColor(0xF4F1E8, 1));
    for (NSInteger i = 0; i < holes; i++) {
        CGFloat x = strip.origin.x + step * i + (step - hole) / 2;
        CGContextFillRect(pen->ctx, CGRectMake(x, CGRectGetMinY(strip) + (band - hh) / 2, hole, hh));
        CGContextFillRect(pen->ctx, CGRectMake(x, CGRectGetMaxY(strip) - band + (band - hh) / 2, hole, hh));
    }
}

/// Downloads: a green arrow pointing down, with a dark green outline.
static void W7EmblemDownloads(const W7FolderPen *pen, CGRect b) {
    CGFloat w = b.size.width, h = b.size.height, x = b.origin.x, y = b.origin.y;
    CGPoint pts[] = {
        { x + w * 0.32, y + h }, { x + w * 0.68, y + h }, { x + w * 0.68, y + h * 0.48 }, { x + w * 0.92, y + h * 0.48 },
        { x + w * 0.50, y }, { x + w * 0.08, y + h * 0.48 }, { x + w * 0.32, y + h * 0.48 },
    };
    CGPathRef arrow = W7FolderPolygon(pts, sizeof pts / sizeof pts[0], w * 0.02);
    if (pen->size != W7FolderSmall) W7FolderStroke(pen, arrow, 0x1F7A12, 1, pen->line * 1.5);
    W7FolderGradient(pen, arrow, 0x5CC845, 1, 0x3FAE2A, 1, y + h, y);
}

/// Desktop: a small monitor with a blue screen on a stand.
static void W7EmblemDesktop(const W7FolderPen *pen, CGRect b) {
    CGFloat w = b.size.width, h = b.size.height;
    CGRect bezel = CGRectMake(b.origin.x, b.origin.y + h * 0.22, w, h * 0.70);
    CGPathRef bz = W7FolderRect(bezel, w * 0.05);
    W7FolderFill(pen, bz, 0x39424C, 1);
    CGFloat edge = MAX(w * 0.07, 1 / pen->pixels);
    CGRect screen = CGRectInset(bezel, edge, edge);
    W7FolderGradient(pen, W7FolderRect(screen, 0), 0x6FC2FF, 1, 0x1C6FD0, 1, CGRectGetMaxY(screen), CGRectGetMinY(screen));
    CGContextSetFillColorWithColor(pen->ctx, W7FolderColor(0x5A646E, 1));
    CGFloat neck = MAX(w * 0.14, 1 / pen->pixels);
    CGContextFillRect(pen->ctx, CGRectMake(CGRectGetMidX(b) - neck / 2, b.origin.y + h * 0.08, neck, h * 0.14));
    CGContextFillRect(pen->ctx, CGRectMake(CGRectGetMidX(b) - w * 0.25, b.origin.y, w * 0.5, MAX(h * 0.09, 1 / pen->pixels)));
}

/// User: a person silhouette, head and shoulders.
static void W7EmblemUser(const W7FolderPen *pen, CGRect b) {
    CGFloat w = b.size.width, h = b.size.height;
    CGMutablePathRef person = CGPathCreateMutable();
    CGFloat d = w * 0.42;
    CGPathAddEllipseInRect(person, NULL, CGRectMake(CGRectGetMidX(b) - d / 2, b.origin.y + h * 0.52, d, d));
    CGRect body = CGRectMake(b.origin.x + w * 0.10, b.origin.y, w * 0.80, h * 0.56);
    CGPathMoveToPoint(person, NULL, CGRectGetMinX(body), CGRectGetMinY(body));
    CGPathAddCurveToPoint(person, NULL, CGRectGetMinX(body), CGRectGetMaxY(body), CGRectGetMaxX(body), CGRectGetMaxY(body),
                          CGRectGetMaxX(body), CGRectGetMinY(body));
    CGPathCloseSubpath(person);
    if (pen->size != W7FolderSmall) W7FolderStroke(pen, person, 0x2E4E73, 1, pen->line * 1.5);
    W7FolderGradient(pen, person, 0x7FA6D1, 1, 0x4A73A3, 1, b.origin.y + h, b.origin.y);
    CGPathRelease(person);
}

static void W7DrawEmblem(const W7FolderPen *pen, W7FolderIconKind kind, CGPoint centre) {
    CGFloat side = pen->size == W7FolderSmall ? 0.52 : pen->size == W7FolderMedium ? 0.42 : 0.34;
    CGRect box = CGRectMake(W7Snap(pen, centre.x - side / 2), W7Snap(pen, centre.y - side / 2), side, side);
    switch (kind) {
        case W7FolderIconDocuments: W7EmblemDocuments(pen, box); break;
        case W7FolderIconPictures: W7EmblemPictures(pen, box); break;
        case W7FolderIconMusic: W7EmblemMusic(pen, box); break;
        case W7FolderIconVideos: W7EmblemVideos(pen, box); break;
        case W7FolderIconDownloads: W7EmblemDownloads(pen, box); break;
        case W7FolderIconDesktop: W7EmblemDesktop(pen, box); break;
        case W7FolderIconUser: W7EmblemUser(pen, box); break;
        case W7FolderIconPlain: break;
    }
}

#pragma mark - Icon

CGImageRef W7CreateFolderIconImage(W7FolderIconKind kind, CGFloat pointSize, CGFloat scale) {
    if (!(pointSize > 0) || !(scale > 0)) return NULL;
    size_t px = (size_t)MAX(1, round(pointSize * scale));
    CGContextRef ctx = CGBitmapContextCreate(NULL, px, px, 8, 0, W7FolderSRGB(), (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (!ctx) return NULL;
    CGContextScaleCTM(ctx, px, px);
    W7FolderPen pen = {
        .ctx = ctx,
        .pixels = px,
        .line = MAX(1.0, px / 96.0) / px,
        .size = pointSize < 28 ? W7FolderSmall : pointSize < 48 ? W7FolderMedium : W7FolderLarge,
    };
    BOOL large = pen.size == W7FolderLarge;
    W7DrawBackPanel(&pen, large ? 0.84 : 0.80, large ? 0.93 : 0.88);
    if (pen.size == W7FolderMedium) {
        W7DrawPaper(&pen, CGRectMake(0.17, 0.30, 0.68, 0.48), -3, 0xF4F1E8);
        W7DrawPaper(&pen, CGRectMake(0.14, 0.32, 0.66, 0.47), 0, 0xFFFFFF);
    } else if (large) {
        W7DrawPaper(&pen, CGRectMake(0.18, 0.28, 0.66, 0.54), -4, 0xF4F1E8);
        W7DrawPaper(&pen, CGRectMake(0.14, 0.30, 0.66, 0.56), 1.5, 0xFFFFFF);
    }
    CGPoint centre = W7DrawFrontPanel(&pen);
    W7DrawEmblem(&pen, kind, centre);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}
