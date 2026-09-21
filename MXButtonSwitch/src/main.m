#import <Cocoa/Cocoa.h>
#import <IOKit/hid/IOHIDLib.h>
#import <QuartzCore/QuartzCore.h>

// ---- Confirmed from raw dump ----
// Top button event:  11 FF 0E 10 <state>
//   report[0] = 0x11  HID++ long
//   report[1] = 0xFF  device index
//   report[2] = 0x0E  feature index (top button)
//   report[3] = 0x10  event type (button press)
//   report[4] = 0x01  pressed / 0x00 released
#define TOP_BUTTON_FEATURE 0x0E
#define TOP_BUTTON_EVENT   0x10

#define LOGITECH_VID       0x046D
#define HIDPP_LONG         0x11
#define DEV_INDEX          0xFF
#define SWID               0x0A
#define FEATURE_CHANGE_HOST 0x1814
#define FUNCTION_GET_FEATURE 0x00
#define FUNCTION_SET_HOST    0x01

// Click timing
#define CLICK_DELTA_MAX   0.40
#define CLICK_RESET_AFTER 0.50
#define CLICK_DEBOUNCE    0.06

static void onAdd(void *ctx, IOReturn r, void *s, IOHIDDeviceRef d);
static void onRemove(void *ctx, IOReturn r, void *s, IOHIDDeviceRef d);
static void onReport(void *ctx, IOReturn r, void *s, IOHIDReportType t,
                     uint32_t id, uint8_t *rep, CFIndex len);

@interface Switcher : NSObject
@property (nonatomic, assign) IOHIDManagerRef mgr;
@property (nonatomic, assign) IOHIDDeviceRef  dev;
@property (nonatomic, assign) uint8_t *buf;
@property (nonatomic, assign) BOOL registered;
@property (nonatomic, assign) uint8_t changeHostIdx;
@property (nonatomic, assign) BOOL awaitingChangeHost;
@property (nonatomic, assign) BOOL buttonDown;

@property (nonatomic, assign) int  clickCount;
@property (nonatomic, assign) CFTimeInterval lastPressTime;
@property (nonatomic, strong) NSTimer *resetTimer;
@end

@implementation Switcher

- (instancetype)init {
    self = [super init];
    _buf = malloc(256); memset(_buf, 0, 256);
    _registered = NO;
    _changeHostIdx = 0;
    _awaitingChangeHost = NO;
    _buttonDown = NO;
    _clickCount = 0;
    _lastPressTime = 0;
    return self;
}

