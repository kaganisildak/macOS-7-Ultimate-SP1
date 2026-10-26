// Finder's Computer location shown as the Windows 7 Computer view: "Hard Disk Drives", "Devices with
// Removable Storage" and "Network Location" groups of drive tiles with capacity bars, over Finder's own view.
//
// Finder's views are never replaced or hidden: the view is an overlay (an NSScrollView) in the browser side of the
// window's split view, under the details pane, shown only while the window is on the Computer location
// (W7ExplorerIsComputerLocation over the Explorer controller's existing location model: no hook, no AppleScript of
// its own) and taken away the moment the title changes (a navigation), the location changes, or anything fails.
// Volume facts come from URL resource values (W7ComputerReadVolumeFacts), read once per show and again on NSWorkspace
// mount, unmount and rename notifications, on one serial queue, one read at a time (a notification during a read asks
// for one more after it), with a 10 s budget: a hung network mount never piles up workers, and with nothing shown yet
// the overlay fails open. Nothing is read per frame, and no path, name or serial number is logged.
// Kill switch: `defaults write -g W7ComputerViewDisabled -bool YES`.
#import "W7ExplorerInternal.h"
#import <sys/sysctl.h>

static const CGFloat kMargin = 14;
static const CGFloat kTopInset = 8;
static const CGFloat kHeaderGap = 2;
static const CGFloat kTileGapX = 8;
static const CGFloat kTileGapY = 4;
static const CGFloat kGroupGap = 10;
static const CGFloat kDetailsIconSide = 48;
static const NSTimeInterval kReadBudget = 10;
static NSString *const kShellBundleID = @"com.win7mac.shell";

static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand;
static const NSEventModifierFlags kShiftCmd = NSEventModifierFlagShift | NSEventModifierFlagCommand;

#pragma mark - Switches and seams

static NSInteger gDisabledOverride = -1;

BOOL W7ComputerViewDisabled(void) {
    if (gDisabledOverride >= 0) return gDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7ComputerViewDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

void W7ComputerViewUseDisabledOverride(NSInteger value) { gDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

static NSString *gHostName;        // main thread
static NSString *gNameOverride;    // tests
static BOOL gNameOverridden;

NSString *W7ComputerName(void) {
    if (gNameOverridden) return gNameOverride;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // NSHost may wait on the name services: once, off the main thread; the answer is kept on the main thread.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *name = nil;
            @try { name = [NSHost.currentHost.localizedName copy]; }
            @catch (NSException *e) { os_log_error(W7Log(), "computer view: host name failed: %{public}@", e.reason ?: @"unknown"); }
            dispatch_async(dispatch_get_main_queue(), ^{ gHostName = name; });
        });
    });
    return gHostName;
}

void W7ComputerViewUseComputerName(NSString *name) {
    gNameOverridden = name != nil;
    gNameOverride = [name copy];
}

static NSArray<NSDictionary<NSString *, id> *> *(^gFactsProvider)(void);

void W7ComputerViewUseVolumeFacts(NSArray<NSDictionary<NSString *, id> *> *(^provider)(void)) { gFactsProvider = [provider copy]; }

static void (^gVolumeReader)(W7ComputerVolumeReadCompletion);

void W7ComputerViewUseVolumeReader(void (^reader)(W7ComputerVolumeReadCompletion)) { gVolumeReader = [reader copy]; }

static NSTimeInterval gReadBudget;

NSTimeInterval W7ComputerVolumeReadBudget(void) { return gReadBudget > 0 ? gReadBudget : kReadBudget; }

void W7ComputerViewUseReadBudget(NSTimeInterval seconds) { gReadBudget = seconds > 0 ? seconds : 0; }

static NSInteger gShellRunningOverride = -1;
static void (^gCommandSink)(NSString *, NSString *);

void W7ComputerViewUseCommandSink(NSInteger shellRunning, void (^sink)(NSString *, NSString *)) {
    gShellRunningOverride = shellRunning < 0 ? -1 : (shellRunning ? 1 : 0);
    gCommandSink = [sink copy];
}

#pragma mark - Volume facts

NSArray<NSURLResourceKey> *W7ComputerVolumeResourceKeys(void) {
    return @[ NSURLVolumeLocalizedNameKey, NSURLVolumeIsRootFileSystemKey, NSURLVolumeIsInternalKey, NSURLVolumeIsRemovableKey,
              NSURLVolumeIsEjectableKey, NSURLVolumeIsLocalKey, NSURLVolumeIsBrowsableKey, NSURLVolumeTypeNameKey,
              NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeAvailableCapacityKey,
              NSURLVolumeLocalizedFormatDescriptionKey ];
}

