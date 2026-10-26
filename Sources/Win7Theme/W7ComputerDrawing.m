// The Windows 7 Computer view's drawing: group headers ("Hard Disk Drives"), drive tiles
// (48 pt icon, name, capacity bar, "N GB free of M GB") and the capacity bar itself. Non-flipped contexts.
// Win7ChromeCore's W7ExplorerComputerView lays the tiles out and feeds them.
#import "Win7Theme.h"

const CGFloat W7ComputerTileWidth = 266;
const CGFloat W7ComputerTileHeight = 58;
const CGFloat W7ComputerCapacityBarWidth = 200;
const CGFloat W7ComputerCapacityBarHeight = 12;
const CGFloat W7ComputerGroupHeaderHeight = 24;

static const CGFloat kIconSide = 48;
static const CGFloat kIconInset = 5;
static const CGFloat kIconTextGap = 6;
static const CGFloat kTopInset = 5;
static const CGFloat kRightInset = 6;
static const CGFloat kNameHeight = 16;
static const CGFloat kNameBarGap = 3;
static const CGFloat kBarTextGap = 2;
static const CGFloat kTextHeight = 14;
static const CGFloat kRuleGap = 6;

static const uint32_t kHeaderTextHex = 0x1E395B;
static const uint32_t kRuleHex = 0xD5DFE5;
static const uint32_t kTroughHex = 0xE6E6E6;
static const uint32_t kFillHex = 0x06B025;
static const uint32_t kLowFillHex = 0xDA2626;
static const uint32_t kBarBorderHex = 0xBCBCBC;
static const uint32_t kCapacityTextHex = 0x6D6D6D;

static void W7ComputerSetFill(CGContextRef ctx, uint32_t hex) {
    W7RGBA c = W7RGBAFromHex(hex, 1);
    CGContextSetRGBFillColor(ctx, c.r, c.g, c.b, c.a);
}

static NSColor *W7ComputerColor(uint32_t hex) {
    W7RGBA c = W7RGBAFromHex(hex, 1);
    return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:1];
}

static NSFont *W7ComputerBoldFont(void) {
    NSFont *base = W7UIFont(12);
    return [NSFontManager.sharedFontManager convertFont:base toHaveTrait:NSBoldFontMask] ?: base;
}

/// `text` in `font`/`hex`, vertically centred in `rect`, clipped to it (truncated with an ellipsis).
static void W7ComputerDrawText(CGContextRef ctx, NSString *text, CGRect rect, NSFont *font, uint32_t hex) {
    if (text.length == 0 || CGRectIsEmpty(rect)) return;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: W7ComputerColor(hex),
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

W7ComputerTileLayout W7ComputerTileLayoutFor(CGRect tile) {
    W7ComputerTileLayout l;
    CGFloat x0 = CGRectGetMinX(tile), top = CGRectGetMaxY(tile);
    l.icon = CGRectMake(x0 + kIconInset, CGRectGetMidY(tile) - kIconSide / 2, kIconSide, kIconSide);
    CGFloat x = CGRectGetMaxX(l.icon) + kIconTextGap;
    CGFloat width = MAX(0, CGRectGetMaxX(tile) - kRightInset - x);
    l.name = CGRectMake(x, top - kTopInset - kNameHeight, width, kNameHeight);
    l.bar = CGRectMake(x, CGRectGetMinY(l.name) - kNameBarGap - W7ComputerCapacityBarHeight,
                       MIN(W7ComputerCapacityBarWidth, width), W7ComputerCapacityBarHeight);
    l.text = CGRectMake(x, CGRectGetMinY(l.bar) - kBarTextGap - kTextHeight, width, kTextHeight);
    return l;
}

CGRect W7ComputerCapacityFillRect(CGRect bar, double usedFraction) {
    double used = isnan(usedFraction) ? 0 : MIN(1.0, MAX(0.0, usedFraction));
    CGRect inner = CGRectInset(bar, 1, 1);
    if (CGRectIsEmpty(inner)) return CGRectMake(CGRectGetMinX(bar) + 1, CGRectGetMinY(bar) + 1, 0, 0);
    return CGRectMake(inner.origin.x, inner.origin.y, round(inner.size.width * used), inner.size.height);
}

void W7DrawComputerCapacityBar(CGContextRef ctx, CGRect bar, double usedFraction, BOOL low) {
    if (!ctx || CGRectIsEmpty(bar)) return;
    CGContextSaveGState(ctx);
    W7ComputerSetFill(ctx, kBarBorderHex);
    CGContextFillRect(ctx, bar);
    W7ComputerSetFill(ctx, kTroughHex);
    CGContextFillRect(ctx, CGRectInset(bar, 1, 1));
    CGRect fill = W7ComputerCapacityFillRect(bar, usedFraction);
    if (!CGRectIsEmpty(fill)) {
        W7ComputerSetFill(ctx, low ? kLowFillHex : kFillHex);
        CGContextFillRect(ctx, fill);
    }
    CGContextRestoreGState(ctx);
}

void W7DrawComputerGroupHeader(CGContextRef ctx, CGRect rect, NSString *title) {
    if (!ctx || CGRectIsEmpty(rect)) return;
    NSFont *font = W7ComputerBoldFont();
    CGFloat titleWidth = title.length ? ceil([title sizeWithAttributes:@{ NSFontAttributeName: font }].width) : 0;
    titleWidth = MIN(titleWidth, CGRectGetWidth(rect));
    W7ComputerDrawText(ctx, title, CGRectMake(rect.origin.x, rect.origin.y, titleWidth, rect.size.height), font, kHeaderTextHex);
    CGFloat ruleX = CGRectGetMinX(rect) + titleWidth + (titleWidth > 0 ? kRuleGap : 0);
    if (ruleX >= CGRectGetMaxX(rect)) return;
    CGContextSaveGState(ctx);
    W7ComputerSetFill(ctx, kRuleHex);
    CGContextFillRect(ctx, CGRectMake(ruleX, floor(CGRectGetMidY(rect)), CGRectGetMaxX(rect) - ruleX, 1));
    CGContextRestoreGState(ctx);
}

void W7DrawComputerTile(CGContextRef ctx, CGRect tile, CGImageRef icon, W7NavPaneGlyph fallback, NSString *name,
                        NSString *capacityText, double usedFraction, BOOL low, BOOL selected, BOOL hover) {
    if (!ctx || CGRectIsEmpty(tile)) return;
    W7DrawNavPaneRow(ctx, tile, selected, hover);
    W7ComputerTileLayout l = W7ComputerTileLayoutFor(tile);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, tile);
    if (icon) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, l.icon, icon);
    } else {
        W7DrawNavPaneGlyph(ctx, l.icon, fallback);
    }
    CGContextRestoreGState(ctx);
    W7ComputerDrawText(ctx, name ?: @"", l.name, W7UIFont(12), 0x000000);
    if (usedFraction >= 0) {
        W7DrawComputerCapacityBar(ctx, l.bar, usedFraction, low);
        W7ComputerDrawText(ctx, capacityText ?: @"", l.text, W7UIFont(11), kCapacityTextHex);
    }
}
