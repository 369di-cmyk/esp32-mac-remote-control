#pragma once
/*
 * Objective-C adaptation of BLEUnlock PR #195, commit
 * c4661c8becc6a1556a4d1e42a130f6ab81c1ddf1:
 * https://github.com/ts1/BLEUnlock/pull/195
 * ScreenLockState.swift, SystemUnlockTarget.swift, UnlockKeyboard.swift.
 * Upstream: MIT; Copyright (c) 2019-2022 Takeshi Sone.
 * Local additions: secure-input/Caps Lock checks, bounded clearing, deadline
 * and cancellation gates. No credential storage, networking, or BLE here.
 * See THIRD_PARTY_NOTICES.txt shipped with the application source.
 */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <Security/Security.h>
#import <unistd.h>

typedef NS_ENUM(NSInteger, LULockState) {
    LULockStateUnknown = -1,
    LULockStateUnlocked = 0,
    LULockStateLocked = 1,
};

static BOOL LUFail(NSString **why, NSString *reason) {
    if (why) *why = reason;
    return NO;
}

// Pure policy function. Conflicting/missing observations never authorize input.
static LULockState LUEvaluateLockState(NSDictionary *session, NSNumber *consoleLocked, uid_t userID) {
    if (![session isKindOfClass:NSDictionary.class]) return LULockStateUnknown;
    NSNumber *owner = session[(__bridge NSString *)kCGSessionUserIDKey];
    NSNumber *onConsole = session[(__bridge NSString *)kCGSessionOnConsoleKey];
    NSNumber *loginDone = session[(__bridge NSString *)kCGSessionLoginDoneKey];
    if (![owner isKindOfClass:NSNumber.class] || owner.unsignedIntValue != userID ||
        ![onConsole isKindOfClass:NSNumber.class] || !onConsole.boolValue ||
        ![loginDone isKindOfClass:NSNumber.class] || !loginDone.boolValue) return LULockStateUnknown;
    NSNumber *legacy = session[@"CGSSessionScreenIsLocked"];
    if (![legacy isKindOfClass:NSNumber.class]) legacy = nil;
    if (![consoleLocked isKindOfClass:NSNumber.class]) consoleLocked = nil;
    if (legacy && consoleLocked && legacy.boolValue != consoleLocked.boolValue) return LULockStateUnknown;
    NSNumber *observed = consoleLocked ?: legacy;
    if (!observed) return LULockStateUnknown;
    return observed.boolValue ? LULockStateLocked : LULockStateUnlocked;
}

static LULockState LUCurrentLockState(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    NSNumber *consoleLocked = nil;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(root, CFSTR("IOConsoleLocked"), kCFAllocatorDefault, 0);
        if (value) {
            if (CFGetTypeID(value) == CFBooleanGetTypeID()) consoleLocked = [(__bridge NSNumber *)value copy];
            CFRelease(value);
        }
        IOObjectRelease(root);
    }
    return LUEvaluateLockState(session, consoleLocked, getuid());
}

