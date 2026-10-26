// Pure model of the Windows 7 Computer view: drive groups and rows from volume facts (URL resource
// values read by W7ComputerReadVolumeFacts), the capacity text, the details pane and Properties texts, the location
// signal and the Computer command set. No I/O; W7ExplorerComputerView.m reads the volumes and shows the view.
#import "Win7ChromeCore.h"

NSString *const W7ComputerVolumePathKey = @"path";
NSString *const W7ControlPanelShowNotificationName = @"com.win7mac.controlpanel.show";

static const long long kTB = 1000000000000LL;
static const long long kGB = 1000000000LL;
static const long long kMB = 1000000LL;

#pragma mark - Rows and groups

@implementation W7ComputerRow

- (instancetype)initWithName:(NSString *)name path:(NSString *)path kind:(W7ComputerDriveKind)kind total:(long long)total
                        free:(long long)free ejectable:(BOOL)ejectable formatName:(NSString *)formatName {
    if ((self = [super init])) {
        _name = [name copy] ?: @"";
        _path = [path copy] ?: @"";
        _kind = kind;
        _total = total;
        _free = free;
        _ejectable = ejectable;
        _formatName = [formatName copy];
    }
    return self;
}

- (NSString *)iconName {
    switch (_kind) {
        case W7ComputerDriveSystem: return @"drive-system";
        case W7ComputerDriveInternal: return @"drive";
        case W7ComputerDriveRemovable: return @"drive-removable";
        case W7ComputerDriveOptical: return @"drive-optical";
        case W7ComputerDriveNetwork: return @"network";
    }
    return @"drive";
}

- (BOOL)low { return W7ComputerCapacityIsLow(_free, _total); }

@end

@interface W7ComputerGroup ()
- (instancetype)initWithKind:(W7ComputerGroupKind)kind rows:(NSArray<W7ComputerRow *> *)rows;
@end

@implementation W7ComputerGroup

- (instancetype)initWithKind:(W7ComputerGroupKind)kind rows:(NSArray<W7ComputerRow *> *)rows {
    if ((self = [super init])) {
        _kind = kind;
        _rows = [rows copy];
        switch (kind) {
            case W7ComputerGroupHardDisks: _title = @"Hard Disk Drives"; break;
            case W7ComputerGroupRemovable: _title = @"Devices with Removable Storage"; break;
            case W7ComputerGroupNetwork: _title = @"Network Location"; break;
        }
    }
    return self;
}

@end

static BOOL W7FactBool(NSDictionary *facts, NSURLResourceKey key, BOOL fallback) {
    id v = facts[key];
    return [v isKindOfClass:NSNumber.class] ? [v boolValue] : fallback;
}

static long long W7FactBytes(NSDictionary *facts, NSURLResourceKey key) {
    id v = facts[key];
    return [v isKindOfClass:NSNumber.class] ? [v longLongValue] : -1;
}

/// Free bytes: the important-usage value (includes purgeable space, as Finder counts it), else the plain available
/// capacity (some network and FAT volumes have no important-usage value), else -1.
static long long W7FactFreeBytes(NSDictionary *facts) {
    long long important = W7FactBytes(facts, NSURLVolumeAvailableCapacityForImportantUsageKey);
    return important >= 0 ? important : W7FactBytes(facts, NSURLVolumeAvailableCapacityKey);
}

static NSString *W7FactString(NSDictionary *facts, NSString *key) {
    id v = facts[key];
    return [v isKindOfClass:NSString.class] && [v length] ? v : nil;
}

BOOL W7ComputerVolumeIsHidden(NSDictionary<NSString *, id> *facts) {
    if (!W7FactBool(facts, NSURLVolumeIsBrowsableKey, YES)) return YES;
    if ([W7FactString(facts, NSURLVolumeTypeNameKey) isEqualToString:@"devfs"]) return YES;
    NSString *path = W7FactString(facts, W7ComputerVolumePathKey);
    for (NSString *dir in @[ @"/System/Volumes", @"/private/var/vm" ])
        if ([path isEqualToString:dir] || [path hasPrefix:[dir stringByAppendingString:@"/"]]) return YES;
    return NO;
}

static W7ComputerDriveKind W7DriveKindForFacts(NSDictionary *facts, NSString *path) {
    if (!W7FactBool(facts, NSURLVolumeIsLocalKey, YES)) return W7ComputerDriveNetwork;
    if (W7FactBool(facts, NSURLVolumeIsRootFileSystemKey, NO) || [path isEqualToString:@"/"]) return W7ComputerDriveSystem;
    NSString *type = W7FactString(facts, NSURLVolumeTypeNameKey).lowercaseString;
    if ([@[ @"cd9660", @"udf", @"cddafs" ] containsObject:type ?: @""]) return W7ComputerDriveOptical;
    BOOL internal = W7FactBool(facts, NSURLVolumeIsInternalKey, NO);
    if (W7FactBool(facts, NSURLVolumeIsRemovableKey, NO) || (W7FactBool(facts, NSURLVolumeIsEjectableKey, NO) && !internal))
        return W7ComputerDriveRemovable;
    return W7ComputerDriveInternal;
}

