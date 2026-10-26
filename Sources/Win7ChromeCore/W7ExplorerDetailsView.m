// The Windows 7 details pane's drawing: up to three stacked icons on the left, then the
// title (a name in bold, or "N items selected"), the kind under it in grey, and name/value rows in
// columns of three. W7ExplorerDetailsPane.m places the view and feeds it.
#import "W7ExplorerInternal.h"

static const CGFloat kIconSide = 48;
static const CGFloat kStackedSide = 40;     // each icon of a stack; 4 pt offsets keep it within 48 pt
static const CGFloat kLeftInset = 12;
static const CGFloat kIconTextGap = 12;
static const CGFloat kRightInset = 12;
static const CGFloat kTopInset = 6;
static const CGFloat kRowPitch = 16;
static const NSUInteger kRowsPerColumn = 3;
static const CGFloat kColumnGap = 24;
static const CGFloat kLabelValueGap = 6;
static const CGFloat kMaxTitleWidth = 300;
static const CGFloat kMaxValueWidth = 220;
static const uint32_t kLabelHex = 0x5A677C;   // Windows 7's grey-blue property names

static NSFont *W7DetailsTitleFont(W7ExplorerDetailsTitleStyle style) {
    static NSFont *bold, *large;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        large = W7UIFont(15);
        bold = [NSFontManager.sharedFontManager convertFont:large toHaveTrait:NSBoldFontMask] ?: large;
    });
    switch (style) {
        case W7ExplorerDetailsTitleName: return bold;
        case W7ExplorerDetailsTitleHeading: return large;
        default: return W7ExplorerFont();
    }
}

static NSColor *W7HexColor(uint32_t hex) {
    W7RGBA c = W7RGBAFromHex(hex, 1);
    return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:1];
}

static NSDictionary<NSAttributedStringKey, id> *W7TextAttributes(NSFont *font, NSColor *color, NSTextAlignment alignment) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineBreakMode = NSLineBreakByTruncatingTail;
    p.alignment = alignment;
    return @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: p };
}

/// One laid-out string.
@interface W7DetailsText : NSObject
@property (nonatomic, copy) NSString *string;
@property (nonatomic, copy) NSDictionary<NSAttributedStringKey, id> *attributes;
@property (nonatomic) NSRect frame;
@end

@implementation W7DetailsText
+ (instancetype)text:(NSString *)string attributes:(NSDictionary *)attributes frame:(NSRect)frame {
    W7DetailsText *t = [self new];
    t.string = string ?: @"";
    t.attributes = attributes;
    t.frame = frame;
    return t;
}
@end

@implementation W7ExplorerDetailsView {
    NSArray<W7DetailsText *> *_layout;   // nil: stale
    NSSize _layoutSize;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) _icons = @[];
    return self;
}

- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setContent:(W7ExplorerDetailsContent *)content {
    if (_content == content || [_content isEqual:content]) return;
    _content = content;
    _layout = nil;
    self.needsDisplay = YES;
}

- (void)setIcons:(NSArray<NSImage *> *)icons {
    icons = icons ?: @[];
    if ([_icons isEqualToArray:icons]) return;
    _icons = [icons copy];
    self.needsDisplay = YES;
}

- (NSRect)iconFrame {
    return NSMakeRect(kLeftInset, floor(NSMidY(self.bounds) - kIconSide / 2), kIconSide, kIconSide);
}

- (NSArray<NSValue *> *)textFrames {
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    for (W7DetailsText *t in [self w7Layout]) [frames addObject:[NSValue valueWithRect:t.frame]];
    return frames;
}

