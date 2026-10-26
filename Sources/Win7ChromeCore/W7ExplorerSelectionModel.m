// Explorer selection model: the item values (+infoForURL: and the folder image scan are the
// only file I/O here, run off the main thread by W7ExplorerSelection.m), then pure logic: the details
// pane's rows, the contextual command set and the Windows 7 highlight colours. No Finder state; the
// details pane, the command bar and the highlight hooks draw what this file decides.
#import "W7ExplorerInternal.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/stat.h>

#pragma mark - Items

#ifndef SF_DATALESS
#define SF_DATALESS 0x40000000
#endif

BOOL W7ExplorerFileIsDataless(NSString *downloadingStatus, uint32_t fileFlags) {
    if (fileFlags & SF_DATALESS) return YES;
    return [downloadingStatus isEqualToString:NSURLUbiquitousItemDownloadingStatusNotDownloaded];
}

/// UTType is not linked into the dylib (only AppKit, QuartzCore, Carbon): looked up at run time.
static BOOL W7TypeConforms(id type, NSString *identifier) {
    Class cls = NSClassFromString(@"UTType");
    if (!type || !cls) return NO;
    UTType *other = [cls typeWithIdentifier:identifier];
    return other && [(UTType *)type conformsToType:other];
}

/// Pixel dimensions from the image header only (no decoding); zero when unknown.
static NSSize W7ImagePixelSize(NSURL *url) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return NSZeroSize;
    NSSize size = NSZeroSize;
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    CFRelease(src);
    NSNumber *w = props[(__bridge NSString *)kCGImagePropertyPixelWidth], *h = props[(__bridge NSString *)kCGImagePropertyPixelHeight];
    if ([w isKindOfClass:NSNumber.class] && [h isKindOfClass:NSNumber.class]) {
        size = NSMakeSize(w.doubleValue, h.doubleValue);
        // EXIF orientations 5–8 are rotated by a quarter turn: Finder shows them the other way round.
        NSNumber *o = props[(__bridge NSString *)kCGImagePropertyOrientation];
        if ([o isKindOfClass:NSNumber.class] && o.integerValue >= 5 && o.integerValue <= 8) size = NSMakeSize(size.height, size.width);
    }
    return size;
}

BOOL W7ExplorerFolderHasImages(NSString *path) {
    if (path.length == 0) return NO;
    NSDirectoryEnumerator<NSURL *> *e = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:path isDirectory:YES]
        includingPropertiesForKeys:@[ NSURLContentTypeKey ]
                           options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsSubdirectoryDescendants |
                                   NSDirectoryEnumerationSkipsPackageDescendants
                      errorHandler:nil];
    NSUInteger seen = 0;
    for (NSURL *url in e) {
        if (++seen > 2000) break;
        id type = nil;
        [url getResourceValue:&type forKey:NSURLContentTypeKey error:NULL];
        if (W7TypeConforms(type, @"public.image")) return YES;
    }
    return NO;
}

@implementation W7ExplorerItemInfo

- (instancetype)init {
    if ((self = [super init])) {
        _name = @"";
        _fileSize = -1;
    }
    return self;
}

+ (instancetype)nameOnlyInfoForURL:(NSURL *)url {
    W7ExplorerItemInfo *info = [[self alloc] init];
    info.url = url;
    info.name = url.lastPathComponent ?: @"";
    return info;
}

