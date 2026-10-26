// Restyles Finder's own sidebar as the Windows 7 navigation pane and its list-view column headers as
// Windows 7 headers. Restyle only: nothing is renamed, moved or removed. Views are found by public
// class and style, never by Finder's private class names, and anything unexpected is skipped.
//
// Sidebar rows: modern NSTableRowViews draw their selection with a layer-backed subview (not
// -drawSelectionInRect:), and AppKit KVO-observes some of them, so rows are not subclassed. Each row
// gets selectionHighlightStyle None plus a decoration subview at the back that draws the Windows 7
// hover/selection and, on section rows, the tree triangle.
//
// Tree look (off with W7ExplorerNavPaneDisabled and in a dark appearance, where the 
// look stays): the Explorer highlight colours (W7DrawExplorerSelection), an icon before each section
// title by the tree node it stands for (W7NavPaneGroupKindFor), and the ▷/◢ expander in place of
// AppKit's show/hide chevron, which stays in the row (transparent) so a click on the expander can
// press it — Finder's own collapse behaviour, nothing re-implemented. Row icons and the child indent
// come from the TSidebarItemCell hooks (W7ExplorerNavPaneIcons.m); cells made before the hooks were
// installed are refreshed here. The Locations header is Windows 7's Computer node: right of the expander, a click
// on it performs Finder's own Go ▸ Computer (not with W7ComputerViewDisabled).
//
// Column headers: the header view gets a per-class dynamic subclass (as KVO does) that overrides
// drawRect: only; a header whose isa someone else already swizzled (KVO) is left alone.
#import "W7ExplorerInternal.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kHeaderPrefix = @"W7ColumnHeader_";
static const void *kHoverRowKey = &kHoverRowKey;
static const void *kSidebarStyledKey = &kSidebarStyledKey;
static const void *kBackingKey = &kBackingKey;
static const void *kTrackerKey = &kTrackerKey;
static const void *kDecorKey = &kDecorKey;
static const NSTimeInterval kScanInterval = 1.0;
static const NSUInteger kMaxVisitedViews = 4000;
static const CGFloat kTriangleX = 3;
static const CGFloat kStarSize = 13;
/// The expander's click area at the left of a section row.
static const CGFloat kExpanderHitWidth = 14;
static const void *kHeaderIconKey = &kHeaderIconKey;
static const void *kExpanderHitKey = &kExpanderHitKey;
static const void *kShowHideHiddenKey = &kShowHideHiddenKey;
static const void *kComputerHitKey = &kComputerHitKey;

static NSOutlineView *W7RowOutline(NSView *row) {
    NSView *v = row.superview;
    while (v && ![v isKindOfClass:NSOutlineView.class]) v = v.superview;
    return (NSOutlineView *)v;
}

static NSInteger W7HoverRow(NSTableView *tv) {
    NSNumber *n = tv ? objc_getAssociatedObject(tv, kHoverRowKey) : nil;
    return n ? n.integerValue : -1;
}

#pragma mark - Row decoration

/// AppKit's show/hide chevron of a section row (NSOutlineViewShowHideButtonKey), or nil.
static NSButton *W7ShowHideButton(NSTableRowView *row) {
    for (NSView *v in row.subviews)
        if ([v isKindOfClass:NSButton.class] && [v.identifier isEqualToString:NSOutlineViewShowHideButtonKey]) return (NSButton *)v;
    return nil;
}

/// Back-most subview of a sidebar row: the hover/selection highlight and the section triangle.
@interface W7NavPaneRowDecor : NSView
/// The row it last showed; a reused row view redraws it.
@property (nonatomic) NSInteger shownRow;
@end

@implementation W7NavPaneRowDecor
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
    @try {
        NSTableRowView *row = [self.superview isKindOfClass:NSTableRowView.class] ? (NSTableRowView *)self.superview : nil;
        NSOutlineView *ov = row ? W7RowOutline(row) : nil;
        if (!ov) return;
        NSInteger r = [ov rowForView:row];
        if (r < 0) return;
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        NSRect b = self.bounds;
        BOOL hover = r == W7HoverRow(ov);
        BOOL tree = W7NavPaneTreeActive(ov);
        // Inset 2 pt from the sides, as Windows 7's navigation pane does.
        NSRect highlight = NSMakeRect(NSMinX(b) + 2, NSMinY(b), MAX(0, NSWidth(b) - 4), NSHeight(b));
        if (tree) W7DrawExplorerSelection(ctx, highlight, W7ExplorerSelectionStateFor(row.isSelected, row.isEmphasized, hover), NO);
        else W7DrawNavPaneRow(ctx, highlight, row.isSelected, hover);
        if (row.isGroupRowStyle) {
            id item = [ov itemAtRow:r];
            W7DrawTreeExpander(ctx, NSMakeRect(NSMinX(b) + kTriangleX, NSMinY(b), 8, NSHeight(b)), item && [ov isItemExpanded:item],
                               tree && hover);
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer nav pane row draw failed: %{public}@", e.reason ?: @"unknown");
    }
}
@end

/// A section title without the icon attachment and space the restyle put in front of it.
static NSString *W7HeaderTitle(NSTextField *tf) {
    NSString *s = tf.attributedStringValue.string ?: @"";
    if (s.length >= 2 && [s characterAtIndex:0] == NSAttachmentCharacter) return [s substringFromIndex:2];
    return s;
}

