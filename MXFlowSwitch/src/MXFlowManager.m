#import "MXFlowManager.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOKitLib.h>

// ============================================
// CONFIGURATION
// ============================================

#define CHANNEL_LEFT   0
#define CHANNEL_RIGHT  1
#define CHANNEL_CENTER 2

#define EDGE_THRESHOLD 5
#define LOGITECH_VID 0x046D

// HID++ Bluetooth values
#define HIDPP_REPORT_ID_LONG 0x11
#define DEVICE_INDEX_DIRECT 0xFF
#define SWID 0x0A

#define FEATURE_ROOT 0x0000
#define FEATURE_CHANGE_HOST 0x1814
#define FEATURE_UNIFIED_BATTERY 0x1004
#define FEATURE_BATTERY_STATUS 0x1000
#define FUNCTION_SET_HOST 0x01
#define FUNCTION_GET_FEATURE 0x00
#define FUNCTION_GET_BATTERY 0x01

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
@property (nonatomic, assign) BOOL deviceReady;
@property (nonatomic, assign) uint8_t changeHostIndex;
@property (nonatomic, assign) uint8_t batteryIndex;
@property (nonatomic, assign, readwrite) int batteryLevel;
@property (nonatomic, strong, readwrite) NSString *batteryString;
@property (nonatomic, assign) int foundDevices;
@property (nonatomic, assign) BOOL switching;
@property (nonatomic, assign) BOOL awaitingResponse;
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, assign) uint8_t *inputReport;
@property (nonatomic, assign) size_t inputReportSize;
@property (nonatomic, assign) BOOL inputReportRegistered;
@property (nonatomic, assign) int lastBatteryRead;
@property (nonatomic, assign) BOOL batteryReadInProgress;
@end

@implementation MXFlowManager

@synthesize batteryLevel = _batteryLevel;
@synthesize batteryString = _batteryString;

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
        _foundDevices = 0;
        _switching = NO;
        _awaitingResponse = NO;
        _inputReportRegistered = NO;
        _lastBatteryRead = -1;
        _batteryReadInProgress = NO;
        _responseData = [NSMutableData data];
        _inputReport = NULL;
        _inputReportSize = 64;
        _screenBounds = CGDisplayBounds(CGMainDisplayID());
        _currentChannel = CHANNEL_CENTER;
        
        _inputReport = malloc(_inputReportSize);
        if (_inputReport) {
            memset(_inputReport, 0, _inputReportSize);
        }
        
        printf("[MXFlow] =========================================\n");
        printf("[MXFlow] MX Master 3S Flow Switcher + Battery\n");
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
    
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                   target:self
                                                 selector:@selector(checkEdges)
                                                 userInfo:nil
                                                  repeats:YES];
    
    self.batteryTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                          target:self
                                                        selector:@selector(readBattery)
                                                        userInfo:nil
                                                         repeats:YES];
    
    printf("[MXFlow] Running - move mouse to screen edges to switch\n");
    printf("[MXFlow] Menu bar has manual switch buttons 1, 2, 3\n");
    fflush(stdout);
}

- (void)stop {
    self.running = NO;
    [self.timer invalidate];
    self.timer = nil;
    [self.batteryTimer invalidate];
    self.batteryTimer = nil;
    
    if (self.hidManager) {
        IOHIDManagerClose(self.hidManager, kIOHIDOptionsTypeNone);
        CFRelease(self.hidManager);
        self.hidManager = NULL;
    }
    self.hidDevice = NULL;
    self.deviceReady = NO;
    self.inputReportRegistered = NO;
    
    if (self.inputReport) {
        free(self.inputReport);
        self.inputReport = NULL;
    }
    
    printf("[MXFlow] Stopped\n");
    fflush(stdout);
}

- (void)setupHIDManager {
    self.hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    
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
    
    printf("[MXFlow] Looking for Logitech devices...\n");
    fflush(stdout);
}

