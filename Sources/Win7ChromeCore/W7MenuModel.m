#import "Win7ChromeCore.h"

@implementation W7MenuNode

- (instancetype)initWithTitle:(NSString *)title enabled:(BOOL)enabled isSeparator:(BOOL)isSeparator
                        state:(NSControlStateValue)state shortcut:(NSString *)shortcut
                   hasSubmenu:(BOOL)hasSubmenu image:(NSImage *)image
                  sourceIndex:(NSInteger)sourceIndex {
    if ((self = [super init])) {
        _title = [title copy] ?: @"";
        _enabled = enabled;
        _isSeparator = isSeparator;
        _state = state;
        _shortcut = [shortcut copy];
        _hasSubmenu = hasSubmenu;
        _image = image;
        _sourceIndex = sourceIndex;
    }
    return self;
}

- (NSString *)description {
    return self.isSeparator ? @"<W7MenuNode —>"
                            : [NSString stringWithFormat:@"<W7MenuNode %@ #%ld>", self.title, (long)self.sourceIndex];
}

@end

id W7ContextMenuItemTarget(NSMenuItem *item, NSView *view) {
    if (!item || item.target || !item.action || !view) return nil;
    // AppKit's context menu sends nil-target actions from the clicked view (its _setContextMenuTarget:), not from
    // the key window's first responder. A first responder inside the view (a field editor) comes first.
    SEL action = item.action;
    NSWindow *window = view.window;
    NSResponder *start = view;
    NSResponder *first = window.firstResponder;
    if ([first isKindOfClass:NSView.class] && [(NSView *)first isDescendantOf:view]) start = first;
    // NSApplication's -targetForAction:to:from: walk for one window: each responder, or its supplemental target,
    // then the window's delegate. Bounded in case an app builds a responder cycle.
    NSUInteger steps = 0;
    for (NSResponder *r = start; r && steps < 256; r = r.nextResponder, steps++) {
        if ([r respondsToSelector:action]) return r;
        id supplemental = [r supplementalTargetForAction:action sender:item];
        if (supplemental) return supplemental;
    }
    id delegate = window.delegate;
    return [delegate respondsToSelector:action] ? delegate : nil;
}

/// Validates `menu`'s nil-target items against the target `view`'s responder chain gives them (see the header).
static void W7RevalidateForView(NSMenu *menu, NSView *view) {
    if (!view || !menu.autoenablesItems) return;
    for (NSMenuItem *item in menu.itemArray) {
        @try {
            id target = W7ContextMenuItemTarget(item, view);
            if (!target) continue;
            BOOL enabled = YES;
            if ([target respondsToSelector:@selector(validateMenuItem:)]) enabled = [target validateMenuItem:item];
            else if ([target respondsToSelector:@selector(validateUserInterfaceItem:)])
                enabled = [target validateUserInterfaceItem:item];
            item.enabled = enabled;
        } @catch (NSException *e) {
            os_log_error(W7Log(), "context menu validation failed: %{public}@", e.reason ?: @"unknown");
        }
    }
}

NSArray<W7MenuNode *> *W7MenuNodes(NSMenu *menu) { return W7MenuNodesForView(menu, nil); }

