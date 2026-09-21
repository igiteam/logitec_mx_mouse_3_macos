#import "MXKeysManager.h"
#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOKitLib.h>

// ============================================
// CONFIG
// ============================================

#define LOGITECH_VID 0x046D
#define MX_KEYS_MINI_PID     0xB369
#define MX_KEYS_MINI_MAC_PID 0xB36A

#define HIDPP_REPORT_ID_LONG 0x11
#define DEVICE_INDEX_DIRECT  0xFF
#define SWID                 0x0A

#define FEATURE_ROOT             0x0000
#define FEATURE_CHANGE_HOST      0x1814
#define FEATURE_UNIFIED_BATTERY  0x1004
#define FEATURE_BATTERY_STATUS   0x1000

#define FUNCTION_GET_FEATURE    0x00
#define FUNCTION_GET_HOST_INFO  0x00
#define FUNCTION_SET_HOST       0x01
#define FUNCTION_GET_BATTERY_UNIFIED 0x01
#define FUNCTION_GET_BATTERY_STATUS  0x00

// ============================================

static void HIDDeviceMatchingCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void HIDDeviceRemovalCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void HIDInputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                    uint32_t reportID, uint8_t *report, CFIndex reportLength);

@interface MXKeysManager ()
@property (nonatomic, assign) IOHIDDeviceRef hidDevice;
@property (nonatomic, assign) IOHIDManagerRef hidManager;
@property (nonatomic, assign) BOOL deviceReady;
@property (nonatomic, assign, readwrite) BOOL deviceConnected;
@property (nonatomic, strong, readwrite) NSString *deviceName;
@property (nonatomic, assign) uint8_t changeHostIndex;
@property (nonatomic, assign) BOOL changeHostIndexFound;
@property (nonatomic, assign) uint8_t batteryIndex;
@property (nonatomic, assign) BOOL batteryIsUnified;
@property (nonatomic, assign, readwrite) int batteryLevel;
@property (nonatomic, strong, readwrite) NSString *batteryLevelString;
@property (nonatomic, assign) BOOL switching;
@property (nonatomic, assign) uint8_t *inputReport;
@property (nonatomic, assign) size_t inputReportSize;
@property (nonatomic, assign) BOOL inputReportRegistered;
@property (nonatomic, assign) BOOL awaitingHostIndex;
@property (nonatomic, assign) BOOL awaitingBatteryIndex;
@property (nonatomic, assign) BOOL awaitingBatteryValue;
@property (nonatomic, assign) BOOL batteryLookupDone;

@property (nonatomic, assign) int cachedBatteryLevel;
@property (nonatomic, strong) NSString *cachedBatteryString;
@end

@implementation MXKeysManager

@synthesize deviceConnected = _deviceConnected;
@synthesize deviceName = _deviceName;
@synthesize batteryLevel = _batteryLevel;
@synthesize batteryLevelString = _batteryLevelString;

- (instancetype)init {
    self = [super init];
    if (self) {
        _running = NO;
        _deviceReady = NO;
        _deviceConnected = NO;
        _deviceName = @"Not connected";
        _changeHostIndex = 0;
        _changeHostIndexFound = NO;
        _batteryIndex = 0;
        _batteryIsUnified = NO;
        _batteryLevel = -1;
        _batteryLevelString = @"--";
        _switching = NO;
        _inputReportRegistered = NO;
        _awaitingHostIndex = NO;
        _awaitingBatteryIndex = NO;
        _awaitingBatteryValue = NO;
        _batteryLookupDone = NO;
        _cachedBatteryLevel = -1;
        _cachedBatteryString = @"--";
        _inputReportSize = 64;
        _inputReport = malloc(_inputReportSize);
        if (_inputReport) memset(_inputReport, 0, _inputReportSize);

        printf("[MXKeys] =========================================\n");
        printf("[MXKeys] MX Keys Mini Host Switcher + Wine Killer\n");
        printf("[MXKeys] =========================================\n");
        fflush(stdout);
    }
    return self;
}

- (void)start {
    if (self.running) return;
    self.running = YES;
    printf("[MXKeys] Starting HID manager...\n");
    fflush(stdout);
    [self setupHIDManager];
}

- (void)stop {
    self.running = NO;
    if (self.hidManager) {
        IOHIDManagerClose(self.hidManager, kIOHIDOptionsTypeNone);
        CFRelease(self.hidManager);
        self.hidManager = NULL;
    }
    self.hidDevice = NULL;
    self.deviceReady = NO;
    self.deviceConnected = NO;
    self.deviceName = @"Not connected";
    self.inputReportRegistered = NO;
    self.changeHostIndexFound = NO;
    if (self.inputReport) { free(self.inputReport); self.inputReport = NULL; }
    printf("[MXKeys] Stopped\n");
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
        printf("[MXKeys] IOHIDManagerOpen failed (%d). Grant Input Monitoring.\n", r);
        fflush(stdout);
    } else {
        printf("[MXKeys] Scanning for Logitech devices...\n");
        fflush(stdout);
    }
}

