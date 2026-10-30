#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <sys/file.h>
#import <unistd.h>
#import "LocalUnlock.h"

static NSString *Service=@"io.github.esp32macremote.unlock.password";
static NSString *Base(void){return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ESP32MacRemoteUnlock"];}
static NSString *Now(void){return [[NSISO8601DateFormatter new]stringFromDate:NSDate.date];}
static NSData *ReadSmall(NSString *path,NSUInteger max){
 int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);if(fd<0)return nil;
 struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<0||st.st_size>max){close(fd);return nil;}
 NSMutableData *data=[NSMutableData dataWithLength:max+1];ssize_t n=read(fd,data.mutableBytes,max+1);close(fd);if(n<0||n>max)return nil;data.length=n;return data;
}
static BOOL Equal(NSString*a,NSString*b){NSData*x=[a dataUsingEncoding:NSUTF8StringEncoding],*y=[b dataUsingEncoding:NSUTF8StringEncoding];if(!x||x.length!=y.length||x.length<32)return NO;const uint8_t*p=x.bytes,*q=y.bytes;uint8_t d=0;for(NSUInteger i=0;i<x.length;i++)d|=p[i]^q[i];return d==0;}
static NSMutableDictionary *KC(void){return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:Service,(__bridge id)kSecAttrAccount:NSUserName()} mutableCopy];}
static void NonInteractive(NSMutableDictionary*q){
 // Fail instead of showing a hidden authorization dialog during a locked request.
 LAContext*ctx=[LAContext new];ctx.interactionNotAllowed=YES;q[(__bridge id)kSecUseAuthenticationContext]=ctx;
 q[(__bridge id)kSecUseAuthenticationUI]=(__bridge id)kSecUseAuthenticationUIFail;
}
static NSData *Password(BOOL interactive){NSMutableDictionary*q=KC();q[(__bridge id)kSecReturnData]=@YES;if(!interactive)NonInteractive(q);CFTypeRef result=NULL;OSStatus rc=SecItemCopyMatching((__bridge CFDictionaryRef)q,&result);return rc==errSecSuccess?CFBridgingRelease(result):nil;}
static BOOL PasswordPresent(void){NSMutableDictionary*q=KC();q[(__bridge id)kSecReturnAttributes]=@YES;NonInteractive(q);CFTypeRef result=NULL;OSStatus rc=SecItemCopyMatching((__bridge CFDictionaryRef)q,&result);if(result)CFRelease(result);return rc==errSecSuccess;}
static OSStatus SavePassword(NSData*d){NSMutableDictionary*q=KC();OSStatus rc=SecItemUpdate((__bridge CFDictionaryRef)q,(__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:d});if(rc==errSecItemNotFound){q[(__bridge id)kSecValueData]=d;q[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;rc=SecItemAdd((__bridge CFDictionaryRef)q,NULL);}return rc;}
static BOOL ValidPassword(NSString*p){if(!p.length||p.length>64)return NO;for(NSUInteger i=0;i<p.length;i++){unichar c=[p characterAtIndex:i];if(c<32||c>126)return NO;}return YES;}
static void Trace(NSString*phase){NSString*p=[Base() stringByAppendingPathComponent:@"local-unlock-state.log"];NSString*old=[NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil]?:@"";if(old.length>12000)old=[old substringFromIndex:old.length-12000];[[old stringByAppendingFormat:@"%@ %@\n",Now(),phase]writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];chmod(p.fileSystemRepresentation,0600);}
static void WriteJSON(NSString*name,NSDictionary*d){NSString*p=[Base()stringByAppendingPathComponent:name];[[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil]writeToFile:p atomically:YES];chmod(p.fileSystemRepresentation,0600);}

@interface UnlockApp:NSObject<NSApplicationDelegate>
@property NSWindow*window;@property NSTextField*status;@property NSSecureTextField*password;@property NSSecureTextField*confirm;@property NSButton*sso;
@property NSStatusItem*item;@property NSString*requestToken;@property NSURL*cloud;@property BOOL scoped;@property BOOL busy;@property (atomic) BOOL cancelled;@property (atomic) BOOL sleeping;@property double deadline;@property NSDate*issued;
@end
@implementation UnlockApp
- (void)applicationDidFinishLaunching:(NSNotification*)n{
 [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
 NSArray*args=NSProcessInfo.processInfo.arguments;
 if([args containsObject:@"--diagnostic"]){NSMutableDictionary*d=[LULocalDiagnostic(YES) mutableCopy];d[@"timestamp"]=Now();d[@"run_id"]=NSUUID.UUID.UUIDString;d[@"mode"]=@"read_only_no_credentials_no_input";WriteJSON(@"local-diagnostic.json",d);[NSApp terminate:nil];return;}
 NSData*d=ReadSmall([Base()stringByAppendingPathComponent:@"config.json"],2048);NSDictionary*c=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;self.requestToken=[c isKindOfClass:NSDictionary.class]&&[c[@"request_token"] isKindOfClass:NSString.class]?c[@"request_token"]:nil;
 self.item=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];self.item.button.title=@"⌑";self.item.button.toolTip=@"Mac 唤醒并解锁";
 NSMenu*m=[NSMenu new];for(NSArray*a in @[@[@"设置 / 本地填写密码",NSStringFromSelector(@selector(show:))],@[@"暂停并取消本次解锁",NSStringFromSelector(@selector(pause:))],@[@"退出",NSStringFromSelector(@selector(quit:))]]){NSMenuItem*i=[m addItemWithTitle:a[0] action:NSSelectorFromString(a[1]) keyEquivalent:@""];i.target=self;}self.item.menu=m;
 [self build];NSData*b=[NSUserDefaults.standardUserDefaults dataForKey:@"CloudBookmark"];if(b){BOOL stale=NO;NSURL*u=[NSURL URLByResolvingBookmarkData:b options:NSURLBookmarkResolutionWithSecurityScope|NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&stale error:nil];if([u.path isEqualToString:[self cloudPath]]){self.cloud=u;self.scoped=[u startAccessingSecurityScopedResource];}}
 NSNotificationCenter*nc=NSWorkspace.sharedWorkspace.notificationCenter;
 [nc addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];[nc addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
 [NSUserDefaults.standardUserDefaults setBool:PasswordPresent() forKey:@"KeychainReady"];
 if([args containsObject:@"--enable"])[self enable:nil];
 [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
 [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer*t){NSMutableDictionary*d=[LULocalDiagnostic(YES)mutableCopy];d[@"timestamp"]=Now();d[@"enabled"]=@([NSUserDefaults.standardUserDefaults boolForKey:@"Enabled"]);d[@"busy"]=@(self.busy);d[@"keychain_item_present"]=@([NSUserDefaults.standardUserDefaults boolForKey:@"KeychainReady"]);WriteJSON(@"local-state.json",d);}];
 if(![args containsObject:@"--background"])[self show:nil];Trace(@"helper_started_local_only");
}
- (NSString*)cloudPath{return [NSHomeDirectory()stringByAppendingPathComponent:@"Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/MacSleepControl"];}
- (void)build{
 self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,640,485) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];self.window.title=@"Mac 唤醒并解锁 — 本地设置";self.window.releasedWhenClosed=NO;
 NSTextField*t=[NSTextField wrappingLabelWithString:@"ESP32 只负责蓝牙唤醒，密码只保存在本机钥匙串。\nMac 检查锁屏和系统登录进程，再在本机定向输入；网络设置不变。\n基于 BLEUnlock 的 macOS 27 修复分支，仅处理一次性请求。"];
 t.frame=NSMakeRect(22,382,596,76);[self.window.contentView addSubview:t];
 for(int i=0;i<2;i++){NSTextField*l=[NSTextField labelWithString:i?@"再输入一次":@"Mac 登录密码"];l.frame=NSMakeRect(22,343-i*39,120,24);[self.window.contentView addSubview:l];NSSecureTextField*f=[[NSSecureTextField alloc]initWithFrame:NSMakeRect(150,341-i*39,465,28)];f.placeholderString=@"已有密码可直接启用，无需重复填写";[self.window.contentView addSubview:f];if(i)self.confirm=f;else self.password=f;}
 NSArray*buttons=@[@[@"授权辅助功能",NSStringFromSelector(@selector(permission:))],@[@"连接 iCloud 文件夹",NSStringFromSelector(@selector(connect:))],@[@"启用已保存密码",NSStringFromSelector(@selector(enable:))],@[@"保存密码并启用",NSStringFromSelector(@selector(save:))],@[@"删除密码并停用",NSStringFromSelector(@selector(remove:))],@[@"检查状态（不输入）",NSStringFromSelector(@selector(check:))]];
 for(int i=0;i<6;i++){NSButton*b=[NSButton buttonWithTitle:buttons[i][0] target:self action:NSSelectorFromString(buttons[i][1])];b.frame=NSMakeRect(17+(i%3)*207,247-(i/3)*41,204,32);[self.window.contentView addSubview:b];}
 self.sso=[NSButton checkboxWithTitle:@"兼容新版系统密码界面（仅本人 Mac 登录密码）" target:self action:@selector(ssoChanged:)];self.sso.frame=NSMakeRect(22,171,596,25);self.sso.state=[NSUserDefaults.standardUserDefaults boolForKey:@"AllowPlatformSSO"]?NSControlStateValueOn:NSControlStateValueOff;[self.window.contentView addSubview:self.sso];
 self.status=[NSTextField wrappingLabelWithString:@"先授权辅助功能，再启用已保存密码。\n密码支持 1–64 个英文、数字及英文半角符号。"];
 if([NSUserDefaults.standardUserDefaults boolForKey:@"Enabled"])self.status.stringValue=@"已启用；密码仅在本机使用。错误时只尝试一次。";
 self.status.frame=NSMakeRect(22,62,596,100);[self.window.contentView addSubview:self.status];NSButton*b=[NSButton buttonWithTitle:@"完成，在后台运行" target:self action:@selector(hide:)];b.frame=NSMakeRect(382,18,233,32);[self.window.contentView addSubview:b];[self.window center];
}
- (void)show:(id)x{[NSApp activateIgnoringOtherApps:YES];[self.window makeKeyAndOrderFront:nil];}
- (void)hide:(id)x{[self.window orderOut:nil];}
- (void)pause:(id)x{self.cancelled=YES;[NSUserDefaults.standardUserDefaults setBool:NO forKey:@"Enabled"];self.status.stringValue=@"已暂停；不会继续输入密码。";Trace(@"paused");}
- (void)quit:(id)x{[self pause:nil];[NSApp terminate:nil];}
- (void)willSleep:(NSNotification*)n{self.sleeping=YES;self.cancelled=YES;Trace(@"system_will_sleep_attempt_cancelled");}
- (void)didWake:(NSNotification*)n{self.sleeping=NO;Trace(@"system_did_wake");}
- (void)ssoChanged:(id)x{[NSUserDefaults.standardUserDefaults setBool:self.sso.state==NSControlStateValueOn forKey:@"AllowPlatformSSO"];self.cancelled=YES;}
- (void)permission:(id)x{AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt:@YES});CGRequestPostEventAccess();self.status.stringValue=@"请在系统设置中允许“Mac 唤醒并解锁”的辅助功能权限，然后点击“启用已保存密码”。";}
- (void)enable:(id)x{
 if(!AXIsProcessTrusted()||!CGPreflightPostEventAccess()){self.status.stringValue=@"尚未取得辅助功能／输入控制权限。请先在系统设置授权这个助手。";return;}
 if(!self.cloud||self.requestToken.length<32){self.status.stringValue=@"请先连接专用 iCloud 文件夹。";return;}
 NSData*stored=Password(YES);BOOL ready=stored.length>0;stored=nil;[NSUserDefaults.standardUserDefaults setBool:ready forKey:@"KeychainReady"];if(!ready){self.status.stringValue=@"新版暂时无法读取本机钥匙串密码，请在上方本地填写两遍并保存。";return;}
 [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"Enabled"];self.status.stringValue=@"已启用。密码仅在本机使用，等待手机的一次性请求。\n请在电脑旁完成真实锁屏和睡眠唤醒测试。";Trace(@"enabled");
}
- (void)remove:(id)x{[self pause:nil];SecItemDelete((__bridge CFDictionaryRef)KC());self.password.stringValue=@"";self.confirm.stringValue=@"";[NSUserDefaults.standardUserDefaults setBool:NO forKey:@"KeychainReady"];self.status.stringValue=@"已删除本机保存的密码并停用。";}
- (void)save:(id)x{NSString*p=self.password.stringValue;if(!ValidPassword(p)||![p isEqualToString:self.confirm.stringValue]){self.status.stringValue=@"请填写两次一致的密码，支持 1–64 个英文、数字及英文半角符号。";return;}OSStatus rc=SavePassword([p dataUsingEncoding:NSUTF8StringEncoding]);self.password.stringValue=@"";self.confirm.stringValue=@"";if(rc!=errSecSuccess){self.status.stringValue=@"本机钥匙串保存失败，未启用。";return;}[NSUserDefaults.standardUserDefaults setBool:YES forKey:@"KeychainReady"];[self enable:nil];}
- (void)connect:(id)x{NSOpenPanel*p=NSOpenPanel.openPanel;p.canChooseDirectories=YES;p.canChooseFiles=NO;p.allowsMultipleSelection=NO;p.directoryURL=[NSURL fileURLWithPath:[self cloudPath]];p.message=@"请选择 iCloud 云盘 → Shortcuts → MacSleepControl。";if([p runModal]!=NSModalResponseOK)return;if(![p.URL.path isEqualToString:[self cloudPath]]){self.status.stringValue=@"请选择 MacSleepControl 专用文件夹。";return;}NSData*b=[p.URL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:nil];if(!b)return;[NSUserDefaults.standardUserDefaults setObject:b forKey:@"CloudBookmark"];if(self.scoped)[self.cloud stopAccessingSecurityScopedResource];self.cloud=p.URL;self.scoped=[self.cloud startAccessingSecurityScopedResource];self.status.stringValue=@"文件夹已连接。可以启用已保存密码。";}
- (void)check:(id)x{NSMutableDictionary*d=[LULocalDiagnostic(YES)mutableCopy];d[@"timestamp"]=Now();d[@"mode"]=@"read_only_no_credentials_no_input";WriteJSON(@"local-diagnostic.json",d);self.status.stringValue=[NSString stringWithFormat:@"辅助功能：%@；输入权限：%@；保存的密码记录：%@。\n已记录本次状态，没有读取或输入密码。",AXIsProcessTrusted()?@"已授权":@"未授权",CGPreflightPostEventAccess()?@"已授权":@"未授权",PasswordPresent()?@"存在":@"未找到"];}
- (BOOL)allowed{return !self.cancelled&&!self.sleeping&&[NSUserDefaults.standardUserDefaults boolForKey:@"Enabled"]&&NSProcessInfo.processInfo.systemUptime<self.deadline&&self.issued&&-self.issued.timeIntervalSinceNow<=90;}
- (void)receipt:(NSString*)ident message:(NSString*)message{NSString*s=[NSString stringWithFormat:@"请求码：%@\n%@\n时间：%@",ident,message,Now()];[s writeToURL:[self.cloud URLByAppendingPathComponent:@"unlock-result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];dispatch_async(dispatch_get_main_queue(),^{self.status.stringValue=message;});}
- (void)attempt:(NSString*)ident{
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
 __block NSString*why=nil;__block LUUnlockTarget*target=nil;__block BOOL ok=NO;double readyBy=NSProcessInfo.processInfo.systemUptime+5;
 Trace(@"request_accepted_waiting_for_system_target");
 do{dispatch_sync(dispatch_get_main_queue(),^{if(![self allowed]){why=@"本次请求已取消或过期，未输入。";return;}if(LUCurrentLockState()!=LULockStateLocked){why=@"未确认当前用户处于锁屏状态，已停止。";return;}target=LUCaptureTarget([NSUserDefaults.standardUserDefaults boolForKey:@"AllowPlatformSSO"],&why);ok=target&&LULocalGuard(target,self.deadline,^BOOL{return [self allowed];},&why);});if(ok)break;if(![self allowed])break;[NSThread sleepForTimeInterval:0.2];}while(NSProcessInfo.processInfo.systemUptime<readyBy);
 NSData*pd=ok?Password(NO):nil;NSString*pw=pd?[[NSString alloc]initWithData:pd encoding:NSUTF8StringEncoding]:nil;
 if(ok&&!ValidPassword(pw)){ok=NO;why=@"钥匙串密码不可用或字符不支持，未输入。请在 Mac 本地重新保存。";}
 __block NSArray*pairs=nil;
 if(ok)dispatch_sync(dispatch_get_main_queue(),^{if(LULocalGuard(target,self.deadline,^BOOL{return [self allowed];},&why))pairs=LUBuildUnlockEventPairs(pw,64,&why);else ok=NO;});
 pw=nil;pd=nil;if(ok&&!pairs.count)ok=NO;
 if(ok){Trace(@"directed_input_started");for(id pair in pairs){dispatch_sync(dispatch_get_main_queue(),^{ok=LUDeliverEventPair(pair,target,self.deadline,^BOOL{return [self allowed];},&why);});if(!ok)break;[NSThread sleepForTimeInterval:0.012];}}
 pairs=nil;target=nil;
 BOOL confirmed=NO;
 if(ok){Trace(@"password_submitted_waiting_for_unlock");for(int i=0;i<50;i++){__block LULockState state;dispatch_sync(dispatch_get_main_queue(),^{state=LUCurrentLockState();});if(state==LULockStateUnlocked){confirmed=YES;break;}if(self.sleeping)break;[NSThread sleepForTimeInterval:0.2];}why=confirmed?@"Mac 已退出锁屏，本次解锁成功。":@"已提交密码，但未确认解锁成功；不会自动重试。";}
 Trace(confirmed?@"unlock_confirmed":ok?@"unlock_unconfirmed":@"attempt_stopped");
 WriteJSON(@"local-attempt-result.json",@{@"timestamp":Now(),@"request_id":ident,@"submitted":@(ok),@"unlocked_confirmed":@(confirmed),@"message":why?:@"本次解锁停止，未自动重试。"});
 [self receipt:ident message:why?:@"本次解锁停止，未自动重试。"];dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;});
 }});
}
- (void)tick:(id)x{
 if(!self.cloud||self.busy||self.sleeping)return;NSData*d=ReadSmall([[self.cloud URLByAppendingPathComponent:@"unlock-request.txt"]path],1024);NSString*s=d?[[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding]:nil;if(!s)return;
 NSArray*p=[[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]componentsSeparatedByString:@"|"];if(p.count!=3||!Equal(p[2],self.requestToken))return;
 NSString*ident=p[0];if(ident.length!=9||[ident rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"]invertedSet]].location!=NSNotFound)return;
 NSDate*issued=[[NSISO8601DateFormatter new]dateFromString:p[1]];if(!issued)return;NSString*signature=[NSString stringWithFormat:@"%@|%@",p[0],p[1]];
 NSMutableArray*seen=[[NSUserDefaults.standardUserDefaults arrayForKey:@"Seen"]mutableCopy]?:[NSMutableArray new];if([seen containsObject:signature])return;[seen addObject:signature];while(seen.count>256)[seen removeObjectAtIndex:0];[NSUserDefaults.standardUserDefaults setObject:seen forKey:@"Seen"];[NSUserDefaults.standardUserDefaults synchronize];
 double age=-issued.timeIntervalSinceNow;if(age < -5 || age>90){[self receipt:ident message:@"请求已过期或时间不正确，未输入密码。请重新运行快捷指令。"];return;}
 if(![NSUserDefaults.standardUserDefaults boolForKey:@"Enabled"]){[self receipt:ident message:@"本机助手尚未启用，未输入密码。"];return;}
 double last=[NSUserDefaults.standardUserDefaults doubleForKey:@"LastAttempt"];if(NSDate.date.timeIntervalSince1970-last<60){[self receipt:ident message:@"距离上次尝试不足 60 秒，未重复输入。"];return;}
 [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:@"LastAttempt"];self.busy=YES;self.cancelled=NO;self.issued=issued;self.deadline=NSProcessInfo.processInfo.systemUptime+20;[self attempt:ident];
}
@end
static int Tests(void){@autoreleasepool{NSCAssert(ValidPassword(@"A b9!"),@"supported");NSCAssert(!ValidPassword(@"\n")&&!ValidPassword(@"")&&!ValidPassword(@"中文"),@"unsupported");NSCAssert(Equal(@"0123456789012345678901234567890123",@"0123456789012345678901234567890123"),@"token match");NSCAssert(!Equal(@"0123456789012345678901234567890123",@"0123456789012345678901234567890124"),@"token mismatch");puts("PASS: credential validation and request-token comparison");return 0;}}
int main(int argc,const char*argv[]){@autoreleasepool{if(argc>1&&!strcmp(argv[1],"--self-test"))return Tests();if(argc>1&&!strcmp(argv[1],"--state")){puts([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:LULocalDiagnostic(YES) options:0 error:nil]encoding:NSUTF8StringEncoding].UTF8String);return 0;}[[NSFileManager defaultManager]createDirectoryAtPath:Base() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
static int instanceFD=-1;instanceFD=open([[Base()stringByAppendingPathComponent:@"helper.lock"]fileSystemRepresentation],O_CREAT|O_RDWR|O_NOFOLLOW,0600);
if(instanceFD<0||flock(instanceFD,LOCK_EX|LOCK_NB)!=0)return 0;
NSApplication*a=NSApplication.sharedApplication;UnlockApp*d=[UnlockApp new];a.delegate=d;[a run];}return 0;}