NSArray<NSDictionary<NSString *, id> *> *W7ComputerReadVolumeFacts(void) {
    NSMutableArray<NSDictionary<NSString *, id> *> *facts = [NSMutableArray array];
    @try {
        NSArray<NSURLResourceKey> *keys = W7ComputerVolumeResourceKeys();
        NSArray<NSURL *> *urls = [NSFileManager.defaultManager mountedVolumeURLsIncludingResourceValuesForKeys:keys
                                                                                                  options:NSVolumeEnumerationSkipHiddenVolumes];
        for (NSURL *url in urls) {
            NSString *path = url.path;
            if (path.length == 0) continue;
            NSMutableDictionary<NSString *, id> *f = [NSMutableDictionary dictionaryWithDictionary:[url resourceValuesForKeys:keys error:NULL] ?: @{}];
            f[W7ComputerVolumePathKey] = path;
            [facts addObject:f];
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view: volume read failed: %{public}@", e.reason ?: @"unknown");
    }
    return facts;
}

/// "Apple M2" (machdep.cpu.brand_string), read once; nil when unknown.
static NSString *W7ProcessorName(void) {
    static NSString *name;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char buf[256] = { 0 };
        size_t size = sizeof(buf) - 1;
        if (sysctlbyname("machdep.cpu.brand_string", buf, &size, NULL, 0) == 0 && buf[0]) name = @(buf);
    });
    return name;
}

#pragma mark - Icons

static W7NavPaneGlyph W7GlyphForKind(W7ComputerDriveKind kind) {
    switch (kind) {
        case W7ComputerDriveSystem: return W7NavPaneGlyphSystemDrive;
        case W7ComputerDriveInternal: return W7NavPaneGlyphDrive;
        case W7ComputerDriveRemovable: return W7NavPaneGlyphRemovableDrive;
        case W7ComputerDriveOptical: return W7NavPaneGlyphOpticalDrive;
        case W7ComputerDriveNetwork: return W7NavPaneGlyphNetwork;
    }
    return W7NavPaneGlyphDrive;
}

/// The user's icon `name` at `side` (W7UserIconImageSized), else the glyph drawn at that size. A new image.
static NSImage *W7ComputerIconImage(NSString *name, W7NavPaneGlyph glyph, CGFloat side) {
    NSImage *own = W7UserIconImageSized(name, NSMakeSize(side, side));
    if (own) return own;
    return [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect r) {
        W7DrawNavPaneGlyph(NSGraphicsContext.currentContext.CGContext, r, glyph);
        return YES;
    }];
}

#pragma mark - The tiles

@implementation W7ExplorerComputerView {
    NSArray<W7ComputerRow *> *_rows;
    NSInteger _hover;
    NSTrackingArea *_tracking;
    NSMutableDictionary<NSString *, id> *_bitmaps;   // icon name → CGImage or NSNull, per W7UserIconsGeneration
    NSUInteger _bitmapGeneration;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _groups = @[];
        _rows = @[];
        _selectedIndex = _hover = NSNotFound;
        _bitmaps = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (NSMenu *)menuForEvent:(NSEvent *)e { return nil; }   // our own menu, from -rightMouseDown:

- (void)setGroups:(NSArray<W7ComputerGroup *> *)groups {
    NSString *selectedPath = self.selectedRow.path;
    _groups = [groups copy] ?: @[];
    NSMutableArray<W7ComputerRow *> *rows = [NSMutableArray array];
    for (W7ComputerGroup *g in _groups) [rows addObjectsFromArray:g.rows];
    _rows = rows;
    _hover = NSNotFound;
    // The same drive stays selected across a reload (a mount elsewhere); a drive that went away is deselected.
    NSInteger keep = NSNotFound;
    for (NSUInteger i = 0; selectedPath && i < rows.count; i++) if ([rows[i].path isEqualToString:selectedPath]) keep = (NSInteger)i;
    BOOL changed = keep != _selectedIndex || (selectedPath && keep == NSNotFound);
    _selectedIndex = keep;
    [self w7Fit];
    self.needsDisplay = YES;
    if (changed && _onSelectionChange) _onSelectionChange();
}

- (W7ComputerRow *)selectedRow {
    return _selectedIndex >= 0 && _selectedIndex < (NSInteger)_rows.count ? _rows[_selectedIndex] : nil;
}

- (void)selectRowAtIndex:(NSInteger)index {
    NSInteger idx = index >= 0 && index < (NSInteger)_rows.count ? index : NSNotFound;
    if (idx == _selectedIndex) return;
    _selectedIndex = idx;
    self.needsDisplay = YES;
    if (idx != NSNotFound) [self scrollRectToVisible:NSInsetRect([self frameOfRowAtIndex:idx], 0, -kTileGapY)];
    if (_onSelectionChange) _onSelectionChange();
}

#pragma mark Layout

/// Header rects (one per group) and tile rects (one per row) at `width`; returns the height needed.
- (CGFloat)w7LayoutForWidth:(CGFloat)width headers:(NSMutableArray<NSValue *> *)headers tiles:(NSMutableArray<NSValue *> *)tiles {
    NSInteger columns = MAX(1, (NSInteger)floor((width - 2 * kMargin + kTileGapX) / (W7ComputerTileWidth + kTileGapX)));
    CGFloat y = kTopInset;
    for (W7ComputerGroup *g in _groups) {
        [headers addObject:[NSValue valueWithRect:NSMakeRect(kMargin, y, MAX(0, width - 2 * kMargin), W7ComputerGroupHeaderHeight)]];
        y += W7ComputerGroupHeaderHeight + kHeaderGap;
        NSInteger count = (NSInteger)g.rows.count;
        for (NSInteger i = 0; i < count; i++) {
            NSInteger col = i % columns, line = i / columns;
            [tiles addObject:[NSValue valueWithRect:NSMakeRect(kMargin + col * (W7ComputerTileWidth + kTileGapX),
                                                               y + line * (W7ComputerTileHeight + kTileGapY),
                                                               W7ComputerTileWidth, W7ComputerTileHeight)]];
        }
        NSInteger lines = (count + columns - 1) / columns;
        y += lines * (W7ComputerTileHeight + kTileGapY) - (lines ? kTileGapY : 0) + kGroupGap;
    }
    return (_groups.count ? y - kGroupGap : y) + kTopInset;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self w7LayoutForWidth:width headers:[NSMutableArray array] tiles:[NSMutableArray array]];
}