typedef NS_ENUM(NSInteger, LUTargetKind) { LUTargetUnknown, LUTargetClassic, LUTargetPlatformSSO };
static NSString *LUBundleIdentifier(LUTargetKind kind) {
    if (kind == LUTargetClassic) return @"com.apple.loginwindow";
    if (kind == LUTargetPlatformSSO) return @"com.apple.PlatformSSO.PlatformSSOUIAgent";
    return nil;
}
static NSString *LUExecutablePath(LUTargetKind kind) {
    if (kind == LUTargetClassic) return @"/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow";
    if (kind == LUTargetPlatformSSO) return @"/System/Library/PrivateFrameworks/PlatformSSO.framework/Support/PlatformSSOUIAgent.app/Contents/MacOS/PlatformSSOUIAgent";
    return nil;
}
static LUTargetKind LUKindForIdentity(NSString *bundle, NSString *resolvedPath) {
    for (NSInteger kind = LUTargetClassic; kind <= LUTargetPlatformSSO; kind++)
        if ([bundle isEqualToString:LUBundleIdentifier(kind)] && [resolvedPath isEqualToString:LUExecutablePath(kind)]) return kind;
    return LUTargetUnknown;
}
static LUTargetKind LUKindForApplication(NSRunningApplication *app) {
    return LUKindForIdentity(app.bundleIdentifier, app.executableURL.URLByResolvingSymlinksInPath.path);
}
static BOOL LUHasAppleIdentity(NSRunningApplication *app, LUTargetKind kind) {
    if (!app || app.processIdentifier <= 0 || kind == LUTargetUnknown) return NO;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(app.processIdentifier)};
    SecCodeRef code = NULL;
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) != errSecSuccess || !code) return NO;
    NSString *expression = [NSString stringWithFormat:@"anchor apple and identifier \"%@\"", LUBundleIdentifier(kind)];
    SecRequirementRef requirement = NULL;
    OSStatus result = SecRequirementCreateWithString((__bridge CFStringRef)expression, kSecCSDefaultFlags, &requirement);
    BOOL valid = result == errSecSuccess && requirement && SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement) == errSecSuccess;
    if (requirement) CFRelease(requirement);
    CFRelease(code);
    return valid;
}
static BOOL LUIsSecureTextRole(NSString *role, NSString *subrole) {
    return [role isEqualToString:@"AXTextField"] && [subrole isEqualToString:@"AXSecureTextField"];
}
static NSString *LURoleIdentifier(id value) {
    if (![value isKindOfClass:NSString.class] || ![value hasPrefix:@"AX"] || [value length] > 80) return nil;
    NSCharacterSet *valid = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"];
    return [value rangeOfCharacterFromSet:valid.invertedSet].location == NSNotFound ? value : nil;
}
static id LUAXAttribute(AXUIElementRef element, CFStringRef name, AXError *error) {
    CFTypeRef value = NULL;
    AXError result = AXUIElementCopyAttributeValue(element, name, &value);
    if (error) *error = result;
    return value ? CFBridgingRelease(value) : nil;
}
static BOOL LUIsAXElement(id value) { return value && CFGetTypeID((__bridge CFTypeRef)value) == AXUIElementGetTypeID(); }
static BOOL LUMatchesAXOwner(id element, pid_t pid, NSString **why) {
    pid_t owner = 0;
    AXError error = AXUIElementGetPid((__bridge AXUIElementRef)element, &owner);
    if (error != kAXErrorSuccess) return LUFail(why, @"无法确认密码输入框所属进程，已停止。");
    return owner == pid ? YES : LUFail(why, @"密码输入框所属进程不匹配，已停止。");
}

// Reads only focus identity, roles, ownership and ancestor types, never text/value.
static id LUNativeSecureFocus(NSRunningApplication *app, NSString **why) {
    if (!AXIsProcessTrusted()) { LUFail(why, @"需要为本地助手开启辅助功能权限，才能核对密码输入框。"); return nil; }
    AXUIElementRef rawApp = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(rawApp, 0.1);
    AXError error = kAXErrorSuccess;
    id focus = LUAXAttribute(rawApp, kAXFocusedUIElementAttribute, &error);
    CFRelease(rawApp);
    if (error != kAXErrorSuccess || !LUIsAXElement(focus)) { LUFail(why, @"系统密码输入框尚未就绪，未输入密码。"); return nil; }
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)focus, 0.1);
    if (!LUMatchesAXOwner(focus, app.processIdentifier, why)) return nil;
    AXError roleError = kAXErrorSuccess, subroleError = kAXErrorSuccess;
    NSString *role = LURoleIdentifier(LUAXAttribute((__bridge AXUIElementRef)focus, kAXRoleAttribute, &roleError));
    NSString *subrole = LURoleIdentifier(LUAXAttribute((__bridge AXUIElementRef)focus, kAXSubroleAttribute, &subroleError));
    if (roleError != kAXErrorSuccess || subroleError != kAXErrorSuccess || !LUIsSecureTextRole(role, subrole)) {
        LUFail(why, @"当前焦点不是系统安全密码输入框，已停止。"); return nil;
    }
    id current = focus;
    NSMutableArray *visited = [NSMutableArray arrayWithObject:focus];
    for (NSUInteger i = 0; i < 8; i++) {
        id parent = LUAXAttribute((__bridge AXUIElementRef)current, kAXParentAttribute, &error);
        if (error != kAXErrorSuccess || !LUIsAXElement(parent)) { LUFail(why, @"无法确认密码输入框位于原生系统窗口，已停止。"); return nil; }
        for (id previous in visited) if (CFEqual((__bridge CFTypeRef)previous, (__bridge CFTypeRef)parent)) {
            LUFail(why, @"密码窗口结构异常，已停止。"); return nil;
        }
        [visited addObject:parent];
        AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)parent, 0.1);
        if (!LUMatchesAXOwner(parent, app.processIdentifier, why)) return nil;
        NSString *parentRole = LURoleIdentifier(LUAXAttribute((__bridge AXUIElementRef)parent, kAXRoleAttribute, &error));
        if (error != kAXErrorSuccess || !parentRole) { LUFail(why, @"无法确认密码窗口类型，已停止。"); return nil; }
        if ([parentRole isEqualToString:@"AXWebArea"]) { LUFail(why, @"当前是网页登录区域，已停止。"); return nil; }
        if ([parentRole isEqualToString:@"AXWindow"]) return focus;
        current = parent;
    }
    LUFail(why, @"无法确认密码输入框的原生系统窗口，已停止。");
    return nil;
}

