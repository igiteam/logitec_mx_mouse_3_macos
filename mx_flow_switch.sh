#!/bin/bash
# MX Master 3 - Offline Flow Switcher for macOS
# BATTERY + ICON + TOP-BUTTON 1/2/3 CLICK SWITCHER + EDGES

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║      MX MASTER 3 - OFFLINE FLOW SWITCHER FOR MACOS           ║"
echo "║   BATTERY + TOP BUTTON 1/2/3 CLICK + EDGES                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

APP_NAME="MXFlowSwitch"
BUNDLE_ID="com.github.mxflowswitch"

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/src"
mkdir -p "$APP_NAME/public"
cd "$APP_NAME" || exit

# ===============================================
# DOWNLOAD APP ICON
# ===============================================
echo -e "${CYAN}🎨 Downloading MX Master icon...${NC}"

ICON_URL="https://raw.githubusercontent.com/igiteam/logitec_mx_mouse_3_macos/main/logitec-mx-keys-mini.png"
curl -s -L "$ICON_URL" -o "public/app_icon.png"

if [ -f "public/app_icon.png" ] && [ -s "public/app_icon.png" ]; then
    echo "✅ Icon downloaded successfully!"
    ICONSET_DIR="public/AppIcon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    sips -z 16   16   "public/app_icon.png" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null 2>&1
    sips -z 32   32   "public/app_icon.png" --out "$ICONSET_DIR/icon_16x16@2x.png"   >/dev/null 2>&1
    sips -z 32   32   "public/app_icon.png" --out "$ICONSET_DIR/icon_32x32.png"      >/dev/null 2>&1
    sips -z 64   64   "public/app_icon.png" --out "$ICONSET_DIR/icon_32x32@2x.png"   >/dev/null 2>&1
    sips -z 128  128  "public/app_icon.png" --out "$ICONSET_DIR/icon_128x128.png"    >/dev/null 2>&1
    sips -z 256  256  "public/app_icon.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256  256  "public/app_icon.png" --out "$ICONSET_DIR/icon_256x256.png"    >/dev/null 2>&1
    sips -z 512  512  "public/app_icon.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512  512  "public/app_icon.png" --out "$ICONSET_DIR/icon_512x512.png"    >/dev/null 2>&1
    sips -z 1024 1024 "public/app_icon.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null 2>&1

    if command -v iconutil &> /dev/null && \
       iconutil -c icns "$ICONSET_DIR" -o "public/app_icon.icns" 2>/dev/null; then
        echo "✅ Created .icns file"
    else
        cp "public/app_icon.png" "public/app_icon.icns"
    fi
    rm -rf "$ICONSET_DIR"
else
    echo "⚠ Download failed, creating fallback icon"
    cat > public/app_icon.png.b64 << 'EOF'
iVBORw0KGgoAAAANSUhEUgAAAgAAAAIAAQMAAADOtgr5AAAAAXNSR0IB2cksfwAAAAlwSFlzAAALEwAACxMBAJqcGAAAAANQTFRFAAAAp3o92gAAABxJREFUeJztwTEBAAAAwqD1T20Hb6AAAAAAAAA+Bhw4AAG1cXrRAAAAAElFTkSuQmCC
EOF
    base64 -D < public/app_icon.png.b64 > public/app_icon.png 2>/dev/null || true
    cp public/app_icon.png public/app_icon.icns 2>/dev/null || true
fi

# ===============================================
# SOURCE
# ===============================================

cat > "src/MXFlowManager.h" << 'EOF'
#import <Foundation/Foundation.h>

@interface MXFlowManager : NSObject
@property (nonatomic, assign) BOOL running;
- (void)start;
- (void)stop;
@property (nonatomic, assign, readonly) int batteryLevel;
@property (nonatomic, strong, readonly) NSString *batteryString;
@property (nonatomic, assign, readonly) BOOL deviceReady;
- (void)switchToChannelDirect:(int)channel;
@end
EOF

cat > "src/MXFlowManager.m" << 'EOF'
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
EOF

cat > "src/AppDelegate.h" << 'EOF'
#import <Cocoa/Cocoa.h>
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
EOF

cat > "src/AppDelegate.m" << 'EOF'
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

- (void)switchToChannel1:(id)sender { [self.flowManager switchToChannelDirect:0]; }
- (void)switchToChannel2:(id)sender { [self.flowManager switchToChannelDirect:1]; }
- (void)switchToChannel3:(id)sender { [self.flowManager switchToChannelDirect:2]; }

- (void)updateStatus:(NSString *)status {
    if (self.statusMenuItem) {
        self.statusMenuItem.title = [NSString stringWithFormat:@"Status: %@", status];
    }
}

- (void)updateBatteryDisplay {
    int battery = self.flowManager.batteryLevel;
    if (battery >= 0) {
        self.statusItem.button.title = [NSString stringWithFormat:@"🖱️ %d%%", battery];
        self.statusItem.button.alternateTitle = self.statusItem.button.title;
    } else {
        NSString *s = self.flowManager.batteryString ?: @"--%";
        self.statusItem.button.title = [NSString stringWithFormat:@"🖱️ %@", s];
        self.statusItem.button.alternateTitle = self.statusItem.button.title;
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
EOF

cat > "src/main.m" << 'EOF'
#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
EOF

# ===============================================
# BUILD
# ===============================================

echo -e "${CYAN}🔨 Compiling...${NC}"

APP_BUNDLE="$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/"{MacOS,Resources}

cat > "Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>app_icon</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>MX Flow Switch needs Bluetooth to control your Logitech mouse</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>MX Flow Switch needs Input Monitoring to talk to your Logitech mouse via HID++.</string>
</dict>
</plist>
EOF

cp "Info.plist" "$APP_BUNDLE/Contents/"

if [ -f "public/app_icon.icns" ]; then
    cp "public/app_icon.icns" "$APP_BUNDLE/Contents/Resources/app_icon.icns"
    echo "✅ App icon added"
fi

clang -framework Cocoa -framework Foundation -framework AppKit \
      -framework CoreGraphics -framework IOKit -framework QuartzCore \
      -fobjc-arc -Wno-deprecated-declarations \
      -mmacosx-version-min=11.0 \
      -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" src/*.m 2> build_errors.log

if [ $? -eq 0 ]; then    echo -e "${GREEN}✅ Compilation successful!${NC}"
    rm -f build_errors.log
else
    echo -e "${RED}❌ Compilation failed:${NC}"
    cat build_errors.log
    exit 1
fi

codesign --force --deep --sign - \
         --identifier "$BUNDLE_ID" \
         --options runtime \
         "$APP_BUNDLE" 2>/dev/null || true
xattr -cr "$APP_BUNDLE"

rm -rf "$HOME/Applications/$APP_BUNDLE"
mkdir -p "$HOME/Applications"
cp -R "$APP_BUNDLE" "$HOME/Applications/"

echo -e "\n${GREEN}✅ Built and installed to ~/Applications${NC}"
echo ""
echo "Top button:"
echo "  1 click  → channel 1"
echo "  2 clicks → channel 2"
echo "  3 clicks → channel 3 (fires instantly)"
echo ""
echo "Edges:"
echo "  LEFT  edge → channel 1"
echo "  RIGHT edge → channel 2"
echo "  TOP   edge → channel 3"
echo ""

open "$HOME/Applications/$APP_BUNDLE"