- (void)start {
    self.mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *m = @{ @"VendorID": @(LOGITECH_VID) };
    IOHIDManagerSetDeviceMatching(self.mgr, (__bridge CFDictionaryRef)m);
    IOHIDManagerRegisterDeviceMatchingCallback(self.mgr, onAdd, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(self.mgr, onRemove, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(self.mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    IOReturn r = IOHIDManagerOpen(self.mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        printf("IOHIDManagerOpen failed (%d). Grant Input Monitoring to this app, then quit and relaunch.\n", r);
        fflush(stdout);
        exit(1);
    }
    printf("Waiting for MX Master...\n");
    fflush(stdout);
}

- (void)lookupChangeHost {
    if (!self.dev) return;
    self.awaitingChangeHost = YES;
    uint8_t a[20] = {0};
    a[0] = HIDPP_LONG;
    a[1] = DEV_INDEX;
    a[2] = 0x00;
    a[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
    a[4] = 0x18; a[5] = 0x14;
    IOHIDDeviceSetReport(self.dev, kIOHIDReportTypeOutput, 0x11, a, 20);
}

- (void)switchToChannel:(int)ch {
    if (self.changeHostIdx == 0 || !self.dev) {
        printf("ChangeHost index not ready, cannot switch\n");
        fflush(stdout);
        return;
    }
    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_LONG;
    cmd[1] = DEV_INDEX;
    cmd[2] = self.changeHostIdx;
    cmd[3] = (uint8_t)((FUNCTION_SET_HOST << 4) | SWID);
    cmd[4] = (uint8_t)ch;
    cmd[5] = 0x00;
    IOReturn r = IOHIDDeviceSetReport(self.dev, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    printf("→ Switch to channel %d: %s\n", ch + 1, r == kIOReturnSuccess ? "OK" : "FAIL");
    fflush(stdout);
}

- (void)registerClick {
    CFTimeInterval now = CACurrentMediaTime();

    if (self.lastPressTime > 0 && (now - self.lastPressTime) < CLICK_DEBOUNCE) return;

    CFTimeInterval delta = now - self.lastPressTime;
    self.lastPressTime = now;

    if (delta < CLICK_DELTA_MAX && self.clickCount > 0) self.clickCount++;
    else self.clickCount = 1;

    [self.resetTimer invalidate];
    self.resetTimer = [NSTimer scheduledTimerWithTimeInterval:CLICK_RESET_AFTER
                                                       target:self
                                                     selector:@selector(fireClick)
                                                     userInfo:nil
                                                      repeats:NO];

    printf("click %d\n", self.clickCount);
    fflush(stdout);
}

- (void)fireClick {
    int count = self.clickCount;
    self.clickCount = 0;
    int ch = -1;
    if (count == 1) ch = 0;
    else if (count == 2) ch = 1;
    else if (count >= 3) ch = 2;
    if (ch >= 0) [self switchToChannel:ch];
}

- (void)handle:(uint8_t *)r len:(CFIndex)len {
    if (len < 5) return;
    if (r[0] != 0x11 || r[1] != 0xFF) return;

    // Feature index reply for ChangeHost lookup
    if (r[2] == 0x00 && self.awaitingChangeHost) {
        uint8_t idx = r[4];
        if (idx != 0 && idx != 0xFF) {
            self.changeHostIdx = idx;
            self.awaitingChangeHost = NO;
            printf("ChangeHost index: 0x%02X\n", idx);
            fflush(stdout);
        }
        return;
    }

    // ---- Top button event ----
    if (r[2] == TOP_BUTTON_FEATURE && r[3] == TOP_BUTTON_EVENT) {
        uint8_t state = r[4];
        if (state == 0x01 && !self.buttonDown) {
            self.buttonDown = YES;
            [self registerClick];
        } else if (state == 0x00) {
            self.buttonDown = NO;
        }
    }
}

@end

static void onAdd(void *ctx, IOReturn r, void *s, IOHIDDeviceRef d) {
    Switcher *self = (__bridge Switcher *)ctx;
    if (!d || !self) return;
    CFStringRef pr = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductKey));
    if (!pr) return;
    NSString *n = (__bridge NSString *)pr;
    if (![n containsString:@"MX Master"] &&
        ![n containsString:@"MX Anywhere"]) return;

    printf("Found: %s\n", [n UTF8String]);
    fflush(stdout);
    self.dev = d;

    if (!self.registered) {
        IOHIDDeviceRegisterInputReportCallback(d, self.buf, 256, onReport, (__bridge void *)self);
        self.registered = YES;
    }
    [self lookupChangeHost];
}

static void onRemove(void *ctx, IOReturn r, void *s, IOHIDDeviceRef d) {
    Switcher *self = (__bridge Switcher *)ctx;
    if (d == self.dev) {
        printf("Device removed\n");
        fflush(stdout);
        self.dev = NULL;
        self.registered = NO;
        self.changeHostIdx = 0;
    }
}

static void onReport(void *ctx, IOReturn r, void *s, IOHIDReportType t,
                     uint32_t id, uint8_t *rep, CFIndex len) {
    Switcher *self = (__bridge Switcher *)ctx;
    if (!self) return;
    [self handle:rep len:len];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Switcher *s = [[Switcher alloc] init];
        [s start];
        printf("=================================================\n");
        printf("  MX Button Switch — running\n");
        printf("  Top button 1x → channel 1\n");
        printf("  Top button 2x → channel 2\n");
        printf("  Top button 3x → channel 3\n");
        printf("  Ctrl+C to quit\n");
        printf("=================================================\n");
        fflush(stdout);
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
