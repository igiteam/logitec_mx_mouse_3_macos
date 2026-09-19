#import "Grace3PlayManager.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOKitLib.h>

// ============================================
// CONFIGURATION
// ============================================

#define LOGITECH_VID 0x046D   // kept for HID probe template
#define GRACE_VID    0x0A12   // common CSR-based BT audio VID — adjust if you know the real one
#define GRACE_PID    0x0001

#define HIDPP_REPORT_ID_LONG 0x11
#define DEVICE_INDEX_DIRECT  0xFF
#define SWID 0x0A

#define FEATURE_ROOT 0x0000
#define FEATURE_CHANGE_HOST 0x1814
#define FEATURE_UNIFIED_BATTERY 0x1004
#define FUNCTION_GET_FEATURE 0x00
#define FUNCTION_SET_HOST 0x01
#define FUNCTION_GET_BATTERY 0x01

// ============================================

static void HIDDeviceMatchingCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void HIDDeviceRemovalCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void HIDInputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                    uint32_t reportID, uint8_t *report, CFIndex reportLength);

@interface Grace3PlayManager ()
@property (nonatomic, assign) IOHIDDeviceRef hidDevice;
@property (nonatomic, assign) IOHIDManagerRef hidManager;
@property (nonatomic, assign) BOOL deviceReady;
@property (nonatomic, assign, readwrite) BOOL deviceConnected;
@property (nonatomic, strong, readwrite) NSString *deviceName;
@property (nonatomic, assign) uint8_t changeHostIndex;
@property (nonatomic, assign) BOOL changeHostIndexFound;
@property (nonatomic, assign) uint8_t batteryIndex;
@property (nonatomic, assign, readwrite) int batteryLevel;
@property (nonatomic, strong, readwrite) NSString *batteryString;
@property (nonatomic, assign) int foundDevices;
@property (nonatomic, assign) BOOL switching;
@property (nonatomic, assign) uint8_t *inputReport;
@property (nonatomic, assign) size_t inputReportSize;
@property (nonatomic, assign) BOOL inputReportRegistered;
@property (nonatomic, assign) BOOL awaitingHostIndex;
@property (nonatomic, assign) BOOL awaitingBatteryIndex;
@end

@implementation Grace3PlayManager

@synthesize deviceConnected = _deviceConnected;
@synthesize deviceName = _deviceName;
@synthesize batteryLevel = _batteryLevel;
@synthesize batteryString = _batteryString;

- (instancetype)init {
    self = [super init];
    if (self) {
        _running = NO;
        _deviceReady = NO;
        _deviceConnected = NO;
        _deviceName = @"Grace 3Play not connected";
        _changeHostIndex = 0;
        _changeHostIndexFound = NO;
        _batteryIndex = 0;
        _batteryLevel = -1;
        _batteryString = @"--";
        _foundDevices = 0;
        _switching = NO;
        _inputReportRegistered = NO;
        _awaitingHostIndex = NO;
        _awaitingBatteryIndex = NO;
        _inputReportSize = 64;
        _inputReport = malloc(_inputReportSize);
        if (_inputReport) memset(_inputReport, 0, _inputReportSize);

        printf("[Grace3Play] =========================================\n");
        printf("[Grace3Play] Grace Digital GDI-BTPB300 Controller\n");
        printf("[Grace3Play] =========================================\n");
        fflush(stdout);
    }
    return self;
}

- (void)start {
    if (self.running) return;
    self.running = YES;

    printf("[Grace3Play] Starting HID manager...\n");
    fflush(stdout);

    [self setupHIDManager];

    printf("[Grace3Play] Running — use menu bar for channels\n");
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

    printf("[Grace3Play] Stopped\n");
    fflush(stdout);
}

- (void)setupHIDManager {
    self.hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

    // Match any device whose name contains "3Play" or "Grace"
    // We can't filter by name in the matching dictionary, so we accept all
    // and filter in the callback.
    NSDictionary *criteria = @{};  // no VID filter — Grace 3Play VID varies by firmware
    IOHIDManagerSetDeviceMatching(self.hidManager, (__bridge CFDictionaryRef)criteria);

    IOHIDManagerRegisterDeviceMatchingCallback(self.hidManager,
                                                HIDDeviceMatchingCallback,
                                                (__bridge void *)self);

    IOHIDManagerRegisterDeviceRemovalCallback(self.hidManager,
                                               HIDDeviceRemovalCallback,
                                               (__bridge void *)self);

    IOHIDManagerScheduleWithRunLoop(self.hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(self.hidManager, kIOHIDOptionsTypeNone);

    printf("[Grace3Play] Scanning for 3Play device...\n");
    fflush(stdout);
}

static void HIDDeviceMatchingCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    Grace3PlayManager *self = (__bridge Grace3PlayManager *)context;
    if (!device || !self) return;

    CFStringRef productRef = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    NSString *name = productRef ? (__bridge NSString *)productRef : @"Unknown";

    self.foundDevices++;
    printf("[Grace3Play] Found HID device %d: %s\n",
           self.foundDevices, [name UTF8String]);
    fflush(stdout);

    // Match by name — 3Play typically enumerates as "3Play" or "Grace Digital"
    BOOL is3Play = [name containsString:@"3Play"] ||
                   [name containsString:@"Grace"] ||
                   [name containsString:@"BTPB300"];

    if (!is3Play) return;

    printf("[Grace3Play] ✅ Found Grace 3Play: %s\n", [name UTF8String]);
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
    Grace3PlayManager *self = (__bridge Grace3PlayManager *)context;
    if (device == self.hidDevice) {
        printf("[Grace3Play] ❌ 3Play removed!\n");
        self.hidDevice = NULL;
        self.deviceReady = NO;
        self.deviceConnected = NO;
        self.deviceName = @"Grace 3Play not connected";
        self.changeHostIndex = 0;
        self.changeHostIndexFound = NO;
        self.batteryIndex = 0;
        self.batteryLevel = -1;
        self.batteryString = @"--";
        self.inputReportRegistered = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];
        fflush(stdout);
    }
}

