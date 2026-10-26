// Pure helpers for the Explorer theme: breadcrumbs, menu lookup, AppleScript and saved-search text.
#import "Win7ChromeCore.h"

const CGFloat W7ExplorerNavBarHeight = 34;
const CGFloat W7ExplorerCommandBarHeight = 32;

/// "/a/b/" → "/a/b"; "/" stays "/".
static NSString *W7TrimTrailingSlash(NSString *path) {
    while (path.length > 1 && [path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    return path;
}

NSArray<NSDictionary<NSString *, NSString *> *> *W7BreadcrumbSegments(NSURL *folder, NSString *homePath) {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *segs = [NSMutableArray array];
    NSString *path = folder.isFileURL ? W7TrimTrailingSlash(folder.path ?: @"") : @"";
    NSString *home = W7TrimTrailingSlash(homePath ?: @"");
    BOOL validHome = home.length > 1 && [home hasPrefix:@"/"];
    BOOL underHome = validHome && ([path isEqualToString:home] || [path hasPrefix:[home stringByAppendingString:@"/"]]);

    NSString *base;
    if (underHome) {
        base = home;
        [segs addObject:@{ @"title": home.lastPathComponent, @"path": home }];
    } else {
        base = @"/";
        [segs addObject:@{ @"title": @"Computer", @"path": @"/" }];
    }
    if (![path hasPrefix:@"/"]) return segs;

    NSString *rest = [path substringFromIndex:MIN(base.length, path.length)];
    NSString *current = base;
    for (NSString *component in [rest componentsSeparatedByString:@"/"]) {
        if (component.length == 0) continue;
        current = [current stringByAppendingPathComponent:component];
        [segs addObject:@{ @"title": component, @"path": current }];
    }
    return segs;
}

/// An uppercase single-letter key becomes lowercase plus Shift. Only the four modifier keys count.
static void W7NormalizeKey(NSString **key, NSEventModifierFlags *mods) {
    NSEventModifierFlags relevant = NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                    NSEventModifierFlagOption | NSEventModifierFlagControl;
    *mods &= relevant;
    NSString *lower = (*key).lowercaseString;   // not locale-dependent: "I" → "i" even in tr_TR
    if (![lower isEqualToString:*key]) {
        *key = lower;
        *mods |= NSEventModifierFlagShift;
    }
}

/// Depth-first, the first item of `menu` (and its submenus) passing `test`.
static NSMenuItem *W7FindIn(NSMenu *menu, NSUInteger depth, BOOL (^test)(NSMenuItem *item)) {
    if (depth > 16) return nil;
    for (NSMenuItem *item in menu.itemArray) {
        if (test(item)) return item;
        if (item.submenu) {
            NSMenuItem *found = W7FindIn(item.submenu, depth + 1, test);
            if (found) return found;
        }
    }
    return nil;
}

/// YES when `itemKey` with `itemMods` (an item's equivalent and mask, normalized) is one of `keys` with `mods`.
static BOOL W7KeyMatches(NSString *itemKey, NSEventModifierFlags itemMods, NSSet<NSString *> *keys, NSEventModifierFlags mods) {
    if (itemKey.length == 0) return NO;
    W7NormalizeKey(&itemKey, &itemMods);
    return itemMods == mods && [keys containsObject:itemKey];
}

NSString *W7MenuActionHint(NSString *keyEquivalent, NSEventModifierFlags mods) {
    NSEventModifierFlags relevant = NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                    NSEventModifierFlagOption | NSEventModifierFlagControl;
    if ((mods & relevant) != NSEventModifierFlagCommand) return nil;
    if ([keyEquivalent isEqualToString:@"["]) return @"back";
    if ([keyEquivalent isEqualToString:@"]"]) return @"forward";
    return nil;
}

NSMenuItem *W7FindMenuItemMatching(NSMenu *root, NSString *keyEquivalent, NSEventModifierFlags mods,
                                   NSData *layoutData, NSString *actionHint, W7MenuMatch *how) {
    if (how) *how = W7MenuMatchNone;
    if (!root || keyEquivalent.length == 0) return nil;
    NSString *key = keyEquivalent;
    W7NormalizeKey(&key, &mods);
    NSSet<NSString *> *exact = [NSSet setWithObject:key];
    NSMenuItem *item = W7FindIn(root, 0, ^BOOL(NSMenuItem *i) {
        return W7KeyMatches(i.keyEquivalent, i.keyEquivalentModifierMask, exact, mods);
    });
    W7MenuMatch match = W7MenuMatchKeyEquivalent;
    if (!item) {
        match = W7MenuMatchUserKeyEquivalent;
        item = W7FindIn(root, 0, ^BOOL(NSMenuItem *i) {
            return W7KeyMatches(i.userKeyEquivalent, i.keyEquivalentModifierMask, exact, mods);
        });
    }
    if (!item) {
        // What the US key's position types in this layout: unshifted, and shifted when Shift is held.
        NSInteger code = W7USVirtualKeyCode(key);
        NSMutableSet<NSString *> *localized = [NSMutableSet set];
        NSString *plain = W7TranslateVirtualKey(layoutData, code, NO).lowercaseString;
        NSString *shifted = (mods & NSEventModifierFlagShift) ? W7TranslateVirtualKey(layoutData, code, YES).lowercaseString : nil;
        if (plain.length) [localized addObject:plain];
        if (shifted.length) [localized addObject:shifted];
        [localized removeObject:key];
        if (localized.count) {
            match = W7MenuMatchLocalizedKey;
            item = W7FindIn(root, 0, ^BOOL(NSMenuItem *i) {
                return W7KeyMatches(i.keyEquivalent, i.keyEquivalentModifierMask, localized, mods) ||
                       W7KeyMatches(i.userKeyEquivalent, i.keyEquivalentModifierMask, localized, mods);
            });
        }
    }
    if (!item && actionHint.length) {
        match = W7MenuMatchActionName;
        item = W7FindIn(root, 0, ^BOOL(NSMenuItem *i) {
            return i.action && [NSStringFromSelector(i.action) rangeOfString:actionHint options:NSCaseInsensitiveSearch].location != NSNotFound;
        });
    }
    if (item && how) *how = match;
    return item;
}

NSMenuItem *W7FindMenuItem(NSMenu *root, NSString *keyEquivalent, NSEventModifierFlags mods) {
    return W7FindMenuItemMatching(root, keyEquivalent, mods, W7CurrentKeyboardLayoutData(), nil, NULL);
}

/// Backslash first, then the double quote, so each quote gains exactly one backslash.
static NSString *W7EscapeQuoted(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

NSString *W7FinderGoScript(NSString *posixPath) {
    return [NSString stringWithFormat:
        @"tell application \"Finder\" to set target of Finder window 1 to (POSIX file \"%@\" as alias)",
        W7EscapeQuoted(posixPath ?: @"/")];
}

/// Query-string escaping: quotes and backslashes as in W7EscapeQuoted, plus the wildcards `*` and `?`
/// so the user's text matches literally.
static NSString *W7EscapeQueryValue(NSString *s) {
    s = W7EscapeQuoted(s);
    s = [s stringByReplacingOccurrencesOfString:@"*" withString:@"\\*"];
    return [s stringByReplacingOccurrencesOfString:@"?" withString:@"\\?"];
}

NSData *W7SavedSearchPlist(NSString *query, NSString *scopePath) {
    NSString *raw = [NSString stringWithFormat:@"(kMDItemDisplayName == \"*%@*\"cd)", W7EscapeQueryValue(query ?: @"")];
    NSArray<NSString *> *scope = @[ scopePath ?: @"/" ];
    NSDictionary *plist = @{
        @"CompatibleVersion": @1,
        @"RawQuery": raw,
        // Newer Finder versions read the query and scope from RawQueryDict.
        @"RawQueryDict": @{ @"RawQuery": raw, @"SearchScopes": scope,
                            @"FinderFilesOnly": @YES, @"UserFilesOnly": @YES },
        @"SearchCriteria": @{ @"FXScopeArrayOfPaths": scope },
    };
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0
                                                             options:0 error:&error];
    if (!data) os_log_error(W7Log(), "saved search plist failed: %{public}@", error.localizedDescription ?: @"unknown");
    return data ?: [NSData data];
}

NSString *W7FinderTargetScript(NSInteger windowID) {
    NSString *window = windowID > 0 ? [NSString stringWithFormat:@"Finder window id %ld", (long)windowID]
                                    : @"Finder window 1";
    return [NSString stringWithFormat:
        @"tell application \"Finder\"\n"
        @"set w to %@\n"
        @"return (id of w as text) & linefeed & (name of w) & linefeed & (POSIX path of (target of w as alias))\n"
        @"end tell", window];
}

NSDictionary<NSString *, id> *W7ParseFinderTargetOutput(NSString *output) {
    if (output.length == 0) return nil;
    NSString *text = [output stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    NSRange nl = [text rangeOfString:@"\n"];
    if (nl.location == NSNotFound) return nil;
    NSString *idText = [text substringToIndex:nl.location];
    NSString *rest = [text substringFromIndex:NSMaxRange(nl)];
    NSRange nl2 = [rest rangeOfString:@"\n"];
    if (nl2.location == NSNotFound) return nil;
    NSString *name = [rest substringToIndex:nl2.location];
    NSString *path = [rest substringFromIndex:NSMaxRange(nl2)];
    // osascript ends its output with one newline; anything before it belongs to the path.
    if ([path hasSuffix:@"\n"]) path = [path substringToIndex:path.length - 1];

    NSScanner *scanner = [NSScanner scannerWithString:idText];
    long long windowID = 0;
    if (![scanner scanLongLong:&windowID] || !scanner.isAtEnd || windowID <= 0) return nil;
    if (![path hasPrefix:@"/"]) return nil;
    path = W7TrimTrailingSlash(path);
    return @{ @"id": @(windowID), @"name": name, @"path": path };
}

BOOL W7AcceptFinderTarget(NSDictionary<NSString *, id> *parsed, NSString *windowTitle, BOOL usedWindowID, BOOL stillKey) {
    if (!parsed) return NO;
    // "Finder window 1" is only this window while it is key; by the time the answer arrives it may
    // be another window's, so an unaddressed answer counts only if the window is still key.
    if (!usedWindowID && !stillKey) return NO;
    NSString *name = [parsed[@"name"] isKindOfClass:NSString.class] ? parsed[@"name"] : nil;
    return name && windowTitle && [name isEqualToString:windowTitle];
}

W7TargetDecision W7DecideFinderTarget(NSDictionary<NSString *, id> *parsed, NSString *queryTitle, NSString *currentTitle,
                                      NSString *locationTitle, BOOL usedWindowID, BOOL stillKey) {
    if (W7AcceptFinderTarget(parsed, currentTitle ?: @"", usedWindowID, stillKey)) return W7TargetDecisionAccept;
    // The benign race: the window navigated while osascript ran. The answer is stale, not wrong.
    if (![queryTitle ?: @"" isEqualToString:currentTitle ?: @""]) return W7TargetDecisionRequery;
    if (parsed && usedWindowID) return W7TargetDecisionWrongWindow;
    BOOL stale = !locationTitle || ![locationTitle isEqualToString:currentTitle ?: @""];
    return stale ? W7TargetDecisionTitleOnly : W7TargetDecisionKeep;
}

NSString *W7FinderSelectionScript(void) {
    return @"tell application \"Finder\"\n"
           @"set out to \"\"\n"
           @"repeat with i in (get selection)\n"
           @"set out to out & (POSIX path of (i as alias)) & linefeed\n"
           @"end repeat\n"
           @"return out\n"
           @"end tell";
}

NSArray<NSString *> *W7ParsePathLines(NSString *output) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *text = [output ?: @"" stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"/"]) [paths addObject:W7TrimTrailingSlash(line)];
    }
    return paths;
}

