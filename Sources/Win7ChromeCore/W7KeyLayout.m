// Keyboard-layout helpers for menu lookup. macOS localizes menu key equivalents to the current layout
// (Cmd+[ shows as Cmd+Ğ on Turkish Q: the key in the US "[" position types "ğ" there), so a US key
// is translated through its US-ANSI virtual key code into what that key types in the current layout.
#import "Win7ChromeCore.h"
#import <Carbon/Carbon.h>

NSInteger W7USVirtualKeyCode(NSString *character) {
    static NSDictionary<NSString *, NSNumber *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"a": @(kVK_ANSI_A), @"b": @(kVK_ANSI_B), @"c": @(kVK_ANSI_C), @"d": @(kVK_ANSI_D),
            @"e": @(kVK_ANSI_E), @"f": @(kVK_ANSI_F), @"g": @(kVK_ANSI_G), @"h": @(kVK_ANSI_H),
            @"i": @(kVK_ANSI_I), @"j": @(kVK_ANSI_J), @"k": @(kVK_ANSI_K), @"l": @(kVK_ANSI_L),
            @"m": @(kVK_ANSI_M), @"n": @(kVK_ANSI_N), @"o": @(kVK_ANSI_O), @"p": @(kVK_ANSI_P),
            @"q": @(kVK_ANSI_Q), @"r": @(kVK_ANSI_R), @"s": @(kVK_ANSI_S), @"t": @(kVK_ANSI_T),
            @"u": @(kVK_ANSI_U), @"v": @(kVK_ANSI_V), @"w": @(kVK_ANSI_W), @"x": @(kVK_ANSI_X),
            @"y": @(kVK_ANSI_Y), @"z": @(kVK_ANSI_Z),
            @"0": @(kVK_ANSI_0), @"1": @(kVK_ANSI_1), @"2": @(kVK_ANSI_2), @"3": @(kVK_ANSI_3),
            @"4": @(kVK_ANSI_4), @"5": @(kVK_ANSI_5), @"6": @(kVK_ANSI_6), @"7": @(kVK_ANSI_7),
            @"8": @(kVK_ANSI_8), @"9": @(kVK_ANSI_9),
            @"[": @(kVK_ANSI_LeftBracket), @"]": @(kVK_ANSI_RightBracket), @";": @(kVK_ANSI_Semicolon),
            @"'": @(kVK_ANSI_Quote), @",": @(kVK_ANSI_Comma), @".": @(kVK_ANSI_Period),
            @"/": @(kVK_ANSI_Slash), @"\\": @(kVK_ANSI_Backslash), @"`": @(kVK_ANSI_Grave),
            @"-": @(kVK_ANSI_Minus), @"=": @(kVK_ANSI_Equal),
        };
    });
    if (character.length != 1) return -1;
    NSNumber *code = table[character.lowercaseString];   // not locale-dependent
    return code ? code.integerValue : -1;
}

NSString *W7TranslateVirtualKey(NSData *layoutData, NSInteger virtualKey, BOOL shift) {
    if (virtualKey < 0 || virtualKey > 0x7F || layoutData.length < sizeof(UCKeyboardLayout)) return nil;
    const UCKeyboardLayout *layout = (const UCKeyboardLayout *)layoutData.bytes;
    if (layout->keyLayoutHeaderFormat != kUCKeyLayoutHeaderFormat) return nil;
    UInt32 deadKeys = 0;
    UniChar chars[8];
    UniCharCount length = 0;
    UInt32 modifiers = shift ? ((shiftKey >> 8) & 0xFF) : 0;
    OSStatus status = UCKeyTranslate(layout, (UInt16)virtualKey, kUCKeyActionDown, modifiers, LMGetKbdType(),
                                     kUCKeyTranslateNoDeadKeysMask, &deadKeys, 8, &length, chars);
    if (status != noErr || length == 0) return nil;
    return [NSString stringWithCharacters:chars length:length];
}

NSData *W7CurrentKeyboardLayoutData(void) {
    @try {
        NSData *result = nil;
        TISInputSourceRef sources[2] = { TISCopyCurrentKeyboardLayoutInputSource(), NULL };
        CFDataRef data = sources[0] ? TISGetInputSourceProperty(sources[0], kTISPropertyUnicodeKeyLayoutData) : NULL;
        if (!data) {   // an input method without 'uchr' data: use the layout it types ASCII with
            sources[1] = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
            data = sources[1] ? TISGetInputSourceProperty(sources[1], kTISPropertyUnicodeKeyLayoutData) : NULL;
        }
        if (data) result = [(__bridge NSData *)data copy];
        for (int i = 0; i < 2; i++) if (sources[i]) CFRelease(sources[i]);
        return result;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "Keyboard layout lookup failed: %{public}@", e.reason ?: @"unknown");
        return nil;
    }
}