@interface LUUnlockTarget : NSObject
@property (nonatomic, strong) NSRunningApplication *application;
@property (nonatomic) LUTargetKind kind;
@property (nonatomic, strong) id secureFocus;
@property (nonatomic, readonly) pid_t processIdentifier;
- (BOOL)isCurrent:(NSString **)why;
@end
@implementation LUUnlockTarget
- (pid_t)processIdentifier { return self.application.processIdentifier; }
- (BOOL)isCurrent:(NSString **)why {
    if (!NSThread.isMainThread) return LUFail(why, @"目标窗口检查必须在主线程执行，已停止。");
    NSRunningApplication *current = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (self.application.terminated || !current || current.processIdentifier != self.processIdentifier ||
        !current.active || current.terminated || LUKindForApplication(current) != self.kind ||
        !LUHasAppleIdentity(current, self.kind)) return LUFail(why, @"系统登录窗口已变化，已停止输入。");
    if (self.kind == LUTargetPlatformSSO) {
        id focus = LUNativeSecureFocus(current, why);
        if (!self.secureFocus || !focus || !CFEqual((__bridge CFTypeRef)self.secureFocus, (__bridge CFTypeRef)focus))
            return LUFail(why, @"系统密码输入框焦点已变化，已停止输入。");
    }
    NSRunningApplication *last = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!last || last.processIdentifier != self.processIdentifier || !last.active || last.terminated ||
        LUKindForApplication(last) != self.kind) return LUFail(why, @"前台系统窗口已变化，已停止输入。");
    return YES;
}
@end

static LUUnlockTarget *LUCaptureTarget(BOOL allowPlatformSSO, NSString **why) {
    if (!NSThread.isMainThread) { LUFail(why, @"目标窗口捕获必须在主线程执行，已停止。"); return nil; }
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    LUTargetKind kind = LUKindForApplication(app);
    if (!app || kind == LUTargetUnknown) { LUFail(why, @"前台不是已验证的系统登录窗口，未输入密码。"); return nil; }
    if (!LUHasAppleIdentity(app, kind)) { LUFail(why, @"系统登录窗口的 Apple 签名校验失败，已停止。"); return nil; }
    if (!app.active || app.terminated) { LUFail(why, @"系统登录窗口尚未激活，未输入密码。"); return nil; }
    if (kind == LUTargetPlatformSSO && !allowPlatformSSO) { LUFail(why, @"当前系统密码窗口需要启用 Platform SSO 支持。"); return nil; }
    id focus = kind == LUTargetPlatformSSO ? LUNativeSecureFocus(app, why) : nil;
    if (kind == LUTargetPlatformSSO && !focus) return nil;
    LUUnlockTarget *target = [LUUnlockTarget new]; target.application = app; target.kind = kind; target.secureFocus = focus;
    return [target isCurrent:why] ? target : nil;
}

static BOOL LULocalGuard(LUUnlockTarget *target, NSTimeInterval deadline, BOOL (^allowed)(void), NSString **why) {
    if (!NSThread.isMainThread) return LUFail(why, @"按键检查必须在主线程执行，已停止。");
    if (NSProcessInfo.processInfo.systemUptime >= deadline) return LUFail(why, @"解锁过程已超时，已停止。");
    if (allowed && !allowed()) return LUFail(why, @"本次解锁已取消。");
    if (LUCurrentLockState() != LULockStateLocked) return LUFail(why, @"未确认当前用户仍处于锁屏状态，已停止。");
    if (!IsSecureEventInputEnabled()) return LUFail(why, @"未检测到安全密码输入状态，已停止。");
    if (CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & kCGEventFlagMaskAlphaShift)
        return LUFail(why, @"Caps Lock 已开启，已停止。请关闭大写锁定后重新尝试。");
    if (!CGPreflightPostEventAccess()) return LUFail(why, @"本地助手尚未获得控制输入权限，未输入密码。");
    if (!target) return LUFail(why, @"未捕获系统密码窗口，未输入密码。");
    if (![target isCurrent:why]) return NO;
    // Recheck after the bounded AX/signature queries, immediately before posting.
    if (NSProcessInfo.processInfo.systemUptime >= deadline || (allowed && !allowed())) return LUFail(why, @"本次解锁已取消或超时。");
    if (LUCurrentLockState() != LULockStateLocked || !IsSecureEventInputEnabled()) return LUFail(why, @"锁屏或安全输入状态已变化，已停止。");
    if (CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & kCGEventFlagMaskAlphaShift)
        return LUFail(why, @"Caps Lock 已开启，已停止。请关闭大写锁定后重新尝试。");
    return YES;
}

