// Windows Live Messenger's pieces for the Messages window's chrome: the status ("buddy") orbs,
// the pale blue header band, the picture tile (the user's picture or a drawn silhouette), the header's layout and
// contents (name, status line, the disabled Messenger toolbar row). Messenger is not part of Windows 7 media, so no
// artwork exists to import: everything here is drawn. Non-flipped contexts (bottom-left origin).
// Win7ChromeCore's W7MessagesLook.m places the band under the Messages window's toolbar and feeds it.
#import "Win7Theme.h"

const CGFloat W7MessengerBandHeight = 64;
const CGFloat W7MessengerCompactBandHeight = 32;
const CGFloat W7MessengerTileSide = 48;
const CGFloat W7MessengerCompactTileSide = 24;
const CGFloat W7MessengerStatusOrbSide = 12;

static const uint32_t kBandTopHex = 0xDFEFFC;
static const uint32_t kBandBottomHex = 0xC4DDF5;
static const uint32_t kTextHex = 0x1C4F8C;
static const uint32_t kDisabledTextHex = 0x6D6D6D;
static const uint32_t kTileBorderHex = 0x8EAACC;
static const uint32_t kTileFrameBottomHex = 0xE8F0FA;
static const uint32_t kSilhouetteHex = 0x7F9FC7;
static const uint32_t kSilhouetteTopHex = 0xF3F7FC;
static const uint32_t kSilhouetteBottomHex = 0xD5E2F1;

static const CGFloat kFullTileInset = 8, kCompactTileInset = 4, kFullTileTextGap = 10, kCompactTileTextGap = 8;
static const CGFloat kRightInset = 4, kNameTopInset = 5, kNameHeight = 18, kStatusHeight = 16, kCommandHeight = 20;
static const CGFloat kCommandBottomInset = 4, kCommandGap = 2, kCommandPadding = 6, kOrbTextGap = 4, kTextArrowGap = 3;
static const CGFloat kArrowWidth = 7, kArrowHeight = 4, kNameStatusGap = 10, kStatusCommandsGap = 14, kMinCompactName = 40;

#pragma mark - Colours and fonts

static CGColorSpaceRef W7MessengerSRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return cs;
}

static CGColorRef W7MessengerCGColor(uint32_t hex, CGFloat alpha) {
    W7RGBA c = W7RGBAFromHex(hex, alpha);
    CGFloat v[4] = { c.r, c.g, c.b, c.a };
    return (CGColorRef)CFAutorelease(CGColorCreate(W7MessengerSRGB(), v));
}

static NSColor *W7MessengerNSColor(uint32_t hex) {
    W7RGBA c = W7RGBAFromHex(hex, 1);
    return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:1];
}

/// A vertical gradient from `top` to `bottom` over `r` (the caller clips).
static void W7MessengerGradient(CGContextRef ctx, CGRect r, uint32_t top, CGFloat topAlpha, uint32_t bottom, CGFloat bottomAlpha) {
    CGColorRef cols[2] = { W7MessengerCGColor(top, topAlpha), W7MessengerCGColor(bottom, bottomAlpha) };
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)cols, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(W7MessengerSRGB(), arr, NULL);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 0);
    CGGradientRelease(g);
    CFRelease(arr);
}

static NSFont *W7MessengerNameFont(void) {
    static NSFont *font;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFont *base = W7UIFont(13);
        font = [NSFontManager.sharedFontManager convertFont:base toHaveTrait:NSBoldFontMask] ?: base;
    });
    return font;
}

static NSFont *W7MessengerTextFont(void) {
    static NSFont *font;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ font = W7UIFont(12); });
    return font;
}

static CGFloat W7MessengerTextWidth(NSString *text, NSFont *font) {
    if (!text.length) return 0;
    return ceil([text sizeWithAttributes:@{ NSFontAttributeName: font }].width);
}

/// `text` in `font`/`hex`, vertically centred in `rect` (left-aligned, or centred), clipped and truncated to it.
static void W7MessengerDrawText(CGContextRef ctx, NSString *text, CGRect rect, NSFont *font, uint32_t hex, BOOL centred) {
    if (text.length == 0 || CGRectIsEmpty(rect)) return;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    ps.alignment = centred ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: W7MessengerNSColor(hex),
                             NSParagraphStyleAttributeName: ps };
    CGFloat h = ceil(font.ascender - font.descender);
    CGContextSaveGState(ctx);   // the clip below belongs to ctx, which NSGraphicsContext's restore does not reset
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    NSRectClip(rect);
    [text drawInRect:NSMakeRect(rect.origin.x, round(CGRectGetMidY(rect) - h / 2), rect.size.width, h) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(ctx);
}