static W7ComputerGroupKind W7GroupKindForDrive(W7ComputerDriveKind kind) {
    switch (kind) {
        case W7ComputerDriveSystem:
        case W7ComputerDriveInternal: return W7ComputerGroupHardDisks;
        case W7ComputerDriveRemovable:
        case W7ComputerDriveOptical: return W7ComputerGroupRemovable;
        case W7ComputerDriveNetwork: return W7ComputerGroupNetwork;
    }
    return W7ComputerGroupHardDisks;
}

NSArray<W7ComputerGroup *> *W7ComputerGroupsFromVolumes(NSArray<NSDictionary<NSString *, id> *> *facts) {
    NSMutableArray<W7ComputerRow *> *byGroup[3] = { [NSMutableArray array], [NSMutableArray array], [NSMutableArray array] };
    for (NSDictionary *f in facts) {
        if (![f isKindOfClass:NSDictionary.class] || W7ComputerVolumeIsHidden(f)) continue;
        NSString *path = W7FactString(f, W7ComputerVolumePathKey);
        if (!path) continue;
        NSString *name = W7FactString(f, NSURLVolumeLocalizedNameKey) ?: path.lastPathComponent;
        W7ComputerDriveKind kind = W7DriveKindForFacts(f, path);
        W7ComputerRow *row = [[W7ComputerRow alloc] initWithName:name path:path kind:kind
                                                           total:W7FactBytes(f, NSURLVolumeTotalCapacityKey)
                                                            free:W7FactFreeBytes(f)
                                                       ejectable:W7FactBool(f, NSURLVolumeIsEjectableKey, NO)
                                                      formatName:W7FactString(f, NSURLVolumeLocalizedFormatDescriptionKey)];
        [byGroup[W7GroupKindForDrive(kind)] addObject:row];
    }
    NSMutableArray<W7ComputerGroup *> *groups = [NSMutableArray array];
    for (NSInteger g = 0; g < 3; g++) {
        if (byGroup[g].count == 0) continue;
        [byGroup[g] sortUsingComparator:^NSComparisonResult(W7ComputerRow *a, W7ComputerRow *b) {
            BOOL as = a.kind == W7ComputerDriveSystem, bs = b.kind == W7ComputerDriveSystem;   // the system drive first
            if (as != bs) return as ? NSOrderedAscending : NSOrderedDescending;
            NSComparisonResult r = [a.name localizedStandardCompare:b.name];
            return r != NSOrderedSame ? r : [a.path compare:b.path];
        }];
        [groups addObject:[[W7ComputerGroup alloc] initWithKind:(W7ComputerGroupKind)g rows:byGroup[g]]];
    }
    return groups;
}

#pragma mark - Capacity

BOOL W7ComputerCapacityIsLow(long long freeBytes, long long totalBytes) {
    return totalBytes > 0 && freeBytes >= 0 && (double)freeBytes < 0.1 * (double)totalBytes;
}

double W7ComputerUsedFraction(long long freeBytes, long long totalBytes) {
    if (totalBytes <= 0 || freeBytes < 0) return -1;
    double used = 1.0 - (double)freeBytes / (double)totalBytes;
    return MIN(1.0, MAX(0.0, used));
}

/// "117 GB" (whole, rounded down), or "3.9 TB" (one decimal, rounded down) from 1000 GB up.
static NSString *W7GigabyteText(long long bytes) {
    if (bytes < kTB) return [NSString stringWithFormat:@"%lld GB", bytes / kGB];
    long long tenths = bytes / (kTB / 10);
    return [NSString stringWithFormat:@"%lld.%lld TB", tenths / 10, tenths % 10];
}

NSString *W7ComputerCapacityText(long long freeBytes, long long totalBytes) {
    if (freeBytes < 0 || totalBytes <= 0) return @"";
    if (totalBytes < kGB) return [NSString stringWithFormat:@"%lld MB free of %lld MB", freeBytes / kMB, totalBytes / kMB];
    return [NSString stringWithFormat:@"%@ free of %@", W7GigabyteText(freeBytes), W7GigabyteText(totalBytes)];
}

