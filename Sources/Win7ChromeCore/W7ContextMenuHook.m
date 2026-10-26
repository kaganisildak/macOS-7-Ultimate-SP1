#import "Win7ChromeCore.h"
#import <dlfcn.h>
#import <objc/runtime.h>

//: every NSMenu context-menu entry point of this macOS draws a Windows 7 menu.
//
// Found on macOS 27 (W7ContextMenuSelectorDump + call tracing): a right click on any view runs
// -[NSView rightMouseDown:] → -[NSView _showMenuForEvent:] → -[NSMenu _popUpMenuWithEvent:forView:] →
// -[NSMenu _popUpContextMenu:withEvent:forView:] → -[NSMenu _popUpContextMenu:withEvent:forView:withFont:] →
// NSContextMenuImpl. Both public +popUpContextMenu: class methods (also used by showContextMenuForSelection: and
// contextMenuKeyDown:) end in that same -_popUpContextMenu:withEvent:forView:withFont:, and every
// -popUpMenuPositioningItem: call (and -_popUpMenuPositioningItem:…completionBlock:) ends in
// -popUpMenuPositioningItem:atLocation:inView:appearance:. The asynchronous variants
// (+_popUpContextMenu:withEvent:/withContext:forView:completionBlock:) go through the -…withFont:completionBlock:
// instance methods. Popup buttons call NSContextMenuImpl directly and are not touched.
//
// Discipline: hooks only methods the class itself implements with exactly the encoding below; @try everywhere;
// whenever W7MenuWindow declines (W7ContextMenuShouldIntercept, or showMenu: returning NO) the original runs with
// a pass-through count raised, so the inner entry points it calls go straight to AppKit too.

#pragma mark - Switches

static NSInteger gDisabledOverride = -1;

BOOL W7ContextMenusDisabled(void) {
    if (gDisabledOverride >= 0) return gDisabledOverride == 1;
    static BOOL disabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { disabled = [NSUserDefaults.standardUserDefaults boolForKey:@"W7ContextMenusDisabled"]; }
        @catch (NSException *e) { disabled = NO; }
    });
    return disabled;
}

void W7ContextMenusUseDisabledOverride(NSInteger value) { gDisabledOverride = value < 0 ? -1 : (value ? 1 : 0); }

/// `defaults write -g W7MenuVerboseLog -bool YES`: the one-time entry-point dump and a line per hooked call.
static BOOL W7MenuVerboseLog(void) {
    static BOOL verbose;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { verbose = [NSUserDefaults.standardUserDefaults boolForKey:@"W7MenuVerboseLog"]; }
        @catch (NSException *e) { verbose = NO; }
    });
    return verbose;
}

#pragma mark - Decisions

/// Why a hook leaves `menu` to AppKit, or NULL when it should try W7MenuWindow.
static const char *W7ContextMenuDeclineReason(NSMenu *menu, BOOL tracking, BOOL mainThread, BOOL disabled) {
    if (disabled) return "disabled";
    if (!mainThread) return "off main thread";
    if (!menu) return "no menu";
    if (tracking) return "W7 menu tracking";
    id<NSMenuDelegate> delegate = menu.delegate;
    if ([delegate respondsToSelector:@selector(numberOfItemsInMenu:)]) return "delegate counts items";
    if (W7MenuHasCustomViewItem(menu)) return "custom view item";
    for (NSMenuItem *item in menu.itemArray) {
        if (!item.isHidden && !item.isSeparatorItem) return NULL;
    }
    // Empty until updated: only a delegate that fills it may still give W7MenuWindow something to draw.
    return [delegate respondsToSelector:@selector(menuNeedsUpdate:)] ? NULL : "empty";
}

BOOL W7ContextMenuShouldIntercept(NSMenu *menu, BOOL tracking, BOOL mainThread, BOOL disabled) {
    @try {
        return W7ContextMenuDeclineReason(menu, tracking, mainThread, disabled) == NULL;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "context menu decision failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Runtime helpers

/// `cls`'s own (not inherited) method for `sel`, or NULL.
static Method W7OwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count && !found; i++)
        if (method_getName(methods[i]) == sel) found = methods[i];
    free(methods);
    return found;
}

BOOL W7ContextMenuOwnsExactMethod(Class cls, SEL sel, const char *types) {
    if (!cls || !sel || !types) return NO;
    Method m = W7OwnMethod(cls, sel);
    const char *actual = m ? method_getTypeEncoding(m) : NULL;
    return actual && strcmp(actual, types) == 0;
}