#pragma mark - Status

uint32_t W7MessengerStatusColor(W7MessengerStatus status) {
    switch (status) {
        case W7MessengerStatusBusy: return 0xE2412F;
        case W7MessengerStatusAway: return 0xF4C02E;
        case W7MessengerStatusOffline: return 0xA5A5A5;
        case W7MessengerStatusAvailable:
        default: return 0x5BCB3A;
    }
}

NSString *W7MessengerStatusTitle(W7MessengerStatus status) {
    switch (status) {
        case W7MessengerStatusBusy: return @"Busy";
        case W7MessengerStatusAway: return @"Away";
        case W7MessengerStatusOffline: return @"Appear offline";
        case W7MessengerStatusAvailable:
        default: return @"Available";
    }
}

NSArray<NSString *> *W7MessengerToolbarLabels(void) {
    return @[ @"Send an instant message", @"Send a file", @"Video call", @"Add a contact" ];
}

/// The status colour at 60 % brightness: the orb's rim.
static uint32_t W7MessengerRimHex(uint32_t hex) {
    uint32_t r = ((hex >> 16) & 0xFF) * 6 / 10, g = ((hex >> 8) & 0xFF) * 6 / 10, b = (hex & 0xFF) * 6 / 10;
    return r << 16 | g << 8 | b;
}

void W7DrawMessengerStatusOrb(CGContextRef ctx, CGRect rect, W7MessengerStatus status) {
    if (CGRectIsEmpty(rect)) return;
    CGFloat side = MIN(rect.size.width, rect.size.height);
    CGRect c = CGRectMake(CGRectGetMidX(rect) - side / 2, CGRectGetMidY(rect) - side / 2, side, side);
    uint32_t hex = W7MessengerStatusColor(status);
    CGContextSaveGState(ctx);
    CGContextSetFillColorWithColor(ctx, W7MessengerCGColor(hex, 1));
    CGContextFillEllipseInRect(ctx, c);
    // The gloss: an ellipse over the upper half, white fading downwards.
    CGRect gloss = CGRectMake(c.origin.x + side * 0.18, CGRectGetMidY(c), side * 0.64, side * 0.42);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, gloss);
    CGContextClip(ctx);
    W7MessengerGradient(ctx, gloss, 0xFFFFFF, 0.75, 0xFFFFFF, 0.15);
    CGContextRestoreGState(ctx);
    CGContextSetStrokeColorWithColor(ctx, W7MessengerCGColor(W7MessengerRimHex(hex), 1));
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(c, 0.5, 0.5));
    CGContextRestoreGState(ctx);
}

#pragma mark - Band and tile

void W7DrawMessengerBandBackground(CGContextRef ctx, CGRect rect) {
    if (CGRectIsEmpty(rect)) return;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    W7MessengerGradient(ctx, rect, kBandTopHex, 1, kBandBottomHex, 1);
    CGContextRestoreGState(ctx);
}

/// A head and shoulders in `inner`, on its pale gradient.
static void W7MessengerSilhouette(CGContextRef ctx, CGRect inner) {
    W7MessengerGradient(ctx, inner, kSilhouetteTopHex, 1, kSilhouetteBottomHex, 1);
    CGFloat x = inner.origin.x, y = inner.origin.y, w = inner.size.width, h = inner.size.height;
    CGContextSetFillColorWithColor(ctx, W7MessengerCGColor(kSilhouetteHex, 1));
    CGFloat head = h * 0.2;
    CGContextFillEllipseInRect(ctx, CGRectMake(x + w / 2 - head, y + h * 0.62 - head, head * 2, head * 2));
    CGContextFillEllipseInRect(ctx, CGRectMake(x + w * 0.16, y - h * 0.2, w * 0.68, h * 0.55));
}