/// Puts `icon` (or nothing) in front of a section title; `key` names the icon so an unchanged one is
/// not rebuilt on every pass.
static void W7SetHeaderIcon(NSTextField *tf, NSImage *icon, NSString *key, NSFont *font) {
    NSString *title = W7HeaderTitle(tf);
    if (title.length == 0) return;
    NSString *s = tf.attributedStringValue.string;
    BOOL decorated = s.length && [s characterAtIndex:0] == NSAttachmentCharacter;
    if (icon ? (decorated && [objc_getAssociatedObject(tf, kHeaderIconKey) isEqualToString:key]) : !decorated) return;
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor };
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    if (icon) {
        NSTextAttachment *att = [NSTextAttachment new];
        att.image = icon;
        CGFloat side = icon.size.height;
        // A tree icon is centred on the capitals; the star sat on the descender.
        CGFloat y = side > kStarSize ? round((font.capHeight - side) / 2) : floor(font.descender);
        att.bounds = NSMakeRect(0, y, icon.size.width, side);
        [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:attrs]];
    }
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:title attributes:attrs]];
    tf.attributedStringValue = text;
    objc_setAssociatedObject(tf, kHeaderIconKey, icon ? key : nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

/// The row's labels in the Windows 7 font. Section rows read as tree roots: normal weight, black, with
/// `headerIcon` (named `iconKey`) in front of the unchanged title.
/// Our own views in a row (the decoration, the expander's click area): never styled or searched.
static BOOL W7IsOwnRowView(NSView *v) {
    return strncmp(class_getName(object_getClass(v)), "W7NavPane", 9) == 0;
}

/// The first view of `cls` in `row`, breadth-first over at most four levels, skipping buttons and our
/// own views. Finder's section headers are not always table cell views with a textField outlet.
static __kindof NSView *W7RowFind(NSView *row, Class cls) {
    NSArray<NSView *> *level = row.subviews;
    for (int depth = 0; depth < 4 && level.count; depth++) {
        NSMutableArray<NSView *> *next = [NSMutableArray array];
        for (NSView *v in level) {
            if ([v isKindOfClass:NSButton.class] || W7IsOwnRowView(v)) continue;
            if ([v isKindOfClass:cls]) return v;
            [next addObjectsFromArray:v.subviews];
        }
        level = next;
    }
    return nil;
}

/// The row's title: a table cell view's textField, else the first text field in it.
static NSTextField *W7RowTitleField(NSTableRowView *row) {
    for (NSView *v in row.subviews)
        if ([v isKindOfClass:NSTableCellView.class] && ((NSTableCellView *)v).textField) return ((NSTableCellView *)v).textField;
    return W7RowFind(row, NSTextField.class);
}

/// The row's icon: a table cell view's imageView, else the first image view in it.
static NSImageView *W7RowImageView(NSTableRowView *row) {
    for (NSView *v in row.subviews)
        if ([v isKindOfClass:NSTableCellView.class] && ((NSTableCellView *)v).imageView) return ((NSTableCellView *)v).imageView;
    return W7RowFind(row, NSImageView.class);
}

/// The cell holding `view`: its nearest table cell view, else the row's direct subview it is in.
static NSView *W7RowCellFor(NSView *view, NSTableRowView *row) {
    NSView *v = view;
    while (v && v.superview != row && ![v isKindOfClass:NSTableCellView.class]) v = v.superview;
    return v;
}

static void W7StyleRowText(NSTableRowView *row, NSImage *headerIcon, NSString *iconKey) {
    NSFont *font = W7UIFont(12);
    NSTextField *tf = W7RowTitleField(row);
    if (!tf) return;
    if (![tf.font isEqual:font]) tf.font = font;
    // Plain black instead of the system label colours, which turn grey over vibrancy; any other
    // colour Finder chose on purpose (a dimmed or tinted item) is kept.
    NSColor *c = tf.textColor;
    BOOL systemLabel = c.type == NSColorTypeCatalog && [@[ @"labelColor", @"secondaryLabelColor", @"controlTextColor",
                                                           @"textColor", @"headerTextColor" ] containsObject:c.colorNameComponent];
    if (systemLabel || (row.isGroupRowStyle && ![c isEqual:NSColor.blackColor])) tf.textColor = NSColor.blackColor;
    if (row.isGroupRowStyle) W7SetHeaderIcon(tf, headerIcon, iconKey, font);
}

#pragma mark - Expander

/// The click area over a section row's ▷/◢: presses AppKit's own (transparent) show/hide button, so
/// Finder expands or collapses the section exactly as it does for that button.
@interface W7NavPaneExpanderHit : NSView
@end

@implementation W7NavPaneExpanderHit
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)mouseDown:(NSEvent *)e {
    if (![self w7Toggle]) [super mouseDown:e];
}
/// NO when the row has no show/hide button to press.
- (BOOL)w7Toggle {
    @try {
        NSTableRowView *row = [self.superview isKindOfClass:NSTableRowView.class] ? (NSTableRowView *)self.superview : nil;
        NSButton *button = row ? W7ShowHideButton(row) : nil;
        if (!button) return NO;
        [button performClick:self];
        return YES;
    } @catch (NSException *x) {
        os_log_error(W7Log(), "Explorer nav pane expander failed: %{public}@", x.reason ?: @"unknown");
        return NO;
    }
}
@end

