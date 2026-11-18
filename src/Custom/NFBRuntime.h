//
//  NFBRuntime.h
//  NeoFreeBird (custom tweaks)
//
//  Type-checked runtime probing. X renames and retypes its classes between
//  builds; calling a selector whose return type is not what the caller
//  assumes (an integer read as an object, say) crashes. These helpers read
//  the method signature first and return nil / NO / fallback instead.
//

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static inline char NFBReturnTypeCode(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector]) return 0;
    NSMethodSignature* signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return 0;  // self + _cmd only
    const char* type = signature.methodReturnType;
    // Skip type qualifiers such as 'r' (const) that may prefix the code.
    while (type && (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' ||
                    *type == 'R' || *type == 'V')) {
        type++;
    }
    return type ? *type : 0;
}

// Object-returning zero-argument getter, or nil.
static inline id NFBGetObject(id target, NSString* selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (NFBReturnTypeCode(target, selector) != '@') return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

// BOOL getter; `found` (optional) reports whether a BOOL getter existed.
static inline BOOL NFBGetBool(id target, NSString* selectorName, BOOL* found) {
    SEL selector = NSSelectorFromString(selectorName);
    char code = NFBReturnTypeCode(target, selector);
    if (found) *found = NO;
    if (code != 'B' && code != 'c') return NO;
    if (found) *found = YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

// Integer getter (any signed or unsigned integer width), or `fallback`.
static inline long long NFBGetInteger(id target, NSString* selectorName, long long fallback) {
    SEL selector = NSSelectorFromString(selectorName);
    switch (NFBReturnTypeCode(target, selector)) {
        case 'q': case 'Q':
            return ((long long (*)(id, SEL))objc_msgSend)(target, selector);
        case 'l': case 'L': case 'i': case 'I':
            return ((int (*)(id, SEL))objc_msgSend)(target, selector);
        default:
            return fallback;
    }
}

static inline BOOL NFBInstancesRespond(NSString* className, SEL selector) {
    Class cls = NSClassFromString(className);
    return cls && class_getInstanceMethod(cls, selector) != NULL;
}

static inline BOOL NFBClassResponds(NSString* className, SEL selector) {
    Class cls = NSClassFromString(className);
    return cls && class_getClassMethod(cls, selector) != NULL;
}

// NSLog with a fixed prefix, so device logs (Console.app, idevicesyslog) can
// be filtered to these tweaks with "[NFB custom]".
#define NFBCustomLog(fmt, ...) NSLog(@"[NFB custom] " fmt, ##__VA_ARGS__)
