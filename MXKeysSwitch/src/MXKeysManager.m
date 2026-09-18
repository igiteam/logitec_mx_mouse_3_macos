#import "MXKeysManager.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOKitLib.h>

// ============================================
// CONFIGURATION
// ============================================

#define LOGITECH_VID 0x046D
// MX Keys Mini Bluetooth PID
#define MX_KEYS_MINI_PID 0xB369
// MX Keys Mini (for Mac) PID variant
#define MX_KEYS_MINI_MAC_PID 0xB36A

// HID++ 2.0 over Bluetooth
#define HIDPP_REPORT_ID_LONG 0x11
#define DEVICE_INDEX_DIRECT 0xFF
#define SWID 0x0A

#define FEATURE_ROOT 0x0000
#define FEATURE_CHANGE_HOST 0x1814
#define FEATURE_UNIFIED_BATTERY 0x1004
#define FUNCTION_GET_FEATURE 0x00
#define FUNCTION_GET_HOST 0x00
#define FUNCTION_SET_HOST 0x01
#define FUNCTION_GET_BATTERY 0x01

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
@property (nonatomic, assign, readwrite) int batteryLevel;
@property (nonatomic, strong, readwrite) NSString *batteryLevelString;
@property (nonatomic, assign) int foundDevices;
@property (nonatomic, assign) BOOL switching;
@property (nonatomic, assign) uint8_t *inputReport;
@property (nonatomic, assign) size_t inputReportSize;
@property (nonatomic, assign) BOOL inputReportRegistered;
@property (nonatomic, assign) BOOL awaitingHostIndex;
@property (nonatomic, assign) BOOL awaitingBatteryIndex;
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
        _batteryLevel = -1;
        _batteryLevelString = @"--";
        _foundDevices = 0;
        _switching = NO;
        _inputReportRegistered = NO;
        _awaitingHostIndex = NO;
        _awaitingBatteryIndex = NO;
        _inputReportSize = 64;
        _inputReport = malloc(_inputReportSize);
        if (_inputReport) memset(_inputReport, 0, _inputReportSize);

        printf("[MXKeys] =========================================\n");
        printf("[MXKeys] MX Keys Mini Host Switcher\n");
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

    printf("[MXKeys] Running - use menu bar to switch host\n");
    fflush(stdout);
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
    self.inputReportRegistered = NO;
    self.changeHostIndexFound = NO;

    if (self.inputReport) {
        free(self.inputReport);
        self.inputReport = NULL;
    }

    printf("[MXKeys] Stopped\n");
    fflush(stdout);
}

- (void)setupHIDManager {
    self.hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

    // Match ANY Logitech device - we filter by name in the callback
    NSDictionary *criteria = @{
        @"VendorID": @(LOGITECH_VID)
    };
    IOHIDManagerSetDeviceMatching(self.hidManager, (__bridge CFDictionaryRef)criteria);

    IOHIDManagerRegisterDeviceMatchingCallback(self.hidManager,
                                                HIDDeviceMatchingCallback,
                                                (__bridge void *)self);

    IOHIDManagerRegisterDeviceRemovalCallback(self.hidManager,
                                               HIDDeviceRemovalCallback,
                                               (__bridge void *)self);

    IOHIDManagerScheduleWithRunLoop(self.hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(self.hidManager, kIOHIDOptionsTypeNone);

    printf("[MXKeys] Scanning for Logitech devices...\n");
    fflush(stdout);
}

static void HIDDeviceMatchingCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    MXKeysManager *self = (__bridge MXKeysManager *)context;
    if (!device || !self) return;

    CFStringRef productRef = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    CFNumberRef pidRef = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));

    NSString *name = productRef ? (__bridge NSString *)productRef : @"Unknown";
    int pid = 0;
    if (pidRef) CFNumberGetValue(pidRef, kCFNumberIntType, &pid);

    self.foundDevices++;
    printf("[MXKeys] Found HID device %d: %s (PID 0x%04X)\n",
           self.foundDevices, [name UTF8String], pid);

    // Match MX Keys Mini by name OR by PID
    BOOL isMXKeysMini = [name containsString:@"MX Keys Mini"] ||
                        [name containsString:@"MX Keys"] ||
                        (pid == MX_KEYS_MINI_PID) ||
                        (pid == MX_KEYS_MINI_MAC_PID);

    if (!isMXKeysMini) {
        fflush(stdout);
        return;
    }

    printf("[MXKeys] ✅ Found MX Keys Mini: %s (PID 0x%04X)\n",
           [name UTF8String], pid);
    fflush(stdout);

    self.hidDevice = device;
    self.deviceReady = YES;
    self.deviceConnected = YES;
    self.deviceName = name;

    [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];

    [self registerInputReport:device];
    [self discoverFeatures:device];
}