@interface LUEventPair : NSObject
@property (nonatomic, strong) id down;
@property (nonatomic, strong) id up;
@property (nonatomic) BOOL submits;
@end
@implementation LUEventPair
@end

// Pure UTF-16 splitting, never separates surrogate pairs. Same 20-unit bound as upstream.
static NSArray<NSData *> *LUUnicodeChunks(NSString *text) {
    NSMutableArray<NSData *> *chunks = [NSMutableArray new];
    NSMutableData *chunk = [NSMutableData new];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar units[2] = {[text characterAtIndex:i], 0}; NSUInteger count = 1;
        if (CFStringIsSurrogateHighCharacter(units[0]) && i + 1 < text.length &&
            CFStringIsSurrogateLowCharacter([text characterAtIndex:i + 1])) { units[1] = [text characterAtIndex:++i]; count = 2; }
        if (chunk.length + count * sizeof(unichar) > 20 * sizeof(unichar)) { [chunks addObject:[chunk copy]]; [chunk setLength:0]; }
        [chunk appendBytes:units length:count * sizeof(unichar)];
    }
    if (chunk.length) [chunks addObject:[chunk copy]];
    return chunks;
}
static LUEventPair *LUMakeEventPair(CGEventSourceRef source, CGKeyCode key, NSData *unicode, BOOL submits) {
    CGEventRef down = CGEventCreateKeyboardEvent(source, key, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, key, false);
    if (!down || !up) { if (down) CFRelease(down); if (up) CFRelease(up); return nil; }
    CGEventSetFlags(down, 0); CGEventSetFlags(up, 0);
    if (unicode.length) {
        CGEventKeyboardSetUnicodeString(down, unicode.length / sizeof(unichar), unicode.bytes);
        CGEventKeyboardSetUnicodeString(up, unicode.length / sizeof(unichar), unicode.bytes);
    }
    LUEventPair *pair = [LUEventPair new]; pair.down = CFBridgingRelease(down); pair.up = CFBridgingRelease(up); pair.submits = submits;
    return pair;
}
static NSArray<LUEventPair *> *LUBuildUnlockEventPairs(NSString *password, NSUInteger backspaceCount, NSString **why) {
    if (!password.length || password.length > 256 || backspaceCount > 256) { LUFail(why, @"密码或清空长度不受支持，未输入。"); return nil; }
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!source) { LUFail(why, @"无法创建本地输入事件，未输入密码。"); return nil; }
    NSMutableArray<LUEventPair *> *pairs = [NSMutableArray new];
    BOOL success = YES;
    for (NSUInteger i = 0; i < backspaceCount && success; i++) {
        LUEventPair *pair = LUMakeEventPair(source, 0x33, nil, NO); if (pair) [pairs addObject:pair]; else success = NO;
    }
    if (success) for (NSData *chunk in LUUnicodeChunks(password)) {
        LUEventPair *pair = LUMakeEventPair(source, 0x31, chunk, NO); if (pair) [pairs addObject:pair]; else { success = NO; break; }
    }
    if (success) { LUEventPair *pair = LUMakeEventPair(source, 0x24, nil, YES); if (pair) [pairs addObject:pair]; else success = NO; }
    CFRelease(source);
    if (!success) { LUFail(why, @"无法创建完整的本地输入事件，未输入密码。"); return nil; }
    return pairs;
}

// Injectable delivery boundary enables tests with in-memory events/mock posts.
static BOOL LUDeliverPairWithGate(LUEventPair *pair, pid_t pid, BOOL (^gate)(void), void (^post)(pid_t, CGEventRef)) {
    if (!pair.down || !pair.up || pid <= 0 || !gate || !post || !gate()) return NO;
    post(pid, (__bridge CGEventRef)pair.down);
    post(pid, (__bridge CGEventRef)pair.up);
    return YES;
}