/// `image` scaled to fill `r` (centred; the overflow is clipped by the caller).
static void W7MessengerDrawImageFilling(CGContextRef ctx, CGImageRef image, CGRect r) {
    CGFloat iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
    if (iw <= 0 || ih <= 0) return;
    CGFloat scale = MAX(r.size.width / iw, r.size.height / ih);
    CGFloat w = iw * scale, h = ih * scale;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(CGRectGetMidX(r) - w / 2, CGRectGetMidY(r) - h / 2, w, h), image);
}

void W7DrawMessengerPictureTile(CGContextRef ctx, CGRect rect, CGImageRef picture) {
    if (CGRectIsEmpty(rect)) return;
    CGFloat side = MIN(rect.size.width, rect.size.height);
    BOOL large = side >= 40;
    CGFloat radius = large ? 4 : 2, frame = large ? 3 : 2;
    CGContextSaveGState(ctx);
    CGPathRef outer = CGPathCreateWithRoundedRect(rect, radius, radius, NULL);
    CGContextAddPath(ctx, outer);
    CGContextClip(ctx);
    W7MessengerGradient(ctx, rect, 0xFFFFFF, 1, kTileFrameBottomHex, 1);
    CGRect inner = CGRectInset(rect, frame, frame);
    CGContextSaveGState(ctx);
    CGPathRef innerPath = CGPathCreateWithRoundedRect(inner, radius / 2, radius / 2, NULL);
    CGContextAddPath(ctx, innerPath);
    CGContextClip(ctx);
    if (picture) W7MessengerDrawImageFilling(ctx, picture, inner);
    else W7MessengerSilhouette(ctx, inner);
    CGContextRestoreGState(ctx);
    CGPathRelease(innerPath);
    CGContextRestoreGState(ctx);
    // The border over everything, inside the tile's edge.
    CGContextSaveGState(ctx);
    CGPathRef border = CGPathCreateWithRoundedRect(CGRectInset(rect, 0.5, 0.5), radius - 0.5, radius - 0.5, NULL);
    CGContextAddPath(ctx, border);
    CGContextSetStrokeColorWithColor(ctx, W7MessengerCGColor(kTileBorderHex, 1));
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
    CGPathRelease(border);
    CGPathRelease(outer);
}

#pragma mark - Commands

CGFloat W7MessengerCommandWidth(NSString *label) {
    return W7MessengerTextWidth(label, W7MessengerTextFont()) + 2 * kCommandPadding;
}

void W7DrawMessengerCommand(CGContextRef ctx, CGRect rect, NSString *label) {
    if (CGRectIsEmpty(rect)) return;
    W7DrawCommandButton(ctx, rect, W7StateDisabled);   // a disabled flat button: no face
    W7MessengerDrawText(ctx, label, rect, W7MessengerTextFont(), kDisabledTextHex, YES);
}

#pragma mark - Header