static void HIDDeviceRemovalCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    MXKeysManager *self = (__bridge MXKeysManager *)context;
    if (device == self.hidDevice) {
        printf("[MXKeys] ❌ Keyboard removed!\n");
        self.hidDevice = NULL;
        self.deviceReady = NO;
        self.deviceConnected = NO;
        self.deviceName = @"Not connected";
        self.changeHostIndex = 0;
        self.changeHostIndexFound = NO;
        self.batteryIndex = 0;
        self.batteryLevel = -1;
        self.batteryLevelString = @"--";
        self.inputReportRegistered = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];
        fflush(stdout);
    }
}

static void HIDInputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                    uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    MXKeysManager *self = (__bridge MXKeysManager *)context;
    if (!self || reportLength < 4) return;

    printf("[MXKeys] 📥 Response (%ld bytes): ", (long)reportLength);
    for (int i = 0; i < reportLength && i < 16; i++) printf("%02X ", report[i]);
    printf("\n");
    fflush(stdout);

    // HID++ 2.0 long report
    if (report[0] != HIDPP_REPORT_ID_LONG) return;

    uint8_t featureIndex = report[2];
    uint8_t functionId = report[3] & 0x0F;   // low nibble = function
    uint8_t swid = (report[3] >> 4) & 0x0F;  // high nibble = software id

    if (swid != SWID) return;

    // ---- Response to feature lookup ----
    if (self.awaitingHostIndex) {
        // Function 0x00 = getFeature response
        // report[4] = feature index (0 if not found)
        uint8_t idx = report[4];
        if (idx != 0x00 && idx != 0xFF) {
            self.changeHostIndex = idx;
            self.changeHostIndexFound = YES;
            printf("[MXKeys] ✅ ChangeHost feature index: 0x%02X\n", idx);
        } else {
            printf("[MXKeys] ⚠️ ChangeHost feature not found on this device\n");
        }
        self.awaitingHostIndex = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];
        fflush(stdout);
        return;
    }

    if (self.awaitingBatteryIndex) {
        uint8_t idx = report[4];
        if (idx != 0x00 && idx != 0xFF) {
            self.batteryIndex = idx;
            printf("[MXKeys] ✅ Battery feature index: 0x%02X\n", idx);
        } else {
            printf("[MXKeys] ⚠️ Battery feature not found\n");
        }
        self.awaitingBatteryIndex = NO;
        fflush(stdout);
        return;
    }

    // ---- Response to getHost / setHost ----
    if (featureIndex == self.changeHostIndex && functionId == FUNCTION_GET_HOST) {
        uint8_t currentHost = report[4];
        printf("[MXKeys] 🔘 Current host: %d\n", currentHost + 1);
        fflush(stdout);
        return;
    }

    // ---- Response to battery ----
    if (featureIndex == self.batteryIndex && functionId == FUNCTION_GET_BATTERY) {
        // UnifiedBattery (0x1004) response:
        // report[4] = battery level (0-100) OR level enum depending on capability
        // report[5] = flags
        // report[6] = status
        uint8_t level = report[4];
        uint8_t flags = report[5];

        // Bit 7 of flags indicates "state of charge" is available
        BOOL hasPercentage = (flags & 0x80) != 0;

        if (hasPercentage && level <= 100) {
            self.batteryLevel = level;
            self.batteryLevelString = [NSString stringWithFormat:@"%d%%", level];
            printf("[MXKeys] 🔋 Battery: %d%%\n", level);
        } else {
            // Level enum: 0=empty, 1=critical, 2=low, 4=good, 8=full
            NSString *levelStr = @"--";
            if (level == 1) levelStr = @"Critical";
            else if (level == 2) levelStr = @"Low";
            else if (level == 4) levelStr = @"Good";
            else if (level == 8) levelStr = @"Full";
            self.batteryLevel = -1;
            self.batteryLevelString = levelStr;
            printf("[MXKeys] 🔋 Battery level: %s\n", [levelStr UTF8String]);
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];
        fflush(stdout);
        return;
    }
}

- (void)registerInputReport:(IOHIDDeviceRef)device {
    if (self.inputReportRegistered || !self.inputReport) return;

    IOHIDDeviceRegisterInputReportCallback(
        device,
        self.inputReport,
        self.inputReportSize,
        HIDInputReportCallback,
        (__bridge void *)self
    );
    self.inputReportRegistered = YES;
    printf("[MXKeys] 📡 Input report callback registered\n");
    fflush(stdout);
}

