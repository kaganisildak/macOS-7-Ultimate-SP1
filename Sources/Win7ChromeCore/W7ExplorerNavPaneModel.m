// What the Windows 7 navigation pane tree shows for Finder's sidebar: the icon name of a row
// by its target (or, when the target can't be read, its title), the tree node a section header stands
// for, and the child-row geometry. Pure apart from W7NavPaneTitleIconNames (display names) and
// W7NavPaneTrashIsFull (reads a directory).
#import "Win7ChromeCore.h"
#import <dirent.h>

const CGFloat W7NavPaneIconSize = 16;
const CGFloat W7NavPaneIconGap = 4;
const CGFloat W7NavPaneChildIndent = 12;

static NSString *const kTreeDisabledKey = @"W7ExplorerNavPaneDisabled";

#pragma mark - Row icons

/// Finder's node classes (DesktopServicesPriv FINode subclasses) with a Windows 7 icon of their own.
static NSString *W7IconNameForNodeClass(NSString *cls) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"FIDSNode_Trash": @"recycle-bin",
            @"FIDSNode_NetworkSidebar": @"network",
            @"FIDSNode_NetworkNearby": @"network",
            @"FIDSNode_Computer": @"computer",
        };
    });
    NSString *exact = map[cls];
    if (exact) return exact;
    // Recents (FIDSNode_RecentDocuments) by its class name part. No node class names the Shared row (it
    // is a canned search, or matched by title); a class rule for "Shared" would run before
    // W7NavPaneNodeClassKeepsFinderIcon and take Finder's icon from a future iCloud or file-provider class.
    if ([cls rangeOfString:@"RecentDocuments"].location != NSNotFound) return @"recent-places";
    return nil;
}

/// the canned searches Finder's Recents and Shared rows open, in Finder's own MyLibraries folder
/// (Finder.app/Contents/Resources/MyLibraries): myDocuments → recent-places; SharedDocuments, SharedWithMe and
/// SharedByMe → shared. The same names anywhere else are the user's own files.
static NSString *W7IconNameForCannedSearch(NSString *standardPath) {
    if (![standardPath.pathExtension isEqualToString:@"cannedSearch"]) return nil;
    NSString *dir = standardPath.stringByDeletingLastPathComponent;
    if (![dir hasSuffix:@"/Finder.app/Contents/Resources/MyLibraries"]) return nil;
    NSString *search = standardPath.lastPathComponent.stringByDeletingPathExtension;
    if ([search isEqualToString:@"myDocuments"]) return @"recent-places";
    if ([@[ @"SharedDocuments", @"SharedWithMe", @"SharedByMe" ] containsObject:search]) return @"shared";
    return nil;
}

/// Node classes Finder draws its own icon for, whatever their path: AirDrop, iCloud, file providers and tags.
BOOL W7NavPaneNodeClassKeepsFinderIcon(NSString *cls) {
    if (cls.length == 0) return NO;
    for (NSString *part in @[ @"AirDrop", @"ICloud", @"Cloud", @"FPProvider", @"Tag" ])
        if ([cls rangeOfString:part].location != NSNotFound) return YES;
    return NO;
}

NSString *W7NavPaneIconNameForTarget(NSString *nodeClassName, NSString *path, BOOL isVolume,
                                     NSDictionary<NSString *, NSNumber *> *specialPaths) {
    if (nodeClassName.length) {
        NSString *byClass = W7IconNameForNodeClass(nodeClassName);
        if (byClass) return byClass;
        if (W7NavPaneNodeClassKeepsFinderIcon(nodeClassName)) return nil;
    }
    if (path.length == 0) return nil;
    NSString *standard = path.stringByStandardizingPath;
    NSNumber *kind = specialPaths[standard];
    if (kind) {
        NSInteger value = kind.integerValue;
        if (value == W7FolderIconUser) return @"user";
        if (value > W7FolderIconPlain && value < W7FolderIconKindCount) return W7FolderIconAssetName((W7FolderIconKind)value);
    }
    if ([standard isEqualToString:@"/Applications"] || [standard isEqualToString:@"/System/Applications"]) return @"applications";
    NSString *canned = W7IconNameForCannedSearch(standard);
    if (canned) return canned;
    if ([standard isEqualToString:@"/"]) return @"drive-system";
    if (isVolume) return @"drive";
    if ([standard isEqualToString:[NSHomeDirectory() stringByAppendingPathComponent:@".Trash"].stringByStandardizingPath]) return @"recycle-bin";
    return nil;
}

