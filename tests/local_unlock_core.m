#import "../macos/unlock/LocalUnlock.h"
#import <assert.h>

int main(void) { @autoreleasepool {
    NSDictionary *session = @{(__bridge NSString *)kCGSessionUserIDKey:@501,
                              (__bridge NSString *)kCGSessionOnConsoleKey:@YES,
                              (__bridge NSString *)kCGSessionLoginDoneKey:@YES};
    assert(LUEvaluateLockState(session,@YES,501)==LULockStateLocked);
    assert(LUEvaluateLockState(session,@NO,501)==LULockStateUnlocked);
    assert(LUEvaluateLockState(session,nil,501)==LULockStateUnknown);
    assert(LUEvaluateLockState(session,@YES,502)==LULockStateUnknown);
    assert(LUEvaluateLockState(nil,@YES,501)==LULockStateUnknown);
    for (NSString *key in session) { NSMutableDictionary *missing=[session mutableCopy];[missing removeObjectForKey:key];assert(LUEvaluateLockState(missing,@YES,501)==LULockStateUnknown); }
    NSMutableDictionary *legacy=[session mutableCopy];legacy[@"CGSSessionScreenIsLocked"]=@YES;
    assert(LUEvaluateLockState(legacy,nil,501)==LULockStateLocked);
    assert(LUEvaluateLockState(legacy,@NO,501)==LULockStateUnknown);
    legacy[@"CGSSessionScreenIsLocked"]=@NO;
    assert(LUEvaluateLockState(legacy,@YES,501)==LULockStateUnknown);
    assert(LUKindForIdentity(@"com.apple.loginwindow",LUExecutablePath(LUTargetClassic))==LUTargetClassic);
    assert(LUKindForIdentity(@"com.apple.loginwindow",@"/tmp/loginwindow")==LUTargetUnknown);
    assert(LUKindForIdentity(@"lookalike",LUExecutablePath(LUTargetClassic))==LUTargetUnknown);
    assert(LUKindForIdentity(LUBundleIdentifier(LUTargetPlatformSSO),LUExecutablePath(LUTargetPlatformSSO))==LUTargetPlatformSSO);
    assert(LUIsSecureTextRole(@"AXTextField",@"AXSecureTextField"));
    assert(!LUIsSecureTextRole(@"AXTextField",@"AXSearchTextField"));
    assert(!LUIsSecureTextRole(@"AXWebArea",@"AXSecureTextField"));
    assert(LURoleIdentifier(@"AXWindow")!=nil);
    assert(LURoleIdentifier(@"secret-field-content") == nil);
    NSString *sample=[[@"x" stringByPaddingToLength:19 withString:@"x" startingAtIndex:0] stringByAppendingString:@"😀Z"];
    NSArray<NSData *> *chunks=LUUnicodeChunks(sample);
    assert(chunks.count==2 && chunks[0].length==38 && chunks[1].length==6);
    NSMutableData *joined=[NSMutableData new];for(NSData *c in chunks)[joined appendData:c];
    assert([[[NSString alloc]initWithCharacters:joined.bytes length:joined.length/2] isEqualToString:sample]);
    NSString *why=nil;
    NSArray<LUEventPair *> *pairs=LUBuildUnlockEventPairs(sample,2,&why);
    assert(pairs.count==5 && !pairs[0].submits && pairs.lastObject.submits);
    assert(CGEventGetIntegerValueField((__bridge CGEventRef)pairs[0].down,kCGKeyboardEventKeycode)==0x33);
    assert(CGEventGetIntegerValueField((__bridge CGEventRef)pairs.lastObject.down,kCGKeyboardEventKeycode)==0x24);
    for(LUEventPair *p in pairs) { assert(CGEventGetFlags((__bridge CGEventRef)p.down)==0); assert(CGEventGetFlags((__bridge CGEventRef)p.up)==0); }
    assert(!LUBuildUnlockEventPairs(@"",0,&why));
    assert(!LUBuildUnlockEventPairs(@"sample",257,&why));
    __block int posts=0, gates=0;
    void(^post)(pid_t,CGEventRef)=^(pid_t pid,CGEventRef e){ assert(pid==123);assert(e);posts++;};
    assert(!LUDeliverPairWithGate(pairs[0],123,^BOOL{gates++;return NO;},post));
    assert(posts==0 && gates==1);
    __block BOOL allow=YES;
    assert(LUDeliverPairWithGate(pairs.lastObject,123,^BOOL{gates++;return allow;},^(pid_t pid,CGEventRef e){assert(pid==123);assert(e);posts++;allow=NO;}));
    assert(posts==2 && gates==2); // Release still sent after submission changes eligibility.
    assert(!LULocalGuard(nil,NSProcessInfo.processInfo.systemUptime-1,nil,&why));
    assert([why containsString:@"超时"]);
    assert(!LULocalGuard(nil,NSProcessInfo.processInfo.systemUptime+1,^BOOL{return NO;},&why));
    assert([why containsString:@"取消"]);
    puts("PASS: local unlock policy, identity allowlist, Unicode boundaries, event pairs, cancellation and mock delivery. No real input, Keychain, BLE or AX queries performed.");
    return 0;
} }