NSString *W7ComputerDriveTypeName(W7ComputerDriveKind kind) {
    switch (kind) {
        case W7ComputerDriveSystem:
        case W7ComputerDriveInternal: return @"Local Disk";
        case W7ComputerDriveRemovable: return @"Removable Disk";
        case W7ComputerDriveOptical: return @"CD Drive";
        case W7ComputerDriveNetwork: return @"Network Drive";
    }
    return @"Local Disk";
}

#pragma mark - Texts

W7ExplorerDetailsContent *W7ComputerDetailsForRow(W7ComputerRow *row, NSLocale *locale) {
    NSMutableArray<NSString *> *labels = [NSMutableArray array], *values = [NSMutableArray array];
    if (row.total >= 0) { [labels addObject:@"Total size:"]; [values addObject:W7ExplorerSizeText(row.total, locale)]; }
    if (row.free >= 0) { [labels addObject:@"Free space:"]; [values addObject:W7ExplorerSizeText(row.free, locale)]; }
    if (row.formatName.length) { [labels addObject:@"File system:"]; [values addObject:row.formatName]; }
    return [[W7ExplorerDetailsContent alloc] initWithTitle:row.name style:W7ExplorerDetailsTitleName
                                                  subtitle:W7ComputerDriveTypeName(row.kind) labels:labels values:values];
}

/// "16 GB" (binary gigabytes, as Windows shows memory), one decimal when not whole.
static NSString *W7MemoryText(unsigned long long bytes) {
    double gb = (double)bytes / 1073741824.0;
    double tenths = round(gb * 10) / 10;
    return fmod(tenths, 1) == 0 ? [NSString stringWithFormat:@"%.0f GB", tenths] : [NSString stringWithFormat:@"%.1f GB", tenths];
}

W7ExplorerDetailsContent *W7ComputerDetailsForComputer(NSString *name, NSString *processor, unsigned long long memoryBytes) {
    NSMutableArray<NSString *> *labels = [NSMutableArray array], *values = [NSMutableArray array];
    if (processor.length) { [labels addObject:@"Processor:"]; [values addObject:processor]; }
    if (memoryBytes > 0) { [labels addObject:@"Memory:"]; [values addObject:W7MemoryText(memoryBytes)]; }
    return [[W7ExplorerDetailsContent alloc] initWithTitle:name ?: @"" style:W7ExplorerDetailsTitleName subtitle:nil
                                                    labels:labels values:values];
}

NSString *W7ComputerPropertiesText(W7ComputerRow *row, NSLocale *locale) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:[@"Type: " stringByAppendingString:W7ComputerDriveTypeName(row.kind)]];
    if (row.formatName.length) [lines addObject:[@"File system: " stringByAppendingString:row.formatName]];
    if (row.total >= 0 && row.free >= 0)
        [lines addObject:[@"Used space: " stringByAppendingString:W7ExplorerSizeText(MAX(0, row.total - row.free), locale)]];
    if (row.free >= 0) [lines addObject:[@"Free space: " stringByAppendingString:W7ExplorerSizeText(row.free, locale)]];
    if (row.total >= 0) [lines addObject:[@"Total size: " stringByAppendingString:W7ExplorerSizeText(row.total, locale)]];
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Location and commands

BOOL W7ExplorerIsComputerLocation(NSString *locationPath, NSString *locationTitle, NSString *windowTitle,
                                  NSString *computerName, NSURL *representedURL) {
    if (locationPath.length || windowTitle.length == 0) return NO;
    if (![locationTitle isEqualToString:windowTitle]) return NO;   // the window navigated; its location is not read yet
    // Unverified guess: nothing shows Finder setting an x-finder:Computer represented URL (macOS 27 Finder leaves
    // representedURL nil). Harmless, because the title check above still applies.
    NSString *scheme = representedURL.scheme, *specifier = representedURL.resourceSpecifier;
    if (scheme && specifier && [scheme caseInsensitiveCompare:@"x-finder"] == NSOrderedSame &&
        [specifier caseInsensitiveCompare:@"computer"] == NSOrderedSame) return YES;
    // Finder titles its Computer location with the computer's name, never "Computer" (observed):
    // no literal "Computer" match, which would only cover a folder or saved search of that name.
    return computerName.length && [windowTitle isEqualToString:computerName];
}

NSArray<NSNumber *> *W7ExplorerCommandsForComputer(void) {
    return @[ @(W7ExplorerCommandSystemProperties), @(W7ExplorerCommandUninstallProgram), @(W7ExplorerCommandMapNetworkDrive),
              @(W7ExplorerCommandOpenControlPanel) ];
}

NSURL *W7ComputerSystemPropertiesURL(void) {
    return [NSURL URLWithString:@"x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension"];
}