NSString *W7ItemCountText(NSInteger count) {
    if (count < 0) return @"";
    return count == 1 ? @"1 item" : [NSString stringWithFormat:@"%ld items", (long)count];
}

NSInteger W7CountVisibleItems(NSString *path) {
    if (path.length == 0) return -1;
    NSError *error = nil;
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:path]
                                                         includingPropertiesForKeys:@[]
                                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                              error:&error];
    return items ? (NSInteger)items.count : -1;
}

NSArray<NSDictionary<NSString *, NSString *> *> *W7SubfolderEntries(NSString *path, NSUInteger limit) {
    if (path.length == 0 || limit == 0) return @[];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSURLResourceKey> *keys = @[ NSURLIsDirectoryKey, NSURLIsPackageKey, NSURLLocalizedNameKey ];
    NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:path] includingPropertiesForKeys:keys
                                                   options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries = [NSMutableArray array];
    for (NSURL *u in items) {
        NSDictionary<NSURLResourceKey, id> *v = [u resourceValuesForKeys:keys error:NULL];
        if (![v[NSURLIsDirectoryKey] boolValue] || [v[NSURLIsPackageKey] boolValue]) continue;
        NSString *title = [v[NSURLLocalizedNameKey] isKindOfClass:NSString.class] ? v[NSURLLocalizedNameKey] : u.lastPathComponent;
        // Built from the caller's path, so a symlinked prefix (/var vs /private/var) is kept as given.
        NSString *child = [W7TrimTrailingSlash(path) stringByAppendingPathComponent:u.lastPathComponent ?: @""];
        [entries addObject:@{ @"title": title ?: @"", @"path": child }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedStandardCompare:b[@"title"]];
    }];
    if (entries.count > limit) [entries removeObjectsInRange:NSMakeRange(limit, entries.count - limit)];
    return entries;
}

BOOL W7ExplorerShouldAdopt(NSString *bundleID, NSString *windowClassName, BOOL hasToolbar) {
    if (![bundleID isEqualToString:@"com.apple.finder"]) return NO;
    return [windowClassName hasPrefix:@"TBrowser"] || hasToolbar;
}

NSURL *W7ExplorerFolderURL(NSURL *url) {
    if (!url.isFileURL) return nil;
    if (url.hasDirectoryPath) return url;
    NSNumber *isDir = nil;
    if ([url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL] && isDir.boolValue) return url;
    return nil;
}

NSUInteger W7RemoveStaleSavedSearches(NSString *directory, NSDate *now) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDate *cutoff = [now dateByAddingTimeInterval:-24 * 3600];
    NSUInteger removed = 0;
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:NULL]) {
        if (![name hasPrefix:@"Win7Search-"] || ![name.pathExtension isEqualToString:@"savedSearch"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDate *modified = [fm attributesOfItemAtPath:path error:NULL].fileModificationDate;
        if (modified && [modified compare:cutoff] == NSOrderedAscending && [fm removeItemAtPath:path error:NULL]) removed++;
    }
    return removed;
}