+ (instancetype)infoForURL:(NSURL *)url detailed:(BOOL)detailed {
    W7ExplorerItemInfo *info = [self nameOnlyInfoForURL:url];
    // One resource-value read per item; the extra keys only for a single selected item.
    NSMutableArray<NSURLResourceKey> *keys = [@[ NSURLLocalizedNameKey, NSURLContentTypeKey, NSURLIsDirectoryKey,
                                                 NSURLIsPackageKey, NSURLFileSizeKey, NSURLContentModificationDateKey ] mutableCopy];
    if (detailed)
        [keys addObjectsFromArray:@[ NSURLLocalizedTypeDescriptionKey, NSURLCreationDateKey, NSURLUbiquitousItemDownloadingStatusKey ]];
    NSDictionary<NSURLResourceKey, id> *v = [url resourceValuesForKeys:keys error:NULL];
    if (!v) return info;
    if ([v[NSURLLocalizedNameKey] isKindOfClass:NSString.class]) info.name = v[NSURLLocalizedNameKey];
    if ([v[NSURLLocalizedTypeDescriptionKey] isKindOfClass:NSString.class]) info.typeName = v[NSURLLocalizedTypeDescriptionKey];
    info.isFolder = [v[NSURLIsDirectoryKey] boolValue] && ![v[NSURLIsPackageKey] boolValue];
    if (!info.isFolder && [v[NSURLFileSizeKey] isKindOfClass:NSNumber.class]) info.fileSize = [v[NSURLFileSizeKey] longLongValue];
    if ([v[NSURLContentModificationDateKey] isKindOfClass:NSDate.class]) info.modified = v[NSURLContentModificationDateKey];
    if ([v[NSURLCreationDateKey] isKindOfClass:NSDate.class]) info.created = v[NSURLCreationDateKey];
    id type = v[NSURLContentTypeKey];
    if (info.isFolder) return info;
    info.isImage = W7TypeConforms(type, @"public.image");   // in-memory type checks, no I/O
    info.isPrintable = info.isImage || W7TypeConforms(type, @"com.adobe.pdf") || W7TypeConforms(type, @"public.text");
    if (!detailed) return info;
    info.hasDefaultApp = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:url] != nil;
    if (info.isImage) {
        NSString *status = [v[NSURLUbiquitousItemDownloadingStatusKey] isKindOfClass:NSString.class] ? v[NSURLUbiquitousItemDownloadingStatusKey] : nil;
        struct stat st;
        uint32_t flags = lstat(url.fileSystemRepresentation, &st) == 0 ? st.st_flags : 0;
        if (!W7ExplorerFileIsDataless(status, flags)) info.pixelSize = W7ImagePixelSize(url);
    }
    return info;
}

@end

#pragma mark - Details rows

@implementation W7ExplorerDetailsContent

- (instancetype)initWithTitle:(NSString *)title style:(W7ExplorerDetailsTitleStyle)style subtitle:(NSString *)subtitle
                       labels:(NSArray<NSString *> *)labels values:(NSArray<NSString *> *)values {
    if ((self = [super init])) {
        _title = [title copy] ?: @"";
        _titleStyle = style;
        _subtitle = [subtitle copy];
        NSUInteger n = MIN(labels.count, values.count);
        _labels = [[labels subarrayWithRange:NSMakeRange(0, n)] copy];
        _values = [[values subarrayWithRange:NSMakeRange(0, n)] copy];
    }
    return self;
}

- (BOOL)isEqual:(id)other {
    if (other == self) return YES;
    if (![other isKindOfClass:W7ExplorerDetailsContent.class]) return NO;
    W7ExplorerDetailsContent *o = other;
    return [_title isEqualToString:o.title] && _titleStyle == o.titleStyle &&
           (_subtitle == o.subtitle || [_subtitle isEqualToString:o.subtitle]) &&
           [_labels isEqualToArray:o.labels] && [_values isEqualToArray:o.values];
}

- (NSUInteger)hash { return _title.hash ^ _values.hash; }

@end