static void HIDInputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                    uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    Grace3PlayManager *self = (__bridge Grace3PlayManager *)context;
    if (!self || reportLength < 4) return;

    printf("[Grace3Play] 📥 Response (%ld bytes): ", (long)reportLength);
    for (int i = 0; i < reportLength && i < 16; i++) printf("%02X ", report[i]);
    printf("\n");
    fflush(stdout);

    if (report[0] != HIDPP_REPORT_ID_LONG) return;

    uint8_t featureIndex = report[2];
    uint8_t functionId = report[3] & 0x0F;
    uint8_t swid = (report[3] >> 4) & 0x0F;

    if (swid != SWID) return;

    if (self.awaitingHostIndex) {
        uint8_t idx = report[4];
        if (idx != 0x00 && idx != 0xFF) {
            self.changeHostIndex = idx;
            self.changeHostIndexFound = YES;
            printf("[Grace3Play] ✅ ChangeHost feature index: 0x%02X\n", idx);
        } else {
            printf("[Grace3Play] ⚠️ ChangeHost feature not found\n");
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
            printf("[Grace3Play] ✅ Battery feature index: 0x%02X\n", idx);
        } else {
            printf("[Grace3Play] ⚠️ Battery feature not found\n");
        }
        self.awaitingBatteryIndex = NO;
        fflush(stdout);
        return;
    }

    if (featureIndex == self.batteryIndex && functionId == FUNCTION_GET_BATTERY) {
        uint8_t level = report[4];
        uint8_t flags = report[5];
        BOOL hasPercentage = (flags & 0x80) != 0;

        if (hasPercentage && level <= 100) {
            self.batteryLevel = level;
            self.batteryString = [NSString stringWithFormat:@"%d%%", level];
        } else {
            NSString *levelStr = @"--";
            if (level == 1) levelStr = @"Critical";
            else if (level == 2) levelStr = @"Low";
            else if (level == 4) levelStr = @"Good";
            else if (level == 8) levelStr = @"Full";
            self.batteryLevel = -1;
            self.batteryString = levelStr;
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
    printf("[Grace3Play] 📡 Input report callback registered\n");
    fflush(stdout);
}

- (void)discoverFeatures:(IOHIDDeviceRef)device {
    printf("[Grace3Play] 🔍 Discovering features...\n");
    fflush(stdout);

    self.awaitingHostIndex = YES;
    uint8_t lookupHost[20] = {0};
    lookupHost[0] = HIDPP_REPORT_ID_LONG;
    lookupHost[1] = DEVICE_INDEX_DIRECT;
    lookupHost[2] = 0x00;
    lookupHost[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
    lookupHost[4] = 0x18;
    lookupHost[5] = 0x14;
    IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, lookupHost, 20);
    usleep(300000);

    self.awaitingBatteryIndex = YES;
    uint8_t lookupBattery[20] = {0};
    lookupBattery[0] = HIDPP_REPORT_ID_LONG;
    lookupBattery[1] = DEVICE_INDEX_DIRECT;
    lookupBattery[2] = 0x00;
    lookupBattery[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
    lookupBattery[4] = 0x10;
    lookupBattery[5] = 0x04;
    IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, lookupBattery, 20);
    usleep(300000);

    [self performSelector:@selector(readBattery) withObject:nil afterDelay:1.5];
}

- (void)readBattery {
    if (!self.deviceReady || !self.hidDevice) return;
    if (self.batteryIndex == 0) {
        printf("[Grace3Play] ⚠️ Battery feature index unknown, skipping\n");
        return;
    }

    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.batteryIndex;
    cmd[3] = (uint8_t)((FUNCTION_GET_BATTERY << 4) | SWID);

    IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
}

- (void)switchToChannelDirect:(int)channel {
    if (!self.running) {
        printf("[Grace3Play] ❌ App not running\n");
        return;
    }
    if (!self.deviceReady || !self.hidDevice) {
        printf("[Grace3Play] ❌ 3Play not connected\n");
        return;
    }
    if (!self.changeHostIndexFound) {
        printf("[Grace3Play] ❌ ChangeHost feature index not discovered yet\n");
        return;
    }
    if (channel < 0 || channel > 2) {
        printf("[Grace3Play] ❌ Invalid channel: %d\n", channel);
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

    printf("[Grace3Play] 📤 Switch to channel %d: ", channel + 1);
    for (int i = 0; i < 8; i++) printf("%02X ", cmd[i]);
    printf("\n");
    fflush(stdout);

    IOReturn result = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (result == kIOReturnSuccess) {
        printf("[Grace3Play] ✅ Switch to channel %d sent!\n", channel + 1);
    } else {
        printf("[Grace3Play] ❌ Send failed (error: %d)\n", result);
    }

    self.switching = NO;
    fflush(stdout);
}

- (void)dealloc {
    [self stop];
}

@end