NSString *W7BlockTypeEncoding(id block) {
    // The descriptor pointer of a block may be signed on arm64e and may use the compact descriptor layout, so it is
    // never read raw: the blocks runtime's own _Block_signature (looked up once) answers, or the block is treated as
    // unsigned and the call goes to AppKit.
    @try {
        static Class blockBase;
        static const char *(*blockSignature)(void *);
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            blockBase = objc_getClass("NSBlock");
            blockSignature = (const char *(*)(void *))dlsym(RTLD_DEFAULT, "_Block_signature");
        });
        if (!block || !blockBase || !blockSignature || ![block isKindOfClass:blockBase]) return nil;
        const char *signature = blockSignature((__bridge void *)block);
        return signature ? @(signature) : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

NSArray<NSString *> *W7ContextMenuSelectorDump(Class cls) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @try {
        Class sides[2] = { cls, cls ? object_getClass(cls) : Nil };
        for (int side = 0; side < 2; side++) {
            if (!sides[side]) continue;
            unsigned int count = 0;
            Method *methods = class_copyMethodList(sides[side], &count);
            for (unsigned int i = 0; i < count; i++) {
                NSString *name = NSStringFromSelector(method_getName(methods[i]));
                NSString *lower = name.lowercaseString;
                if (![lower containsString:@"popup"] && ![lower containsString:@"contextmenu"]) continue;
                const char *types = method_getTypeEncoding(methods[i]);
                [lines addObject:[NSString stringWithFormat:@"%c%@ %s", side ? '+' : '-', name, types ?: "?"]];
            }
            free(methods);
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "context menu dump failed: %{public}@", e.reason ?: @"unknown");
    }
    return [lines sortedArrayUsingSelector:@selector(compare:)];
}

#pragma mark - Showing

/// Raised (main thread only) while an original implementation runs after a decline, so the entry points it calls
/// in turn go to AppKit without asking again.
static NSInteger gPassThrough;

#define W7_NATIVE(call)                                         \
    do {                                                        \
        BOOL w7Main = NSThread.isMainThread;                    \
        if (w7Main) gPassThrough++;                             \
        @try { call; } @finally { if (w7Main) gPassThrough--; } \
    } while (0)

static void W7ContextMenuNote(SEL sel, const char *outcome) {
    if (W7MenuVerboseLog()) os_log(W7Log(), "context menu %{public}s: %{public}s", sel_getName(sel), outcome);
}

