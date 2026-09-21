#!/bin/bash
# MX Master 3 - Offline Flow Switcher for macOS
# TOP BUTTON 1/2/3 + EDGES + BATTERY + STABLE SIGNING

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║      MX MASTER 3 - OFFLINE FLOW SWITCHER FOR MACOS             ║"
echo "║   TOP BUTTON 1/2/3 + EDGES + BATTERY                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

APP_NAME="MXFlowSwitch"
BUNDLE_ID="com.github.mxflowswitch"
SIGN_IDENTITY="MXFlowLocal"

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/src"
mkdir -p "$APP_NAME/public"
cd "$APP_NAME" || exit

# ===============================================
# ICON
# ===============================================
echo -e "${CYAN}🎨 Downloading icon...${NC}"
ICON_URL="https://raw.githubusercontent.com/igiteam/logitec_mx_mouse_3_macos/main/logitec-mx-keys-mini.png"
curl -s -L "$ICON_URL" -o "public/app_icon.png"

if [ -f "public/app_icon.png" ] && [ -s "public/app_icon.png" ]; then
    ICONSET_DIR="public/AppIcon.iconset"
    rm -rf "$ICONSET_DIR"; mkdir -p "$ICONSET_DIR"
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
        echo "✅ .icns created"
    else
        cp "public/app_icon.png" "public/app_icon.icns"
    fi
    rm -rf "$ICONSET_DIR"
else
    echo "⚠ No icon downloaded"
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