- (void)discoverFeatures:(IOHIDDeviceRef)device {
    printf("[MXKeys] 🔍 Discovering features...\n");
    fflush(stdout);

    // -------- Look up ChangeHost (0x1814) --------
    self.awaitingHostIndex = YES;

    uint8_t lookupHost[20] = {0};
    lookupHost[0] = HIDPP_REPORT_ID_LONG;
    lookupHost[1] = DEVICE_INDEX_DIRECT;
    lookupHost[2] = 0x00;  // IRoot
    lookupHost[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
    lookupHost[4] = 0x18;  // feature id high byte
    lookupHost[5] = 0x14;  // feature id low byte

    printf("[MXKeys] 📤 Lookup CHANGE_HOST (0x1814)\n");
    fflush(stdout);

    IOReturn result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, lookupHost, 20);
    if (result != kIOReturnSuccess) {
        printf("[MXKeys] ⚠️ ChangeHost lookup failed (%d)\n", result);
        self.awaitingHostIndex = NO;
    }
    usleep(300000);

    // -------- Look up UnifiedBattery (0x1004) --------
    self.awaitingBatteryIndex = YES;

    uint8_t lookupBattery[20] = {0};
    lookupBattery[0] = HIDPP_REPORT_ID_LONG;
    lookupBattery[1] = DEVICE_INDEX_DIRECT;
    lookupBattery[2] = 0x00;
    lookupBattery[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
    lookupBattery[4] = 0x10;
    lookupBattery[5] = 0x04;

    printf("[MXKeys] 📤 Lookup UNIFIED_BATTERY (0x1004)\n");
    fflush(stdout);

    result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, lookupBattery, 20);
    if (result != kIOReturnSuccess) {
        printf("[MXKeys] ⚠️ Battery lookup failed (%d)\n", result);
        self.awaitingBatteryIndex = NO;
    }
    usleep(300000);

    // Give responses time to arrive, then read battery
    [self performSelector:@selector(readBattery) withObject:nil afterDelay:1.5];
    [self performSelector:@selector(readCurrentHost) withObject:nil afterDelay:0.5];
}

- (void)readCurrentHost {
    if (!self.deviceReady || !self.hidDevice || !self.changeHostIndexFound) return;

    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.changeHostIndex;
    cmd[3] = (uint8_t)((FUNCTION_GET_HOST << 4) | SWID);

    printf("[MXKeys] 📤 Querying current host\n");
    fflush(stdout);

    IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
}

- (void)readBattery {
    if (!self.deviceReady || !self.hidDevice) return;
    if (self.batteryIndex == 0) {
        printf("[MXKeys] ⚠️ Battery feature index unknown, skipping\n");
        return;
    }

    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.batteryIndex;
    cmd[3] = (uint8_t)((FUNCTION_GET_BATTERY << 4) | SWID);

    printf("[MXKeys] 📤 Battery request\n");
    fflush(stdout);

    IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
}

- (void)switchToChannelDirect:(int)channel {
    if (!self.running) {
        printf("[MXKeys] ❌ App not running\n");
        return;
    }

    if (!self.deviceReady || !self.hidDevice) {
        printf("[MXKeys] ❌ Keyboard not connected\n");
        return;
    }

    if (!self.changeHostIndexFound) {
        printf("[MXKeys] ❌ ChangeHost feature index not discovered yet - try again in a moment\n");
        return;
    }

    if (channel < 0 || channel > 2) {
        printf("[MXKeys] ❌ Invalid channel: %d\n", channel);
        return;
    }

    self.switching = YES;

    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.changeHostIndex;
    cmd[3] = (uint8_t)((FUNCTION_SET_HOST << 4) | SWID);
    cmd[4] = (uint8_t)channel;  // 0 = host 1, 1 = host 2, 2 = host 3
    cmd[5] = 0x00;

    printf("[MXKeys] 📤 Switch to host %d: ", channel + 1);
    for (int i = 0; i < 8; i++) printf("%02X ", cmd[i]);
    printf("\n");
    fflush(stdout);

    IOReturn result = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (result == kIOReturnSuccess) {
        printf("[MXKeys] ✅ Switch to host %d sent!\n", channel + 1);
    } else {
        printf("[MXKeys] ❌ Send failed (error: %d)\n", result);
    }

    self.switching = NO;
    fflush(stdout);
}

- (void)dealloc {
    [self stop];
}

@end
