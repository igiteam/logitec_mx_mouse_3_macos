#import "MXFlowManager.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>

// ============================================
// CONFIG
// ============================================

#define CHANNEL_LEFT   0
#define CHANNEL_RIGHT  1
#define CHANNEL_TOP    2

#define EDGE_THRESHOLD 5
#define LOGITECH_VID 0x046D

#define HIDPP_REPORT_ID_LONG 0x11
#define DEVICE_INDEX_DIRECT 0xFF
#define SWID 0x0A

#define FEATURE_CHANGE_HOST 0x1814
#define FEATURE_UNIFIED_BATTERY 0x1004

#define FUNCTION_GET_FEATURE 0x00
#define FUNCTION_SET_HOST    0x01
#define FUNCTION_GET_BATTERY 0x01

// Confirmed from raw dump on MX Master 3:
//   press/release toggle: 11 FF 0E 10 <state>
// The button toggles between state 0 and 1 on every press.
// We count every event, not just one state.
#define TOP_BUTTON_FEATURE 0x0E
#define TOP_BUTTON_EVENT   0x10

#define CLICK_DELTA_MAX   0.50
#define CLICK_RESET_AFTER 0.60
#define CLICK_DEBOUNCE    0.08

// ============================================

static void HIDDeviceMatchingCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void HIDDeviceRemovalCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void HIDInputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                    uint32_t reportID, uint8_t *report, CFIndex reportLength);

@interface MXFlowManager ()
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSTimer *batteryTimer;
@property (nonatomic, assign) CGRect screenBounds;
@property (nonatomic, assign) int currentChannel;
@property (nonatomic, assign) IOHIDDeviceRef hidDevice;
@property (nonatomic, assign) IOHIDManagerRef hidManager;
@property (nonatomic, assign, readwrite) BOOL deviceReady;
@property (nonatomic, assign) uint8_t changeHostIndex;
@property (nonatomic, assign) uint8_t batteryIndex;
@property (nonatomic, assign, readwrite) int batteryLevel;
@property (nonatomic, strong, readwrite) NSString *batteryString;
@property (nonatomic, assign) BOOL switching;
@property (nonatomic, assign) BOOL awaitingBatteryValue;
@property (nonatomic, assign) uint8_t *inputReport;
@property (nonatomic, assign) size_t inputReportSize;
@property (nonatomic, assign) BOOL inputReportRegistered;
@property (nonatomic, assign) BOOL batteryReadInProgress;
@property (nonatomic, assign) BOOL awaitingHostIndex;
@property (nonatomic, assign) BOOL awaitingBatteryIndex;
@property (nonatomic, assign) BOOL batteryLookupDone;

// Click tracking
@property (nonatomic, assign) int clickCount;
@property (nonatomic, strong) NSTimer *clickResetTimer;
@property (nonatomic, assign) CFTimeInterval lastPressTime;
@end

@implementation MXFlowManager

@synthesize batteryLevel = _batteryLevel;
@synthesize batteryString = _batteryString;
@synthesize deviceReady = _deviceReady;

- (instancetype)init {
    self = [super init];
    if (self) {
        _running = NO;
        _currentChannel = -1;
        _deviceReady = NO;
        _changeHostIndex = 0;
        _batteryIndex = 0;
        _batteryLevel = -1;
        _batteryString = @"--%";
        _switching = NO;
        _awaitingBatteryValue = NO;
        _inputReportRegistered = NO;
        _batteryReadInProgress = NO;
        _inputReportSize = 64;
        _screenBounds = CGDisplayBounds(CGMainDisplayID());
        _clickCount = 0;
        _lastPressTime = 0;
        _awaitingHostIndex = NO;
        _awaitingBatteryIndex = NO;
        _batteryLookupDone = NO;

        _inputReport = malloc(_inputReportSize);
        if (_inputReport) memset(_inputReport, 0, _inputReportSize);

        printf("[MXFlow] =========================================\n");
        printf("[MXFlow] MX Master 3 Flow Switcher + Battery\n");
        printf("[MXFlow] =========================================\n");
        fflush(stdout);
    }
    return self;
}

- (void)start {
    if (self.running) return;
    self.running = YES;

    printf("[MXFlow] Starting...\n");
    fflush(stdout);

    [self setupHIDManager];

    self.clickCount = 0;
    self.lastPressTime = 0;

    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                   target:self
                                                 selector:@selector(checkEdges)
                                                 userInfo:nil
                                                  repeats:YES];

    printf("[MXFlow] Running\n");
    fflush(stdout);
}