// Channel mapping (0-indexed, displayed 1/2/3):
//   Channel 0 = Mac 1
//   Channel 1 = Mac 2
//   Channel 2 = Mac 3
//
// Physical desk layout: Mac 1 (left) ↔ Mac 2 (center) ↔ Mac 3 (right)
//
// CHANNEL_HOME = the channel of the Mac this build runs on.
// For the Mac 1 build it's 0. If you ever build for Mac 2, change it to 1,
// and for Mac 3 to 2. The edge logic is derived from it — no per-Mac
// branching required.
#define CHANNEL_MIN 0
#define CHANNEL_MAX 2
#define CHANNEL_HOME   0

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
        // The mouse only leaves this Mac when a channel switch *actually*
        // took effect (Mac 2/Mac 3 received it). That's the real signal
        // that the edge did its job, so this is where we disarm.
        //
        // If a switch attempt fails (target Mac offline, mouse bounces
        // back to us), no removal callback fires and edgeArmed stays YES,
        // so the user can flick again immediately.
        self.edgeArmed = NO;
        [self.batteryTimer invalidate];
        self.batteryTimer = nil;
        fflush(stdout);
        // NOTE: do NOT reset the battery cache — the mouse will come back
        // on the same channel and we want the menu bar to keep showing the
        // last known reading instead of blanking during the switch.
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
//
//   Left edge  → CHANNEL_HOME - 1  (one Mac to the left in the row)
//   Right edge → CHANNEL_HOME + 1  (one Mac to the right)
//
// On the leftmost Mac, CHANNEL_HOME - 1 is below CHANNEL_MIN, so left does
// nothing. Same for right edge on the rightmost Mac.
//
// IMPORTANT: we use CHANNEL_HOME, not currentChannel, for the math. The
// mouse is either here (deviceReady == YES) or away — we can't tell which
// remote Mac it went to. But when it IS here, we're always on this Mac's
// own channel, so the destination is unambiguously CHANNEL_HOME ± 1.
// Using currentChannel caused the "left edge goes to Mac 3" bug because
// it went stale across device removals.
//
// edgeArmed prevents double-firing when the cursor lands back at an edge
// after a warp. It is re-armed only when the cursor moves well away from
// both edges, and it is disarmed only when the mouse actually leaves this
// Mac (see HIDDeviceRemovalCallback) — not on switch attempts. So if a
// switch fails because the target Mac is offline, you can try again right
// away without having to toss the mouse around.
- (void)checkEdges {
    if (!self.running || self.switching) return;
    if (!self.deviceReady) return;

    CGEventRef event = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(event);
    CFRelease(event);

    CGFloat w = self.screenBounds.size.width;

    // Re-arm the edge trigger once the cursor is clearly away from both
    // edges. 40 px is roughly a scrollbar width — comfortable without
    // requiring a shove to the middle of the screen.
    CGFloat rearmDist = 40.0;
    if (!self.edgeArmed) {
        if (p.x > rearmDist && p.x < w - rearmDist) {
            self.edgeArmed = YES;
        }
        return;
    }

    if (p.x <= EDGE_THRESHOLD) {
        int next = CHANNEL_HOME - 1;
        if (next >= CHANNEL_MIN) {
            printf("[MXFlow] LEFT edge -> channel %d (Mac %d)\n", next, next + 1);
            fflush(stdout);
            // Do NOT disarm here — only the actual device removal does that.
            [self switchToChannelDirect:next];
            [self warpMouse:p.x + 20 y:p.y];
        }
        return;
    }

    if (p.x >= w - EDGE_THRESHOLD) {
        int next = CHANNEL_HOME + 1;
        if (next <= CHANNEL_MAX) {
            printf("[MXFlow] RIGHT edge -> channel %d (Mac %d)\n", next, next + 1);
            fflush(stdout);
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
@property (nonatomic, assign) BOOL permissionPrompted;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.flowManager = [[MXFlowManager alloc] init];
    self.isActive = NO;
    self.permissionPrompted = NO;

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

    NSMenuItem *switch1 = [[NSMenuItem alloc] initWithTitle:@"Channel 1"
                                                      action:@selector(switchToChannel1:)
                                               keyEquivalent:@"1"];
    switch1.target = self; [menu addItem:switch1];

    NSMenuItem *switch2 = [[NSMenuItem alloc] initWithTitle:@"Channel 2"
                                                      action:@selector(switchToChannel2:)
                                               keyEquivalent:@"2"];
    switch2.target = self; [menu addItem:switch2];

    NSMenuItem *switch3 = [[NSMenuItem alloc] initWithTitle:@"Channel 3"
                                                      action:@selector(switchToChannel3:)
                                               keyEquivalent:@"3"];
    switch3.target = self; [menu addItem:switch3];

    [menu addItem:[NSMenuItem separatorItem]];

    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Status: Stopped"
                                                         action:nil
                                                  keyEquivalent:@""];
    [menu addItem:self.statusMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                       action:@selector(quitApp:)
                                                keyEquivalent:@"q"];
    quitItem.target = self; [menu addItem:quitItem];

    self.statusItem.menu = menu;

    [self performSelector:@selector(autoStart) withObject:nil afterDelay:0.5];
}

- (void)autoStart {
    self.isActive = YES;
    [self.flowManager start];
    self.toggleMenuItem.title = @"Stop Flow Switching";
    [self updateStatus:@"Running"];
    [self performSelector:@selector(checkForDevice) withObject:nil afterDelay:3.0];
}

- (void)checkForDevice {
    if (self.flowManager.deviceReady || self.permissionPrompted) return;
    self.permissionPrompted = YES;

    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Input Monitoring permission required";
    a.informativeText = @"MX Flow Switch can't see your Logitech mouse. Open System Settings → Privacy & Security → Input Monitoring and enable this app, then quit and relaunch.";
    [a addButtonWithTitle:@"Open Settings"];
    [a addButtonWithTitle:@"Later"];
    if ([a runModal] == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:
            [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
    }
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
    } else {
        NSString *s = self.flowManager.batteryString ?: @"--%";
        self.statusItem.button.title = [NSString stringWithFormat:@"🖱️ %@", s];
    }
    self.statusItem.button.alternateTitle = self.statusItem.button.title;
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
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>app_icon</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
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

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Compilation successful!${NC}"
    rm -f build_errors.log
else
    echo -e "${RED}❌ Compilation failed:${NC}"
    cat build_errors.log
    exit 1
fi

# ---- Sign with a stable identity if available ----
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo -e "${CYAN}🔏 Signing with $SIGN_IDENTITY${NC}"
    codesign --force --deep --sign "$SIGN_IDENTITY" \
             --identifier "$BUNDLE_ID" \
             --options runtime \
             "$APP_BUNDLE" 2>/dev/null || {
        echo -e "${YELLOW}⚠ Signing with $SIGN_IDENTITY failed, falling back to ad-hoc${NC}"
        codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE" 2>/dev/null || true
    }
else
    echo -e "${YELLOW}⚠ Self-signed cert '$SIGN_IDENTITY' not found — using ad-hoc.${NC}"
    echo -e "${YELLOW}  Input Monitoring permission will reset on every rebuild.${NC}"
    echo -e "${YELLOW}  To fix once and for all:${NC}"
    echo -e "${YELLOW}    Keychain Access → Certificate Assistant → Create a Certificate…${NC}"
    echo -e "${YELLOW}    Name: $SIGN_IDENTITY  Type: Code Signing  Self-signed${NC}"
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE" 2>/dev/null || true
fi
xattr -cr "$APP_BUNDLE"

rm -rf "$HOME/Applications/$APP_BUNDLE"
mkdir -p "$HOME/Applications"
cp -R "$APP_BUNDLE" "$HOME/Applications/"

echo -e "\n${GREEN}✅ Built and installed to ~/Applications${NC}"
echo ""
echo "Edges (one step per flick, based on physical position):"
echo "  LEFT  edge → previous Mac in the row"
echo "  RIGHT edge → next Mac in the row"
echo ""
echo "Top button:"
echo "  1 click  → channel 1"
echo "  2 clicks → channel 2"
echo "  3 clicks → channel 3 (fires instantly)"
echo ""
echo "Battery: 100% / 80% / 50% / 10% (last value cached across switches)"
echo ""

open "$HOME/Applications/$APP_BUNDLE"

echo -e "\n${GREEN}✅ MX Flow Switch compiled successfully!${NC}"
echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    WHAT THIS VERSION DOES                    ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║ 1. ✅ Battery: 100/80/50/10, cached across channel switches  ║"
echo "║ 2. ✅ Top button: 1/2/3 clicks → direct channel jump         ║"
echo "║ 3. ✅ Edges: one step per flick, uses CHANNEL_HOME not stale ║"
echo "║ 4. ✅ Edge re-arms only when mouse actually leaves this Mac  ║"
echo "║ 5. ✅ ChangeHost + battery feature discovery, no retry spam  ║"
echo "║ 6. ✅ Stable signing (MXFlowLocal) if cert exists            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  Grant Input Monitoring permission:"
echo "   System Settings → Privacy & Security → Input Monitoring"
echo "   Add ~/Applications/$APP_NAME.app, toggle ON"
echo -e "${NC}"

# 🎯 What You've Achieved
# Feature	Status
# Edge detection	✅ Working
# HID++ over Bluetooth	✅ Working
# Manual switch buttons	✅ Working
# Battery next to icon	✅ Working
# Input report callback	✅ Working
# Feature index discovery	✅ Working (0x0A)
# No USB receiver needed	✅ Working
# macOS Monterey + Sonoma	✅ Working
# Big Sur support	✅ Should work too

# 11 FF 08 0A 64 32 00 00 ...
#        ↑  ↑  ↑  ↑
#        │  │  │  └── byte 6 = status (0 = discharging)
#        │  │  └───── byte 5 = next level (0x32 = 50)
#        │  └──────── byte 4 = current level (0x64 = 100)
#        └─────────── byte 2 = feature index 0x08 (BatteryStatus)