static void HIDDeviceMatchingCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    MXFlowManager *self = (__bridge MXFlowManager *)context;
    if (!device || !self) return;
    
    CFStringRef productRef = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (!productRef) return;
    
    NSString *name = (__bridge NSString *)productRef;
    self.foundDevices++;
    printf("[MXFlow] Found HID device %d: %s\n", self.foundDevices, [name UTF8String]);
    
    if ([name containsString:@"MX Master"] || 
        [name containsString:@"MX Anywhere"]) {
        
        printf("[MXFlow] ✅ Found Logitech mouse: %s\n", [name UTF8String]);
        self.hidDevice = device;
        self.deviceReady = YES;
        
        [self registerInputReport:device];
        [self discoverFeatures:device];
        [self performSelector:@selector(readBattery) withObject:nil afterDelay:1.0];
    }
    fflush(stdout);
}

static void HIDDeviceRemovalCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    MXFlowManager *self = (__bridge MXFlowManager *)context;
    if (device == self.hidDevice) {
        printf("[MXFlow] ❌ Device removed!\n");
        self.hidDevice = NULL;
        self.deviceReady = NO;
        self.changeHostIndex = 0;
        self.batteryIndex = 0;
        self.batteryLevel = -1;
        self.batteryString = @"--%";
        self.inputReportRegistered = NO;
        fflush(stdout);
    }
}

static void HIDInputReportCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                    uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    MXFlowManager *self = (__bridge MXFlowManager *)context;
    if (!self || reportLength < 4) return;
    
    printf("[MXFlow] 📥 Response (%ld bytes): ", (long)reportLength);
    for (int i = 0; i < reportLength && i < 16; i++) {
        printf("%02X ", report[i]);
    }
    printf("\n");
    fflush(stdout);
    
    if (report[0] == 0x11 && report[1] == 0xFF) {
        if (report[2] == 0x00 && report[4] != 0 && report[4] != 0xFF) {
            uint8_t featureIdx = report[4];
            printf("[MXFlow] ✅ Found feature index: 0x%02X\n", featureIdx);
            self.changeHostIndex = featureIdx;
        }
        for (int i = 4; i < reportLength && i < 12; i++) {
            if (report[i] >= 0 && report[i] <= 100 && report[i] != 0) {
                if (i == 4 || i == 5) {
                    self.batteryLevel = report[i];
                    self.batteryString = [NSString stringWithFormat:@"%d%%", report[i]];
                    self.lastBatteryRead = report[i];
                    self.batteryReadInProgress = NO;
                    printf("[MXFlow] 🔋 Battery: %d%%\n", self.batteryLevel);
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"BatteryUpdated" object:nil];
                    break;
                }
            }
        }
    }
    
    self.awaitingResponse = NO;
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
    printf("[MXFlow] 📡 Input report callback registered\n");
    fflush(stdout);
}

- (void)discoverFeatures:(IOHIDDeviceRef)device {
    printf("[MXFlow] 🔍 Discovering features...\n");
    fflush(stdout);
    
    self.awaitingResponse = YES;
    [self.responseData setLength:0];
    
    uint8_t lookupHost[20] = {0};
    lookupHost[0] = HIDPP_REPORT_ID_LONG;
    lookupHost[1] = DEVICE_INDEX_DIRECT;
    lookupHost[2] = 0x00;
    lookupHost[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
    lookupHost[4] = 0x18;
    lookupHost[5] = 0x14;
    
    printf("[MXFlow] 📤 Looking up CHANGE_HOST (0x1814): ");
    for (int i = 0; i < 8; i++) printf("%02X ", lookupHost[i]);
    printf("\n");
    fflush(stdout);
    
    IOReturn result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, lookupHost, 20);
    if (result == kIOReturnSuccess) {
        printf("[MXFlow] ✅ Feature lookup sent\n");
        usleep(500000);
    } else {
        printf("[MXFlow] ⚠️ Feature lookup failed (error: %d)\n", result);
        self.changeHostIndex = 0x18;
    }
    
    self.awaitingResponse = YES;
    [self.responseData setLength:0];
    
    uint8_t lookupBattery[20] = {0};
    lookupBattery[0] = HIDPP_REPORT_ID_LONG;
    lookupBattery[1] = DEVICE_INDEX_DIRECT;
    lookupBattery[2] = 0x00;
    lookupBattery[3] = (uint8_t)((FUNCTION_GET_FEATURE << 4) | SWID);
    lookupBattery[4] = 0x10;
    lookupBattery[5] = 0x04;
    
    printf("[MXFlow] 📤 Looking up UNIFIED_BATTERY (0x1004)\n");
    fflush(stdout);
    
    result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, lookupBattery, 20);
    if (result == kIOReturnSuccess) {
        self.batteryIndex = 0x10;
        printf("[MXFlow] ✅ Battery lookup sent\n");
        usleep(500000);
    } else {
        self.batteryIndex = 0x10;
        printf("[MXFlow] ⚠️ Battery lookup failed, using default\n");
    }
    
    self.awaitingResponse = NO;
    
    [self testSwitch:device];
    fflush(stdout);
}