// This is the only production input-delivery function. Never calls CGEventPost.
// Both halves go to the same captured PID even if Return immediately unlocks.
static BOOL LUDeliverEventPair(LUEventPair *pair, LUUnlockTarget *target, NSTimeInterval deadline, BOOL (^allowed)(void), NSString **why) {
    if (!pair.down || !pair.up) return LUFail(why, @"本地输入事件不完整，已停止。");
    if (!target) return LUFail(why, @"未捕获系统密码窗口，未输入密码。");
    __block NSString *reason = nil;
    BOOL delivered = LUDeliverPairWithGate(pair, target.processIdentifier, ^BOOL{ return LULocalGuard(target, deadline, allowed, &reason); }, ^(pid_t pid, CGEventRef event) {
        CGEventPostToPid(pid, event);
    });
    if (!delivered && why) *why = reason ?: @"本地输入已停止。";
    return delivered;
}

// Read-only focus metadata for an already captured system target. This does not
// authorize input and deliberately omits values, names, titles and ancestors.
// The routine diagnostic therefore adds at most three bounded AX queries.
static NSDictionary *LUFocusDiagnostic(LUUnlockTarget *target) {
    if (!NSThread.isMainThread) return @{@"reason": @"main_thread_required"};
    if (!target || target.processIdentifier <= 0 || target.application.terminated)
        return @{@"reason": @"no_captured_target"};
    if (!AXIsProcessTrusted()) return @{@"reason": @"accessibility_not_trusted"};
    AXUIElementRef application = AXUIElementCreateApplication(target.processIdentifier);
    if (!application) return @{@"reason": @"application_element_unavailable"};
    AXUIElementSetMessagingTimeout(application, 0.1);
    AXError focusError = kAXErrorSuccess;
    id focus = LUAXAttribute(application, kAXFocusedUIElementAttribute, &focusError);
    CFRelease(application);
    if (focusError != kAXErrorSuccess || !LUIsAXElement(focus))
        return @{@"reason": @"focused_element_unavailable", @"ax_error": @(focusError)};
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)focus, 0.1);
    pid_t owner = 0;
    AXError ownerError = AXUIElementGetPid((__bridge AXUIElementRef)focus, &owner);
    if (ownerError != kAXErrorSuccess)
        return @{@"reason": @"focus_owner_unavailable", @"ax_error": @(ownerError)};
    if (owner != target.processIdentifier)
        return @{@"reason": @"focus_owner_mismatch", @"owner_matches_target": @NO,
                 @"ax_error": @(kAXErrorSuccess)};
    AXError roleError = kAXErrorSuccess, subroleError = kAXErrorSuccess;
    NSString *role = LURoleIdentifier(LUAXAttribute((__bridge AXUIElementRef)focus, kAXRoleAttribute, &roleError));
    NSString *subrole = LURoleIdentifier(LUAXAttribute((__bridge AXUIElementRef)focus, kAXSubroleAttribute, &subroleError));
    BOOL complete = roleError == kAXErrorSuccess && subroleError == kAXErrorSuccess && role && subrole;
    return @{@"reason": complete ? @"focus_metadata_available" : @"focus_role_unavailable",
             @"owner_matches_target": @YES,
             @"role": role ?: @"unavailable", @"subrole": subrole ?: @"unavailable",
             @"role_ax_error": @(roleError), @"subrole_ax_error": @(subroleError),
             @"secure_text_role": @(complete && LUIsSecureTextRole(role, subrole))};
}

// Metadata only: no credential, field value, window title, or arbitrary app name.
static NSDictionary *LULocalDiagnostic(BOOL allowPlatformSSO) {
    if (!NSThread.isMainThread) return @{@"error": @"main_thread_required"};
    NSString *why = nil;
    LUUnlockTarget *target = LUCaptureTarget(allowPlatformSSO, &why);
    LULockState lock = LUCurrentLockState();
    NSMutableDictionary *diagnostic = [@{@"lock_state": lock == LULockStateLocked ? @"locked" : (lock == LULockStateUnlocked ? @"unlocked" : @"unknown"),
             @"secure_input": @(IsSecureEventInputEnabled()),
             @"caps_lock": @((CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & kCGEventFlagMaskAlphaShift) != 0),
             @"post_events_allowed": @(CGPreflightPostEventAccess()), @"accessibility_allowed": @(AXIsProcessTrusted()),
             @"target_ready": @(target != nil),
             @"target_kind": target.kind == LUTargetClassic ? @"classic-loginwindow" : (target.kind == LUTargetPlatformSSO ? @"platform-sso" : @"none"),
             @"reason": why ?: @"目标窗口已验证。"} mutableCopy];
    if (target) diagnostic[@"target_focus"] = LUFocusDiagnostic(target);
    return diagnostic;
}