W7MessengerHeaderLayout W7MessengerHeaderLayoutFor(CGRect content, BOOL compact, NSString *name, W7MessengerStatus status) {
    W7MessengerHeaderLayout l;
    memset(&l, 0, sizeof l);
    if (CGRectIsEmpty(content) || CGRectIsNull(content)) return l;
    CGFloat side = compact ? W7MessengerCompactTileSide : W7MessengerTileSide;
    CGFloat inset = compact ? kCompactTileInset : kFullTileInset;
    CGFloat x0 = CGRectGetMinX(content), right = CGRectGetMaxX(content) - kRightInset, midY = CGRectGetMidY(content);
    if (x0 + inset + side > right) return l;   // not even the tile fits
    l.tile = CGRectMake(x0 + inset, round(midY - side / 2), side, side);
    CGFloat tx = CGRectGetMaxX(l.tile) + (compact ? kCompactTileTextGap : kFullTileTextGap);
    CGFloat avail = right - tx;
    if (avail <= 0) return l;

    CGFloat nameWidth = W7MessengerTextWidth(name, W7MessengerNameFont());
    CGFloat statusWidth = W7MessengerTextWidth(W7MessengerStatusTitle(status), W7MessengerTextFont());
    CGFloat statusBlock = W7MessengerStatusOrbSide + kOrbTextGap + statusWidth + kTextArrowGap + kArrowWidth;
    CGFloat orbSide = W7MessengerStatusOrbSide;
    CGFloat commandsX, commandsY;

    if (!compact) {
        CGFloat top = CGRectGetMaxY(content);
        l.name = CGRectMake(tx, top - kNameTopInset - kNameHeight, MIN(nameWidth, avail), kNameHeight);
        if (statusBlock <= avail) {
            CGFloat rowY = CGRectGetMinY(l.name) - kStatusHeight, rowMid = rowY + kStatusHeight / 2;
            l.orb = CGRectMake(tx, round(rowMid - orbSide / 2), orbSide, orbSide);
            l.status = CGRectMake(CGRectGetMaxX(l.orb) + kOrbTextGap, rowY, statusWidth, kStatusHeight);
            l.arrow = CGRectMake(CGRectGetMaxX(l.status) + kTextArrowGap, round(rowMid - kArrowHeight / 2), kArrowWidth, kArrowHeight);
        }
        commandsX = tx - kCommandPadding;   // the labels' text lines up with the name
        commandsY = CGRectGetMinY(content) + kCommandBottomInset;
    } else {
        CGFloat lineY = round(midY - kNameHeight / 2);
        CGFloat nameMax = avail - kNameStatusGap - statusBlock;
        BOOL withStatus = nameMax >= MIN(nameWidth, kMinCompactName);
        CGFloat shown = withStatus ? MIN(nameWidth, nameMax) : MIN(nameWidth, avail);
        l.name = CGRectMake(tx, lineY, shown, kNameHeight);
        CGFloat after = CGRectGetMaxX(l.name);
        if (withStatus) {
            l.orb = CGRectMake(after + kNameStatusGap, round(midY - orbSide / 2), orbSide, orbSide);
            l.status = CGRectMake(CGRectGetMaxX(l.orb) + kOrbTextGap, round(midY - kStatusHeight / 2), statusWidth, kStatusHeight);
            l.arrow = CGRectMake(CGRectGetMaxX(l.status) + kTextArrowGap, round(midY - kArrowHeight / 2), kArrowWidth, kArrowHeight);
            after = CGRectGetMaxX(l.arrow);
        }
        commandsX = after + kStatusCommandsGap;
        commandsY = round(midY - kCommandHeight / 2);
    }
    if (l.name.size.width <= 0) l.name = CGRectZero;

    CGFloat x = MAX(commandsX, x0);
    for (NSString *label in W7MessengerToolbarLabels()) {
        if (l.commandCount >= 4) break;
        CGFloat w = W7MessengerCommandWidth(label);
        if (x + w > right) break;
        l.commands[l.commandCount++] = CGRectMake(x, commandsY, w, kCommandHeight);
        x += w + kCommandGap;
    }
    return l;
}

/// The ▾ after the status title, in the text colour.
static void W7MessengerDrawArrow(CGContextRef ctx, CGRect r) {
    if (CGRectIsEmpty(r)) return;
    CGContextSaveGState(ctx);
    CGContextSetFillColorWithColor(ctx, W7MessengerCGColor(kTextHex, 1));
    CGContextMoveToPoint(ctx, CGRectGetMinX(r), CGRectGetMaxY(r));
    CGContextAddLineToPoint(ctx, CGRectGetMaxX(r), CGRectGetMaxY(r));
    CGContextAddLineToPoint(ctx, CGRectGetMidX(r), CGRectGetMinY(r));
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
}

void W7DrawMessengerHeader(CGContextRef ctx, CGRect content, BOOL compact, CGImageRef picture, NSString *name,
                           W7MessengerStatus status) {
    W7MessengerHeaderLayout l = W7MessengerHeaderLayoutFor(content, compact, name ?: @"", status);
    if (CGRectIsEmpty(l.tile)) return;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, content);
    W7DrawMessengerPictureTile(ctx, l.tile, picture);
    W7MessengerDrawText(ctx, name, l.name, W7MessengerNameFont(), kTextHex, NO);
    if (!CGRectIsEmpty(l.orb)) {
        W7DrawMessengerStatusOrb(ctx, l.orb, status);
        W7MessengerDrawText(ctx, W7MessengerStatusTitle(status), l.status, W7MessengerTextFont(), kTextHex, NO);
        W7MessengerDrawArrow(ctx, l.arrow);
    }
    NSArray<NSString *> *labels = W7MessengerToolbarLabels();
    for (NSUInteger i = 0; i < l.commandCount && i < labels.count; i++) W7DrawMessengerCommand(ctx, l.commands[i], labels[i]);
    CGContextRestoreGState(ctx);
}
