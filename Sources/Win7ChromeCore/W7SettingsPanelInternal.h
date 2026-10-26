// Internal to W7SettingsPanel.m and W7SettingsPanelSupport.m. Not part of Win7ChromeCore.h.
#import "Win7ChromeCore.h"

NS_ASSUME_NONNULL_BEGIN

/// Bounds for the walks of System Settings' view tree.
static const NSUInteger kProbeMaxDepth = 48, kProbeMaxViews = 6000;

#pragma mark - Guarded private getters (each checks respondsToSelector and the exact type encoding)

/// `object`'s method for `sel` has one of the `count` encodings in `types`.
FOUNDATION_EXPORT BOOL W7SPHasTypes(id _Nullable object, SEL sel, const char *const _Nonnull *_Nonnull types, size_t count);
/// An object getter (`@16@0:8`), or nil.
FOUNDATION_EXPORT id _Nullable W7SPGetObject(id _Nullable object, SEL sel);
/// W7SPGetObject when it is an NSString, or nil.
FOUNDATION_EXPORT NSString *_Nullable W7SPGetString(id _Nullable object, SEL sel);
/// A BOOL getter; `ok` says whether it could be read.
FOUNDATION_EXPORT BOOL W7SPGetBool(id _Nullable object, SEL sel, BOOL *_Nullable ok);

#pragma mark - Change snapshot

/// Every change made to one window, in order, each with its value from before the first change.
@class W7SettingsSnapshot;
FOUNDATION_EXPORT id W7SPBoxed(id _Nullable value);
FOUNDATION_EXPORT id _Nullable W7SPUnboxed(id _Nullable value);
/// The window's snapshot while it is styled, or nil.
FOUNDATION_EXPORT W7SettingsSnapshot *_Nullable W7SPSnapshotFor(NSWindow *_Nullable window);
/// A new, empty snapshot for `window` (which then counts as styled).
FOUNDATION_EXPORT W7SettingsSnapshot *W7SPCreateSnapshot(NSWindow *window);
/// The windows styled now (weak).
FOUNDATION_EXPORT NSHashTable<NSWindow *> *W7SPStyledWindows(void);
FOUNDATION_EXPORT BOOL W7SPWindowIsStyled(NSWindow *_Nullable window);
/// Records `target`'s `name` (its value now, before the caller changes it) once per snapshot. Targets are
/// held weakly.
FOUNDATION_EXPORT void W7SPRecord(W7SettingsSnapshot *snapshot, id target, NSString *name, id _Nullable (^read)(id),
                                  void (^restore)(id, id _Nullable));
/// `name: original → current` for each change.
FOUNDATION_EXPORT NSArray<NSString *> *W7SPChangeLines(W7SettingsSnapshot *snapshot);
/// "<Class>.<property>".
FOUNDATION_EXPORT NSString *W7SPChangeName(id target, NSString *property);
/// Puts back every change, last first and each on its own, drops the snapshot, and returns the change lines.
FOUNDATION_EXPORT NSArray<NSString *> *W7SPRestoreSnapshot(NSWindow *window);
/// Logs a transition's lines and keeps them for W7SettingsLastTransitionLines.
FOUNDATION_EXPORT void W7SPLogTransition(NSWindow *window, NSString *what, NSArray<NSString *> *lines);

#pragma mark - Sidebar

FOUNDATION_EXPORT BOOL W7SPIsAnyWrapper(NSView *view);
FOUNDATION_EXPORT BOOL W7SPIsSidebarWrapper(NSView *view);
/// The sidebar split item wrappers under the window's content view (other columns are never searched): only
/// read, as the "this is the main Settings window" gate.
FOUNDATION_EXPORT NSArray<NSView *> *W7SPSidebarWrappers(NSWindow *window);
FOUNDATION_EXPORT NSSplitViewItem *_Nullable W7SPWrapperItem(NSView *wrapper);

#pragma mark - Diagnostics

/// `defaults write com.apple.systempreferences W7SettingsPanelVerboseLog -bool YES`, read once per launch.
FOUNDATION_EXPORT BOOL W7SPVerboseLog(void);
FOUNDATION_EXPORT NSString *W7SPColorDescription(NSColor *_Nullable color);
FOUNDATION_EXPORT NSString *W7SPProbeSummary(NSArray<NSDictionary<NSString *, NSString *> *> *probes);
/// The window line with `summary`; the view tree only with the verbose flag.
FOUNDATION_EXPORT void W7SPLogDiagnostics(NSWindow *window, NSString *summary);

NS_ASSUME_NONNULL_END