NSString *W7ExplorerSizeText(long long bytes, NSLocale *locale) {
    if (bytes < 0) return @"—";
    if (bytes < 1000) return bytes == 1 ? @"1 byte" : [NSString stringWithFormat:@"%lld bytes", bytes];
    static NSString *const units[] = { @"KB", @"MB", @"GB", @"TB", @"PB" };
    double value = bytes / 1000.0;
    NSUInteger unit = 0;
    // A value that would round to 1000 moves up a unit ("1 MB", not "1000 KB").
    while (unit < 4 && value >= 999.5) { value /= 1000.0; unit++; }
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.locale = locale;
    f.numberStyle = NSNumberFormatterDecimalStyle;
    f.usesGroupingSeparator = NO;
    f.roundingMode = NSNumberFormatterRoundHalfUp;
    f.minimumFractionDigits = 0;
    f.maximumFractionDigits = value < 99.95 ? 1 : 0;
    NSString *number = [f stringFromNumber:@(value)] ?: [NSString stringWithFormat:@"%.0f", value];
    return [NSString stringWithFormat:@"%@ %@", number, units[unit]];
}

NSString *W7ExplorerDateText(NSDate *date, NSLocale *locale, NSTimeZone *timeZone) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = locale;
    f.timeZone = timeZone;
    f.dateStyle = NSDateFormatterShortStyle;
    f.timeStyle = NSDateFormatterShortStyle;
    // Windows puts a space between date and time, without the comma some locales use.
    NSString *text = [f stringFromDate:date] ?: @"";
    return [text stringByReplacingOccurrencesOfString:@", " withString:@" "];
}

W7ExplorerDetailsContent *W7ExplorerDetailsForItems(NSArray<W7ExplorerItemInfo *> *items, NSString *folderTitle,
                                                    NSInteger folderItemCount, NSLocale *locale, NSTimeZone *timeZone) {
    NSMutableArray<NSString *> *labels = [NSMutableArray array], *values = [NSMutableArray array];
    void (^row)(NSString *, NSString *) = ^(NSString *label, NSString *value) {
        if (!value.length) return;
        [labels addObject:label];
        [values addObject:value];
    };
    NSString *(^dateText)(NSDate *) = ^NSString *(NSDate *d) { return d ? W7ExplorerDateText(d, locale, timeZone) : nil; };

    if (items.count == 0) {
        NSString *count = W7ItemCountText(folderItemCount);
        return [[W7ExplorerDetailsContent alloc] initWithTitle:count.length ? count : (folderTitle ?: @"")
                                                         style:W7ExplorerDetailsTitlePlain subtitle:nil labels:@[] values:@[]];
    }
    if (items.count == 1) {
        W7ExplorerItemInfo *item = items.firstObject;
        row(@"Date modified:", dateText(item.modified));
        if (item.isFolder) {
            return [[W7ExplorerDetailsContent alloc] initWithTitle:item.name style:W7ExplorerDetailsTitleName
                                                          subtitle:@"File folder" labels:labels values:values];
        }
        if (item.fileSize >= 0) row(@"Size:", W7ExplorerSizeText(item.fileSize, locale));
        row(@"Date created:", dateText(item.created));
        if (item.isImage && item.pixelSize.width > 0 && item.pixelSize.height > 0)
            row(@"Dimensions:", [NSString stringWithFormat:@"%.0f x %.0f", item.pixelSize.width, item.pixelSize.height]);
        return [[W7ExplorerDetailsContent alloc] initWithTitle:item.name style:W7ExplorerDetailsTitleName
                                                      subtitle:item.typeName.length ? item.typeName : nil labels:labels values:values];
    }
    NSDate *first = nil, *last = nil;
    long long total = 0;
    BOOL anyFile = NO;
    for (W7ExplorerItemInfo *item in items) {
        if (item.modified) {
            if (!first || [item.modified compare:first] == NSOrderedAscending) first = item.modified;
            if (!last || [item.modified compare:last] == NSOrderedDescending) last = item.modified;
        }
        if (!item.isFolder && item.fileSize >= 0) { anyFile = YES; total += item.fileSize; }
    }
    if (first) {
        NSString *a = dateText(first), *b = dateText(last);
        row(@"Date modified:", [a isEqualToString:b] ? a : [NSString stringWithFormat:@"%@ - %@", a, b]);
    }
    row(@"Size:", anyFile ? W7ExplorerSizeText(total, locale) : @"—");
    return [[W7ExplorerDetailsContent alloc] initWithTitle:[NSString stringWithFormat:@"%lu items selected", (unsigned long)items.count]
                                                     style:W7ExplorerDetailsTitleHeading subtitle:nil labels:labels values:values];
}

