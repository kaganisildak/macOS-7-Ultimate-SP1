// Windows 7 Explorer selection highlight in Finder's icon and list views.
//
// Hook points, found statically in Finder (see task-24-research.md for the method dump):
//   - TIconSelectionView (a TUpdateLayerView: wantsUpdateLayer) draws the icon view's selection with
//     its layer in -updateLayer. After the original, the layer gets the Windows 7 border, radius and a
//     gradient sublayer (above any contents Finder set, under the border).
//   - TIconView -titleBubbleViewIsSelected drives the accent title bubble and -_titleFontColor its
//     text (white, alternateSelectedControlTextColor, when selected). They are hooked as a pair: in a
//     light appearance a bubble Finder would show is dropped and the text turns dark, so a selected
//     title is never white on white (W7ExplorerIconTitleLookFor).
//   - TListRowView (an NSTableRowView that inherits -drawSelectionInRect: and -interiorBackgroundStyle)
//     gets its own overrides: the Windows 7 highlight, and a normal background style for its cells.
// Every hook checks the exact type encoding first, runs the replacement inside @try and falls back to
// Finder's own drawing. Kill switch: `defaults write com.apple.finder W7ExplorerSelectionDisabled -bool YES`.
// Scope: these are Finder's classes, so the highlight is Finder-wide (every icon and list view Finder
// draws, Explorer window or not), and in a dark appearance every hook defers to Finder's own look.
// Not covered: hover (Finder draws none, so there is nothing to replace) and the column view.
#import "Win7ChromeCore.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kSelectionDisabledKey = @"W7ExplorerSelectionDisabled";
static NSString *const kGradientLayerName = @"com.win7mac.selection";
static NSMutableSet<NSString *> *gHooked;   // "<kind>|<class>", main thread only

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

/// The own method of `cls` for `sel` when its encoding is exactly `types`; logs why not otherwise.
static Method W7CheckedOwnMethod(Class cls, SEL sel, const char *types, const char *what) {
    Method m = W7OwnMethod(cls, sel);
    NSString *name = NSStringFromClass(cls);
    if (!m) {
        os_log(W7Log(), "selection highlight: %{public}@ skipped, it does not implement %{public}s", name, what);
        return NULL;
    }
    const char *actual = method_getTypeEncoding(m);
    if (!actual || strcmp(actual, types) != 0) {
        os_log(W7Log(), "selection highlight: %{public}@ skipped, %{public}s has types %{public}s", name, what, actual ?: "(none)");
        return NULL;
    }
    return m;
}

/// YES the first time `kind` is claimed for `cls` (then the caller hooks it).
static BOOL W7ClaimHook(NSString *kind, Class cls) {
    if (!gHooked) gHooked = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%@|%p", kind, (__bridge const void *)cls];
    if ([gHooked containsObject:key]) return NO;
    [gHooked addObject:key];
    return YES;
}

static BOOL W7IsHooked(NSString *kind, Class cls) {
    return [gHooked containsObject:[NSString stringWithFormat:@"%@|%p", kind, (__bridge const void *)cls]];
}

