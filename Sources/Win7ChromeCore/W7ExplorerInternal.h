// Shared between the W7Explorer*.m files (and W7UserIcons.m). Not public.
#import "Win7ChromeCore.h"

NS_ASSUME_NONNULL_BEGIN

/// Where an Explorer window is: built off the main thread, read on it.
@interface W7ExplorerLocation : NSObject
/// The folder's POSIX path; nil when unknown (Recents, a search, or before the first query returns).
@property (nonatomic, readonly, copy, nullable) NSString *path;
/// Breadcrumbs (`{title, path}`) with Finder's display names; a single `{title, ""}` when unknown.
@property (nonatomic, readonly, copy) NSArray<NSDictionary<NSString *, NSString *> *> *segments;
@property (nonatomic, readonly, strong, nullable) NSImage *icon;
/// Visible items in the folder, -1 when unknown.
@property (nonatomic, readonly) NSInteger itemCount;
/// The window title this location was built for.
@property (nonatomic, readonly, copy) NSString *title;
/// YES for the adoption seed: built from the window title before any location query answered, so nothing is
/// known about the window's location (the Computer view never counts it).
@property (nonatomic, readonly) BOOL unread;
/// Does file I/O (display names, icon, count): call it off the main thread.
+ (instancetype)locationForPath:(nullable NSString *)path title:(NSString *)title;
/// The adoption seed for `title`: no path, `unread`. No file I/O.
+ (instancetype)unreadLocationForTitle:(NSString *)title;
@end

@class W7ExplorerDetailsController, W7ExplorerController, W7ExplorerComputerController;

// W7ExplorerSelectionSnapshot / W7ExplorerSelectionTracker are public (Win7ChromeCore.h).

/// Once per process, Finder only and not with W7ExplorerSelectionDisabled: hooks -selectionChanged of
/// Finder's browser view controllers so the tracker hears of changes at once (otherwise it polls).
FOUNDATION_EXPORT void W7ExplorerInstallSelectionObserver(void);
/// Whether `path` directly holds an image file (at most 2000 entries looked at). File I/O.
FOUNDATION_EXPORT BOOL W7ExplorerFolderHasImages(NSString *path);
/// Empties W7FolderIconImage's rendered-bitmap cache. Every icon-loader reset calls it (W7UserIcons.m). Thread-safe.
FOUNDATION_EXPORT void W7FolderIconClearBitmapCache(void);

/// Per-window glue, owned by the window (associated object). Drives Finder only through its main
/// menu items (found by key equivalent) and osascript. Holds the window and both bars weakly.
@interface W7ExplorerController : NSObject <W7ExplorerSelectionHost>
- (instancetype)initWithWindow:(NSWindow *)window NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, weak, nullable) NSWindow *window;
/// The folder the window shows (its representedURL, else the queried location), or nil.
@property (nonatomic, readonly, nullable) NSURL *currentFolder;
/// The latest location (never nil once adopted; its path may be).
@property (nonatomic, readonly, strong, nullable) W7ExplorerLocation *location;
/// Finder's selection in this window, once read.
@property (nonatomic, readonly, strong, nullable) W7ExplorerSelectionSnapshot *selection;
@property (nonatomic, readonly, strong) W7ExplorerSelectionTracker *selectionTracker;
/// Re-reads the location soon (debounced): representedURL when Finder sets it, else an asynchronous
/// osascript query of this window's target, matched by its Finder window id.
- (void)scheduleLocationQuery;
/// Re-targets the window at its own folder (Finder re-reads it) and re-reads the location.
- (void)refreshFolder;
/// Shares Finder's selection (or the current folder) through the macOS share picker, shown next to
/// `rect` in `view`. The selection is read asynchronously.
- (void)shareFromView:(NSView *)view rect:(NSRect)rect;
/// Finder's main-menu item for the shortcut; logs once per shortcut when it is missing.
- (nullable NSMenuItem *)itemForKey:(NSString *)key mods:(NSEventModifierFlags)mods;
/// Runs -[NSMenu update] once per distinct menu of `items` so their enabled/state values are current.
- (void)validateItems:(NSArray<NSMenuItem *> *)items;
/// Makes the window key, validates and performs the item. NO when missing or disabled.
- (BOOL)performKey:(NSString *)key mods:(NSEventModifierFlags)mods;
/// Proxy menu-item action: representedObject is @{@"key": NSString, @"mods": NSNumber}.
- (void)w7PerformProxy:(nullable NSMenuItem *)sender;
/// Finder's main-menu item whose action is `action` (by selector, cached), else the one for (key, mods).
- (nullable NSMenuItem *)itemForAction:(NSString *)action key:(NSString *)key mods:(NSEventModifierFlags)mods;
/// performKey:mods: for itemForAction:key:mods:. NO when missing or disabled.
- (BOOL)performAction:(NSString *)action key:(NSString *)key mods:(NSEventModifierFlags)mods;
/// The Computer view overlay of this window; always there, shown only on the Computer location.
@property (nonatomic, readonly, strong) W7ExplorerComputerController *computer;
/// The Computer view was shown, hidden, reloaded or its selection changed: the command bar and details pane follow.
- (void)computerViewDidChange;
/// Takes `location` as the window's location, as an accepted location query does.
- (void)applyLocation:(W7ExplorerLocation *)location;
/// Points Finder's front window at `path` through an asynchronous osascript task.
- (void)navigateToPath:(NSString *)path;
/// Writes a .savedSearch for `text` in the current folder and opens it.
- (void)searchFor:(NSString *)text;
@end

