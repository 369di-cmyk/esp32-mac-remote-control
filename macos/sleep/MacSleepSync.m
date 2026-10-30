#import <Cocoa/Cocoa.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

@interface SleepSyncDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *detail;
@property NSStatusItem *item;
@property NSURL *cloud;
@property BOOL scoped;
@property NSTimer *timer;
@end
@implementation SleepSyncDelegate
- (NSString *)cloudPath { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/MacSleepControl"]; }
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.item=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.title=@"☾";
    self.item.button.toolTip=@"Mac 睡眠同步";
    NSMenu *menu=[NSMenu new];
    [menu addItemWithTitle:@"Mac 睡眠同步" action:NULL keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings=[menu addItemWithTitle:@"查看状态 / 连接文件夹…" action:@selector(showSettings:) keyEquivalent:@""]; settings.target=self;
    NSMenuItem *now=[menu addItemWithTitle:@"立即同步" action:@selector(syncNow:) keyEquivalent:@""]; now.target=self;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit=[menu addItemWithTitle:@"退出同步" action:@selector(quitApp:) keyEquivalent:@""]; quit.target=self;
    self.item.menu=menu;
    [self buildWindow];
    NSData *data=[[NSUserDefaults standardUserDefaults] dataForKey:@"DedicatedSyncFolderBookmark"];
    if(data){
        BOOL stale=NO; NSError *error=nil;
        NSURL *url=[NSURL URLByResolvingBookmarkData:data options:NSURLBookmarkResolutionWithSecurityScope|NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
        if(url && [url.URLByStandardizingPath.path isEqualToString:self.cloudPath]){
            self.cloud=url;self.scoped=[url startAccessingSecurityScopedResource];
            if(stale)[self saveBookmark:url error:nil];
            [self syncNow:nil];
        } else { [self showSettings:nil]; }
    } else { [self showSettings:nil]; }
    self.timer=[NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(syncNow:) userInfo:nil repeats:YES];
    self.timer.tolerance=1;
}
- (void)buildWindow {
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,540,285) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Mac 睡眠同步";self.window.releasedWhenClosed=NO;
    NSTextField *title=[NSTextField labelWithString:@"连接手机上的睡眠快捷指令"];
    title.font=[NSFont boldSystemFontOfSize:21]; title.frame=NSMakeRect(24,225,490,32);
    NSTextField *info=[NSTextField wrappingLabelWithString:@"支持 20/30/50/60 分钟、2/3/4/5 小时及远程睡眠、在线查询。\n请选择 iCloud 云盘 → Shortcuts → MacSleepControl。\n此应用只需要这个专用文件夹，不需要完全磁盘访问权限。"];
    info.frame=NSMakeRect(24,130,490,82);
    self.detail=[NSTextField wrappingLabelWithString:@"尚未连接。点击下方按钮选择同步文件夹。"];
    self.detail.frame=NSMakeRect(24,65,490,58);
    NSButton *connect=[NSButton buttonWithTitle:@"连接专用 iCloud 文件夹…" target:self action:@selector(connect:)];connect.frame=NSMakeRect(24,20,245,32);
    NSButton *hide=[NSButton buttonWithTitle:@"完成并在后台运行" target:self action:@selector(hideWindow:)];hide.frame=NSMakeRect(290,20,225,32);
    for(NSView *v in @[title,info,self.detail,connect,hide])[self.window.contentView addSubview:v];
    [self.window center];
}
- (void)showSettings:(id)sender { [NSApp activateIgnoringOtherApps:YES];[self.window makeKeyAndOrderFront:nil]; }
- (void)hideWindow:(id)sender { [self.window orderOut:nil]; }
- (void)quitApp:(id)sender { [NSApp terminate:nil]; }
- (BOOL)saveBookmark:(NSURL *)url error:(NSError **)error {
    NSData *data=[url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:error];
    if(!data)return NO;
    [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"DedicatedSyncFolderBookmark"];return YES;
}
- (void)connect:(id)sender {
    NSOpenPanel *p=[NSOpenPanel openPanel];
    p.title=@"选择 MacSleepControl 专用文件夹";p.message=@"仅授予此睡眠同步文件夹的访问权限。";p.prompt=@"连接此文件夹";
    p.canChooseDirectories=YES;p.canChooseFiles=NO;p.allowsMultipleSelection=NO;p.canCreateDirectories=NO;
    p.directoryURL=[NSURL fileURLWithPath:self.cloudPath isDirectory:YES];
    if([p runModal]!=NSModalResponseOK)return;
    NSURL *url=p.URL;
    if(![url.URLByStandardizingPath.path isEqualToString:self.cloudPath]){self.detail.stringValue=@"请选择 iCloud 云盘 / Shortcuts / MacSleepControl 文件夹。";return;}
    NSError *error=nil;
    if(![self saveBookmark:url error:&error]){self.detail.stringValue=[@"连接失败：" stringByAppendingString:error.localizedDescription];return;}
    if(self.scoped)[self.cloud stopAccessingSecurityScopedResource];
    self.cloud=url;self.scoped=[url startAccessingSecurityScopedResource];[self syncNow:nil];
}
- (NSData *)readSmall:(NSURL *)url limit:(NSUInteger)limit error:(NSError **)error {
    int fd=open(url.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);
    if(fd<0)return nil;
    struct stat st;
    if(fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_size<0 || (uint64_t)st.st_size>limit){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:limit+1];
    ssize_t count=read(fd,data.mutableBytes,limit+1);close(fd);
    if(count<0 || (NSUInteger)count>limit)return nil;
    data.length=(NSUInteger)count;return data;
}
- (BOOL)replace:(NSData *)data at:(NSURL *)url error:(NSError **)error {
    NSData *old=[self readSmall:url limit:4096 error:nil];
    if([data isEqualToData:old])return YES;
    return [data writeToURL:url options:NSDataWritingAtomic error:error];
}
- (void)syncNow:(id)sender {
    if(!self.cloud)return;
    NSError *error=nil;
    NSURL *local=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MacSleepControl"] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:local withIntermediateDirectories:YES attributes:nil error:&error];
    NSURL *online=[self.cloud URLByAppendingPathComponent:@"online.txt"];
    if(![[NSFileManager defaultManager] fileExistsAtPath:online.path])
        [self replace:[@"尚未收到本次查询回复。" dataUsingEncoding:NSUTF8StringEncoding] at:online error:nil];
    NSURL *ping=[self.cloud URLByAppendingPathComponent:@"ping.txt"];
    NSData *pingData=[self readSmall:ping limit:256 error:nil];
    NSString *pingText=[[NSString alloc] initWithData:pingData encoding:NSUTF8StringEncoding];
    NSRegularExpression *pingPattern=[NSRegularExpression regularExpressionWithPattern:@"\\A[0-9]{9}\\|[0-9T:+Z-]{20,25}\\s*\\z" options:0 error:nil];
    if(pingText && [pingPattern numberOfMatchesInString:pingText options:0 range:NSMakeRange(0,pingText.length)]==1){
        NSArray *parts=[[pingText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"|"];
        NSDate *issued=[[NSISO8601DateFormatter new] dateFromString:parts[1]];
        NSTimeInterval age=issued ? -issued.timeIntervalSinceNow : 9999;
        NSString *previous=[[NSUserDefaults standardUserDefaults] stringForKey:@"LastOnlineChallenge"];
        if(age>=-30 && age<=120 && ![previous isEqualToString:pingText]){
            NSString *answer=[NSString stringWithFormat:@"Mac 已回应本次查询。\n请求码：%@\n回应时间：%@\n这表示回应时 Mac 接收程序正在运行；不保证屏幕已亮或远程桌面可用。",parts[0],[[NSISO8601DateFormatter new] stringFromDate:NSDate.date]];
            if([self replace:[answer dataUsingEncoding:NSUTF8StringEncoding] at:[self.cloud URLByAppendingPathComponent:@"online.txt"] error:&error])
                [[NSUserDefaults standardUserDefaults] setObject:pingText forKey:@"LastOnlineChallenge"];
        }
    }
    NSURL *request=[self.cloud URLByAppendingPathComponent:@"request.txt"];
    if([[NSFileManager defaultManager] fileExistsAtPath:request.path]){
        NSData *data=[self readSmall:request limit:256 error:&error];
        if(!data){[self showError:error];return;}
        NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"\\A(?:(20|30|50|60|120|180|240|300)\\|[0-9]{9}|sleep\\|[0-9]{9}\\|[0-9T:+Z-]{20,25})\\s*\\z" options:0 error:nil];
        if(text && [regex numberOfMatchesInString:text options:0 range:NSMakeRange(0,text.length)]==1){
            if(![self replace:data at:[local URLByAppendingPathComponent:@"request.txt"] error:&error]){[self showError:error];return;}
        }
    }
    NSURL *status=[NSURL fileURLWithPath:@"/var/db/io.github.esp32macremote.sleep/status.txt"];
    if([[NSFileManager defaultManager] fileExistsAtPath:status.path]){
        NSData *data=[self readSmall:status limit:4096 error:&error];
        if(!data || ![self replace:data at:[self.cloud URLByAppendingPathComponent:@"status.txt"] error:&error]){[self showError:error];return;}
        NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *first=[[text componentsSeparatedByString:@"\n"] firstObject]?:@"回执已同步。";
        self.detail.stringValue=[NSString stringWithFormat:@"已连接，每 5 秒同步一次。\n%@\n最近检查：%@",first,[NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];
    } else self.detail.stringValue=@"已连接。等待第一条执行回执，每 5 秒同步一次。";
    self.item.button.toolTip=@"Mac 睡眠同步：已连接";
}
- (void)showError:(NSError *)error {
    self.detail.stringValue=[NSString stringWithFormat:@"同步失败：%@\n请重新连接专用文件夹。",error.localizedDescription?:@"无法读取文件。"];
    self.item.button.toolTip=@"Mac 睡眠同步：需要检查权限";
}
- (void)applicationWillTerminate:(NSNotification *)note { if(self.scoped)[self.cloud stopAccessingSecurityScopedResource]; }
@end
int main(int argc,const char *argv[]){ @autoreleasepool {NSApplication *app=NSApplication.sharedApplication;SleepSyncDelegate *delegate=[SleepSyncDelegate new];app.delegate=delegate;[app run];}return 0; }
