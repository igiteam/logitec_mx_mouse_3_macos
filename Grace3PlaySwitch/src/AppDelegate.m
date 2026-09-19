#import "AppDelegate.h"
#import "Grace3PlayManager.h"

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) Grace3PlayManager *manager;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, strong) NSMenuItem *deviceMenuItem;
@property (nonatomic, strong) NSMenuItem *batteryMenuItem;
@property (nonatomic, assign) BOOL isActive;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.manager = [[Grace3PlayManager alloc] init];
    self.isActive = NO;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"🎧 --%";;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateDisplay)
                                                 name:@"DeviceUpdated"
                                               object:nil];

    NSMenu *menu = [[NSMenu alloc] init];

    self.toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@"Start 3Play Control"
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

    NSMenuItem *switchTitle = [[NSMenuItem alloc] initWithTitle:@"── Switch Input ──"
                                                          action:nil
                                                   keyEquivalent:@""];
    [menu addItem:switchTitle];

    NSMenuItem *switch1 = [[NSMenuItem alloc] initWithTitle:@"Switch to Channel 1"
                                                      action:@selector(switchToChannel1:)
                                               keyEquivalent:@"1"];
    switch1.target = self;
    [menu addItem:switch1];

    NSMenuItem *switch2 = [[NSMenuItem alloc] initWithTitle:@"Switch to Channel 2"
                                                      action:@selector(switchToChannel2:)
                                               keyEquivalent:@"2"];
    switch2.target = self;
    [menu addItem:switch2];

    NSMenuItem *switch3 = [[NSMenuItem alloc] initWithTitle:@"Switch to Channel 3"
                                                      action:@selector(switchToChannel3:)
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
    [self.manager start];
    self.toggleMenuItem.title = @"Stop 3Play Control";
    [self updateDisplay];
}

- (void)toggleFlow:(id)sender {
    self.isActive = !self.isActive;
    if (self.isActive) {
        [self.manager start];
        self.toggleMenuItem.title = @"Stop 3Play Control";
    } else {
        [self.manager stop];
        self.toggleMenuItem.title = @"Start 3Play Control";
    }
    [self updateDisplay];
}

- (void)switchToChannel1:(id)sender { [self.manager switchToChannelDirect:0]; }
- (void)switchToChannel2:(id)sender { [self.manager switchToChannelDirect:1]; }
- (void)switchToChannel3:(id)sender { [self.manager switchToChannelDirect:2]; }

- (void)updateDisplay {
    if (self.manager.deviceConnected) {
        self.statusItem.button.title = @"🎧 --%";;
        self.deviceMenuItem.title = [NSString stringWithFormat:@"Device: %@", self.manager.deviceName];
        self.batteryMenuItem.title = [NSString stringWithFormat:@"Battery: %@", self.manager.batteryString];
    } else {
        self.statusItem.button.title = @"🎧 --%";;
        self.deviceMenuItem.title = @"Device: Not connected";
        self.batteryMenuItem.title = @"Battery: --";
    }
}

- (void)quitApp:(id)sender {
    [self.manager stop];
    [NSApp terminate:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