/// `a` and `b` equal ignoring case and diacritics (Turkish İ/ı included).
static BOOL W7LooseEqual(NSString *a, NSString *b) {
    if (a.length == 0 || b.length == 0) return NO;
    NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    if ([a compare:b options:opts range:NSMakeRange(0, a.length) locale:nil] == NSOrderedSame) return YES;
    // `İ` folds to "i̇" (with a dot) and `ı` stays apart; compare the Turkish-folded forms too.
    NSLocale *tr = [NSLocale localeWithLocaleIdentifier:@"tr_TR"];
    NSString *fa = [a stringByFoldingWithOptions:opts locale:tr], *fb = [b stringByFoldingWithOptions:opts locale:tr];
    return [fa isEqualToString:fb];
}

NSString *W7NavPaneIconNameForTitle(NSString *title, NSDictionary<NSString *, NSString *> *titleNames) {
    if (title.length == 0) return nil;
    NSString *exact = titleNames[title];
    if (exact) return exact;
    for (NSString *key in titleNames)
        if (W7LooseEqual(key, title)) return titleNames[key];
    return nil;
}

NSDictionary<NSString *, NSString *> *W7NavPaneTitleIconNames(NSDictionary<NSString *, NSNumber *> *specialPaths) {
    NSMutableDictionary<NSString *, NSString *> *map = [@{
        @"Applications": @"applications", @"Uygulamalar": @"applications",
        @"Trash": @"recycle-bin", @"Çöp Sepeti": @"recycle-bin", @"Çöp": @"recycle-bin",
        @"Network": @"network", @"Ağ": @"network",
        @"Macintosh HD": @"drive-system",
        @"Desktop": @"folder-desktop", @"Masaüstü": @"folder-desktop",
        @"Documents": @"folder-documents", @"Belgeler": @"folder-documents",
        @"Downloads": @"folder-downloads", @"İndirilenler": @"folder-downloads",
        @"Pictures": @"folder-pictures", @"Resimler": @"folder-pictures",
        @"Music": @"folder-music", @"Müzik": @"folder-music",
        @"Movies": @"folder-videos", @"Filmler": @"folder-videos",
        @"Recents": @"recent-places", @"Son Kullanılanlar": @"recent-places",
        @"Shared": @"shared", @"Paylaşılan": @"shared",
    } mutableCopy];
    NSFileManager *fm = NSFileManager.defaultManager;
    // The names Finder shows in this process's language win over the built-ins.
    [specialPaths enumerateKeysAndObjectsUsingBlock:^(NSString *path, NSNumber *kind, __unused BOOL *stop) {
        NSString *name = W7NavPaneIconNameForTarget(nil, path, NO, @{ path.stringByStandardizingPath: kind });
        NSString *display = [fm displayNameAtPath:path];
        if (name && display.length) map[display] = name;
    }];
    NSString *apps = [fm displayNameAtPath:@"/Applications"];
    if (apps.length) map[apps] = @"applications";
    return map;
}

BOOL W7NavPanePathIsMountPoint(NSString *path) {
    if (path.length == 0) return NO;
    NSArray<NSString *> *parts = path.stringByStandardizingPath.pathComponents;
    return [path.stringByStandardizingPath isEqualToString:@"/"] ||
           (parts.count == 3 && [parts[0] isEqualToString:@"/"] && [parts[1] isEqualToString:@"Volumes"]);
}

BOOL W7NavPaneTrashIsFull(NSString *trashPath) {
    if (trashPath.length == 0) return NO;
    DIR *dir = opendir(trashPath.fileSystemRepresentation);
    if (!dir) return NO;
    BOOL full = NO;
    struct dirent *entry;
    while (!full && (entry = readdir(dir))) {
        const char *n = entry->d_name;
        if (strcmp(n, ".") == 0 || strcmp(n, "..") == 0 || strcmp(n, ".DS_Store") == 0) continue;
        full = YES;
    }
    closedir(dir);
    return full;
}