static void HIDDeviceMatchingCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    MXKeysManager *self = (__bridge MXKeysManager *)context;
    if (!device || !self) return;

    CFStringRef productRef = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    CFNumberRef pidRef = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    NSString *name = productRef ? (__bridge NSString *)productRef : @"Unknown";
    int pid = 0;
    if (pidRef) CFNumberGetValue(pidRef, kCFNumberIntType, &pid);

    BOOL isMini = (pid == MX_KEYS_MINI_PID) || (pid == MX_KEYS_MINI_MAC_PID);
    if (!isMini && pid != 0) return;
    if (!isMini && ![name containsString:@"MX Keys Mini"]) return;
    if (self.hidDevice != NULL) return;

    printf("[MXKeys] ✅ Found MX Keys Mini: %s (PID 0x%04X)\n", [name UTF8String], pid);
    fflush(stdout);

    self.hidDevice = device;
    self.deviceReady = YES;
    self.deviceConnected = YES;
    self.deviceName = name;

    [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];

    [self registerInputReport:device];
    [self lookupChangeHost];
}

static void HIDDeviceRemovalCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    MXKeysManager *self = (__bridge MXKeysManager *)context;
    if (device == self.hidDevice) {
        printf("[MXKeys] ❌ Keyboard removed\n");
        self.hidDevice = NULL;
        self.deviceReady = NO;
        self.deviceConnected = NO;
        self.deviceName = @"Not connected";
        self.changeHostIndex = 0;
        self.changeHostIndexFound = NO;
        self.batteryIndex = 0;
        self.batteryLookupDone = NO;
        self.inputReportRegistered = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];
        fflush(stdout);
    }
}

static void HIDInputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                    uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    MXKeysManager *self = (__bridge MXKeysManager *)context;
    if (!self || reportLength < 5) return;
    if (report[0] != HIDPP_REPORT_ID_LONG) return;
    if (report[1] != DEVICE_INDEX_DIRECT) return;

    printf("[MXKeys] HID++ [%2ld]: ", (long)reportLength);
    for (int i = 0; i < reportLength && i < 12; i++) printf("%02X ", report[i]);
    printf("\n");
    fflush(stdout);

    // HID++ response: report[3] = (function << 4) | SWID.
    // SWID lives in the LOW nibble.
    uint8_t function = (report[3] >> 4) & 0x0F;
    uint8_t swid     = report[3] & 0x0F;
    if (swid != SWID) return;

    // ---- Feature index replies on feature 0x00 ----
    if (report[2] == 0x00) {
        uint8_t idx = report[4];

        if (self.awaitingHostIndex) {
            self.awaitingHostIndex = NO;
            if (idx == 0 || idx == 0xFF) {
                printf("[MXKeys] ChangeHost not present\n");
                fflush(stdout);
                return;
            }
            self.changeHostIndex = idx;
            self.changeHostIndexFound = YES;
            printf("[MXKeys] ChangeHost index: 0x%02X\n", idx);
            fflush(stdout);
            [self performSelector:@selector(lookupBattery) withObject:nil afterDelay:0.5];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];
            return;
        }

        if (self.awaitingBatteryIndex) {
            self.awaitingBatteryIndex = NO;
            if (idx == 0 || idx == 0xFF) {
                if (self.batteryIsUnified) {
                    printf("[MXKeys] UnifiedBattery not present, trying BatteryStatus (0x1000)\n");
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
                printf("[MXKeys] No battery feature on this device\n");
                self.batteryLookupDone = YES;
                fflush(stdout);
                return;
            }
            self.batteryIndex = idx;
            self.batteryLookupDone = YES;
            printf("[MXKeys] Battery index: 0x%02X (feature 0x%04X)\n",
                   idx, self.batteryIsUnified ? 0x1004 : 0x1000);
            fflush(stdout);
            [self performSelector:@selector(readBattery) withObject:nil afterDelay:0.3];
            return;
        }
    }

    // ---- Battery value reply ----
    if (self.awaitingBatteryValue && self.batteryIndex != 0 && report[2] == self.batteryIndex) {
        uint8_t raw = report[4];
        BOOL ok = NO;
        int pct = -1;

        // MX Keys Mini's 0x1004 reports the percentage directly in byte 4,
        // WITHOUT setting the "valid" flag in byte 5 that the MX Master
        // mouse sets. So accept any 1..100 value as the percentage.
        if (raw > 0 && raw <= 100) {
            pct = raw;
            ok = YES;
        } else if (raw == 0) {
            // Level enum 0 = "unavailable" — keep last
            ok = NO;
        }

        if (ok) {
            int snapped;
            if (pct >= 90) snapped = 100;
            else if (pct >= 65) snapped = 80;
            else if (pct >= 30) snapped = 50;
            else snapped = 10;
            self.batteryLevel = snapped;
            self.batteryLevelString = [NSString stringWithFormat:@"%d%%", snapped];
            self.cachedBatteryLevel = snapped;
            self.cachedBatteryString = self.batteryLevelString;
            printf("[MXKeys] Battery: %d%% (raw %d)\n", snapped, pct);
        } else {
            printf("[MXKeys] Battery read inconclusive, keeping last\n");
        }

        self.awaitingBatteryValue = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];
        fflush(stdout);
        return;
    }

    // ---- Unsolicited battery notifications on the battery feature ----
    // These arrive with function 0x00 and are not a reply to our request.
    if (self.batteryIndex != 0 && report[2] == self.batteryIndex && function == 0x00) {
        uint8_t raw = report[4];
        if (raw > 0 && raw <= 100) {
            int snapped;
            if (raw >= 90) snapped = 100;
            else if (raw >= 65) snapped = 80;
            else if (raw >= 30) snapped = 50;
            else snapped = 10;
            self.batteryLevel = snapped;
            self.batteryLevelString = [NSString stringWithFormat:@"%d%%", snapped];
            self.cachedBatteryLevel = snapped;
            self.cachedBatteryString = self.batteryLevelString;
            printf("[MXKeys] Battery update (pushed): %d%% (raw %d)\n", snapped, raw);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];
            fflush(stdout);
        }
    }
}

