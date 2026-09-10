#import "AppDelegate.h"
#import "MXFlowManager.h"

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) MXFlowManager *flowManager;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.flowManager = [[MXFlowManager alloc] init];
    self.isActive = NO;
    
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"🖱️ --%";
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateBatteryDisplay)
                                                 name:@"BatteryUpdated"
                                               object:nil];
    
    NSMenu *menu = [[NSMenu alloc] init];
    
    self.toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@"Start Flow Switching"
                                                      action:@selector(toggleFlow:)
                                               keyEquivalent:@"s"];
    self.toggleMenuItem.target = self;
    [menu addItem:self.toggleMenuItem];
    
    [menu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *switchTitle = [[NSMenuItem alloc] initWithTitle:@"── Manual Switch ──" 
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
    
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Status: Stopped" 
                                                         action:nil 
                                                  keyEquivalent:@""];
    self.statusMenuItem.tag = 100;
    [menu addItem:self.statusMenuItem];
    
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
    [self.flowManager start];
    self.toggleMenuItem.title = @"Stop Flow Switching";
    [self updateStatus:@"Running"];
}

- (void)toggleFlow:(id)sender {
    self.isActive = !self.isActive;
    if (self.isActive) {
        [self.flowManager start];
        self.toggleMenuItem.title = @"Stop Flow Switching";
        [self updateStatus:@"Running"];
    } else {
        [self.flowManager stop];
        self.toggleMenuItem.title = @"Start Flow Switching";
        [self updateStatus:@"Stopped"];
    }
}

- (void)switchToChannel1:(id)sender {
    [self.flowManager switchToChannelDirect:0];
}

- (void)switchToChannel2:(id)sender {
    [self.flowManager switchToChannelDirect:1];
}

- (void)switchToChannel3:(id)sender {
    [self.flowManager switchToChannelDirect:2];
}

- (void)updateStatus:(NSString *)status {
    if (self.statusMenuItem) {
        self.statusMenuItem.title = [NSString stringWithFormat:@"Status: %@", status];
    }
}

- (void)updateBatteryDisplay {
    int battery = self.flowManager.batteryLevel;
    if (battery >= 0) {
        self.statusItem.button.title = [NSString stringWithFormat:@"🖱️ %d%%", battery];
        self.statusItem.button.alternateTitle = [NSString stringWithFormat:@"🖱️ %d%%", battery];
    } else {
        self.statusItem.button.title = @"🖱️ --%";
        self.statusItem.button.alternateTitle = @"🖱️ --%";
    }
}

- (void)quitApp:(id)sender {
    [self.flowManager stop];
    [NSApp terminate:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