const NSUInteger W7ExplorerSelectionReadLimit = 1000;

W7ExplorerDetailsContent *W7ExplorerDetailsForUnreadSelection(NSUInteger count) {
    return [[W7ExplorerDetailsContent alloc] initWithTitle:[NSString stringWithFormat:@"%lu items selected", (unsigned long)count]
                                                     style:W7ExplorerDetailsTitleHeading subtitle:nil labels:@[] values:@[]];
}

#pragma mark - Command set

NSArray<NSNumber *> *W7ExplorerCommandsForUnreadSelection(void) {
    return @[ @(W7ExplorerCommandOrganize), @(W7ExplorerCommandOpen), @(W7ExplorerCommandBurn), @(W7ExplorerCommandNewFolder) ];
}

NSArray<NSNumber *> *W7ExplorerCommandsForItems(NSArray<W7ExplorerItemInfo *> *items, BOOL folderHasImages) {
    NSMutableArray<NSNumber *> *c = [NSMutableArray arrayWithObject:@(W7ExplorerCommandOrganize)];
    NSUInteger folders = 0, images = 0, printable = 0;
    for (W7ExplorerItemInfo *item in items) {
        if (item.isFolder) { folders++; continue; }
        if (item.isImage) images++;
        if (item.isPrintable) printable++;
    }
    NSUInteger files = items.count - folders;
    BOOL single = items.count == 1;
    if (single && files == 1) {
        [c addObject:@(items.firstObject.hasDefaultApp ? W7ExplorerCommandOpenMenu : W7ExplorerCommandOpenWith)];
    } else if (items.count > 0) {
        [c addObject:@(W7ExplorerCommandOpen)];
    }
    [c addObject:@(W7ExplorerCommandShare)];
    if (items.count == 0 ? folderHasImages : images > 0) [c addObject:@(W7ExplorerCommandSlideShow)];
    if (files > 0 && folders == 0) {
        if (printable == files) [c addObject:@(W7ExplorerCommandPrint)];
        [c addObject:@(W7ExplorerCommandEmail)];
    }
    [c addObject:@(W7ExplorerCommandBurn)];
    [c addObject:@(W7ExplorerCommandNewFolder)];
    return c;
}

NSString *W7ExplorerCommandTitle(W7ExplorerCommand command) {
    switch (command) {
        case W7ExplorerCommandOrganize: return @"Organize";
        case W7ExplorerCommandOpen:
        case W7ExplorerCommandOpenMenu: return @"Open";
        case W7ExplorerCommandOpenWith: return @"Open with";
        case W7ExplorerCommandShare: return @"Share with";
        case W7ExplorerCommandSlideShow: return @"Slide show";
        case W7ExplorerCommandPrint: return @"Print";
        case W7ExplorerCommandEmail: return @"E-mail";
        case W7ExplorerCommandBurn: return @"Burn";
        case W7ExplorerCommandNewFolder: return @"New folder";
        case W7ExplorerCommandSystemProperties: return @"System properties";
        case W7ExplorerCommandUninstallProgram: return @"Uninstall or change a program";
        case W7ExplorerCommandMapNetworkDrive: return @"Map network drive";
        case W7ExplorerCommandOpenControlPanel: return @"Open Control Panel";
        default: return @"";
    }
}

BOOL W7ExplorerCommandHasMenu(W7ExplorerCommand command) {
    return command == W7ExplorerCommandOrganize || command == W7ExplorerCommandOpenMenu ||
           command == W7ExplorerCommandOpenWith || command == W7ExplorerCommandShare;
}