- (void)registerInputReport:(IOHIDDeviceRef)device {
    if (self.inputReportRegistered || !self.inputReport) return;
    IOHIDDeviceRegisterInputReportCallback(device, self.inputReport, self.inputReportSize,
                                            HIDInputReportCallback, (__bridge void *)self);
    self.inputReportRegistered = YES;
    printf("[MXKeys] Input report callback registered\n");
    fflush(stdout);
}

- (void)lookupChangeHost {
    if (!self.hidDevice) return;
    if (self.changeHostIndex != 0) return;
    if (self.awaitingHostIndex) return;

    printf("[MXKeys] Looking up CHANGE_HOST (0x1814)\n");
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
        printf("[MXKeys] ChangeHost write failed: %d\n", r);
        self.awaitingHostIndex = NO;
        fflush(stdout);
    }
}

- (void)lookupBattery {
    if (!self.hidDevice) return;
    if (self.batteryIndex != 0) return;
    if (self.awaitingBatteryIndex) return;
    if (self.batteryLookupDone) return;

    self.batteryIsUnified = YES;
    printf("[MXKeys] Looking up UNIFIED_BATTERY (0x1004)\n");
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
        printf("[MXKeys] Battery write failed: %d\n", r);
        self.awaitingBatteryIndex = NO;
        fflush(stdout);
    }
}

- (void)readBattery {
    if (!self.deviceReady || !self.hidDevice) return;
    if (self.batteryIndex == 0) return;

    self.awaitingBatteryValue = YES;

    uint8_t fn = self.batteryIsUnified ? FUNCTION_GET_BATTERY_UNIFIED
                                        : FUNCTION_GET_BATTERY_STATUS;
    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.batteryIndex;
    cmd[3] = (uint8_t)((fn << 4) | SWID);

    IOReturn r = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (r != kIOReturnSuccess) {
        self.awaitingBatteryValue = NO;
    }
}

- (void)switchToChannelDirect:(int)channel {
    if (!self.running) { printf("[MXKeys] ❌ App not running\n"); return; }
    if (!self.deviceReady || !self.hidDevice) { printf("[MXKeys] ❌ Keyboard not connected\n"); return; }
    if (!self.changeHostIndexFound) { printf("[MXKeys] ❌ ChangeHost feature not discovered yet\n"); return; }
    if (channel < 0 || channel > 2) { printf("[MXKeys] ❌ Invalid channel: %d\n", channel); return; }

    self.switching = YES;
    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.changeHostIndex;
    cmd[3] = (uint8_t)((FUNCTION_SET_HOST << 4) | SWID);
    cmd[4] = (uint8_t)channel;
    cmd[5] = 0x00;

    printf("[MXKeys] Switching to host %d\n", channel + 1);
    fflush(stdout);

    IOReturn result = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (result == kIOReturnSuccess) {
        printf("[MXKeys] ✅ Switch to host %d sent\n", channel + 1);
    } else {
        printf("[MXKeys] ❌ Send failed (%d)\n", result);
    }
    self.switching = NO;
    fflush(stdout);
}

- (int)batteryLevel {
    if (_batteryLevel >= 0) return _batteryLevel;
    return self.cachedBatteryLevel;
}
- (NSString *)batteryLevelString {
    if (_batteryLevel >= 0) return _batteryLevelString;
    return self.cachedBatteryString;
}

- (void)dealloc { [self stop]; }

@end
