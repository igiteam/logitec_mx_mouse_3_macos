#import "AppDelegate.h"
#import "MXKeysManager.h"

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) MXKeysManager *keysManager;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, strong) NSMenuItem *deviceMenuItem;
@property (nonatomic, strong) NSMenuItem *batteryMenuItem;
@property (nonatomic, assign) BOOL isActive;
@end

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

    NSMenuItem *switch1 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 1"
                                                      action:@selector(switchToHost1:)
                                               keyEquivalent:@"1"];
    switch1.target = self;
    [menu addItem:switch1];

    NSMenuItem *switch2 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 2"
                                                      action:@selector(switchToHost2:)
                                               keyEquivalent:@"2"];
    switch2.target = self;
    [menu addItem:switch2];

    NSMenuItem *switch3 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 3"
                                                      action:@selector(switchToHost3:)
                                               keyEquivalent:@"3"];
    switch3.target = self;
    [menu addItem:switch3];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                       action:@selector(quitApp:)
                                                keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;

    [self performSelector:@selector(autoStart) withObject:nil afterDelay:0.5];
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

- (void)updateDisplay {
    if (self.keysManager.deviceConnected) {
        self.statusItem.button.title = @"⌨️ --%";
        self.deviceMenuItem.title = [NSString stringWithFormat:@"Device: %@", self.keysManager.deviceName];
        self.batteryMenuItem.title = [NSString stringWithFormat:@"Battery: %@", self.keysManager.batteryLevelString];
    } else {
        self.statusItem.button.title = @"⌨️ --%";
        self.deviceMenuItem.title = @"Device: Not connected";
        self.batteryMenuItem.title = @"Battery: --";
    }
}

- (void)quitApp:(id)sender {
    [self.keysManager stop];
    [NSApp terminate:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