/// A section row in the tree look: AppKit's chevron transparent (still in place and working) and the
/// expander's click area in front. Otherwise both as AppKit left them.
static void W7StyleSectionExpander(NSTableRowView *row, BOOL tree) {
    NSButton *button = W7ShowHideButton(row);
    if (button && tree && button.alphaValue != 0) {
        button.alphaValue = 0;
        objc_setAssociatedObject(button, kShowHideHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (button && !tree && objc_getAssociatedObject(button, kShowHideHiddenKey)) {
        button.alphaValue = 1;
        objc_setAssociatedObject(button, kShowHideHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    W7NavPaneExpanderHit *hit = objc_getAssociatedObject(row, kExpanderHitKey);
    if (!tree) {
        hit.hidden = YES;
        return;
    }
    if (!hit) {
        hit = [[W7NavPaneExpanderHit alloc] initWithFrame:NSMakeRect(0, 0, kExpanderHitWidth, NSHeight(row.bounds))];
        hit.autoresizingMask = NSViewHeightSizable;
        objc_setAssociatedObject(row, kExpanderHitKey, hit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    hit.hidden = NO;
    // In front of the cell, which may reach under the expander.
    if (row.subviews.lastObject != hit) [row addSubview:hit positioned:NSWindowAbove relativeTo:nil];
}

#pragma mark - Computer node

/// The Locations header right of the expander: a click goes to Finder's Computer location (W7ExplorerGoToComputer,
/// Finder's own Go ▸ Computer item), as Windows 7's Computer node does. Anything else passes on to the row, and so
/// does a Control-click, which is a right-click (the outline view's context menu).
@interface W7NavPaneComputerHit : NSView
@end

BOOL W7NavPaneComputerClickNavigates(NSEventModifierFlags flags) { return (flags & NSEventModifierFlagControl) == 0; }

@implementation W7NavPaneComputerHit
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)mouseDown:(NSEvent *)e {
    if (!W7NavPaneComputerClickNavigates(e.modifierFlags) || ![self w7GoToComputer]) [super mouseDown:e];
}
- (BOOL)w7GoToComputer {
    @try { return W7ExplorerGoToComputer(self.window); }
    @catch (NSException *x) {
        os_log_error(W7Log(), "Explorer nav pane Computer click failed: %{public}@", x.reason ?: @"unknown");
        return NO;
    }
}
@end

/// The Computer click area on a Locations header (`show`), behind the expander's; hidden on any other row.
static void W7StyleComputerHit(NSTableRowView *row, BOOL show) {
    W7NavPaneComputerHit *hit = objc_getAssociatedObject(row, kComputerHitKey);
    if (!show) {
        hit.hidden = YES;
        return;
    }
    if (!hit) {
        hit = [[W7NavPaneComputerHit alloc] initWithFrame:NSZeroRect];
        hit.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        objc_setAssociatedObject(row, kComputerHitKey, hit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSRect target = NSMakeRect(kExpanderHitWidth, 0, MAX(0, NSWidth(row.bounds) - kExpanderHitWidth), NSHeight(row.bounds));
    if (!NSEqualRects(hit.frame, target)) hit.frame = target;
    hit.hidden = NO;
    NSView *expander = objc_getAssociatedObject(row, kExpanderHitKey);
    if (expander.superview != row) expander = nil;
    NSArray<NSView *> *subs = row.subviews;
    NSUInteger at = [subs indexOfObjectIdenticalTo:hit];
    BOOL placed = expander ? (at != NSNotFound && at + 1 < subs.count && subs[at + 1] == expander) : subs.lastObject == hit;
    // In front of the cell, behind the expander's click area.
    if (!placed) [row addSubview:hit positioned:expander ? NSWindowBelow : NSWindowAbove relativeTo:expander];
}

#pragma mark - Hover tracking

/// Owns the sidebar's hover tracking area and records the hovered row on the outline view.
@interface W7NavPaneTracker : NSObject
- (instancetype)initWithOutline:(NSOutlineView *)outline;
- (void)detach;
@end

@implementation W7NavPaneTracker {
    __weak NSOutlineView *_outline;
    NSTrackingArea *_area;
}

- (instancetype)initWithOutline:(NSOutlineView *)outline {
    if ((self = [super init])) {
        _outline = outline;
        _area = [[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
              owner:self userInfo:nil];
        [outline addTrackingArea:_area];
    }
    return self;
}

- (void)detach {
    NSOutlineView *ov = _outline;
    if (ov && _area) [ov removeTrackingArea:_area];
    _area = nil;
}

- (void)w7SetHover:(NSInteger)row {
    NSOutlineView *ov = _outline;
    if (!ov) return;
    NSInteger old = W7HoverRow(ov);
    if (old == row) return;
    objc_setAssociatedObject(ov, kHoverRowKey, @(row), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSInteger changed[2] = { old, row };
    for (int i = 0; i < 2; i++) {
        if (changed[i] < 0 || changed[i] >= ov.numberOfRows) continue;
        NSTableRowView *rv = [ov rowViewAtRow:changed[i] makeIfNecessary:NO];
        [(NSView *)objc_getAssociatedObject(rv, kDecorKey) setNeedsDisplay:YES];
    }
}

- (void)mouseMoved:(NSEvent *)e {
    @try {
        NSOutlineView *ov = _outline;
        if (!ov) return;
        [self w7SetHover:[ov rowAtPoint:[ov convertPoint:e.locationInWindow fromView:nil]]];
    } @catch (NSException *x) { os_log_error(W7Log(), "Explorer nav pane hover failed: %{public}@", x.reason ?: @"unknown"); }
}
- (void)mouseEntered:(NSEvent *)e { [self mouseMoved:e]; }
- (void)mouseExited:(NSEvent *)e {
    @try { [self w7SetHover:-1]; }
    @catch (NSException *x) { os_log_error(W7Log(), "Explorer nav pane hover exit failed: %{public}@", x.reason ?: @"unknown"); }
}

@end

#pragma mark - White backing

/// Opaque white under the sidebar, covering its vibrancy. Never hit.
@interface W7NavPaneBacking : NSView
@end
@implementation W7NavPaneBacking
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirty { [NSColor.whiteColor setFill]; NSRectFill(dirty); }
@end

#pragma mark - Column headers

/// The dynamic class `prefix<base>` (created and registered once; `add` installs its methods).
static Class W7DynamicSubclass(Class base, NSString *prefix, void (^add)(Class cls)) {
    NSString *name = [prefix stringByAppendingString:NSStringFromClass(base)];
    Class cls = NSClassFromString(name);
    if (cls) return cls;
    cls = objc_allocateClassPair(base, name.UTF8String, 0);
    if (!cls) return Nil;
    add(cls);
    objc_registerClassPair(cls);
    return cls;
}

/// Gives `obj` the dynamic subclass. YES when it has it (now or already); NO when its isa is someone
/// else's dynamic class (KVO), which is left alone.
static BOOL W7AdoptDynamicSubclass(id obj, NSString *prefix, void (^add)(Class cls)) {
    Class current = object_getClass(obj);
    // C class names, so the walk allocates nothing: a header Finder keeps under KVO is
    // retried on every scan.
    const char *cPrefix = prefix.UTF8String;
    size_t prefixLen = strlen(cPrefix);
    for (Class c = current; c; c = class_getSuperclass(c))
        if (strncmp(class_getName(c), cPrefix, prefixLen) == 0) return YES;
    if (current != [obj class]) return NO;
    Class sub = W7DynamicSubclass(current, prefix, add);
    if (!sub) return NO;
    object_setClass(obj, sub);
    return YES;
}

/// `r` (in a flipped view of height `h`) as the matching rect for drawing un-flipped.
static NSRect W7Unflip(NSRect r, CGFloat h) { return NSMakeRect(NSMinX(r), h - NSMaxY(r), NSWidth(r), NSHeight(r)); }

/// The class our dynamic subclass was made from. Works under a later KVO subclass too.
static Class W7HeaderOriginalClass(id obj) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c))
        if ([NSStringFromClass(c) hasPrefix:kHeaderPrefix]) return class_getSuperclass(c);
    return object_getClass(obj);
}

/// The sort arrow for `col`: the table's indicator image (by name for the standard ones), else its
/// sort descriptors, else its highlighted column. `image` gets a non-standard indicator to draw as is.
static BOOL W7HeaderSortDirection(NSTableView *tv, NSTableColumn *col, W7ChevronDirection *dir, NSImage **image) {
    NSImage *indicator = [tv indicatorImageInTableColumn:col];
    if (indicator) {
        if ([indicator.name isEqualToString:@"NSAscendingSortIndicator"]) { *dir = W7ChevronUp; return YES; }
        if ([indicator.name isEqualToString:@"NSDescendingSortIndicator"]) { *dir = W7ChevronDown; return YES; }
        *image = indicator;
        return YES;
    }
    NSSortDescriptor *sort = tv.sortDescriptors.firstObject;
    NSString *key = col.sortDescriptorPrototype.key;
    if (sort && key && [sort.key isEqualToString:key]) { *dir = sort.ascending ? W7ChevronUp : W7ChevronDown; return YES; }
    if (tv.highlightedTableColumn == col) { *dir = (!sort || sort.ascending) ? W7ChevronUp : W7ChevronDown; return YES; }
    return NO;
}

static void W7HeaderDrawRect(NSTableHeaderView *self, SEL _cmd, NSRect dirty) {
    @try {
        // While a column is being dragged, AppKit's own drawing shows the movement.
        if (self.draggedColumn >= 0) {
            struct objc_super sup = { self, W7HeaderOriginalClass(self) };
            ((void (*)(struct objc_super *, SEL, NSRect))objc_msgSendSuper)(&sup, _cmd, dirty);
            return;
        }
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        NSRect b = self.bounds;
        CGFloat h = NSHeight(b);
        BOOL flipped = self.isFlipped;
        // Theme drawing expects a bottom-left origin: undo the header's flip around it.
        CGContextSaveGState(ctx);
        if (flipped) { CGContextTranslateCTM(ctx, 0, h); CGContextScaleCTM(ctx, 1, -1); }
        W7DrawColumnHeader(ctx, b);
        CGContextRestoreGState(ctx);

        NSTableView *tv = self.tableView;
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        NSFont *font = W7UIFont(12);
        W7RGBA tc = W7RGBAFromHex(W7ColumnHeaderTextHex, 1);
        NSColor *color = [NSColor colorWithSRGBRed:tc.r green:tc.g blue:tc.b alpha:1];
        CGFloat th = ceil(font.ascender - font.descender);
        NSArray<NSTableColumn *> *cols = tv.tableColumns;
        for (NSInteger i = 0; i < (NSInteger)cols.count; i++) {
            NSTableColumn *col = cols[(NSUInteger)i];
            if (col.hidden) continue;
            NSRect r = [self headerRectOfColumn:i];
            if (NSIsEmptyRect(r) || !NSIntersectsRect(r, dirty)) continue;
            NSString *title = col.headerCell.stringValue.length ? col.headerCell.stringValue : (col.title ?: @"");
            ps.alignment = col.headerCell.alignment == NSTextAlignmentRight ? NSTextAlignmentRight : NSTextAlignmentLeft;
            NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: ps };
            // Text is drawn in the view's own (possibly flipped) coordinates; NSString handles the flip.
            [title drawInRect:NSMakeRect(NSMinX(r) + 6, floor(NSMidY(r) - th / 2), MAX(0, NSWidth(r) - 14), th) withAttributes:attrs];
            NSRect u = flipped ? W7Unflip(r, h) : r;
            W7ChevronDirection dir = W7ChevronUp;
            NSImage *indicator = nil;
            BOOL sorted = W7HeaderSortDirection(tv, col, &dir, &indicator);
            if (indicator) {   // someone else's indicator: drawn as given, at the top centre
                NSSize is = indicator.size;
                CGFloat ih = MIN(is.height, 8), iw = is.height > 0 ? is.width * ih / is.height : 0;
                NSRect ir = NSMakeRect(NSMidX(r) - iw / 2, flipped ? NSMinY(r) + 1 : NSMaxY(r) - 1 - ih, iw, ih);
                [indicator drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
                       respectFlipped:YES hints:nil];
            }
            CGContextSaveGState(ctx);
            if (flipped) { CGContextTranslateCTM(ctx, 0, h); CGContextScaleCTM(ctx, 1, -1); }
            // Windows 7 puts the sort arrow at the top centre of the column header.
            if (sorted && !indicator) W7DrawChevron(ctx, NSMakePoint(NSMidX(u), NSMaxY(u) - 4), dir, 0x97A5B9, 1);
            W7DrawColumnHeaderSeparator(ctx, NSMaxX(u) - 1, u);
            CGContextRestoreGState(ctx);
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer column header draw failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// As KVO does: the object still reports its original class.
static Class W7HeaderClass(id self, __unused SEL _cmd) { return W7HeaderOriginalClass(self); }

static BOOL W7HeaderIsOpaque(__unused NSTableHeaderView *self, __unused SEL _cmd) { return YES; }
static BOOL W7HeaderWantsUpdateLayer(__unused NSTableHeaderView *self, __unused SEL _cmd) { return NO; }

static void W7AddHeaderMethods(Class cls) {
    Method draw = class_getInstanceMethod(NSView.class, @selector(drawRect:));
    Method opaque = class_getInstanceMethod(NSView.class, @selector(isOpaque));
    Method update = class_getInstanceMethod(NSView.class, @selector(wantsUpdateLayer));
    if (draw) class_addMethod(cls, @selector(drawRect:), (IMP)W7HeaderDrawRect, method_getTypeEncoding(draw));
    if (opaque) class_addMethod(cls, @selector(isOpaque), (IMP)W7HeaderIsOpaque, method_getTypeEncoding(opaque));
    if (update) class_addMethod(cls, @selector(wantsUpdateLayer), (IMP)W7HeaderWantsUpdateLayer, method_getTypeEncoding(update));
    Method klass = class_getInstanceMethod(NSObject.class, @selector(class));
    if (klass) class_addMethod(cls, @selector(class), (IMP)W7HeaderClass, method_getTypeEncoding(klass));
}

#pragma mark - Row icons the styler keeps (only for cells that are not the hooked class)

static const NSTimeInterval kIconKeepInterval = 0.2;

/// For a row whose cell is not the hooked class (the -image hook and W7NavPaneRefreshCell look after
/// those): its image view shows its Windows 7 icon by title, or Finder's again when the tree look is
/// off. YES when it changed. `looked` counts rows actually checked.
static BOOL W7KeepRowIcon(NSTableRowView *rv, NSUInteger *looked) {
    if (rv.isGroupRowStyle) return NO;
    NSImageView *iv = W7RowImageView(rv);
    if (!iv) return NO;
    NSView *cell = W7RowCellFor(iv, rv);
    if (W7NavPaneCellIsHooked(cell)) return NO;
    if (looked) (*looked)++;
    NSTextField *tf = W7RowTitleField(rv);
    BOOL changed = W7NavPaneSyncRowIcon(iv, cell, tf.stringValue);
    static BOOL logged;
    if (changed && !logged && W7NavPaneDiagnosticsEnabled()) {
        logged = YES;
        W7NavPaneNoteDiagnosticLine();
        os_log(W7Log(), "nav pane: styler set row icon '%{public}@' -> %{public}@ (image view %{public}@ in %{public}@)",
               tf.stringValue ?: @"", W7NavPaneRowIconName(cell, tf.stringValue) ?: @"(Finder's restored)",
               NSStringFromClass(iv.class), cell ? NSStringFromClass(cell.class) : @"-");
    }
    if (changed) cell.needsLayout = YES;
    return changed;
}

NSUInteger W7NavPaneKeepRowIcons(NSOutlineView *ov) {
    NSUInteger looked = 0;
    @try {
        // The periodic pass only keeps our icons up; a switch to dark or the kill switch is undone once,
        // by the row restyle the tree-look change triggers (w7StyleRows).
        if (!ov || !W7NavPaneTreeActive(ov)) return 0;
        NSRange range = [ov rowsInRect:ov.visibleRect];
        for (NSUInteger r = range.location; r < NSMaxRange(range) && r < range.location + 200; r++) {
            NSTableRowView *rv = [ov rowViewAtRow:(NSInteger)r makeIfNecessary:NO];
            if (rv) W7KeepRowIcon(rv, &looked);
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer nav pane icon keeping failed: %{public}@", e.reason ?: @"unknown");
    }
    return looked;
}

#pragma mark - Diagnostics (what Finder's sidebar is made of; only with W7ExplorerNavPaneDiagnostics)

static NSString *W7ClassChain(id object) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (Class c = object_getClass(object); c && names.count < 5; c = class_getSuperclass(c)) [names addObject:@(class_getName(c))];
    return [names componentsJoinedByString:@" < "];
}

static NSString *W7ColorText(NSColor *c) {
    if (!c) return @"nil";
    if (c.type == NSColorTypeCatalog) return c.colorNameComponent;
    NSColor *rgb = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return rgb ? [NSString stringWithFormat:@"#%02X%02X%02X", (int)(rgb.redComponent * 255), (int)(rgb.greenComponent * 255),
                                            (int)(rgb.blueComponent * 255)]
               : NSStringFromClass(c.class);
}

/// One view and (down to depth 3) its subviews, for the log.
static NSString *W7DescribeView(NSView *v, int depth) {
    NSMutableString *s = [NSMutableString stringWithString:NSStringFromClass(v.class)];
    if (v.hidden) [s appendString:@" hidden"];
    if ([v isKindOfClass:NSImageView.class]) {
        NSImage *img = ((NSImageView *)v).image;
        [s appendFormat:@"(image %@ %.0fx%.0f template %d ours %d tint %@)", img.name ?: (img ? NSStringFromClass(img.class) : @"nil"),
                        img.size.width, img.size.height, img.isTemplate, W7NavPaneImageIsOurs(img),
                        W7ColorText(((NSImageView *)v).contentTintColor)];
    } else if ([v isKindOfClass:NSTextField.class]) {
        NSTextField *tf = (NSTextField *)v;
        NSString *text = tf.stringValue.length > 24 ? [tf.stringValue substringToIndex:24] : tf.stringValue;
        [s appendFormat:@"('%@' %@ %@)", text, W7ColorText(tf.textColor), tf.font.fontName ?: @"-"];
    } else if ([v isKindOfClass:NSTableCellView.class]) {
        NSTableCellView *cell = (NSTableCellView *)v;
        [s appendFormat:@"[textField %d imageView %d objectValue %@]", cell.textField != nil, cell.imageView != nil,
                        cell.objectValue ? NSStringFromClass([cell.objectValue class]) : @"nil"];
    }
    if (depth < 3 && v.subviews.count) {
        NSMutableArray<NSString *> *kids = [NSMutableArray array];
        for (NSView *sub in v.subviews) [kids addObject:W7DescribeView(sub, depth + 1)];
        [s appendFormat:@" {%@}", [kids componentsJoinedByString:@"; "]];
    }
    return s;
}

/// Once per process and phase: the sidebar outline, its first rows' views, which cell classes they
/// use, what each row maps to, and how often each hook ran ("never called" lines after 2 s).
static void W7LogSidebarDiagnostics(NSOutlineView *ov, NSString *phase) {
    @try {
        static NSMutableSet<NSString *> *done;
        if (!done) done = [NSMutableSet set];
        if ([done containsObject:phase]) return;
        [done addObject:phase];
        W7NavPaneNoteDiagnosticLine();   // the dump counts as one
        NSMutableArray<NSString *> *supers = [NSMutableArray array];
        for (NSView *v = ov.superview; v && supers.count < 8; v = v.superview) [supers addObject:NSStringFromClass(v.class)];
        os_log(W7Log(), "nav pane diag (%{public}@): sidebar %{public}@, delegate %{public}@, rows %ld, tree look %d, window %{public}s, in %{public}@",
               phase, W7ClassChain(ov), ov.delegate ? NSStringFromClass([(NSObject *)ov.delegate class]) : @"nil", (long)ov.numberOfRows,
               W7NavPaneTreeActive(ov), W7ExplorerAppearanceIsDark(ov.window.effectiveAppearance) ? "dark" : "light",
               [supers componentsJoinedByString:@" < "]);
        Class hooked = NSClassFromString(@"TSidebarItemCell");
        NSUInteger cells = 0, hookedCells = 0;
        NSMutableSet<NSString *> *others = [NSMutableSet set];
        for (NSInteger r = 0; r < ov.numberOfRows && r < 24; r++) {
            NSTableRowView *rv = [ov rowViewAtRow:r makeIfNecessary:NO];
            if (!rv) continue;
            NSString *text = W7DescribeView(rv, 0);
            if (text.length > 900) text = [[text substringToIndex:900] stringByAppendingString:@"…"];
            os_log(W7Log(), "nav pane diag: row %ld level %ld group %d selected %d emphasized %d highlight style %ld: %{public}@",
                   (long)r, (long)[ov levelForRow:r], rv.isGroupRowStyle, rv.isSelected, rv.isEmphasized,
                   (long)rv.selectionHighlightStyle, text);
            for (NSView *v in rv.subviews) {
                if (W7IsOwnRowView(v) || [v isKindOfClass:NSButton.class]) continue;
                cells++;
                if (hooked && [v isKindOfClass:hooked]) hookedCells++;
                else [others addObject:NSStringFromClass(v.class)];
            }
            NSImageView *iv = rv.isGroupRowStyle ? nil : W7RowImageView(rv);
            NSTextField *tf = W7RowTitleField(rv);
            if (iv)
                os_log(W7Log(), "nav pane diag: row %ld '%{public}@' maps to %{public}@", (long)r, tf.stringValue ?: @"",
                       W7NavPaneRowIconName(W7RowCellFor(iv, rv), tf.stringValue) ?: @"(none: Finder's icon)");
        }
        os_log(W7Log(), "nav pane diag (%{public}@): %lu row subviews, %lu TSidebarItemCell (class %{public}s), others: %{public}@",
               phase, (unsigned long)cells, (unsigned long)hookedCells, hooked ? "present" : "missing",
               others.count ? [others.allObjects componentsJoinedByString:@", "] : @"none");
        os_log(W7Log(), "nav pane diag (%{public}@): hook calls: %{public}@", phase, W7NavPaneHookCallSummary());
        if ([phase isEqualToString:@"after 2 s"]) {
            const char *names[] = { "-image", "-imageSize", "-_textFieldFrame", "-setFrame:", "-viewDidMoveToWindow" };
            for (NSInteger k = 0; k < W7NavPaneHookKindCount; k++)
                if (W7NavPaneHookCallCount(k) == 0) os_log(W7Log(), "nav pane diag: %{public}s never called in 2 s", names[k]);
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "nav pane diagnostics failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark - Styler

/// Each adopted window's styler (weak both ways), for W7NavPaneRefreshStylerForWindow. Main thread.
static NSMapTable<NSWindow *, W7ExplorerContentStyler *> *gStylers;

void W7NavPaneRefreshStylerForWindow(NSWindow *window) {
    if (window) [[gStylers objectForKey:window] refresh];
}

static BOOL W7IsSourceList(NSTableView *tv) {
    if (tv.style == NSTableViewStyleSourceList) return YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return tv.selectionHighlightStyle == NSTableViewSelectionHighlightStyleSourceList;
#pragma clang diagnostic pop
}

@implementation W7ExplorerContentStyler {
    __weak NSWindow *_window;
    __weak NSOutlineView *_sidebar;
    NSHashTable<NSTableHeaderView *> *_headers;
    NSHashTable<NSView *> *_decors;
    CFAbsoluteTime _lastScan;
    CFAbsoluteTime _lastIconKeep;
    BOOL _loggedMissing;
    NSDictionary<NSNumber *, NSNumber *> *_sectionOrdinals;
    NSInteger _sectionOrdinalRows;
    /// The tree look the rows were last styled in; a change restyles them.
    BOOL _styledTree;
    // What the rows were last styled for; restyling runs only when this changes (or is forced).
    NSInteger _styledRows;
    NSRange _styledRange;
    __weak NSTableRowView *_styledFirst, *_styledLast;
    BOOL _restyle;
    W7ExplorerSidebarKeeper *_keeper;
}

- (instancetype)initWithWindow:(NSWindow *)window {
    if ((self = [super init])) {
        _window = window;
        _headers = [NSHashTable weakObjectsHashTable];
        _decors = [NSHashTable weakObjectsHashTable];
        _keeper = [[W7ExplorerSidebarKeeper alloc] initWithWindow:window];
        _lastScan = -1e9;
        W7ExplorerInstallNavPaneHooks();   // once; Finder only, kill switch W7ExplorerNavPaneDisabled
        if (!gStylers) gStylers = [NSMapTable weakToWeakObjectsMapTable];
        [gStylers setObject:self forKey:window];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    NSOutlineView *ov = _sidebar;
    W7NavPaneTracker *t = ov ? objc_getAssociatedObject(ov, kTrackerKey) : nil;
    [t detach];
}

- (void)refresh {
    @try {
        NSWindow *w = _window;
        if (!w.contentView) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSOutlineView *sidebar = _sidebar;
        if (now - _lastScan >= kScanInterval || (sidebar && sidebar.window != w)) {
            _lastScan = now;
            [self w7Scan:w];
            _sectionOrdinals = nil;
            sidebar = _sidebar;
            // The first scan runs at adoption; later ones are the throttled maintenance pass.
            [_keeper checkSidebar:sidebar];
        }
        if (sidebar && [self w7RowsChanged:sidebar]) [self w7StyleRows:sidebar];
        // Cells that are not the hooked class may get Finder's icon back by any path: rechecked at most
        // every kIconKeepInterval, and only while the window refreshes (activity).
        if (sidebar && now - _lastIconKeep >= kIconKeepInterval) {
            _lastIconKeep = now;
            W7NavPaneKeepRowIcons(sidebar);
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer content restyle failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// Breadth-first over the content view: the first source-list outline is the sidebar; every table
/// header view gets the Windows 7 look.
- (void)w7Scan:(NSWindow *)w {
    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:w.contentView];
    NSOutlineView *sidebar = nil;
    NSUInteger visited = 0;
    while (queue.count && visited < kMaxVisitedViews) {
        NSView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (!sidebar && [v isKindOfClass:NSOutlineView.class] && W7IsSourceList((NSTableView *)v)) sidebar = (NSOutlineView *)v;
        if ([v isKindOfClass:NSTableHeaderView.class]) {
            // Windows 7's Details view has no zebra stripes. Checked on every scan: Finder may turn
            // them back on when it rebuilds the list.
            NSTableView *list = ((NSTableHeaderView *)v).tableView;
            if (list.usesAlternatingRowBackgroundColors) list.usesAlternatingRowBackgroundColors = NO;
        }
        if ([v isKindOfClass:NSTableHeaderView.class] && ![_headers containsObject:(NSTableHeaderView *)v]) {
            if (W7AdoptDynamicSubclass(v, kHeaderPrefix, ^(Class cls) { W7AddHeaderMethods(cls); })) {
                [_headers addObject:(NSTableHeaderView *)v];
                v.needsDisplay = YES;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }
    if (sidebar && sidebar != _sidebar) {
        _sidebar = sidebar;
        _restyle = YES;
        [self w7StyleSidebar:sidebar];
    } else if (!sidebar && !_loggedMissing) {
        _loggedMissing = YES;
        os_log(W7Log(), "Explorer: no source-list sidebar found in %{public}@; navigation pane not restyled",
               NSStringFromClass(w.contentView.class));
    }
}

- (void)w7StyleSidebar:(NSOutlineView *)ov {
    if (objc_getAssociatedObject(ov, kSidebarStyledKey)) return;
    objc_setAssociatedObject(ov, kSidebarStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ov.backgroundColor = NSColor.whiteColor;
    NSScrollView *scroll = ov.enclosingScrollView;
    // Plain (non-vibrant) light appearance: vibrant text renders grey and heavier over white.
    (scroll ?: ov).appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    if (scroll) {
        scroll.drawsBackground = YES;
        scroll.backgroundColor = NSColor.whiteColor;
        scroll.contentView.drawsBackground = YES;
        scroll.contentView.backgroundColor = NSColor.whiteColor;
    }
    // No vibrancy: an opaque white view at the back of the nearest visual-effect container.
    NSView *v = scroll ?: ov;
    while (v && ![v isKindOfClass:NSVisualEffectView.class] && v != ov.window.contentView) v = v.superview;
    if ([v isKindOfClass:NSVisualEffectView.class] && !objc_getAssociatedObject(v, kBackingKey)) {
        W7NavPaneBacking *backing = [[W7NavPaneBacking alloc] initWithFrame:v.bounds];
        backing.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [v addSubview:backing positioned:NSWindowBelow relativeTo:nil];
        objc_setAssociatedObject(v, kBackingKey, backing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    W7NavPaneTracker *tracker = [[W7NavPaneTracker alloc] initWithOutline:ov];
    objc_setAssociatedObject(ov, kTrackerKey, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[ NSOutlineViewSelectionDidChangeNotification, NSOutlineViewItemDidExpandNotification,
                                       NSOutlineViewItemDidCollapseNotification ]) {
        [nc addObserver:self selector:@selector(w7SidebarChanged:) name:name object:ov];
    }
    os_log(W7Log(), "Explorer: navigation pane restyled (%{public}@)", NSStringFromClass(ov.class));
    if (W7NavPaneDiagnosticsEnabled()) {
        W7LogSidebarDiagnostics(ov, @"adoption");
        __weak NSOutlineView *weakOutline = ov;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSOutlineView *later = weakOutline;
            if (later) W7LogSidebarDiagnostics(later, @"after 2 s");
        });
    }
}

- (void)w7SidebarChanged:(NSNotification *)n {
    @try {
        for (NSView *d in _decors) d.needsDisplay = YES;
        _restyle = YES;   // expanding adds rows; a selection change can re-create cell views
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Explorer nav pane change failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// Ordinal of each section (group) row among the sections, keyed by row, so a scrolled-off Favorites
/// still counts as first. Asks the outline's delegate through the public NSOutlineViewDelegate
/// method; recomputed when the row count changes.
- (NSDictionary<NSNumber *, NSNumber *> *)w7SectionOrdinals:(NSOutlineView *)ov {
    NSInteger rows = ov.numberOfRows;
    if (_sectionOrdinals && rows == _sectionOrdinalRows) return _sectionOrdinals;
    NSMutableDictionary<NSNumber *, NSNumber *> *ordinals = [NSMutableDictionary dictionary];
    id<NSOutlineViewDelegate> delegate = ov.delegate;
    BOOL asks = [delegate respondsToSelector:@selector(outlineView:isGroupItem:)];
    NSInteger ordinal = 0;
    for (NSInteger r = 0; asks && r < rows && r < 2000; r++) {
        if ([ov levelForRow:r] != 0) continue;
        id item = [ov itemAtRow:r];
        if (item && [delegate outlineView:ov isGroupItem:item]) ordinals[@(r)] = @(ordinal++);
    }
    _sectionOrdinals = ordinals;
    _sectionOrdinalRows = rows;
    return ordinals;
}

/// YES when the row count, the visible range or the row views at its ends changed since the last
/// styling (or a restyle was requested), so the 10 Hz refresh normally does no work.
- (BOOL)w7RowsChanged:(NSOutlineView *)ov {
    NSInteger rows = ov.numberOfRows;
    NSRange range = [ov rowsInRect:ov.visibleRect];
    NSTableRowView *first = range.length ? [ov rowViewAtRow:(NSInteger)range.location makeIfNecessary:NO] : nil;
    NSTableRowView *last = range.length ? [ov rowViewAtRow:(NSInteger)NSMaxRange(range) - 1 makeIfNecessary:NO] : nil;
    BOOL tree = W7NavPaneTreeActive(ov);
    BOOL changed = _restyle || rows != _styledRows || !NSEqualRanges(range, _styledRange) ||
                   first != _styledFirst || last != _styledLast || tree != _styledTree;
    if (tree != _styledTree)
        for (NSView *d in _decors) d.needsDisplay = YES;   // the highlight colours change with it
    _styledTree = tree;
    _restyle = NO;
    _styledRows = rows;
    _styledRange = range;
    _styledFirst = first;
    _styledLast = last;
    return changed;
}

/// The Windows 7 tree node of the section at `row`: by its title, else by its visible children's icons.
static W7NavPaneGroupKind W7SectionKind(NSOutlineView *ov, NSTableRowView *rowView, NSInteger row) {
    NSTextField *tf = W7RowTitleField(rowView);
    NSString *title = tf ? W7HeaderTitle(tf) : nil;
    NSMutableArray<NSString *> *children = [NSMutableArray array];
    for (NSInteger r = row + 1; r < ov.numberOfRows && r <= row + 50; r++) {
        NSTableRowView *child = [ov rowViewAtRow:r makeIfNecessary:NO];
        if (child.isGroupRowStyle || [ov levelForRow:r] == 0) break;
        NSImageView *iv = child ? W7RowImageView(child) : nil;
        NSString *name = iv ? W7NavPaneRowIconName(W7RowCellFor(iv, child), W7RowTitleField(child).stringValue) : nil;
        if (name) [children addObject:name];
    }
    return W7NavPaneGroupKindFor(title, children);
}

- (void)w7StyleRows:(NSOutlineView *)ov {
    NSDictionary<NSNumber *, NSNumber *> *ordinals = [self w7SectionOrdinals:ov];
    NSHashTable<NSView *> *decors = _decors;
    BOOL tree = W7NavPaneTreeActive(ov);
    [ov enumerateAvailableRowViewsUsingBlock:^(__kindof NSTableRowView *rowView, NSInteger row) {
        @try {
            if (rowView.selectionHighlightStyle != NSTableViewSelectionHighlightStyleNone)
                rowView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
            W7NavPaneRowDecor *decor = objc_getAssociatedObject(rowView, kDecorKey);
            if (!decor) {
                decor = [[W7NavPaneRowDecor alloc] initWithFrame:rowView.bounds];
                decor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                objc_setAssociatedObject(rowView, kDecorKey, decor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [decors addObject:decor];
            }
            // Right under the cells: above AppKit's own row backgrounds (a floating section row's
            // banner view), below the icon and text.
            NSArray<NSView *> *subs = rowView.subviews;
            NSUInteger firstCell = [subs indexOfObjectPassingTest:^BOOL(NSView *v, __unused NSUInteger i, __unused BOOL *stop) {
                return [v isKindOfClass:NSTableCellView.class];
            }];
            NSView *anchor = firstCell == NSNotFound ? nil : subs[firstCell];
            BOOL placed = decor.superview == rowView &&
                          (anchor ? [subs indexOfObjectIdenticalTo:decor] + 1 == firstCell : subs.firstObject == decor);
            if (!placed) [rowView addSubview:decor positioned:NSWindowBelow relativeTo:anchor];
            if (decor.shownRow != row) { decor.shownRow = row; decor.needsDisplay = YES; }
            NSImage *headerIcon = nil;
            NSString *iconKey = nil;
            if (rowView.isGroupRowStyle) {
                W7StyleSectionExpander(rowView, tree);
                if (tree) {
                    W7NavPaneGroupKind kind = W7SectionKind(ov, rowView, row);
                    headerIcon = W7NavPaneGroupIconImage(kind, W7NavPaneIconSize);
                    iconKey = [NSString stringWithFormat:@"tree-%ld", (long)kind];
                    W7StyleComputerHit(rowView, kind == W7NavPaneGroupLocations && !W7ComputerViewDisabled());
                } else if ([ordinals[@(row)] isEqual:@0]) {
                    // The look: a star in front of the first section only.
                    headerIcon = W7NavPaneGroupIconImage(W7NavPaneGroupFavorites, kStarSize);
                    iconKey = @"star";
                }
                if (!tree) W7StyleComputerHit(rowView, NO);
            } else {
                [(NSView *)objc_getAssociatedObject(rowView, kExpanderHitKey) setHidden:YES];   // a reused section row
                W7StyleComputerHit(rowView, NO);
                for (NSView *v in rowView.subviews) W7NavPaneRefreshCell(v);
                W7KeepRowIcon(rowView, NULL);
            }
            W7StyleRowText(rowView, headerIcon, iconKey);
        } @catch (NSException *e) {
            os_log_error(W7Log(), "Explorer nav pane row restyle failed: %{public}@", e.reason ?: @"unknown");
        }
    }];
}

@end