static CGColorRef W7CreateColor(uint32_t hex) {
    W7RGBA c = W7RGBAFromHex(hex, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[] = { c.r, c.g, c.b, 1 };
    CGColorRef color = CGColorCreate(cs, comps);
    CGColorSpaceRelease(cs);
    return color;
}

#pragma mark - Icon view

/// `object`'s method for `sel` has exactly `types`.
static BOOL W7HasTypes(id object, SEL sel, const char *types) {
    Method m = object ? class_getInstanceMethod(object_getClass(object), sel) : NULL;
    const char *actual = m ? method_getTypeEncoding(m) : NULL;
    return actual && strcmp(actual, types) == 0;
}

/// Finder's own notion of an active (focused) icon view, from the nearest superview answering
/// -useActiveAppearance (TIconView); otherwise whether the window is key.
static BOOL W7IconSelectionFocused(NSView *view) {
    SEL sel = sel_registerName("useActiveAppearance");
    NSView *v = view.superview;
    for (int depth = 0; v && depth < 6; depth++, v = v.superview) {
        Method m = class_getInstanceMethod(object_getClass(v), sel);
        if (!m) continue;
        const char *types = method_getTypeEncoding(m);
        if (types && strcmp(types, "B16@0:8") == 0) return ((BOOL (*)(id, SEL))objc_msgSend)(v, sel);
        break;
    }
    return view.window.isKeyWindow;
}

static const void *kSavedLayerKey = &kSavedLayerKey;

static CAGradientLayer *W7OurGradient(CALayer *layer) {
    for (CALayer *sub in layer.sublayers)
        if ([sub isKindOfClass:CAGradientLayer.class] && [sub.name isEqualToString:kGradientLayerName]) return (CAGradientLayer *)sub;
    return nil;
}

/// Whether `color` is one of the two border colours the restyle sets.
static BOOL W7IsOurBorderColor(CGColorRef color) {
    if (!color) return NO;
    for (NSNumber *state in @[ @(W7ExplorerSelectionSelected), @(W7ExplorerSelectionSelectedUnfocused) ]) {
        CGColorRef ours = W7CreateColor(W7ExplorerSelectionColorsForState(state.integerValue).border);
        BOOL same = CGColorEqualToColor(color, ours);
        CGColorRelease(ours);
        if (same) return YES;
    }
    return NO;
}

/// Dark appearance: take a highlight drawn while light off again. A property is put back to what
/// Finder had set only while it still holds our value (Finder's original may just have set its own).
static void W7UnstyleIconSelectionLayer(NSView *view, CALayer *layer) {
    CAGradientLayer *gradient = W7OurGradient(layer);
    NSDictionary *saved = objc_getAssociatedObject(view, kSavedLayerKey);
    if (!gradient && !saved) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [gradient removeFromSuperlayer];
    if (saved) {
        if (layer.backgroundColor == NULL) layer.backgroundColor = (__bridge CGColorRef)saved[@"bg"];
        if (W7IsOurBorderColor(layer.borderColor)) layer.borderColor = (__bridge CGColorRef)saved[@"border"];
        if (layer.borderWidth == 1) layer.borderWidth = [saved[@"borderWidth"] doubleValue];
        if (layer.cornerRadius == W7ExplorerSelectionRadius) layer.cornerRadius = [saved[@"cornerRadius"] doubleValue];
    }
    [CATransaction commit];
    objc_setAssociatedObject(view, kSavedLayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void W7StyleIconSelectionLayer(NSView *view) {
    CALayer *layer = view.layer;
    if (!layer) return;
    if (W7ExplorerAppearanceIsDark(view.effectiveAppearance)) { W7UnstyleIconSelectionLayer(view, layer); return; }
    W7ExplorerSelectionColors c = W7ExplorerSelectionColorsForState(
        W7IconSelectionFocused(view) ? W7ExplorerSelectionSelected : W7ExplorerSelectionSelectedUnfocused);
    CGColorRef border = W7CreateColor(c.border), top = W7CreateColor(c.top), bottom = W7CreateColor(c.bottom);
    // What Finder's original set before the first restyle, for W7UnstyleIconSelectionLayer (later passes
    // may find our own values still in place, so only the first is recorded).
    if (!objc_getAssociatedObject(view, kSavedLayerKey)) {
        NSMutableDictionary *saved = [NSMutableDictionary dictionary];
        if (layer.backgroundColor) saved[@"bg"] = (__bridge id)layer.backgroundColor;
        if (layer.borderColor) saved[@"border"] = (__bridge id)layer.borderColor;
        saved[@"borderWidth"] = @(layer.borderWidth);
        saved[@"cornerRadius"] = @(layer.cornerRadius);
        objc_setAssociatedObject(view, kSavedLayerKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.backgroundColor = NULL;
    layer.borderColor = border;
    layer.borderWidth = 1;
    layer.cornerRadius = W7ExplorerSelectionRadius;
    CAGradientLayer *gradient = W7OurGradient(layer);
    if (!gradient) {
        gradient = [CAGradientLayer layer];
        gradient.name = kGradientLayerName;
        gradient.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        [layer insertSublayer:gradient atIndex:0];
    }
    gradient.frame = layer.bounds;
    gradient.cornerRadius = W7ExplorerSelectionRadius;
    gradient.colors = @[ (__bridge id)top, (__bridge id)bottom ];
    // Unit y = 0 is the bottom unless the layer tree is flipped where the gradient renders.
    BOOL flipped = gradient.contentsAreFlipped;
    gradient.startPoint = CGPointMake(0.5, flipped ? 0 : 1);
    gradient.endPoint = CGPointMake(0.5, flipped ? 1 : 0);
    [CATransaction commit];
    CGColorRelease(border);
    CGColorRelease(top);
    CGColorRelease(bottom);
}

BOOL W7ExplorerHookIconSelectionClass(Class cls) {
    @try {
        if (!cls) return NO;
        if (W7IsHooked(@"icon", cls)) return YES;
        SEL sel = @selector(updateLayer);
        Method m = W7CheckedOwnMethod(cls, sel, "v16@0:8", "updateLayer");
        if (!m || !W7ClaimHook(@"icon", cls)) return m != NULL;
        void (*original)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(NSView *view) {
            original(view, sel);
            @try { W7StyleIconSelectionLayer(view); }
            @catch (NSException *e) { os_log_error(W7Log(), "icon selection restyle failed: %{public}@", e.reason ?: @"unknown"); }
        }));
        os_log(W7Log(), "selection highlight: %{public}@ -updateLayer hooked", NSStringFromClass(cls));
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "icon selection hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

BOOL W7ExplorerHookIconTitleClass(Class cls) {
    @try {
        if (!cls) return NO;
        if (W7IsHooked(@"title", cls)) return YES;
        // A pair, both or neither: Finder's selected title is white (-_titleFontColor answers
        // alternateSelectedControlTextColor when selected), so taking its bubble away alone makes it vanish.
        SEL bubbleSel = sel_registerName("titleBubbleViewIsSelected"), colorSel = sel_registerName("_titleFontColor");
        Method bubble = W7CheckedOwnMethod(cls, bubbleSel, "B16@0:8", "titleBubbleViewIsSelected");
        Method color = bubble ? W7CheckedOwnMethod(cls, colorSel, "@16@0:8", "_titleFontColor") : NULL;
        if (!bubble || !color) return NO;
        if (!W7ClaimHook(@"title", cls)) return YES;
        BOOL (*originalBubble)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(bubble);
        id (*originalColor)(id, SEL) = (id (*)(id, SEL))method_getImplementation(color);
        SEL dimmedSel = sel_registerName("isTitleDimmed");
        W7ExplorerIconTitleLook (^look)(id) = ^W7ExplorerIconTitleLook(id view) {
            BOOL dark = ![view isKindOfClass:NSView.class] || W7ExplorerAppearanceIsDark(((NSView *)view).effectiveAppearance);
            return W7ExplorerIconTitleLookFor(originalBubble(view, bubbleSel), dark);
        };
        method_setImplementation(bubble, imp_implementationWithBlock(^BOOL(id view) {
            @try { return look(view) == W7ExplorerIconTitleDarkNoBubble ? NO : originalBubble(view, bubbleSel); }
            @catch (NSException *e) { return originalBubble(view, bubbleSel); }
        }));
        method_setImplementation(color, imp_implementationWithBlock(^id(id view) {
            id original = originalColor(view, colorSel);
            @try {
                if (look(view) != W7ExplorerIconTitleDarkNoBubble) return original;
                BOOL dimmed = W7HasTypes(view, dimmedSel, "B16@0:8") && ((BOOL (*)(id, SEL))objc_msgSend)(view, dimmedSel);
                return W7ExplorerIconTitleDarkColor(dimmed);
            } @catch (NSException *e) {
                return original;
            }
        }));
        os_log(W7Log(), "selection highlight: %{public}@ -titleBubbleViewIsSelected and -_titleFontColor hooked", NSStringFromClass(cls));
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "icon title hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - List view

/// The row's highlight rect: the horizontal span of its cell views (Finder's inset style leaves a
/// margin at both ends) widened by 2, within the bounds; the whole row when it has no cells.
static NSRect W7RowHighlightRect(NSTableRowView *row) {
    NSRect b = row.bounds;
    CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX;
    for (NSView *sub in row.subviews) {
        if (sub.isHidden || NSWidth(sub.frame) <= 0) continue;
        minX = MIN(minX, NSMinX(sub.frame));
        maxX = MAX(maxX, NSMaxX(sub.frame));
    }
    if (maxX <= minX) return NSInsetRect(b, 1, 0);
    minX = MAX(NSMinX(b), minX - 2);
    maxX = MIN(NSMaxX(b), maxX + 2);
    return NSMakeRect(minX, NSMinY(b), maxX - minX, NSHeight(b));
}

/// The draw hook paints the Windows 7 highlight for this row (a highlight style, a light appearance);
/// otherwise Finder's own selection is drawn.
static BOOL W7RowDrawsWindowsHighlight(NSTableRowView *row) {
    return row.selectionHighlightStyle != NSTableViewSelectionHighlightStyleNone && !W7ExplorerAppearanceIsDark(row.effectiveAppearance);
}

/// Calls the implementation `cls`'s superclass has for `sel` now (the class's own method was added
/// by the hook, so the inherited one is looked up on every call).
static IMP W7SuperIMP(Class cls, SEL sel) {
    return class_getMethodImplementation(class_getSuperclass(cls), sel);
}

/// Hooks `sel` on `cls`: replaces its own method, or adds one that overrides the inherited one. The
/// encoding must equal NSTableRowView's. `make` builds the replacement from a block calling the original.
static BOOL W7HookRowMethod(Class cls, SEL sel, id (^make)(IMP (^original)(void))) {
    Method base = class_getInstanceMethod(NSTableRowView.class, sel);
    const char *types = base ? method_getTypeEncoding(base) : NULL;
    if (!types) return NO;
    Method own = W7OwnMethod(cls, sel);
    if (own) {
        const char *ownTypes = method_getTypeEncoding(own);
        if (!ownTypes || strcmp(ownTypes, types) != 0) {
            os_log(W7Log(), "selection highlight: %{public}@ skipped, %{public}@ has types %{public}s",
                   NSStringFromClass(cls), NSStringFromSelector(sel), ownTypes ?: "(none)");
            return NO;
        }
        IMP saved = method_getImplementation(own);
        method_setImplementation(own, imp_implementationWithBlock(make(^IMP { return saved; })));
        return YES;
    }
    Method inherited = class_getInstanceMethod(cls, sel);
    const char *inheritedTypes = inherited ? method_getTypeEncoding(inherited) : NULL;
    if (!inheritedTypes || strcmp(inheritedTypes, types) != 0) return NO;
    return class_addMethod(cls, sel, imp_implementationWithBlock(make(^IMP { return W7SuperIMP(cls, sel); })), types);
}

BOOL W7ExplorerHookListRowClass(Class cls) {
    @try {
        if (!cls || ![cls isSubclassOfClass:NSTableRowView.class]) return NO;
        if (W7IsHooked(@"row", cls)) return YES;
        SEL draw = @selector(drawSelectionInRect:), style = @selector(interiorBackgroundStyle);
        // Both are checked before either is hooked, so a class is never half restyled.
        Method baseDraw = class_getInstanceMethod(NSTableRowView.class, draw), baseStyle = class_getInstanceMethod(NSTableRowView.class, style);
        Method d = class_getInstanceMethod(cls, draw), s = class_getInstanceMethod(cls, style);
        const char *dTypes = d ? method_getTypeEncoding(d) : NULL, *sTypes = s ? method_getTypeEncoding(s) : NULL;
        const char *baseDrawTypes = baseDraw ? method_getTypeEncoding(baseDraw) : NULL;
        const char *baseStyleTypes = baseStyle ? method_getTypeEncoding(baseStyle) : NULL;
        if (!dTypes || !sTypes || !baseDrawTypes || !baseStyleTypes || strcmp(dTypes, baseDrawTypes) != 0 ||
            strcmp(sTypes, baseStyleTypes) != 0) {
            os_log(W7Log(), "selection highlight: %{public}@ skipped, row methods have unexpected types", NSStringFromClass(cls));
            return NO;
        }
        if (!W7ClaimHook(@"row", cls)) return YES;
        __block BOOL painted = NO;   // per hooked class: the draw hook has painted a row (main thread)
        BOOL okDraw = W7HookRowMethod(cls, draw, ^id(IMP (^original)(void)) {
            return ^(NSTableRowView *row, NSRect dirty) {
                @try {
                    if (W7RowDrawsWindowsHighlight(row)) {
                        W7ExplorerSelectionState state = row.isEmphasized ? W7ExplorerSelectionSelected : W7ExplorerSelectionSelectedUnfocused;
                        W7DrawExplorerSelection(NSGraphicsContext.currentContext.CGContext, W7RowHighlightRect(row), state, row.isFlipped);
                        if (!painted) {
                            painted = YES;
                            os_log(W7Log(), "selection highlight: %{public}@ drew its first row", NSStringFromClass(cls));
                        }
                        return;
                    }
                } @catch (NSException *e) {
                    os_log_error(W7Log(), "list selection draw failed: %{public}@", e.reason ?: @"unknown");
                }
                ((void (*)(id, SEL, NSRect))original())(row, draw, dirty);
            };
        });
        // Black text only where our light highlight is drawn: no draw hook, no background style hook; and
        // until the draw hook has actually painted a row of this class (the latch), Finder's own style —
        // if Finder drew its selection some other way, its white-on-accent text is left alone.
        BOOL okStyle = okDraw && W7HookRowMethod(cls, style, ^id(IMP (^original)(void)) {
            return ^NSBackgroundStyle(NSTableRowView *row) {
                NSBackgroundStyle value = ((NSBackgroundStyle (*)(id, SEL))original())(row, style);
                @try { return painted && row.isSelected && W7RowDrawsWindowsHighlight(row) ? NSBackgroundStyleNormal : value; }
                @catch (NSException *e) { return value; }
            };
        });
        os_log(W7Log(), "selection highlight: %{public}@ rows hooked (draw %d, background style %d)", NSStringFromClass(cls), okDraw, okStyle);
        return okDraw;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "list row hook failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

#pragma mark - Install

void W7ExplorerInstallSelectionHighlight(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
            BOOL disabled = [NSUserDefaults.standardUserDefaults boolForKey:kSelectionDisabledKey];
            if (!W7ExplorerSelectionHighlightShouldInstall(bundleID, disabled)) {
                os_log(W7Log(), "selection highlight: not installed in %{public}@ (%{public}s)", bundleID ?: @"(none)",
                       disabled ? "W7ExplorerSelectionDisabled" : "not Finder");
                return;
            }
            struct { const char *name; BOOL (*hook)(Class); } hooks[] = {
                { "TIconSelectionView", W7ExplorerHookIconSelectionClass },
                { "TIconView", W7ExplorerHookIconTitleClass },
                { "TListRowView", W7ExplorerHookListRowClass },
            };
            for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
                Class cls = objc_getClass(hooks[i].name);
                if (!cls) { os_log(W7Log(), "selection highlight: %{public}s missing", hooks[i].name); continue; }
                hooks[i].hook(cls);
            }
        } @catch (NSException *e) {
            os_log_error(W7Log(), "selection highlight install failed: %{public}@", e.reason ?: @"unknown");
        }
    });
}