- (void)stop {
    self.running = NO;
    [self.timer invalidate]; self.timer = nil;
    [self.batteryTimer invalidate]; self.batteryTimer = nil;
    [self.clickResetTimer invalidate]; self.clickResetTimer = nil;

    if (self.hidManager) {
        IOHIDManagerClose(self.hidManager, kIOHIDOptionsTypeNone);
        CFRelease(self.hidManager);
        self.hidManager = NULL;
    }
    self.hidDevice = NULL;
    self.deviceReady = NO;
    self.inputReportRegistered = NO;

    if (self.inputReport) { free(self.inputReport); self.inputReport = NULL; }

    printf("[MXFlow] Stopped\n");
    fflush(stdout);
}

- (void)setupHIDManager {
    self.hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

    NSDictionary *criteria = @{ @"VendorID": @(LOGITECH_VID) };
    IOHIDManagerSetDeviceMatching(self.hidManager, (__bridge CFDictionaryRef)criteria);

    IOHIDManagerRegisterDeviceMatchingCallback(self.hidManager, HIDDeviceMatchingCallback, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(self.hidManager, HIDDeviceRemovalCallback, (__bridge void *)self);

    IOHIDManagerScheduleWithRunLoop(self.hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    IOReturn r = IOHIDManagerOpen(self.hidManager, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        printf("[MXFlow] IOHIDManagerOpen failed (%d). Grant Input Monitoring.\n", r);
        fflush(stdout);
    } else {
        printf("[MXFlow] Looking for Logitech devices...\n");
        fflush(stdout);
    }
}

static void HIDDeviceMatchingCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    MXFlowManager *self = (__bridge MXFlowManager *)context;
    if (!device || !self) return;

    CFStringRef productRef = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (!productRef) return;

    NSString *name = (__bridge NSString *)productRef;

    // Silent skip for non-mouse Logitech devices
    if (![name containsString:@"MX Master"] && ![name containsString:@"MX Anywhere"]) {
        return;
    }

    // Already attached — ignore duplicate enumeration
    if (self.hidDevice != NULL) return;

    printf("[MXFlow] Found: %s\n", [name UTF8String]);
    fflush(stdout);

    self.hidDevice = device;
    self.deviceReady = YES;

    [self registerInputReport:device];

    // Sequential lookup: ChangeHost first, battery only after
    [self lookupChangeHost];
}

static void HIDDeviceRemovalCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    MXFlowManager *self = (__bridge MXFlowManager *)context;
    if (device == self.hidDevice) {
        printf("[MXFlow] Device removed\n");
        self.hidDevice = NULL;
        self.deviceReady = NO;
        self.changeHostIndex = 0;
        self.batteryIndex = 0;
        self.batteryLevel = -1;
        self.batteryString = @"--%";
        self.inputReportRegistered = NO;
        self.batteryLookupDone = NO;
        [self.batteryTimer invalidate];
        self.batteryTimer = nil;
        fflush(stdout);
    }
}

