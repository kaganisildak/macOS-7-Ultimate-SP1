// Safari's own menu items and toolbar actions behind the IE8 command bar (; the controls are in
// W7SafariCommandBar.m): the lookups by selector, the ▾ menus built from COPIES of Safari's items, and the two ways a
// control performs — through the item's own menu after Safari's validation, or a toolbar item's own action.
// the selectors are Safari's REAL ones, dumped live from its main menu (selectors only); every list keeps
// the older guesses as later fallbacks so an older Safari still resolves. Never a synthesized event. The resolver
// matches by selector only: the Bookmarks menu's folder submenus hold user data and are never read for titles,
// copied or logged (W7SafariFindMenuItem walks submenus breadth first comparing actions, nothing else).
#import "W7SafariInternal.h"

#pragma mark - Safari's selectors (pure)

NSArray<NSString *> *W7SafariFavoritesActions(void) {
    static NSArray<NSString *> *actions;
    if (!actions) actions = @[ @"toggleBookmarksSidebar:", @"safari_toggleSidebar:", @"toggleBookmarks:", @"toggleSidebar:" ];
    return actions;
}

NSArray<NSString *> *W7SafariPrintActions(void) {
    static NSArray<NSString *> *actions;
    if (!actions) actions = @[ @"safari_printDocument:", @"printDocument:", @"print:", @"printWebView:" ];
    return actions;
}

NSMenuItem *W7SafariFindMenuItem(NSMenu *menu, NSArray<NSString *> *actions) {
    for (NSString *name in actions) {   // in priority order: the first selector anywhere wins over the next
        SEL want = NSSelectorFromString(name);
        NSMutableArray<NSMenu *> *queue = menu ? [NSMutableArray arrayWithObject:menu] : [NSMutableArray array];
        for (NSUInteger i = 0; i < queue.count && i < 512; i++)
            for (NSMenuItem *item in queue[i].itemArray) {
                if (item.action == want && !item.isSeparatorItem) return item;
                if (item.submenu) [queue addObject:item.submenu];
            }
    }
    return nil;
}

/// The menu holding a menu item with one of `actions` (Safari's Text Encoding submenu), or nil.
static NSMenu *W7SafariMenuContaining(NSMenu *menu, NSArray<NSString *> *actions) { return W7SafariFindMenuItem(menu, actions).menu; }

NSMenu *W7SafariBuildCommandMenu(NSMenu *main, NSString *command, NSMutableArray<NSString *> *found) {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:command];
    void (^add)(NSArray<NSString *> *) = ^(NSArray<NSString *> *actions) {
        NSMenuItem *item = W7SafariFindMenuItem(main, actions);
        if (!item) return;
        NSMenuItem *copy = [item copy];   // Safari's title, action, target and key equivalent; validated as Safari's
        [menu addItem:copy];
        [found addObject:NSStringFromSelector(item.action)];
    };
    void (^separator)(void) = ^{
        if (menu.numberOfItems && ![menu itemAtIndex:menu.numberOfItems - 1].isSeparatorItem) [menu addItem:NSMenuItem.separatorItem];
    };
    if ([command isEqualToString:@"Page"]) {
        add(@[ @"zoomIn:", @"makeTextBigger:" ]);
        add(@[ @"zoomOut:", @"makeTextSmaller:" ]);
        add(@[ @"zoomToStandardSize:", @"resetZoom:", @"zoomToActualSize:", @"actualSize:", @"makeTextStandardSize:" ]);
        separator();
        add(@[ @"saveDocumentTo:", @"saveDocumentAs:", @"saveAs:" ]);
        add(@[ @"saveDocumentToPDF:" ]);
        NSMenu *encodings = W7SafariMenuContaining(main, @[ @"changeTextEncoding:" ]);
        NSMenuItem *parent = encodings.supermenu ? [encodings.supermenu itemAtIndex:[encodings.supermenu indexOfItemWithSubmenu:encodings]] : nil;
        if (parent) { [menu addItem:[parent copy]]; [found addObject:@"changeTextEncoding: (submenu)"]; }
        add(@[ @"toggleReader:" ]);
        add(@[ @"showPageSource:", @"viewSource:", @"showSource:" ]);   // only there when Safari's Develop menu is on
    } else if ([command isEqualToString:@"Safety"]) {
        add(@[ @"createPrivateBrowsingWindow:", @"newPrivateWindow:" ]);
        add(@[ @"clearHistoryAndWebsiteData:", @"clearHistory:" ]);
        add(@[ @"showPrivacyReport:" ]);
        add(@[ @"showCertificateInformation:" ]);
    } else if ([command isEqualToString:@"Tools"]) {
        add(@[ @"showDownloads:" ]);
        add(@[ @"showExtensionsSettings:" ]);
        add(@[ @"showPreferences:", @"showSettings:", @"orderFrontPreferencesPanel:", @"orderFrontSettingsWindow:" ]);   // Safari's own title
        add(@[ @"toggleStatusBar:" ]);
        add(@[ @"toggleFullScreen:" ]);
    } else if ([command isEqualToString:@"Favorites"]) {   // ★'s right-click / long-press menu: IE's Favorites Center
        add(@[ @"toggleBookmarksSidebar:" ]);
        add(@[ @"toggleReadingListSidebar:" ]);
        add(@[ @"toggleBookmarks:" ]);
        add(@[ @"toggleHistoryInBookmarksView:" ]);
        add(@[ @"toggleFavoritesBar:" ]);
    } else if ([command isEqualToString:@"Help"]) {
        for (NSMenuItem *item in NSApp.helpMenu.itemArray) {
            if (item.view) continue;   // the help search field: a view cannot sit in two menus
            [menu addItem:[item copy]];
            if (item.action) [found addObject:NSStringFromSelector(item.action)];
        }
    }
    while (menu.numberOfItems && [menu itemAtIndex:menu.numberOfItems - 1].isSeparatorItem) [menu removeItemAtIndex:menu.numberOfItems - 1];
    return menu.numberOfItems ? menu : nil;
}

#pragma mark - Performing

BOOL W7SafariPerformMenuItem(NSMenuItem *item, BOOL *enabled) {
    NSMenu *menu = item.menu;
    [menu update];   // Safari's validation of that menu: no Add Bookmark on the Start Page, no Print without a page
    NSInteger index = menu ? [menu indexOfItem:item] : -1;
    BOOL on = index >= 0 && item.isEnabled;
    if (enabled) *enabled = on;
    if (on) [menu performActionForItemAtIndex:index];   // exactly as a menu click
    return on;
}

BOOL W7SafariPerformToolbarItem(NSWindow *w, NSString *identifier) {
    for (NSToolbarItem *item in w.toolbar.items) {
        if (![item.itemIdentifier isEqualToString:identifier]) continue;
        NSControl *control = [item.view isKindOfClass:NSControl.class] ? (NSControl *)item.view : nil;
        if (control) {
            if (!control.isEnabled || !item.isEnabled) return YES;   // Safari's own state: nothing to do
            if (control.action) return [control sendAction:control.action to:control.target];
        }
        if (item.action) {
            if (!item.isEnabled) return YES;
            return [NSApp sendAction:item.action to:item.target from:item];
        }
        return NO;   // a view that is not a control and has no action (CombinedSidebarTabGroup): the menu, then
    }
    return NO;
}