- (NSRect)frameOfRowAtIndex:(NSInteger)index {
    NSMutableArray<NSValue *> *tiles = [NSMutableArray array];
    [self w7LayoutForWidth:NSWidth(self.bounds) headers:[NSMutableArray array] tiles:tiles];
    return index >= 0 && index < (NSInteger)tiles.count ? tiles[index].rectValue : NSZeroRect;
}

- (NSInteger)rowIndexAtPoint:(NSPoint)point {
    NSMutableArray<NSValue *> *tiles = [NSMutableArray array];
    [self w7LayoutForWidth:NSWidth(self.bounds) headers:[NSMutableArray array] tiles:tiles];
    for (NSUInteger i = 0; i < tiles.count; i++) if (NSPointInRect(point, tiles[i].rectValue)) return (NSInteger)i;
    return NSNotFound;
}

/// As wide as the clip view, and as tall as the tiles need (at least the clip view's height).
- (void)w7Fit {
    NSView *clip = self.superview;
    if (!clip) return;
    CGFloat width = NSWidth(clip.bounds);
    NSSize size = NSMakeSize(width, MAX(NSHeight(clip.bounds), [self heightForWidth:width]));
    if (!NSEqualSizes(size, self.frame.size)) [self setFrameSize:size];
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:nil];
    NSView *clip = self.superview;
    if (!clip) return;
    clip.postsFrameChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(w7ClipChanged:) name:NSViewFrameDidChangeNotification object:clip];
    [self w7Fit];
}

- (void)w7ClipChanged:(NSNotification *)n {
    @try { [self w7Fit]; }
    @catch (NSException *e) { os_log_error(W7Log(), "computer view: fit failed: %{public}@", e.reason ?: @"unknown"); }
}

#pragma mark Drawing

/// The tile icon as a CGImage (the user's, W7UserIconBitmap at 2x), or NULL for the drawn glyph.
- (CGImageRef)w7BitmapFor:(NSString *)name {
    NSUInteger generation = W7UserIconsGeneration();
    if (generation != _bitmapGeneration) {
        [_bitmaps removeAllObjects];
        _bitmapGeneration = generation;
    }
    id hit = _bitmaps[name];
    if (!hit) {
        hit = W7UserIconBitmap(name, (size_t)(W7ComputerTileHeight * 2)) ?: NSNull.null;
        _bitmaps[name] = hit;
    }
    return hit == NSNull.null ? NULL : (__bridge CGImageRef)hit;
}

/// Draws with `rect` given in view (flipped) coordinates as a non-flipped rect for the theme.
static void W7DrawUnflipped(CGContextRef ctx, NSRect rect, void (^draw)(CGRect local)) {
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, NSMaxY(rect));
    CGContextScaleCTM(ctx, 1, -1);
    draw(CGRectMake(NSMinX(rect), 0, NSWidth(rect), NSHeight(rect)));
    CGContextRestoreGState(ctx);
}