static void HIDInputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                    uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    MXFlowManager *self = (__bridge MXFlowManager *)context;
    if (!self || reportLength < 5) return;

    // Only handle HID++ long reports. Mouse movement (reportID 0x02) is
    // silently ignored — no log, no handling.
    if (report[0] != 0x11) return;

    printf("[MXFlow] HID++ [%2ld]: ", (long)reportLength);
    for (int i = 0; i < reportLength && i < 12; i++) printf("%02X ", report[i]);
    printf("\n");
    fflush(stdout);

    // ---- Feature index replies on feature 0x00 ----
    if (report[2] == 0x00) {
        uint8_t idx = report[4];

        if (self.awaitingHostIndex) {
            self.awaitingHostIndex = NO;
            if (idx == 0 || idx == 0xFF) {
                printf("[MXFlow] ChangeHost not present on this device\n");
                fflush(stdout);
                return;
            }
            self.changeHostIndex = idx;
            printf("[MXFlow] ChangeHost index: 0x%02X\n", idx);
            fflush(stdout);
            // Delay before battery lookup — device needs a moment
            [self performSelector:@selector(lookupBattery) withObject:nil afterDelay:0.5];
            return;
        }

        if (self.awaitingBatteryIndex) {
            self.awaitingBatteryIndex = NO;
            self.batteryLookupDone = YES;
            if (idx == 0 || idx == 0xFF) {
                printf("[MXFlow] Battery feature not present on this device\n");
                fflush(stdout);
                return;
            }
            self.batteryIndex = idx;
            printf("[MXFlow] Battery index: 0x%02X\n", idx);
            fflush(stdout);
            // Start polling
            [self performSelector:@selector(readBattery) withObject:nil afterDelay:0.3];
            self.batteryTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                                  target:self
                                                                selector:@selector(readBattery)
                                                                userInfo:nil
                                                                 repeats:YES];
            return;
        }
    }

    // ---- Battery value response ----
    if (self.awaitingBatteryValue &&
        self.batteryIndex != 0 &&
        report[2] == self.batteryIndex) {

        uint8_t level = report[4];
        uint8_t flags = report[5];
        BOOL hasPercentage = (flags & 0x80) != 0;

        if (hasPercentage && level <= 100) {
            self.batteryLevel = level;
            self.batteryString = [NSString stringWithFormat:@"%d%%", level];
            printf("[MXFlow] Battery: %d%%\n", level);
        } else {
            NSString *s = @"--";
            switch (level) {
                case 0: s = @"Empty"; break;
                case 1: s = @"Critical"; break;
                case 2: s = @"Low"; break;
                case 3: s = @"Good"; break;
                case 4: s = @"Full"; break;
                default: s = @"--"; break;
            }
            self.batteryLevel = -1;
            self.batteryString = s;
            printf("[MXFlow] Battery level: %s\n", [s UTF8String]);
        }

        self.awaitingBatteryValue = NO;
        self.batteryReadInProgress = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BatteryUpdated" object:nil];
        fflush(stdout);
        return;
    }

    // ---- Top button (toggle) ----
    // Count every event on this feature/event pair, regardless of state.
    // The 80ms debounce in registerTopButtonPress filters duplicate events
    // from the same physical press.
    if (report[2] == TOP_BUTTON_FEATURE && report[3] == TOP_BUTTON_EVENT) {
        [self registerTopButtonPress];
        return;
    }
}

- (void)registerInputReport:(IOHIDDeviceRef)device {
    if (self.inputReportRegistered || !self.inputReport) return;
    IOHIDDeviceRegisterInputReportCallback(device, self.inputReport, self.inputReportSize,
                                            HIDInputReportCallback, (__bridge void *)self);
    self.inputReportRegistered = YES;
    printf("[MXFlow] Input report callback registered\n");
    fflush(stdout);
}

