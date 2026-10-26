#import "Win7ChromeCore.h"
#import <objc/runtime.h>

BOOL W7SwizzleClassMethod(Class cls, SEL original, SEL replacement) {
    @try {
        if (!cls || !original || !replacement) return NO;
        Class meta = object_getClass(cls);
        Method o = class_getInstanceMethod(meta, original);
        Method r = class_getInstanceMethod(meta, replacement);
        if (!o || !r) return NO;
        // Add first so an inherited original is swizzled on `cls` only, not on its superclass.
        if (class_addMethod(meta, original, method_getImplementation(r), method_getTypeEncoding(r))) {
            class_replaceMethod(meta, replacement, method_getImplementation(o), method_getTypeEncoding(o));
        } else {
            method_exchangeImplementations(o, r);
        }
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "W7SwizzleClassMethod failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}

BOOL W7SwizzleInstanceMethod(Class cls, SEL original, SEL replacement) {
    @try {
        if (!cls || !original || !replacement) return NO;
        Method o = class_getInstanceMethod(cls, original);
        Method r = class_getInstanceMethod(cls, replacement);
        if (!o || !r) return NO;
        // Add first so an inherited original is swizzled on `cls` only, not on its superclass.
        if (class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r))) {
            class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o));
        } else {
            method_exchangeImplementations(o, r);
        }
        return YES;
    } @catch (NSException *e) {
        os_log_error(W7Log(), "W7SwizzleInstanceMethod failed: %{public}@", e.reason ?: @"unknown");
        return NO;
    }
}
