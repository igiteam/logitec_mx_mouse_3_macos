#import "AppDelegate.h"
#import "MXKeysManager.h"
#import <Carbon/Carbon.h>

// Hotkey: Cmd + Shift + F12, watched via CGEventTap so it fires even
// when a game has focus (games can swallow Carbon RegisterEventHotKey).
#define WATCHED_KEYCODE  kVK_F12
#define WATCHED_MODS     (kCGEventFlagMaskCommand | kCGEventFlagMaskShift)

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) MXKeysManager *keysManager;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, strong) NSMenuItem *deviceMenuItem;
@property (nonatomic, strong) NSMenuItem *batteryMenuItem;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) CFMachPortRef eventTap;
@property (nonatomic, assign) CFRunLoopSourceRef eventTapSource;
@end

static CGEventRef EventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                    CGEventRef event, void *userInfo);

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

    [self installEventTap];

    [self performSelector:@selector(autoStart) withObject:nil afterDelay:0.5];
}

// ---------------------------------------------------------------
// CGEventTap — sees key events before the focused app does.
// Runs on the main run loop. If macOS disables it (e.g. because a
// tap callback took too long), kCGEventTapDisabledByTimeout fires
// and we just re-enable.
// ---------------------------------------------------------------
- (void)installEventTap {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);

    // kCGSessionEventTap sits above the app layer but below the window
    // server. For most games this is enough — the event is delivered to
    // us before the game's own keyboard handler can consume it.
    self.eventTap = CGEventTapCreate(kCGSessionEventTap,
                                     kCGHeadInsertEventTap,
                                     kCGEventTapOptionDefault,
                                     mask,
                                     EventTapCallback,
                                     (__bridge void *)self);

    if (!self.eventTap) {
        printf("[MXKeys] ⚠️ Could not create event tap — Accessibility permission missing.\n");
        printf("[MXKeys]    Open System Settings → Privacy & Security → Accessibility,\n");
        printf("[MXKeys]    and enable this app. Then relaunch.\n");
        fflush(stdout);
        return;
    }

    self.eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                         self.eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       self.eventTapSource,
                       kCFRunLoopCommonModes);
    CGEventTapEnable(self.eventTap, true);

    printf("[MXKeys] ✅ Event tap installed for Cmd+Shift+F12\n");
    fflush(stdout);
}

- (void)removeEventTap {
    if (self.eventTapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                              self.eventTapSource,
                              kCFRunLoopCommonModes);
        CFRelease(self.eventTapSource);
        self.eventTapSource = NULL;
    }
    if (self.eventTap) {
        CFRelease(self.eventTap);
        self.eventTap = NULL;
    }
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
    [self removeEventTap];
    [self.keysManager stop];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self removeEventTap];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

// Plain C callback for the event tap.
static CGEventRef EventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                    CGEventRef event, void *userInfo) {
    AppDelegate *self = (__bridge AppDelegate *)userInfo;

    // macOS disables the tap after a timeout; re-enable it.
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (self.eventTap) CGEventTapEnable(self.eventTap, true);
        return event;
    }

    if (type != kCGEventKeyDown) return event;

    CGKeyCode keycode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags flags = CGEventGetFlags(event);

    if (keycode == WATCHED_KEYCODE &&
        (flags & WATCHED_MODS) == WATCHED_MODS) {

        // Check that ONLY cmd+shift is held — ignore if other modifiers
        // like control or option are also down, so we don't steal other
        // combos that happen to end in F12.
        CGEventFlags extra = flags & (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
        if (extra == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self killWineProcesses];
            });
        }
    }
    // Return the event unchanged so F12 still reaches the game if it wants it.
    return event;
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