- (void)drawRect:(NSRect)dirty {
    @try {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
        CGContextFillRect(ctx, dirty);
        NSMutableArray<NSValue *> *headers = [NSMutableArray array], *tiles = [NSMutableArray array];
        [self w7LayoutForWidth:NSWidth(self.bounds) headers:headers tiles:tiles];
        for (NSUInteger g = 0; g < headers.count && g < _groups.count; g++) {
            NSRect r = headers[g].rectValue;
            if (!NSIntersectsRect(r, dirty)) continue;
            NSString *title = _groups[g].title;
            W7DrawUnflipped(ctx, r, ^(CGRect local) { W7DrawComputerGroupHeader(ctx, local, title); });
        }
        for (NSUInteger i = 0; i < tiles.count && i < _rows.count; i++) {
            NSRect r = tiles[i].rectValue;
            if (!NSIntersectsRect(r, dirty)) continue;
            W7ComputerRow *row = _rows[i];
            CGImageRef icon = [self w7BitmapFor:row.iconName];
            BOOL selected = (NSInteger)i == _selectedIndex, hover = (NSInteger)i == _hover;
            W7DrawUnflipped(ctx, r, ^(CGRect local) {
                W7DrawComputerTile(ctx, local, icon, W7GlyphForKind(row.kind), row.name, W7ComputerCapacityText(row.free, row.total),
                                   W7ComputerUsedFraction(row.free, row.total), row.low, selected, hover);
            });
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view: draw failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark Events

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
          owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)w7SetHover:(NSInteger)hover {
    if (hover == _hover) return;
    _hover = hover;
    self.needsDisplay = YES;
}

- (void)mouseMoved:(NSEvent *)e {
    @try { [self w7SetHover:[self rowIndexAtPoint:[self convertPoint:e.locationInWindow fromView:nil]]]; }
    @catch (NSException *x) { os_log_error(W7Log(), "computer view: hover failed: %{public}@", x.reason ?: @"unknown"); }
}

- (void)mouseExited:(NSEvent *)e { [self w7SetHover:NSNotFound]; }

- (void)mouseDown:(NSEvent *)e {
    if (e.modifierFlags & NSEventModifierFlagControl) { [self rightMouseDown:e]; return; }
    @try {
        [self.window makeFirstResponder:self];
        NSInteger idx = [self rowIndexAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
        [self selectRowAtIndex:idx];
        W7ComputerRow *row = self.selectedRow;
        if (e.clickCount == 2 && row && _onOpen) _onOpen(row);
    } @catch (NSException *x) {
        os_log_error(W7Log(), "computer view: click failed: %{public}@", x.reason ?: @"unknown");
    }
}

- (void)rightMouseDown:(NSEvent *)e {
    W7ExplorerComputerView *keep = self;   // a menu action may close the window
    @try {
        [self.window makeFirstResponder:self];
        NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
        [self selectRowAtIndex:[self rowIndexAtPoint:p]];
        W7ComputerRow *row = self.selectedRow;
        NSMenu *menu = row && _menuForRow ? _menuForRow(row) : nil;
        if (!menu) return;
        NSPoint screen = [self.window convertPointToScreen:e.locationInWindow];
        if (![W7MenuWindow showMenu:menu topLeft:screen minWidth:0]) [NSMenu popUpContextMenu:menu withEvent:e forView:self];
    } @catch (NSException *x) {
        os_log_error(W7Log(), "computer view: menu failed: %{public}@", x.reason ?: @"unknown");
    }
    (void)keep;
}

/// The tiles per line at the current width (for Up and Down).
- (NSInteger)w7Columns {
    return MAX(1, (NSInteger)floor((NSWidth(self.bounds) - 2 * kMargin + kTileGapX) / (W7ComputerTileWidth + kTileGapX)));
}

- (void)keyDown:(NSEvent *)e {
    @try {
        NSInteger count = (NSInteger)_rows.count, sel = _selectedIndex;
        switch (e.keyCode) {
            case 36: case 76:   // Return, Enter
                if (self.selectedRow && _onOpen) _onOpen(self.selectedRow);
                return;
            case 123: [self selectRowAtIndex:sel == NSNotFound ? 0 : MAX(0, sel - 1)]; return;                        // ←
            case 124: [self selectRowAtIndex:sel == NSNotFound ? 0 : MIN(count - 1, sel + 1)]; return;                // →
            case 126: [self selectRowAtIndex:sel == NSNotFound ? 0 : MAX(0, sel - [self w7Columns])]; return;          // ↑
            case 125: [self selectRowAtIndex:sel == NSNotFound ? 0 : MIN(count - 1, sel + [self w7Columns])]; return;  // ↓
            default: break;
        }
    } @catch (NSException *x) {
        os_log_error(W7Log(), "computer view: key failed: %{public}@", x.reason ?: @"unknown");
        return;
    }
    [super keyDown:e];
}

@end

#pragma mark - The overlay

@implementation W7ExplorerComputerController {
    __weak W7ExplorerController *_explorer;
    NSScrollView *_scroll;
    W7ExplorerComputerView *_view;
    __weak NSView *_host;
    __weak NSView *_content;          // the content view the overlay was placed for
    __weak NSView *_skippedContent;   // a content view without a browser pane (logged once, searched again each second)
    CFAbsoluteTime _skippedAt;
    NSString *_failedTitle;           // the overlay failed on this title: Finder's view until the window navigates
    NSUInteger _loadToken;            // bumped by every reload and hide: an answer for an older one is dropped
    NSUInteger _readID;               // the read in flight (or the last one)
    BOOL _readInFlight;               // one read at a time, on the one serial queue
    BOOL _readAgain;                  // a reload came during the read: one more read after it
    BOOL _loggedCounts;
    BOOL _observingMounts;
    BOOL _invalidated;
}

- (instancetype)initWithExplorer:(W7ExplorerController *)explorer {
    if ((self = [super init])) _explorer = explorer;
    return self;
}

- (void)dealloc { [self w7StopMountObservation]; }

- (W7ExplorerComputerView *)view { return _shown ? _view : nil; }

#pragma mark Deciding

/// Which part of the signal matched, for the one diagnostic line ("" when none did).
static const char *W7SignalName(NSString *path, NSString *locationTitle, NSString *windowTitle, NSString *computerName, NSURL *represented) {
    if (!W7ExplorerIsComputerLocation(path, locationTitle, windowTitle, computerName, represented)) return "";
    if (represented.scheme && [represented.scheme caseInsensitiveCompare:@"x-finder"] == NSOrderedSame) return "represented x-finder:Computer URL";
    return "no folder path, title is the computer's name";
}

- (BOOL)w7Wants {
    if (_invalidated || W7ComputerViewDisabled()) return NO;
    W7ExplorerController *ex = _explorer;
    NSWindow *w = ex.window;
    W7ExplorerLocation *location = ex.location;
    if (!w || !location || location.unread) return NO;   // the adoption seed: nothing read from Finder yet
    NSString *title = w.title ?: @"";
    if (_failedTitle) {
        if ([_failedTitle isEqualToString:title]) return NO;
        _failedTitle = nil;
    }
    return W7ExplorerIsComputerLocation(location.path, location.title, title, W7ComputerName(), w.representedURL);
}

- (void)update {
    @try {
        BOOL want = [self w7Wants];
        if (!want) {
            if (_shown) [self w7Hide];
            return;
        }
        if (_shown) [self w7Maintain];
        else [self w7Show];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view failed, Finder's view stays: %{public}@", e.reason ?: @"unknown");
        [self w7FailOpen];
    }
}

- (void)invalidate {
    _invalidated = YES;
    @try { if (_shown) [self w7Hide]; }
    @catch (NSException *e) { os_log_error(W7Log(), "computer view: close failed: %{public}@", e.reason ?: @"unknown"); }
    [self w7StopMountObservation];
}

#pragma mark Showing

/// The details pane, when it floats in `host`.
static NSView *W7DetailsViewIn(NSView *host) {
    for (NSView *v in host.subviews) if ([v isKindOfClass:W7ExplorerDetailsView.class] && !v.hidden) return v;
    return nil;
}

/// `host`'s bounds less the details pane's band at the bottom when the pane floats in it.
static NSRect W7OverlayFrame(NSView *host) {
    NSRect b = host.bounds;
    NSView *pane = W7DetailsViewIn(host);
    CGFloat inset = pane ? NSHeight(pane.frame) : 0;
    return NSMakeRect(NSMinX(b), host.isFlipped ? NSMinY(b) : NSMinY(b) + inset, NSWidth(b), MAX(0, NSHeight(b) - inset));
}

- (void)w7Show {
    W7ExplorerController *ex = _explorer;
    NSWindow *w = ex.window;
    NSView *content = w.contentView;
    if (!content) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL sameContent = content == _skippedContent;
    if (sameContent && now - _skippedAt < 1.0) return;
    NSView *host = W7ExplorerBrowserPaneHost(content);
    if (!host) {
        if (!sameContent) os_log(W7Log(), "computer view skipped (no split view browser pane); Finder's view stays");
        _skippedContent = content;
        _skippedAt = now;
        return;
    }
    _skippedContent = nil;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:W7OverlayFrame(host)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = YES;
    scroll.backgroundColor = NSColor.whiteColor;
    scroll.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];   // the scroller matches the white page
    W7ExplorerComputerView *view = [[W7ExplorerComputerView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(scroll.bounds), NSHeight(scroll.bounds))];
    __weak W7ExplorerComputerController *weakSelf = self;
    view.onSelectionChange = ^{ [weakSelf w7SelectionChanged]; };
    view.onOpen = ^(W7ComputerRow *row) { [weakSelf w7Open:row]; };
    view.menuForRow = ^NSMenu *(W7ComputerRow *row) { return [weakSelf w7MenuForRow:row]; };
    scroll.documentView = view;
    NSView *pane = W7DetailsViewIn(host);
    [host addSubview:scroll positioned:pane ? NSWindowBelow : NSWindowAbove relativeTo:pane];
    // Typing goes to the tiles rather than to Finder's view underneath when that had the focus.
    NSResponder *first = w.firstResponder;
    if ([first isKindOfClass:NSView.class] && [(NSView *)first isDescendantOf:host]) [w makeFirstResponder:view];
    _scroll = scroll;
    _view = view;
    _host = host;
    _content = content;
    _shown = YES;
    _loggedCounts = NO;
    _changeCount++;
    [self w7StartMountObservation];
    [self w7Reload];
    static BOOL loggedSignal;
    if (!loggedSignal && W7NavPaneDiagnosticsEnabled()) {
        loggedSignal = YES;
        W7NavPaneNoteDiagnosticLine();
        W7ExplorerLocation *location = ex.location;
        os_log(W7Log(), "computer view: location signal: %{public}s",
               W7SignalName(location.path, location.title, w.title, W7ComputerName(), w.representedURL));
    }
    [ex computerViewDidChange];
}

/// Keeps the overlay in its host, over Finder's views and under the details pane, sized to the browser pane. A
/// replaced content view or host puts it in afresh.
- (void)w7Maintain {
    W7ExplorerController *ex = _explorer;
    NSWindow *w = ex.window;
    NSView *host = _host;
    NSScrollView *scroll = _scroll;
    if (!w || !host || !scroll || w.contentView != _content || host.window != w || scroll.superview != host) {
        [self w7Hide];
        [self w7Show];
        return;
    }
    NSView *pane = W7DetailsViewIn(host);
    NSArray<NSView *> *subs = host.subviews;
    NSUInteger at = [subs indexOfObjectIdenticalTo:scroll];
    BOOL placed = pane ? (at != NSNotFound && at + 1 < subs.count && subs[at + 1] == pane && subs.lastObject == pane) : subs.lastObject == scroll;
    if (!placed) [host addSubview:scroll positioned:pane ? NSWindowBelow : NSWindowAbove relativeTo:pane];
    NSRect frame = W7OverlayFrame(host);
    if (!NSEqualRects(frame, scroll.frame)) scroll.frame = frame;
}

- (void)w7Hide {
    NSWindow *w = _explorer.window;
    NSResponder *first = w.firstResponder;
    if ([first isKindOfClass:NSView.class] && _scroll && [(NSView *)first isDescendantOf:_scroll]) [w makeFirstResponder:nil];
    [self w7StopMountObservation];
    [_scroll removeFromSuperview];
    _view.onSelectionChange = nil;
    _scroll = nil;
    _view = nil;
    _host = nil;
    _shown = NO;
    _loadToken++;
    _changeCount++;
    [_explorer computerViewDidChange];
}

- (void)w7FailOpen {
    @try {
        _failedTitle = [_explorer.window.title copy] ?: @"";
        if (_scroll || _shown) [self w7Hide];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view: fail-open cleanup failed: %{public}@", e.reason ?: @"unknown");
        [_scroll removeFromSuperview];
        _scroll = nil;
        _shown = NO;
    }
}

#pragma mark Volumes

- (void)w7StartMountObservation {
    if (_observingMounts) return;
    _observingMounts = YES;
    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[ NSWorkspaceDidMountNotification, NSWorkspaceDidUnmountNotification,
                                       NSWorkspaceDidRenameVolumeNotification ])
        [nc addObserver:self selector:@selector(w7VolumesChanged:) name:name object:nil];
}

- (void)w7StopMountObservation {
    if (!_observingMounts) return;
    _observingMounts = NO;
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (void)w7VolumesChanged:(NSNotification *)n {
    @try { if (_shown) [self w7Reload]; }
    @catch (NSException *e) { os_log_error(W7Log(), "computer view: volume change failed: %{public}@", e.reason ?: @"unknown"); }
}

/// The one serial queue every volume read runs on.
static dispatch_queue_t W7VolumeReadQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.win7mac.computer-view.volumes",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    });
    return queue;
}

/// Asks for the volumes: a read now, or, while one is in flight, one more read after it (never a second worker).
- (void)w7Reload {
    ++_loadToken;
    if (_readInFlight) _readAgain = YES;
    else [self w7StartRead];
    [self w7ArmBudget];
}

/// One read for the current token: the test seams on the main thread, else W7ComputerReadVolumeFacts on the queue.
- (void)w7StartRead {
    _readInFlight = YES;
    _readAgain = NO;
    NSUInteger token = _loadToken, readID = ++_readID;
    __weak W7ExplorerComputerController *weakSelf = self;
    W7ComputerVolumeReadCompletion done = ^(NSArray<NSDictionary<NSString *, id> *> *facts) {
        [weakSelf w7ReadFinished:facts token:token readID:readID];
    };
    if (gVolumeReader) {
        gVolumeReader(done);
    } else if (gFactsProvider) {
        done(gFactsProvider() ?: @[]);
    } else {
        dispatch_async(W7VolumeReadQueue(), ^{
            NSArray<NSDictionary<NSString *, id> *> *facts = W7ComputerReadVolumeFacts();
            dispatch_async(dispatch_get_main_queue(), ^{ done(facts); });
        });
    }
}

- (void)w7ReadFinished:(NSArray<NSDictionary<NSString *, id> *> *)facts token:(NSUInteger)token readID:(NSUInteger)readID {
    @try {
        if (readID != _readID || !_readInFlight) return;   // answered twice: the first answer counted
        _readInFlight = NO;
        [self w7ApplyFacts:facts ?: @[] token:token];   // dropped when a reload or a hide came since
        BOOL again = _readAgain && _shown;
        _readAgain = NO;
        if (again) [self w7StartRead];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view: volume read answer failed: %{public}@", e.reason ?: @"unknown");
    }
}

/// After the budget: if the read in flight now still has not answered and nothing is shown yet, Finder's view.
- (void)w7ArmBudget {
    if (!_readInFlight) return;
    NSUInteger readID = _readID;
    __weak W7ExplorerComputerController *weakSelf = self;
    // A run-loop timer (common modes) rather than dispatch_after: it also fires in a nested run loop, a menu's included.
    NSTimer *timer = [NSTimer timerWithTimeInterval:W7ComputerVolumeReadBudget() repeats:NO block:^(NSTimer *t) {
        [weakSelf w7BudgetExpiredForRead:readID];
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)w7BudgetExpiredForRead:(NSUInteger)readID {
    @try {
        if (!_readInFlight || readID != _readID || !_shown) return;
        if (_view.groups.count) return;   // the drives shown stay; the late answer lands if still current
        os_log(W7Log(), "computer view: volume read over %.0f s, Finder's view stays", W7ComputerVolumeReadBudget());
        [self w7FailOpen];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view: read budget check failed: %{public}@", e.reason ?: @"unknown");
    }
}

- (void)w7ApplyFacts:(NSArray<NSDictionary<NSString *, id> *> *)facts token:(NSUInteger)token {
    @try {
        if (token != _loadToken || !_shown) return;
        NSArray<W7ComputerGroup *> *groups = W7ComputerGroupsFromVolumes(facts);
        _view.groups = groups;
        _changeCount++;
        if (!_loggedCounts) {
            _loggedCounts = YES;
            NSUInteger drives = 0;
            for (W7ComputerGroup *g in groups) drives += g.rows.count;
            os_log(W7Log(), "computer view: %lu drives in %lu groups", (unsigned long)drives, (unsigned long)groups.count);
        }
        [_explorer computerViewDidChange];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view: showing volumes failed: %{public}@", e.reason ?: @"unknown");
        [self w7FailOpen];
    }
}

#pragma mark Selection, details and actions

- (void)w7SelectionChanged {
    _changeCount++;
    [_explorer computerViewDidChange];
}

- (W7ExplorerDetailsContent *)detailsContent {
    W7ComputerRow *row = _view.selectedRow;
    if (row) return W7ComputerDetailsForRow(row, NSLocale.currentLocale);
    return W7ComputerDetailsForComputer(_explorer.window.title ?: @"", W7ProcessorName(), NSProcessInfo.processInfo.physicalMemory);
}

- (NSArray<NSImage *> *)detailsIcons {
    W7ComputerRow *row = _view.selectedRow;
    NSImage *icon = row ? W7ComputerIconImage(row.iconName, W7GlyphForKind(row.kind), kDetailsIconSide)
                        : W7ComputerIconImage(@"computer", W7NavPaneGlyphComputer, kDetailsIconSide);
    return icon ? @[ icon ] : @[];
}

- (void)w7Open:(W7ComputerRow *)row {
    if (row.path.length == 0) return;
    if (![NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:row.path isDirectory:YES]])
        os_log_error(W7Log(), "computer view: opening a drive failed");
}

- (NSMenu *)w7MenuForRow:(W7ComputerRow *)row {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    void (^add)(NSString *, SEL) = ^(NSString *title, SEL action) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
        item.target = self;
        item.representedObject = row;
        item.enabled = YES;
        [menu addItem:item];
    };
    add(@"Open", @selector(w7OpenItem:));
    if (row.ejectable) add(@"Eject", @selector(w7EjectItem:));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Properties", @selector(w7PropertiesItem:));
    return menu;
}

static W7ComputerRow *W7RowOf(NSMenuItem *item) {
    return [item.representedObject isKindOfClass:W7ComputerRow.class] ? item.representedObject : nil;
}

- (void)w7OpenItem:(NSMenuItem *)sender {
    @try { [self w7Open:W7RowOf(sender)]; }
    @catch (NSException *e) { os_log_error(W7Log(), "computer view: open failed: %{public}@", e.reason ?: @"unknown"); }
}

/// Eject: NSWorkspace's unmount and eject, off the main thread (it waits for the disk).
- (void)w7EjectItem:(NSMenuItem *)sender {
    W7ComputerRow *row = W7RowOf(sender);
    if (!row.ejectable || row.path.length == 0) return;
    NSURL *url = [NSURL fileURLWithPath:row.path isDirectory:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            NSError *error = nil;
            if (![NSWorkspace.sharedWorkspace unmountAndEjectDeviceAtURL:url error:&error]) {
                os_log_error(W7Log(), "computer view: eject failed (%{public}@ %ld)", error.domain ?: @"?", (long)error.code);
                dispatch_async(dispatch_get_main_queue(), ^{ NSBeep(); });
            }
        } @catch (NSException *e) {
            os_log_error(W7Log(), "computer view: eject failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}

/// Properties: the drive's type, file system and space in a sheet on the window.
- (void)w7PropertiesItem:(NSMenuItem *)sender {
    @try {
        W7ComputerRow *row = W7RowOf(sender);
        NSWindow *w = _explorer.window;
        if (!row || !w) return;
        NSAlert *alert = [NSAlert new];
        alert.messageText = row.name;
        alert.informativeText = W7ComputerPropertiesText(row, NSLocale.currentLocale);
        alert.icon = W7ComputerIconImage(row.iconName, W7GlyphForKind(row.kind), 64);
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:w completionHandler:nil];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view: properties failed: %{public}@", e.reason ?: @"unknown");
    }
}

@end

#pragma mark - Command bar actions

BOOL W7ExplorerComputerCommandAvailable(W7ExplorerController *ex, W7ExplorerCommand command) {
    switch (command) {
        case W7ExplorerCommandSystemProperties:
        case W7ExplorerCommandOpenControlPanel: return YES;
        case W7ExplorerCommandUninstallProgram: return [ex itemForAction:@"cmdGoToApplications:" key:@"a" mods:kShiftCmd] != nil;
        case W7ExplorerCommandMapNetworkDrive: return [ex itemForAction:@"cmdConnectTo:" key:@"k" mods:kCmd] != nil;
        default: return NO;
    }
}

/// Opens `url` (or reports it to the test sink); NO when it could not be opened.
static BOOL W7ComputerOpenURL(NSURL *url) {
    if (gCommandSink) { gCommandSink(@"open", url.absoluteString ?: @""); return YES; }
    return [NSWorkspace.sharedWorkspace openURL:url];
}

static BOOL W7ShellIsRunning(void) {
    if (gShellRunningOverride >= 0) return gShellRunningOverride == 1;
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:kShellBundleID].count > 0;
}

void W7ExplorerPerformComputerCommand(W7ExplorerController *ex, W7ExplorerCommand command) {
    @try {
        switch (command) {
            case W7ExplorerCommandSystemProperties:   // Control Panel ▸ System: System Settings ▸ About
                if (!W7ComputerOpenURL(W7ComputerSystemPropertiesURL())) NSBeep();
                break;
            case W7ExplorerCommandUninstallProgram:   // Programs and Features: the Applications folder, in this window
                if (![ex performAction:@"cmdGoToApplications:" key:@"a" mods:kShiftCmd]) NSBeep();
                break;
            case W7ExplorerCommandMapNetworkDrive:    // Finder's own Go ▸ Connect to Server…
                if (![ex performAction:@"cmdConnectTo:" key:@"k" mods:kCmd]) NSBeep();
                break;
            case W7ExplorerCommandOpenControlPanel:
                // The shell's Control Panel when the shell runs; System Settings otherwise.
                if (W7ShellIsRunning()) {
                    if (gCommandSink) {
                        gCommandSink(@"yield", kShellBundleID);
                        gCommandSink(@"post", W7ControlPanelShowNotificationName);
                    } else {
                        [NSApp yieldActivationToApplicationWithBundleIdentifier:kShellBundleID];   // its window may come forward
                        [NSDistributedNotificationCenter.defaultCenter postNotificationName:W7ControlPanelShowNotificationName
                                                                                     object:nil userInfo:nil deliverImmediately:YES];
                    }
                } else if (!W7ComputerOpenURL([NSURL URLWithString:@"x-apple.systempreferences:"])) {
                    NSBeep();
                }
                break;
            default: break;
        }
        os_log(W7Log(), "computer view: %{public}@", W7ExplorerCommandTitle(command));
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view: command failed: %{public}@", e.reason ?: @"unknown");
    }
}

#pragma mark - Window-level entry points

W7ExplorerComputerView *W7ExplorerComputerViewForWindow(NSWindow *window) {
    return W7ExplorerControllerForWindow(window).computer.view;
}

void W7ExplorerSetLocationForTesting(NSWindow *window, NSString *path, NSString *title) {
    [W7ExplorerControllerForWindow(window) applyLocation:[W7ExplorerLocation locationForPath:path title:title ?: @""]];
}

void W7ExplorerPerformComputerCommandForTesting(NSWindow *window, W7ExplorerCommand command) {
    W7ExplorerController *ex = W7ExplorerControllerForWindow(window);
    if (ex) W7ExplorerPerformComputerCommand(ex, command);
}

BOOL W7ExplorerGoToComputer(NSWindow *window) {
    @try {
        W7ExplorerController *ex = W7ExplorerControllerForWindow(window);
        return ex && [ex performAction:@"cmdGoToComputer:" key:@"c" mods:kShiftCmd];
    } @catch (NSException *e) {
        os_log_error(W7Log(), "computer view: Go to Computer failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}