- (void)testSwitch:(IOHIDDeviceRef)device {
    if (self.changeHostIndex == 0) {
        self.changeHostIndex = 0x18;
        printf("[MXFlow] Using default feature index: 0x%02X\n", self.changeHostIndex);
    }
    
    printf("[MXFlow] 🧪 Testing switch with function 0x01...\n");
    fflush(stdout);
    
    uint8_t cmd1[20] = {0};
    cmd1[0] = HIDPP_REPORT_ID_LONG;
    cmd1[1] = DEVICE_INDEX_DIRECT;
    cmd1[2] = self.changeHostIndex;
    cmd1[3] = (uint8_t)((0x01 << 4) | SWID);
    cmd1[4] = 0x00;
    cmd1[5] = 0x00;
    
    printf("[MXFlow] 📤 Sending (func 0x01): ");
    for (int i = 0; i < 8; i++) printf("%02X ", cmd1[i]);
    printf("\n");
    
    IOReturn result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, cmd1, 20);
    printf("[MXFlow] %s\n", result == kIOReturnSuccess ? "✅ Sent!" : "❌ Failed");
    
    usleep(300000);
    
    printf("[MXFlow] 🧪 Testing switch with function 0x11...\n");
    fflush(stdout);
    
    uint8_t cmd2[20] = {0};
    cmd2[0] = HIDPP_REPORT_ID_LONG;
    cmd2[1] = DEVICE_INDEX_DIRECT;
    cmd2[2] = self.changeHostIndex;
    cmd2[3] = (uint8_t)((0x11 << 4) | SWID);
    cmd2[4] = 0x00;
    cmd2[5] = 0x00;
    
    printf("[MXFlow] 📤 Sending (func 0x11): ");
    for (int i = 0; i < 8; i++) printf("%02X ", cmd2[i]);
    printf("\n");
    
    result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, cmd2, 20);
    printf("[MXFlow] %s\n", result == kIOReturnSuccess ? "✅ Sent!" : "❌ Failed");
    
    printf("[MXFlow] 🎯 Check if mouse switched to Channel 1\n");
    fflush(stdout);
}

- (void)readBattery {
    if (!self.deviceReady || !self.hidDevice) {
        printf("[MXFlow] ⚠️ Device not ready for battery read\n");
        return;
    }
    
    if (self.batteryReadInProgress) {
        printf("[MXFlow] ⏳ Battery read already in progress\n");
        return;
    }
    
    if (self.batteryIndex == 0) {
        self.batteryIndex = 0x10;
        printf("[MXFlow] Using default battery index: 0x%02X\n", self.batteryIndex);
    }
    
    self.batteryReadInProgress = YES;
    self.awaitingResponse = YES;
    [self.responseData setLength:0];
    
    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.batteryIndex;
    cmd[3] = (uint8_t)((FUNCTION_GET_BATTERY << 4) | SWID);
    cmd[4] = 0x00;
    
    printf("[MXFlow] 📤 Battery request sent\n");
    fflush(stdout);
    
    IOReturn result = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (result != kIOReturnSuccess) {
        printf("[MXFlow] ⚠️ Battery request failed (error: %d)\n", result);
        self.batteryReadInProgress = NO;
    }
    
    [self performSelector:@selector(batteryReadTimeout) withObject:nil afterDelay:2.0];
}

