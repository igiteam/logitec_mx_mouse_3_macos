#import "MXFlowManager.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>

// ============================================
// CONFIG
// ============================================

// Channel mapping (0-indexed, displayed 1/2/3):
//   Channel 0 = Mac 1 (this Mac, the "home" channel)
//   Channel 1 = Mac 2 (left-edge destination)
//   Channel 2 = Mac 3 (right-edge destination)
#define CHANNEL_MIN 0
#define CHANNEL_MAX 2
#define CHANNEL_HOME   0   // the Mac this app runs on
#define CHANNEL_LEFT   1   // left edge always goes here
#define CHANNEL_RIGHT  2   // right edge always goes here

#define EDGE_THRESHOLD 5
#define LOGITECH_VID 0x046D

#define HIDPP_REPORT_ID_LONG 0x11
#define DEVICE_INDEX_DIRECT 0xFF
#define SWID 0x0A

#define FEATURE_ROOT 0x0000
#define FEATURE_UNIFIED_BATTERY 0x1004
#define FEATURE_BATTERY_STATUS  0x1000
#define FEATURE_CHANGE_HOST     0x1814

#define FUNCTION_GET_FEATURE 0x00
#define FUNCTION_SET_HOST    0x01
#define FUNCTION_GET_BATTERY_UNIFIED 0x01  // 0x1004 get_status
#define FUNCTION_GET_BATTERY_STATUS  0x00  // 0x1000 get_battery_level_status

// Confirmed from raw dump on MX Master 3:
//   toggle event: 11 FF 0E 10 <state>   state flips 0/1 on every press
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
@property (nonatomic, assign) BOOL batteryIsUnified;    // YES = 0x1004, NO = 0x1000
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
@property (nonatomic, assign) BOOL edgeArmed;

// Click tracking
@property (nonatomic, assign) int clickCount;
@property (nonatomic, strong) NSTimer *clickResetTimer;
@property (nonatomic, assign) CFTimeInterval lastPressTime;

// Battery cache (survives disconnect)
@property (nonatomic, assign) int cachedBatteryLevel;
@property (nonatomic, strong) NSString *cachedBatteryString;
@end

@implementation MXFlowManager

@synthesize batteryLevel = _batteryLevel;
@synthesize batteryString = _batteryString;
@synthesize deviceReady = _deviceReady;

- (instancetype)init {
    self = [super init];
    if (self) {
        _running = NO;
        _currentChannel = CHANNEL_HOME;
        _deviceReady = NO;
        _changeHostIndex = 0;
        _edgeArmed = YES;
        _batteryIndex = 0;
        _batteryIsUnified = NO;
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
        _cachedBatteryLevel = -1;
        _cachedBatteryString = @"--%";

        _inputReport = malloc(_inputReportSize);
        if (_inputReport) memset(_inputReport, 0, _inputReportSize);

        printf("[MXFlow] =========================================\n");
        printf("[MXFlow] MX Master 3 Flow Switcher\n");
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

    if (![name containsString:@"MX Master"] && ![name containsString:@"MX Anywhere"]) return;
    if (self.hidDevice != NULL) return;

    printf("[MXFlow] Found: %s\n", [name UTF8String]);
    fflush(stdout);

    self.hidDevice = device;
    self.deviceReady = YES;
    // Reset the edge re-arm on every (re)connect. When the mouse comes back
    // to this Mac, it's because the user flicked away from here, so the
    // current cursor position is already at an edge — don't let that fire.
    self.edgeArmed = NO;

    [self registerInputReport:device];
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
        self.batteryLookupDone = NO;
        self.inputReportRegistered = NO;
        [self.batteryTimer invalidate];
        self.batteryTimer = nil;
        fflush(stdout);
        // NOTE: do NOT reset currentChannel or battery cache — the mouse will
        // come back on the same channel, and we want the icon to keep showing
        // the last known battery reading.
    }
}