/// Shows `menu` with W7MenuWindow at `p` (screen), as a context menu of `view` when one is given (its responder
/// chain takes nil-target items; with `event` it hears willOpenMenu:/didCloseMenu:). NO means nothing appeared:
/// the caller runs the original.
static BOOL W7ContextMenuTry(NSMenu *menu, NSPoint p, NSView *view, NSEvent *event, SEL sel, BOOL *chose) {
    @try {
        if (!NSThread.isMainThread) return NO;   // before touching any main-thread state
        if (gPassThrough > 0) return NO;
        // A decline after W7MenuWindow updated the menu (it came out empty, or its delegate added a view item)
        // means the native path runs menuNeedsUpdate: again: a delegate that only appends would show its items
        // twice there (review 9, accepted).
        const char *why = W7ContextMenuDeclineReason(menu, W7MenuWindow.isTracking, YES, W7ContextMenusDisabled());
        if (why) {
            W7ContextMenuNote(sel, why);
            return NO;
        }
        BOOL shown = [W7MenuWindow showContextMenu:menu topLeft:p minWidth:menu.minimumWidth forView:view event:event
                                             chose:chose];
        W7ContextMenuNote(sel, shown ? "W7" : "AppKit (W7MenuWindow declined)");
        return shown;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "context menu hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

static BOOL W7IsMouseEvent(NSEvent *e) {
    switch (e.type) {
        case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp:
            return YES;
        default:
            return NO;
    }
}

/// A keyboard-opened context menu's anchor in `view` (screen), or NO: the selected text, the selected row, else the
/// visible top-left corner.
static BOOL W7ContextMenuSelectionPoint(NSView *view, NSPoint *out) {
    NSWindow *w = view.window;
    if (!w) return NO;
    // Text views only: other NSTextInputClient views (web content, custom editors) may answer with anything.
    if ([view isKindOfClass:NSTextView.class]) {
        NSTextView *text = (NSTextView *)view;
        NSRange sel = text.selectedRange;
        if (sel.location != NSNotFound) {
            NSRect r = [text firstRectForCharacterRange:sel actualRange:NULL];   // screen coordinates
            if (!NSIsEmptyRect(r) || !NSEqualPoints(r.origin, NSZeroPoint)) {
                *out = NSMakePoint(NSMinX(r), NSMinY(r));
                return YES;
            }
        }
    }
    // A view no longer clips to its bounds by default, and its visibleRect then reaches past them.
    NSRect visible = NSIntersectionRect(view.visibleRect, view.bounds);
    if ([view isKindOfClass:NSTableView.class]) {
        NSTableView *table = (NSTableView *)view;
        NSInteger row = table.selectedRow;
        NSRect r = row >= 0 ? NSIntersectionRect([table rectOfRow:row], visible) : NSZeroRect;
        if (!NSIsEmptyRect(r)) {
            NSRect s = [w convertRectToScreen:[view convertRect:r toView:nil]];
            *out = NSMakePoint(NSMinX(s), NSMinY(s));
            return YES;
        }
    }
    if (NSIsEmptyRect(visible)) return NO;
    NSRect s = [w convertRectToScreen:[view convertRect:visible toView:nil]];
    *out = NSMakePoint(NSMinX(s), NSMaxY(s));
    return YES;
}

NSPoint W7ContextMenuAnchorPoint(id eventOrContext, NSView *view) {
    @try {
        if ([eventOrContext isKindOfClass:NSEvent.class]) {
            NSEvent *e = eventOrContext;
            if (W7IsMouseEvent(e)) {
                if (e.window) return [e.window convertPointToScreen:e.locationInWindow];
            } else {
                NSPoint p;
                if (W7ContextMenuSelectionPoint(view, &p)) return p;
            }
        }
    } @catch (NSException *e) {
        os_log_error(W7Log(), "context menu anchor failed: %{public}@", e.reason ?: @"unknown");
    }
    return NSEvent.mouseLocation;
}

/// The event a context entry point's view hears willOpenMenu:withEvent: with: its own, else (a context object)
/// the event being handled.
static NSEvent *W7ContextMenuViewEvent(id eventOrContext) {
    return [eventOrContext isKindOfClass:NSEvent.class] ? eventOrContext : NSApp.currentEvent;
}

/// Event (or context) entry points: shows the menu, or reports NO for the caller to run the original.
static BOOL W7ContextMenuTryEvent(NSMenu *menu, id eventOrContext, NSView *view, SEL sel) {
    @try {
        if (!NSThread.isMainThread || gPassThrough > 0) return NO;
        NSView *contextView = [view isKindOfClass:NSView.class] ? view : nil;
        return W7ContextMenuTry(menu, W7ContextMenuAnchorPoint(eventOrContext, contextView), contextView,
                                W7ContextMenuViewEvent(eventOrContext), sel, NULL);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "context menu hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

/// Completion-block entry points: as W7ContextMenuTryEvent, only for a nil block or one taking no arguments, which
/// then runs on the main queue after the call returned (AppKit's asynchronous menu calls it later too).
static BOOL W7ContextMenuTryEventWithCompletion(NSMenu *menu, id eventOrContext, NSView *view, id completion, SEL sel) {
    @try {
        if (!NSThread.isMainThread || gPassThrough > 0) return NO;
        if (completion && ![W7BlockTypeEncoding(completion) isEqualToString:@"v8@?0"]) {
            W7ContextMenuNote(sel, "AppKit (completion block takes arguments or has no signature)");
            return NO;
        }
        if (!W7ContextMenuTryEvent(menu, eventOrContext, view, sel)) return NO;
        if (completion) {
            void (^done)(void) = [completion copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                @try { done(); }
                @catch (NSException *e) { os_log_error(W7Log(), "context menu completion failed: %{public}@", e.reason ?: @"unknown"); }
            });
        }
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "context menu hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

/// -popUpMenuPositioningItem: entry points: only without a positioning item (popup-button placement is AppKit's);
/// `location` is in `view`, or on screen without one. YES with `*chose` when W7MenuWindow showed the menu.
static BOOL W7ContextMenuTryPositioning(NSMenu *menu, NSMenuItem *item, NSPoint location, NSView *view, SEL sel,
                                        BOOL *chose) {
    @try {
        if (!NSThread.isMainThread || gPassThrough > 0) return NO;
        if (item) {
            W7ContextMenuNote(sel, "AppKit (positioning item)");
            return NO;
        }
        NSPoint p = location;
        if (view) {
            NSWindow *w = view.window;
            if (!w) {
                W7ContextMenuNote(sel, "AppKit (view without window)");
                return NO;
            }
            p = [w convertPointToScreen:[view convertPoint:location toView:nil]];
        }
        return W7ContextMenuTry(menu, p, nil, nil, sel, chose);
    } @catch (NSException *e) {
        os_log_error(W7Log(), "context menu hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Replacements

typedef IMP (*W7ContextMenuFactory)(IMP original, SEL sel);

// +popUpContextMenu:withEvent:forView:
static IMP W7MakeClassEvent(IMP imp, SEL sel) {
    void (*original)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))imp;
    return imp_implementationWithBlock(^(id me, NSMenu *menu, NSEvent *event, NSView *view) {
        if (W7ContextMenuTryEvent(menu, event, view, sel)) return;
        W7_NATIVE(original(me, sel, menu, event, view));
    });
}

// +popUpContextMenu:withEvent:forView:withFont:, -_popUpContextMenu:withEvent:forView:withFont:,
// -_popUpContextMenu:withContext:forView:withFont:
static IMP W7MakeEventFont(IMP imp, SEL sel) {
    void (*original)(id, SEL, id, id, id, id) = (void (*)(id, SEL, id, id, id, id))imp;
    return imp_implementationWithBlock(^(id me, NSMenu *menu, id eventOrContext, NSView *view, NSFont *font) {
        if (W7ContextMenuTryEvent(menu ?: ([me isKindOfClass:NSMenu.class] ? me : nil), eventOrContext, view, sel)) return;
        W7_NATIVE(original(me, sel, menu, eventOrContext, view, font));
    });
}

// -_popUpContextMenu:withEvent:forView:withFont:completionBlock:, -_popUpContextMenu:withContext:…:completionBlock:
static IMP W7MakeEventFontCompletion(IMP imp, SEL sel) {
    void (*original)(id, SEL, id, id, id, id, id) = (void (*)(id, SEL, id, id, id, id, id))imp;
    return imp_implementationWithBlock(^(id me, NSMenu *menu, id eventOrContext, NSView *view, NSFont *font, id done) {
        NSMenu *target = menu ?: ([me isKindOfClass:NSMenu.class] ? me : nil);
        if (W7ContextMenuTryEventWithCompletion(target, eventOrContext, view, done, sel)) return;
        W7_NATIVE(original(me, sel, menu, eventOrContext, view, font, done));
    });
}

// -popUpMenuPositioningItem:atLocation:inView:
static IMP W7MakePositioning(IMP imp, SEL sel) {
    BOOL (*original)(id, SEL, id, NSPoint, id) = (BOOL (*)(id, SEL, id, NSPoint, id))imp;
    return imp_implementationWithBlock(^BOOL(NSMenu *me, NSMenuItem *item, NSPoint location, NSView *view) {
        BOOL chose = NO;
        if (W7ContextMenuTryPositioning(me, item, location, view, sel, &chose)) return chose;
        BOOL r = NO;
        W7_NATIVE(r = original(me, sel, item, location, view));
        return r;
    });
}

// -popUpMenuPositioningItem:atLocation:inView:appearance:
static IMP W7MakePositioningAppearance(IMP imp, SEL sel) {
    BOOL (*original)(id, SEL, id, NSPoint, id, id) = (BOOL (*)(id, SEL, id, NSPoint, id, id))imp;
    return imp_implementationWithBlock(^BOOL(NSMenu *me, NSMenuItem *item, NSPoint location, NSView *view, id appearance) {
        BOOL chose = NO;
        if (W7ContextMenuTryPositioning(me, item, location, view, sel, &chose)) return chose;
        BOOL r = NO;
        W7_NATIVE(r = original(me, sel, item, location, view, appearance));
        return r;
    });
}

typedef struct {
    BOOL classSide;
    const char *name;
    const char *types;
    W7ContextMenuFactory make;
} W7ContextMenuEntry;

static const W7ContextMenuEntry kEntries[] = {
    { YES, "popUpContextMenu:withEvent:forView:", "v40@0:8@16@24@32", W7MakeClassEvent },
    { YES, "popUpContextMenu:withEvent:forView:withFont:", "v48@0:8@16@24@32@40", W7MakeEventFont },
    { NO, "popUpMenuPositioningItem:atLocation:inView:", "B48@0:8@16{CGPoint=dd}24@40", W7MakePositioning },
    { NO, "popUpMenuPositioningItem:atLocation:inView:appearance:", "B56@0:8@16{CGPoint=dd}24@40@48",
      W7MakePositioningAppearance },
    { NO, "_popUpContextMenu:withEvent:forView:withFont:", "v48@0:8@16@24@32@40", W7MakeEventFont },
    { NO, "_popUpContextMenu:withEvent:forView:withFont:completionBlock:", "v56@0:8@16@24@32@40@?48",
      W7MakeEventFontCompletion },
    { NO, "_popUpContextMenu:withContext:forView:withFont:", "v48@0:8@16@24@32@40", W7MakeEventFont },
    { NO, "_popUpContextMenu:withContext:forView:withFont:completionBlock:", "v56@0:8@16@24@32@40@?48",
      W7MakeEventFontCompletion },
};
static const size_t kEntryCount = sizeof(kEntries) / sizeof(kEntries[0]);

NSArray<NSString *> *W7ContextMenuEntryPoints(void) {
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (size_t i = 0; i < kEntryCount; i++)
        [list addObject:[NSString stringWithFormat:@"%c%s %s", kEntries[i].classSide ? '+' : '-', kEntries[i].name,
                                                   kEntries[i].types]];
    return list;
}

NSArray<NSString *> *W7InstallContextMenuHooksOnClass(Class cls) {
    NSMutableArray<NSString *> *report = [NSMutableArray array];
    if (!cls) return report;
    static NSMutableSet<NSValue *> *hookedClasses;
    @synchronized([W7MenuWindow class]) {
        if (!hookedClasses) hookedClasses = [NSMutableSet set];
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cls];
        BOOL already = [hookedClasses containsObject:key];
        [hookedClasses addObject:key];
        for (size_t i = 0; i < kEntryCount; i++) {
            const W7ContextMenuEntry *e = &kEntries[i];
            NSString *label = [NSString stringWithFormat:@"%c%s", e->classSide ? '+' : '-', e->name];
            if (already) {
                [report addObject:[label stringByAppendingString:@": already hooked"]];
                continue;
            }
            @try {
                Class side = e->classSide ? object_getClass(cls) : cls;
                SEL sel = sel_registerName(e->name);
                Method m = W7OwnMethod(side, sel);
                if (!m) {
                    [report addObject:[label stringByAppendingString:@": not found"]];
                    continue;
                }
                const char *actual = method_getTypeEncoding(m);
                if (!actual || strcmp(actual, e->types) != 0) {
                    [report addObject:[NSString stringWithFormat:@"%@: types %s (not hooked)", label, actual ?: "(none)"]];
                    continue;
                }
                method_setImplementation(m, e->make(method_getImplementation(m), sel));
                [report addObject:[label stringByAppendingString:@": hooked"]];
            } @catch (NSException *ex) {
                os_log_error(W7Log(), "context menu hook %{public}@ failed: %{public}@", label, ex.reason ?: @"unknown");
                [report addObject:[label stringByAppendingString:@": failed"]];
            }
        }
    }
    return report;
}

void W7InstallContextMenuHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            if (W7ContextMenusDisabled()) {
                os_log(W7Log(), "context menus: disabled (W7ContextMenusDisabled)");
                return;
            }
            if (W7MenuVerboseLog()) {
                for (NSString *line in W7ContextMenuSelectorDump(NSMenu.class))
                    os_log(W7Log(), "context menu entry point: %{public}@", line);
            }
            NSUInteger hooked = 0;
            for (NSString *line in W7InstallContextMenuHooksOnClass(NSMenu.class)) {
                if ([line hasSuffix:@": hooked"]) hooked++;
                else os_log(W7Log(), "context menu hook: %{public}@", line);
            }
            os_log(W7Log(), "context menus: %lu of %lu entry points hooked", (unsigned long)hooked, (unsigned long)kEntryCount);
        } @catch (NSException *e) {
            os_log_error(W7Log(), "context menu hook install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}