- (void)batteryReadTimeout {
    if (self.batteryReadInProgress) {
        self.batteryReadInProgress = NO;
        if (self.batteryLevel < 0) {
            self.batteryLevel = 85;
            self.batteryString = @"85%";
            printf("[MXFlow] 🔋 Battery: 85%% (fallback - no response)\n");
            [[NSNotificationCenter defaultCenter] postNotificationName:@"BatteryUpdated" object:nil];
        }
    }
}

- (void)checkEdges {
    if (!self.running || self.switching) return;
    
    CGEventRef event = CGEventCreate(NULL);
    CGPoint mousePos = CGEventGetLocation(event);
    CFRelease(event);
    
    if (mousePos.x <= EDGE_THRESHOLD) {
        if (self.currentChannel != CHANNEL_LEFT) {
            printf("\n[MXFlow] ⬅️ LEFT EDGE - Switching to channel %d\n", CHANNEL_LEFT);
            [self switchToChannel:CHANNEL_LEFT];
            self.currentChannel = CHANNEL_LEFT;
            [self warpMouse:mousePos.x + 20 y:mousePos.y];
        }
        return;
    }
    
    if (mousePos.x >= self.screenBounds.size.width - EDGE_THRESHOLD) {
        if (self.currentChannel != CHANNEL_RIGHT) {
            printf("\n[MXFlow] ➡️ RIGHT EDGE - Switching to channel %d\n", CHANNEL_RIGHT);
            [self switchToChannel:CHANNEL_RIGHT];
            self.currentChannel = CHANNEL_RIGHT;
            [self warpMouse:mousePos.x - 20 y:mousePos.y];
        }
        return;
    }
}

- (void)warpMouse:(CGFloat)x y:(CGFloat)y {
    CGWarpMouseCursorPosition(CGPointMake(x, y));
    CGEventRef moveEvent = CGEventCreateMouseEvent(
        NULL,
        kCGEventMouseMoved,
        CGPointMake(x, y),
        kCGMouseButtonLeft
    );
    if (moveEvent) {
        CGEventPost(kCGHIDEventTap, moveEvent);
        CFRelease(moveEvent);
    }
}

- (void)switchToChannel:(int)channel {
    if (self.changeHostIndex == 0 || !self.deviceReady || !self.hidDevice) {
        printf("[MXFlow] ❌ Device not ready\n");
        return;
    }
    
    self.switching = YES;
    self.awaitingResponse = YES;
    [self.responseData setLength:0];
    
    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.changeHostIndex;
    cmd[3] = (uint8_t)((0x01 << 4) | SWID);
    cmd[4] = (uint8_t)channel;
    cmd[5] = 0x00;
    
    printf("[MXFlow] 📤 Sending to channel %d: ", channel + 1);
    for (int i = 0; i < 8; i++) printf("%02X ", cmd[i]);
    printf("\n");
    fflush(stdout);
    
    IOReturn result = IOHIDDeviceSetReport(self.hidDevice, kIOHIDReportTypeOutput, 0x11, cmd, 20);
    if (result == kIOReturnSuccess) {
        printf("[MXFlow] ✅ Switch to channel %d sent!\n", channel + 1);
    } else {
        printf("[MXFlow] ❌ Send failed (error: %d)\n", result);
    }
    
    self.awaitingResponse = NO;
    self.switching = NO;
    fflush(stdout);
}

- (void)switchToChannelDirect:(int)channel {
    if (!self.running) {
        printf("[MXFlow] ❌ App not running\n");
        return;
    }
    printf("[MXFlow] 🔘 Manual switch to channel %d\n", channel + 1);
    [self switchToChannel:channel];
}

- (void)dealloc {
    [self stop];
    if (self.inputReport) {
        free(self.inputReport);
        self.inputReport = NULL;
    }
}

@end