/// Back/forward, address bar and search box, on the Aero glass under the title bar.
@interface W7ExplorerNavBarController : NSTitlebarAccessoryViewController
- (instancetype)initWithExplorer:(W7ExplorerController *)explorer NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSNibName)n bundle:(nullable NSBundle *)b NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)c NS_UNAVAILABLE;
/// Enables back/forward from Finder's items (only meaningful while the window is key).
- (void)refreshNavigation;
/// Breadcrumbs and search placeholder, when the folder or title changed.
- (void)refreshLocation;
/// Glass tint for the window's active state.
- (void)refreshActive;
@end

/// The details pane along the bottom of the window's content: the selection's icon and properties,
/// or the folder's icon and item count when nothing is selected.
@interface W7ExplorerDetailsController : NSObject
/// Installs the pane in `window`'s content view; nil when that can't be done safely (logged).
+ (nullable instancetype)installInWindow:(NSWindow *)window explorer:(W7ExplorerController *)explorer;
- (void)refresh;
@end

/// Windows 7 navigation pane and column headers, applied to Finder's own views (restyle only).
@interface W7ExplorerContentStyler : NSObject
- (instancetype)initWithWindow:(NSWindow *)window NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Finds the sidebar and list headers (throttled) and restyles rows that appeared since last time.
- (void)refresh;
@end

/// Organize / Share with / New folder, and the views / preview pane / help buttons.
@interface W7ExplorerCommandBarController : NSTitlebarAccessoryViewController
- (instancetype)initWithExplorer:(W7ExplorerController *)explorer NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSNibName)n bundle:(nullable NSBundle *)b NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)c NS_UNAVAILABLE;
/// Enables the buttons from Finder's items.
- (void)refresh;
/// Shows the buttons for the explorer's current selection; validates them while key.
- (void)selectionChanged;
/// Validates the selection-dependent Finder items (Open, Print, Slide show). Only on a selection
/// change and when the window becomes key: never from the 10 Hz refresh.
- (void)validateSelectionCommands;
@end

/// The Windows 7 Computer view over Finder's Computer location (W7ExplorerComputerView.m): an overlay in the browser
/// side of the window's split view, under the details pane; Finder's views are never replaced or hidden.
@interface W7ExplorerComputerController : NSObject
- (instancetype)initWithExplorer:(W7ExplorerController *)explorer NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) BOOL shown;
/// The tiles while shown, else nil.
@property (nonatomic, readonly, nullable) W7ExplorerComputerView *view;
/// Bumped on every show, hide, reload and selection change (the details pane compares it).
@property (nonatomic, readonly) NSUInteger changeCount;
/// Shows, keeps in place or hides the overlay for the window's current title and location. Cheap when nothing
/// changed (string compares): the location setter, the title observer and the 10 Hz refresh call it.
- (void)update;
/// The window closes: hides for good and stops observing.
- (void)invalidate;
/// The details pane while shown: the selected drive, else the computer.
- (W7ExplorerDetailsContent *)detailsContent;
- (NSArray<NSImage *> *)detailsIcons;
@end

/// The browser side of the first split view at or under `content` (breadth-first, bounded), or nil.
FOUNDATION_EXPORT NSView *_Nullable W7ExplorerBrowserPaneHost(NSView *content);
/// Whether a Computer command can run now (Finder has the menu item it performs).
FOUNDATION_EXPORT BOOL W7ExplorerComputerCommandAvailable(W7ExplorerController *explorer, W7ExplorerCommand command);
/// Runs a Computer command: System Settings ▸ About, Finder's Go ▸ Applications or Go ▸ Connect to Server…, or the
/// shell's Control Panel (W7ControlPanelShowNotificationName; System Settings when the shell is not running).
FOUNDATION_EXPORT void W7ExplorerPerformComputerCommand(W7ExplorerController *explorer, W7ExplorerCommand command);

/// The window's Explorer controller once W7ExplorerAdopt has run on it, else nil.
FOUNDATION_EXPORT W7ExplorerController *_Nullable W7ExplorerControllerForWindow(NSWindow *_Nullable window);
/// Appends a separator and the two Browse folders items ("same window" / "its own window"), the
/// current preference checked; choosing one writes the preference (W7ExplorerBrowse.m).
FOUNDATION_EXPORT void W7ExplorerAppendBrowseItems(NSMenu *menu);

/// The Explorer text font (W7UIFont 12, cached).
FOUNDATION_EXPORT NSFont *W7ExplorerFont(void);
/// Proxy menu item that performs Finder's item for (key, mods) through `explorer`.
FOUNDATION_EXPORT NSMenuItem *W7ExplorerProxyItem(W7ExplorerController *explorer, NSString *title,
                                                 NSString *key, NSEventModifierFlags mods);

NS_ASSUME_NONNULL_END