#pragma mark - Highlight colours

const CGFloat W7ExplorerSelectionRadius = 3;

W7ExplorerSelectionColors W7ExplorerSelectionColorsForState(W7ExplorerSelectionState state) {
    switch (state) {
        case W7ExplorerSelectionHover: return (W7ExplorerSelectionColors){ 0xB8D6FB, 0xEBF4FD, 0xDBEAFC, true };
        case W7ExplorerSelectionSelected: return (W7ExplorerSelectionColors){ 0x84ACDD, 0xDCEBFC, 0xC1DBFC, true };
        case W7ExplorerSelectionSelectedUnfocused: return (W7ExplorerSelectionColors){ 0xD9D9D9, 0xF8F8F8, 0xE5E5E5, true };
        default: return (W7ExplorerSelectionColors){ 0, 0, 0, false };
    }
}

W7ExplorerSelectionState W7ExplorerSelectionStateFor(BOOL selected, BOOL focused, BOOL hovered) {
    if (selected) return focused ? W7ExplorerSelectionSelected : W7ExplorerSelectionSelectedUnfocused;
    return hovered ? W7ExplorerSelectionHover : W7ExplorerSelectionNone;
}

void W7DrawExplorerSelection(CGContextRef ctx, CGRect rect, W7ExplorerSelectionState state, BOOL flipped) {
    W7ExplorerSelectionColors c = W7ExplorerSelectionColorsForState(state);
    if (!c.visible || !ctx || CGRectGetWidth(rect) < 2 || CGRectGetHeight(rect) < 2) return;
    CGFloat r = W7ExplorerSelectionRadius;
    CGContextSaveGState(ctx);
    CGPathRef outer = CGPathCreateWithRoundedRect(rect, r, r, NULL);
    CGContextAddPath(ctx, outer);
    CGContextClip(ctx);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    W7RGBA top = W7RGBAFromHex(c.top, 1), bottom = W7RGBAFromHex(c.bottom, 1);
    CGFloat comps[] = { top.r, top.g, top.b, 1, bottom.r, bottom.g, bottom.b, 1 };
    CGFloat locs[] = { 0, 1 };
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    CGFloat yTop = flipped ? CGRectGetMinY(rect) : CGRectGetMaxY(rect), yBottom = flipped ? CGRectGetMaxY(rect) : CGRectGetMinY(rect);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, yTop), CGPointMake(0, yBottom), 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
    // The border: the rounded rect minus the same rect inset by 1, so it sits inside `rect`.
    CGPathRef inner = CGPathCreateWithRoundedRect(CGRectInset(rect, 1, 1), MAX(r - 1, 0), MAX(r - 1, 0), NULL);
    CGContextAddPath(ctx, outer);
    CGContextAddPath(ctx, inner);
    W7RGBA b = W7RGBAFromHex(c.border, 1);
    CGContextSetRGBFillColor(ctx, b.r, b.g, b.b, 1);
    CGContextEOFillPath(ctx);
    CGPathRelease(inner);
    CGPathRelease(outer);
    CGContextRestoreGState(ctx);
}

BOOL W7ExplorerAppearanceIsDark(NSAppearance *appearance) {
    if (!appearance) return NO;
    NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

W7ExplorerIconTitleLook W7ExplorerIconTitleLookFor(BOOL finderBubble, BOOL dark) {
    return finderBubble && !dark ? W7ExplorerIconTitleDarkNoBubble : W7ExplorerIconTitleFinder;
}

NSColor *W7ExplorerIconTitleDarkColor(BOOL dimmed) {
    return [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:dimmed ? 0.5 : 1];
}

BOOL W7ExplorerSelectionHighlightShouldInstall(NSString *bundleID, BOOL disabled) {
    return !disabled && [bundleID isEqualToString:@"com.apple.finder"];
}