- (void)lookupChangeHost {
    if (!self.hidDevice) return;
    if (self.changeHostIndex != 0) return;
    if (self.awaitingHostIndex) return;

    printf("[MXFlow] Looking up CHANGE_HOST (0x1814)\n");
    fflush(stdout);

    self.awaitingHostIndex = YES;
    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = 0x00;
    cmd[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
    cmd[4] = 0x18;
    cmd[5] = 0x14;

    IOReturn r = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (r != kIOReturnSuccess) {
        printf("[MXFlow] ChangeHost lookup write failed: %d\n", r);
        self.awaitingHostIndex = NO;
        fflush(stdout);
    }
}

- (void)lookupBattery {
    if (!self.hidDevice) return;
    if (self.batteryIndex != 0) return;
    if (self.awaitingBatteryIndex) return;
    if (self.batteryLookupDone) return;

    printf("[MXFlow] Looking up UNIFIED_BATTERY (0x1004)\n");
    fflush(stdout);

    self.awaitingBatteryIndex = YES;
    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = 0x00;
    cmd[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
    cmd[4] = 0x10;
    cmd[5] = 0x04;

    IOReturn r = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (r != kIOReturnSuccess) {
        printf("[MXFlow] Battery lookup write failed: %d\n", r);
        self.awaitingBatteryIndex = NO;
        fflush(stdout);
    }
}

- (void)readBattery {
    if (!self.deviceReady || !self.hidDevice) return;
    if (self.batteryIndex == 0) return;
    if (self.batteryReadInProgress) return;

    self.batteryReadInProgress = YES;
    self.awaitingBatteryValue = YES;

    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.batteryIndex;
    cmd[3] = (uint8_t)((FUNCTION_GET_BATTERY << 4) | SWID);
    cmd[4] = 0x00;

    IOReturn result = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (result != kIOReturnSuccess) {
        self.batteryReadInProgress = NO;
        self.awaitingBatteryValue = NO;
        return;
    }
    [self performSelector:@selector(batteryReadTimeout) withObject:nil afterDelay:2.0];
}

- (void)batteryReadTimeout {
    if (self.batteryReadInProgress) {
        self.batteryReadInProgress = NO;
        self.awaitingBatteryValue = NO;
    }
}

// ---- Click logic ----
- (void)registerTopButtonPress {
    CFTimeInterval now = CACurrentMediaTime();

    // Debounce: swallow duplicate events from the same physical press
    if (self.lastPressTime > 0 && (now - self.lastPressTime) < CLICK_DEBOUNCE) return;

    CFTimeInterval delta = now - self.lastPressTime;
    self.lastPressTime = now;

    if (delta < CLICK_DELTA_MAX && self.clickCount > 0) {
        self.clickCount++;
    } else {
        self.clickCount = 1;
    }

    // 3+ clicks: fire immediately
    if (self.clickCount >= 3) {
        printf("[MXFlow] Top button 3 clicks -> channel 3\n");
        fflush(stdout);
        [self.clickResetTimer invalidate];
        self.clickResetTimer = nil;
        self.clickCount = 0;
        [self switchToChannelDirect:2];
        return;
    }

    [self.clickResetTimer invalidate];
    self.clickResetTimer = [NSTimer scheduledTimerWithTimeInterval:CLICK_RESET_AFTER
                                                            target:self
                                                          selector:@selector(clickWindowExpired)
                                                          userInfo:nil
                                                           repeats:NO];

    printf("[MXFlow] Top button click %d\n", self.clickCount);
    fflush(stdout);
}

- (void)clickWindowExpired {
    int count = self.clickCount;
    self.clickCount = 0;

    int channel = -1;
    if (count == 1) channel = 0;
    else if (count == 2) channel = 1;

    if (channel >= 0) {
        printf("[MXFlow] Top button %d click(s) -> channel %d\n", count, channel + 1);
        fflush(stdout);
        [self switchToChannelDirect:channel];
    }
}

- (void)checkEdges {
    if (!self.running || self.switching) return;

    CGEventRef event = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(event);
    CFRelease(event);

    CGFloat w = self.screenBounds.size.width;

    if (p.x <= EDGE_THRESHOLD) {
        if (self.currentChannel != CHANNEL_LEFT) {
            printf("[MXFlow] LEFT edge -> channel 1\n");
            [self switchToChannel:CHANNEL_LEFT];
            self.currentChannel = CHANNEL_LEFT;
            [self warpMouse:p.x + 20 y:p.y];
        }
        return;
    }

    if (p.x >= w - EDGE_THRESHOLD) {
        if (self.currentChannel != CHANNEL_RIGHT) {
            printf("[MXFlow] RIGHT edge -> channel 2\n");
            [self switchToChannel:CHANNEL_RIGHT];
            self.currentChannel = CHANNEL_RIGHT;
            [self warpMouse:p.x - 20 y:p.y];
        }
        return;
    }

    if (p.y <= EDGE_THRESHOLD) {
        if (self.currentChannel != CHANNEL_TOP) {
            printf("[MXFlow] TOP edge -> channel 3\n");
            [self switchToChannel:CHANNEL_TOP];
            self.currentChannel = CHANNEL_TOP;
            [self warpMouse:p.x y:p.y + 20];
        }
        return;
    }
}

- (void)warpMouse:(CGFloat)x y:(CGFloat)y {
    CGWarpMouseCursorPosition(CGPointMake(x, y));
    CGAssociateMouseAndMouseCursorPosition(true);
    CGEventRef moveEvent = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                                    CGPointMake(x, y), kCGMouseButtonLeft);
    if (moveEvent) {
        CGEventPost(kCGHIDEventTap, moveEvent);
        CFRelease(moveEvent);
    }
}

- (void)switchToChannel:(int)channel {
    if (self.changeHostIndex == 0 || !self.deviceReady || !self.hidDevice) {
        printf("[MXFlow] Cannot switch (changeHost=0x%02X ready=%d)\n",
               self.changeHostIndex, self.deviceReady);
        fflush(stdout);
        return;
    }

    self.switching = YES;

    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.changeHostIndex;
    cmd[3] = (uint8_t)((FUNCTION_SET_HOST << 4) | SWID);
    cmd[4] = (uint8_t)channel;
    cmd[5] = 0x00;

    IOReturn result = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (result == kIOReturnSuccess) {
        printf("[MXFlow] Switched to channel %d\n", channel + 1);
    } else {
        printf("[MXFlow] Switch failed (%d)\n", result);
    }
    self.switching = NO;
    fflush(stdout);
}

- (void)switchToChannelDirect:(int)channel {
    if (!self.running) return;
    [self switchToChannel:channel];
    self.currentChannel = channel;
}

- (void)dealloc {
    [self stop];
}

@end
