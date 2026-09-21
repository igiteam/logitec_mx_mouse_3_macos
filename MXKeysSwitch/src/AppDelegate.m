#import "AppDelegate.h"
#import "MXKeysManager.h"
#import <Carbon/Carbon.h>

// Hotkey: Cmd + Shift + F12
#define HOTKEY_KEYCODE  kVK_F12
#define HOTKEY_MODS     (cmdKey | shiftKey)
#define HOTKEY_ID       1
#define HOTKEY_SIG      'WnKl'

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) MXKeysManager *keysManager;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, strong) NSMenuItem *deviceMenuItem;
@property (nonatomic, strong) NSMenuItem *batteryMenuItem;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) EventHotKeyRef hotKeyRef;
@property (nonatomic, assign) EventHandlerRef hotKeyHandlerRef;
@end

static OSStatus WineHotKeyHandler(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData);

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.keysManager = [[MXKeysManager alloc] init];
    self.isActive = NO;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"⌨️ --%";

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateDisplay)
                                                 name:@"DeviceUpdated"
                                               object:nil];

    NSMenu *menu = [[NSMenu alloc] init];

    self.toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@"Start Host Switching"
                                                      action:@selector(toggleFlow:)
                                               keyEquivalent:@"s"];
    self.toggleMenuItem.target = self;
    [menu addItem:self.toggleMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    self.deviceMenuItem = [[NSMenuItem alloc] initWithTitle:@"Device: Not connected"
                                                      action:nil
                                               keyEquivalent:@""];
    [menu addItem:self.deviceMenuItem];

    self.batteryMenuItem = [[NSMenuItem alloc] initWithTitle:@"Battery: --"
                                                       action:nil
                                                keyEquivalent:@""];
    [menu addItem:self.batteryMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *switchTitle = [[NSMenuItem alloc] initWithTitle:@"── Switch Host ──"
                                                          action:nil
                                                   keyEquivalent:@""];
    [menu addItem:switchTitle];

    NSMenuItem *h1 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 1"
                                                action:@selector(switchToHost1:)
                                         keyEquivalent:@"1"];
    h1.target = self; [menu addItem:h1];

    NSMenuItem *h2 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 2"
                                                action:@selector(switchToHost2:)
                                         keyEquivalent:@"2"];
    h2.target = self; [menu addItem:h2];

    NSMenuItem *h3 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 3"
                                                action:@selector(switchToHost3:)
                                         keyEquivalent:@"3"];
    h3.target = self; [menu addItem:h3];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *killWine = [[NSMenuItem alloc] initWithTitle:@"Kill Wine Now  (⌘⇧F12)"
                                                       action:@selector(killWineProcesses)
                                                keyEquivalent:@""];
    killWine.target = self;
    [menu addItem:killWine];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                       action:@selector(quitApp:)
                                                keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;

    [self registerWineHotKey];

    [self performSelector:@selector(autoStart) withObject:nil afterDelay:0.5];
}

- (void)registerWineHotKey {
    EventTypeSpec eventType;
    eventType.eventClass = kEventClassKeyboard;
    eventType.eventKind  = kEventHotKeyPressed;

    InstallApplicationEventHandler(&WineHotKeyHandler,
                                   1,
                                   &eventType,
                                   (__bridge void *)self,
                                   &_hotKeyHandlerRef);

    EventHotKeyID hotKeyID;
    hotKeyID.signature = HOTKEY_SIG;
    hotKeyID.id        = HOTKEY_ID;

    OSStatus status = RegisterEventHotKey(HOTKEY_KEYCODE,
                                          HOTKEY_MODS,
                                          hotKeyID,
                                          GetApplicationEventTarget(),
                                          0,
                                          &_hotKeyRef);
    if (status == noErr) {
        printf("[MXKeys] ✅ Registered Cmd+Shift+F12 for Wine killer\n");
    } else {
        printf("[MXKeys] ⚠️ Hotkey registration failed (%d) — another app may own Cmd+Shift+F12\n", (int)status);
    }
    fflush(stdout);
}

- (void)autoStart {
    self.isActive = YES;
    [self.keysManager start];
    self.toggleMenuItem.title = @"Stop Host Switching";
    [self updateDisplay];
}

- (void)toggleFlow:(id)sender {
    self.isActive = !self.isActive;
    if (self.isActive) {
        [self.keysManager start];
        self.toggleMenuItem.title = @"Stop Host Switching";
    } else {
        [self.keysManager stop];
        self.toggleMenuItem.title = @"Start Host Switching";
    }
    [self updateDisplay];
}

- (void)switchToHost1:(id)sender { [self.keysManager switchToChannelDirect:0]; }
- (void)switchToHost2:(id)sender { [self.keysManager switchToChannelDirect:1]; }
- (void)switchToHost3:(id)sender { [self.keysManager switchToChannelDirect:2]; }

- (void)killWineProcesses {
    printf("[MXKeys] 🔪 Killing Wine processes...\n");
    fflush(stdout);

    NSString *username = NSUserName();
    NSString *cmd = [NSString stringWithFormat:
        @"pkill -9 -U %@ wineserver wine wine64 wine-preloader wine64-preloader 2>/dev/null; "
        @"pgrep -U %@ -f \".exe\" | xargs kill -9 2>/dev/null",
        username, username];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/bash";
    task.arguments = @[@"-c", cmd];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSFileHandle *fh = [pipe fileHandleForReading];

    [task launch];
    [task waitUntilExit];

    NSData *data = [fh readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (output.length > 0) {
        printf("[MXKeys] Kill output: %s\n", [output UTF8String]);
        fflush(stdout);
    }
    printf("[MXKeys] Wine kill exit status: %d\n", [task terminationStatus]);
    fflush(stdout);
}

- (void)updateDisplay {
    if (self.keysManager.deviceConnected) {
        NSString *b = self.keysManager.batteryLevelString ?: @"--%";
        self.statusItem.button.title = [NSString stringWithFormat:@"⌨️ %@", b];
        self.deviceMenuItem.title = [NSString stringWithFormat:@"Device: %@", self.keysManager.deviceName];
        self.batteryMenuItem.title = [NSString stringWithFormat:@"Battery: %@", b];
    } else {
        self.statusItem.button.title = @"⌨️ --%";
        self.deviceMenuItem.title = @"Device: Not connected";
        self.batteryMenuItem.title = @"Battery: --";
    }
    self.statusItem.button.alternateTitle = self.statusItem.button.title;
}

- (void)quitApp:(id)sender {
    if (self.hotKeyRef) { UnregisterEventHotKey(self.hotKeyRef); self.hotKeyRef = NULL; }
    if (self.hotKeyHandlerRef) { RemoveEventHandler(self.hotKeyHandlerRef); self.hotKeyHandlerRef = NULL; }
    [self.keysManager stop];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.hotKeyRef) UnregisterEventHotKey(self.hotKeyRef);
    if (self.hotKeyHandlerRef) RemoveEventHandler(self.hotKeyHandlerRef);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

static OSStatus WineHotKeyHandler(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData) {
    AppDelegate *self = (__bridge AppDelegate *)userData;
    if (!self) return noErr;

    EventHotKeyID hkID;
    GetEventParameter(theEvent, kEventParamDirectObject, typeEventHotKeyID,
                      NULL, sizeof(hkID), NULL, &hkID);

    if (hkID.signature == HOTKEY_SIG && hkID.id == HOTKEY_ID) {
        [self killWineProcesses];
    }
    return noErr;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