#pragma mark - Section headers

W7NavPaneGroupKind W7NavPaneGroupKindFor(NSString *title, NSArray<NSString *> *childIconNames) {
    static const struct { NSString *__unsafe_unretained title; W7NavPaneGroupKind kind; } titles[] = {
        { @"Favorites", W7NavPaneGroupFavorites }, { @"Favoriler", W7NavPaneGroupFavorites },
        { @"Locations", W7NavPaneGroupLocations }, { @"Konumlar", W7NavPaneGroupLocations },
        { @"Tags", W7NavPaneGroupTags }, { @"Etiketler", W7NavPaneGroupTags },
        { @"iCloud", W7NavPaneGroupCloud },
    };
    for (size_t i = 0; i < sizeof titles / sizeof titles[0]; i++)
        if (W7LooseEqual(titles[i].title, title)) return titles[i].kind;
    BOOL favorites = NO;
    for (NSString *name in childIconNames) {
        if ([name hasPrefix:@"drive"] || [name isEqualToString:@"network"] || [name isEqualToString:@"computer"])
            return W7NavPaneGroupLocations;
        if ([name isEqualToString:@"user"] || [name isEqualToString:@"applications"] || [name hasPrefix:@"folder-"]) favorites = YES;
    }
    return favorites ? W7NavPaneGroupFavorites : W7NavPaneGroupUnknown;
}

#pragma mark - Geometry

NSRect W7NavPaneIndentedCellFrame(NSRect frame, CGFloat indent) {
    return NSMakeRect(NSMinX(frame) + indent, NSMinY(frame), MAX(0, NSWidth(frame) - indent), NSHeight(frame));
}

NSRect W7NavPaneTextFrame(NSRect textFrame, NSRect imageFrame, CGFloat iconSide, CGFloat gap) {
    if (NSIsEmptyRect(imageFrame)) return textFrame;
    CGFloat iconRight = NSMidX(imageFrame) + MIN(iconSide, NSWidth(imageFrame)) / 2;
    CGFloat x = round(iconRight + gap);
    if (fabs(x - NSMinX(textFrame)) > W7NavPaneChildIndent) return textFrame;
    CGFloat maxX = NSMaxX(textFrame);
    return NSMakeRect(x, NSMinY(textFrame), MAX(0, maxX - x), NSHeight(textFrame));
}

#pragma mark - Switches

static NSNumber *gTreeDisabledOverride;   // main thread (tests)

void W7NavPaneUseTreeDisabled(NSNumber *disabled) {
    gTreeDisabledOverride = disabled;
}

BOOL W7NavPaneTreeDisabled(void) {
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ disabled = [NSUserDefaults.standardUserDefaults boolForKey:kTreeDisabledKey]; });
    NSNumber *override = gTreeDisabledOverride;
    return override ? override.boolValue : disabled;
}

static NSNumber *gDiagnosticsOverride;   // main thread (tests)
static NSUInteger gDiagnosticLines;

void W7NavPaneUseDiagnosticsEnabled(NSNumber *enabled) {
    gDiagnosticsOverride = enabled;
}

BOOL W7NavPaneDiagnosticsEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7ExplorerNavPaneDiagnostics"]; });
    NSNumber *override = gDiagnosticsOverride;
    return override ? override.boolValue : enabled;
}

void W7NavPaneNoteDiagnosticLine(void) {
    gDiagnosticLines++;
}

NSUInteger W7NavPaneDiagnosticLineCount(void) {
    return gDiagnosticLines;
}

BOOL W7NavPaneTreeActive(NSView *view) {
    if (W7NavPaneTreeDisabled()) return NO;
    // The window's appearance, not the view's: the restyle forces the sidebar itself to Aqua.
    NSAppearance *appearance = view.window.effectiveAppearance ?: NSApp.effectiveAppearance;
    return !W7ExplorerAppearanceIsDark(appearance);
}

BOOL W7NavPaneHooksShouldInstall(NSString *bundleID, BOOL disabled) {
    return !disabled && [bundleID isEqualToString:@"com.apple.finder"];
}