static void HIDInputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                    uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    MXFlowManager *self = (__bridge MXFlowManager *)context;
    if (!self || reportLength < 5) return;
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
                printf("[MXFlow] ChangeHost not present\n");
                fflush(stdout);
                return;
            }
            self.changeHostIndex = idx;
            printf("[MXFlow] ChangeHost index: 0x%02X\n", idx);
            fflush(stdout);
            [self performSelector:@selector(lookupBattery) withObject:nil afterDelay:0.5];
            return;
        }

        if (self.awaitingBatteryIndex) {
            self.awaitingBatteryIndex = NO;
            if (idx == 0 || idx == 0xFF) {
                // 0x1004 not present — fall back to 0x1000
                if (self.batteryIsUnified) {
                    printf("[MXFlow] UnifiedBattery not present, trying BatteryStatus (0x1000)\n");
                    fflush(stdout);
                    self.batteryIsUnified = NO;
                    self.awaitingBatteryIndex = YES;
                    uint8_t cmd[20] = {0};
                    cmd[0] = HIDPP_REPORT_ID_LONG;
                    cmd[1] = DEVICE_INDEX_DIRECT;
                    cmd[2] = 0x00;
                    cmd[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
                    cmd[4] = 0x10;
                    cmd[5] = 0x00;
                    IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
                    return;
                }
                printf("[MXFlow] No battery feature on this device\n");
                self.batteryLookupDone = YES;
                fflush(stdout);
                return;
            }
            self.batteryIndex = idx;
            self.batteryLookupDone = YES;
            printf("[MXFlow] Battery index: 0x%02X (feature 0x%04X)\n",
                   idx, self.batteryIsUnified ? 0x1004 : 0x1000);
            fflush(stdout);
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

        uint8_t raw = report[4];
        BOOL ok = NO;
        int pct = -1;

        if (self.batteryIsUnified) {
            // 0x1004: byte4 = state of charge %, byte5 = level flags,
            // byte6 = charging status. flags bit 7 = "percentage valid".
            uint8_t flags = report[5];
            if ((flags & 0x80) && raw <= 100) {
                pct = raw;
                ok = YES;
            }
        } else {
            // 0x1000: byte4 = level %, byte5 = next level %, byte6 = status.
            // Reported levels are discrete (100/80/50/30/10/5).
            uint8_t status = report[6];
            BOOL charging = (status == 1 || status == 2 || status == 4);
            if (raw > 0 && raw <= 100) {
                pct = raw;
                ok = YES;
            } else if (charging && raw == 0) {
                // invalid level while charging — keep last
                ok = NO;
            }
        }

        if (ok) {
            // Snap to nearest of {100, 80, 50, 10}
            int snapped;
            if (pct >= 90) snapped = 100;
            else if (pct >= 65) snapped = 80;
            else if (pct >= 30) snapped = 50;
            else snapped = 10;

            self.batteryLevel = snapped;
            self.batteryString = [NSString stringWithFormat:@"%d%%", snapped];
            self.cachedBatteryLevel = snapped;
            self.cachedBatteryString = self.batteryString;
            printf("[MXFlow] Battery: %d%% (raw %d)\n", snapped, pct);
        } else {
            printf("[MXFlow] Battery read inconclusive, keeping last\n");
        }

        self.awaitingBatteryValue = NO;
        self.batteryReadInProgress = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BatteryUpdated" object:nil];
        fflush(stdout);
        return;
    }

    // ---- Top button ----
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
        printf("[MXFlow] ChangeHost write failed: %d\n", r);
        self.awaitingHostIndex = NO;
        fflush(stdout);
    }
}

- (void)lookupBattery {
    if (!self.hidDevice) return;
    if (self.batteryIndex != 0) return;
    if (self.awaitingBatteryIndex) return;
    if (self.batteryLookupDone) return;

    // Try UnifiedBattery first
    self.batteryIsUnified = YES;
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
        printf("[MXFlow] Battery write failed: %d\n", r);
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

    uint8_t fn = self.batteryIsUnified ? FUNCTION_GET_BATTERY_UNIFIED
                                        : FUNCTION_GET_BATTERY_STATUS;

    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.batteryIndex;
    cmd[3] = (uint8_t)((fn << 4) | SWID);

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
    if (self.lastPressTime > 0 && (now - self.lastPressTime) < CLICK_DEBOUNCE) return;

    CFTimeInterval delta = now - self.lastPressTime;
    self.lastPressTime = now;

    if (delta < CLICK_DELTA_MAX && self.clickCount > 0) self.clickCount++;
    else self.clickCount = 1;

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

// ---- Edge logic (Flow style, one step at a time) ----
// Physical layout: Mac 1 (left) ↔ Mac 2 (center) ↔ Mac 3 (right)
// Left edge → one Mac to the left. Right edge → one Mac to the right.
//
// edgeArmed prevents double-firing: once we fire a switch, the cursor
// warp may leave the pointer near the edge, and when the mouse comes back
// to this Mac we don't want the same edge position to fire again. We only
// re-arm when the cursor moves away from the edge by more than
// EDGE_THRESHOLD + a small hysteresis.
- (void)checkEdges {
    if (!self.running || self.switching) return;
    if (!self.deviceReady) return;

    CGEventRef event = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(event);
    CFRelease(event);

    CGFloat w = self.screenBounds.size.width;

    // Re-arm the edge trigger once the cursor is clearly away from both
    // edges. Hysteresis = EDGE_THRESHOLD * 2 so tiny jitter doesn't
    // re-arm early.
    CGFloat rearmDist = 40.0;   // must move 40 px in from either edge to re-arm
    if (!self.edgeArmed) {
        if (p.x > rearmDist && p.x < w - rearmDist) {
            self.edgeArmed = YES;
        }
        return;
    }

    if (p.x <= EDGE_THRESHOLD) {
        int next = self.currentChannel - 1;
        if (next >= CHANNEL_MIN) {
            printf("[MXFlow] LEFT edge -> channel %d (Mac %d)\n", next, next + 1);
            fflush(stdout);
            self.edgeArmed = NO;
            [self switchToChannelDirect:next];
            [self warpMouse:p.x + 20 y:p.y];
        }
        return;
    }

    if (p.x >= w - EDGE_THRESHOLD) {
        int next = self.currentChannel + 1;
        if (next <= CHANNEL_MAX) {
            printf("[MXFlow] RIGHT edge -> channel %d (Mac %d)\n", next, next + 1);
            fflush(stdout);
            self.edgeArmed = NO;
            [self switchToChannelDirect:next];
            [self warpMouse:p.x - 20 y:p.y];
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
    if (channel < CHANNEL_MIN || channel > CHANNEL_MAX) return;
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
    if (channel < CHANNEL_MIN || channel > CHANNEL_MAX) return;
    [self switchToChannel:channel];
    self.currentChannel = channel;
}

// ---- Battery accessors: return cache when live value is unavailable ----
- (int)batteryLevel {
    if (_batteryLevel >= 0) return _batteryLevel;
    return self.cachedBatteryLevel;
}

- (NSString *)batteryString {
    if (_batteryLevel >= 0) return _batteryString;
    return self.cachedBatteryString;
}

- (void)dealloc {
    [self stop];
}

@end