NSArray<W7MenuNode *> *W7MenuNodesForView(NSMenu *menu, NSView *view) {
    if (!menu) return @[];
    id<NSMenuDelegate> delegate = menu.delegate;
    if ([delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [delegate menuNeedsUpdate:menu];
    [menu update];
    W7RevalidateForView(menu, view);

    NSMutableArray<W7MenuNode *> *nodes = [NSMutableArray array];
    NSArray<NSMenuItem *> *items = menu.itemArray;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSMenuItem *item = items[i];
        if (item.isHidden || item.isAlternate) continue;
        if (item.isSeparatorItem) {
            // Drop leading and duplicate separators here; a trailing one is dropped below.
            if (nodes.count == 0 || nodes.lastObject.isSeparator) continue;
            [nodes addObject:[[W7MenuNode alloc] initWithTitle:@"" enabled:NO isSeparator:YES state:NSControlStateValueOff
                                                      shortcut:nil hasSubmenu:NO image:nil sourceIndex:(NSInteger)i]];
            continue;
        }
        NSString *shortcut = W7ShortcutString(item.keyEquivalent ?: @"", item.keyEquivalentModifierMask);
        [nodes addObject:[[W7MenuNode alloc] initWithTitle:item.title ?: @"" enabled:item.isEnabled isSeparator:NO
                                                     state:item.state shortcut:shortcut hasSubmenu:item.hasSubmenu
                                                     image:item.image sourceIndex:(NSInteger)i]];
    }
    if (nodes.lastObject.isSeparator) [nodes removeLastObject];
    return nodes;
}

static NSString *W7KeyName(NSString *key) {
    if (key.length == 1) {
        unichar c = [key characterAtIndex:0];
        switch (c) {
            case '\r': case NSEnterCharacter: return @"Enter";
            case '\t': return @"Tab";
            case 0x1b: return @"Esc";
            case ' ': return @"Space";
            case 0x7f: case NSBackspaceCharacter: return @"Backspace";
            case NSDeleteFunctionKey: return @"Del";
            case NSLeftArrowFunctionKey: return @"Left";
            case NSRightArrowFunctionKey: return @"Right";
            case NSUpArrowFunctionKey: return @"Up";
            case NSDownArrowFunctionKey: return @"Down";
            default: break;
        }
        if (c >= NSF1FunctionKey && c <= NSF20FunctionKey) {
            return [NSString stringWithFormat:@"F%d", (int)(c - NSF1FunctionKey + 1)];
        }
        // Other AppKit function keys live in the private-use area and would draw as a missing glyph.
        if (c >= 0xF700 && c <= 0xF8FF) return nil;
    }
    // -uppercaseString is locale-independent, so "i" becomes "I" under tr_TR too.
    return key.uppercaseString;
}

NSString *W7ShortcutString(NSString *keyEquivalent, NSEventModifierFlags mask) {
    if (keyEquivalent.length == 0) return nil;
    NSString *name = W7KeyName(keyEquivalent);
    if (name.length == 0) return nil;

    // An uppercase letter as key equivalent means AppKit requires Shift even without the flag;
    // it is shown in Shift's usual place, so ("S", Cmd) reads the same as ("s", Shift+Cmd).
    BOOL impliesShift = keyEquivalent.length == 1
        && ![keyEquivalent isEqualToString:keyEquivalent.lowercaseString]
        && [keyEquivalent isEqualToString:keyEquivalent.uppercaseString];
    if (impliesShift) mask |= NSEventModifierFlagShift;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (mask & NSEventModifierFlagControl) [parts addObject:@"Ctrl"];
    if (mask & NSEventModifierFlagOption) [parts addObject:@"Alt"];
    if (mask & NSEventModifierFlagShift) [parts addObject:@"Shift"];
    if (mask & NSEventModifierFlagCommand) [parts addObject:@"Cmd"];
    [parts addObject:name];
    return [parts componentsJoinedByString:@"+"];
}

static BOOL W7NodeSelectable(W7MenuNode *n) { return n.enabled && !n.isSeparator; }

NSInteger W7NextSelectableIndex(NSArray<W7MenuNode *> *nodes, NSInteger current, NSInteger direction) {
    NSInteger count = (NSInteger)nodes.count;
    if (count == 0) return NSNotFound;
    NSInteger step = direction < 0 ? -1 : 1;
    if (current == NSNotFound || current < 0 || current >= count) current = step > 0 ? -1 : count;
    for (NSInteger n = 1; n <= count; n++) {
        NSInteger i = ((current + step * n) % count + count) % count;
        if (W7NodeSelectable(nodes[(NSUInteger)i])) return i;
    }
    return NSNotFound;
}

static BOOL W7MenuHasCustomViewItemAtDepth(NSMenu *menu, NSUInteger depth) {
    if (!menu || depth > 4) return NO;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isHidden) continue;
        if (item.view) return YES;
        if (item.hasSubmenu && W7MenuHasCustomViewItemAtDepth(item.submenu, depth + 1)) return YES;
    }
    return NO;
}

BOOL W7MenuHasCustomViewItem(NSMenu *menu) { return W7MenuHasCustomViewItemAtDepth(menu, 0); }