/// The title and subtitle make the first column; then the rows, in columns of three (labels
/// right-aligned, values left-aligned), each column only when all of it fits.
- (NSArray<W7DetailsText *> *)w7Layout {
    NSSize size = self.bounds.size;
    if (_layout && NSEqualSizes(size, _layoutSize)) return _layout;
    NSMutableArray<W7DetailsText *> *out = [NSMutableArray array];
    W7ExplorerDetailsContent *c = _content;
    CGFloat x = NSMaxX(self.iconFrame) + kIconTextGap, limit = size.width - kRightInset;
    if (c && limit > x) {
        NSDictionary *titleAttrs = W7TextAttributes(W7DetailsTitleFont(c.titleStyle), NSColor.blackColor, NSTextAlignmentLeft);
        NSDictionary *greyAttrs = W7TextAttributes(W7ExplorerFont(), W7HexColor(kLabelHex), NSTextAlignmentLeft);
        NSSize ts = [c.title sizeWithAttributes:titleAttrs];
        NSSize ss = c.subtitle.length ? [c.subtitle sizeWithAttributes:greyAttrs] : NSZeroSize;
        CGFloat th = ceil(ts.height), sh = ceil(ss.height);
        CGFloat colW = MIN(MIN(ceil(MAX(ts.width, ss.width)), kMaxTitleWidth), limit - x);
        BOOL oneLine = c.subtitle.length == 0 && c.labels.count == 0;
        CGFloat top = oneLine ? floor((size.height + th) / 2) : size.height - kTopInset;
        W7DetailsText *title = [W7DetailsText text:c.title attributes:titleAttrs frame:NSMakeRect(x, top - th, colW, th)];
        [out addObject:title];
        if (c.subtitle.length)
            [out addObject:[W7DetailsText text:c.subtitle attributes:greyAttrs frame:NSMakeRect(x, NSMinY(title.frame) - sh, colW, sh)]];
        x += colW + kColumnGap;

        NSDictionary *labelAttrs = W7TextAttributes(W7ExplorerFont(), W7HexColor(kLabelHex), NSTextAlignmentRight);
        NSDictionary *valueAttrs = W7TextAttributes(W7ExplorerFont(), NSColor.blackColor, NSTextAlignmentLeft);
        CGFloat rowH = MIN(kRowPitch, ceil([@"Hg" sizeWithAttributes:valueAttrs].height));
        for (NSUInteger start = 0; start < c.labels.count; start += kRowsPerColumn) {
            NSUInteger n = MIN(kRowsPerColumn, c.labels.count - start);
            CGFloat lw = 0, vw = 0;
            for (NSUInteger i = start; i < start + n; i++) {
                lw = MAX(lw, ceil([c.labels[i] sizeWithAttributes:labelAttrs].width));
                vw = MAX(vw, ceil([c.values[i] sizeWithAttributes:valueAttrs].width));
            }
            vw = MIN(vw, kMaxValueWidth);
            if (x + lw + kLabelValueGap + vw > limit) break;   // this column and every one after it
            for (NSUInteger i = start; i < start + n; i++) {
                CGFloat y = size.height - kTopInset - (CGFloat)(i - start + 1) * kRowPitch + (kRowPitch - rowH);
                [out addObject:[W7DetailsText text:c.labels[i] attributes:labelAttrs frame:NSMakeRect(x, y, lw, rowH)]];
                [out addObject:[W7DetailsText text:c.values[i] attributes:valueAttrs
                                             frame:NSMakeRect(x + lw + kLabelValueGap, y, vw, rowH)]];
            }
            x += lw + kLabelValueGap + vw + kColumnGap;
        }
    }
    _layout = out;
    _layoutSize = size;
    return out;
}

- (void)drawRect:(NSRect)dirty {
    @try {
        W7DrawDetailsPane(NSGraphicsContext.currentContext.CGContext, self.bounds);
        NSRect icon = self.iconFrame;
        NSArray<NSImage *> *icons = _icons;
        if (icons.count == 1) {
            [self w7DrawIcon:icons.firstObject in:icon];
        } else if (icons.count > 1) {
            // Back to front: the first icon is the front one at the bottom left, the others 4 pt up and right.
            for (NSUInteger i = MIN(icons.count, 3); i-- > 0;)
                [self w7DrawIcon:icons[i] in:NSMakeRect(NSMinX(icon) + 4 * i, NSMinY(icon) + 4 * i, kStackedSide, kStackedSide)];
        }
        for (W7DetailsText *t in [self w7Layout]) [t.string drawInRect:t.frame withAttributes:t.attributes];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer details draw failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// `image` fitted (aspect kept) and centred in `rect`.
- (void)w7DrawIcon:(NSImage *)image in:(NSRect)rect {
    NSSize s = image.size;
    if (!(s.width > 0) || !(s.height > 0)) return;
    CGFloat scale = MIN(NSWidth(rect) / s.width, NSHeight(rect) / s.height);
    NSSize d = NSMakeSize(round(s.width * scale), round(s.height * scale));
    NSRect r = NSMakeRect(round(NSMidX(rect) - d.width / 2), round(NSMidY(rect) - d.height / 2), d.width, d.height);
    [image drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

@end
