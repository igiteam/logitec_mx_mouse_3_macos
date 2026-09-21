#!/bin/bash
# MX Keys Mini - Offline Host Switcher + Wine Killer for macOS
# Menu bar app: switch keyboard host (1/2/3) + Cmd+Shift+F12 kills Wine

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║       MX KEYS MINI - HOST SWITCHER + WINE KILLER              ║"
echo "║   Menu bar host switch + Cmd+Shift+F12 kills Wine             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

APP_NAME="MXKeysSwitch"
BUNDLE_ID="com.github.mxkeysswitch"
SIGN_IDENTITY="MXFlowLocal"

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/src"
mkdir -p "$APP_NAME/public"
cd "$APP_NAME" || exit

# ===============================================
# ICON
# ===============================================
echo -e "${CYAN}🎨 Downloading keyboard icon...${NC}"
ICON_URL="https://raw.githubusercontent.com/igiteam/logitec_mx_mouse_3_macos/main/logitec-mx-keys-mini.png"
curl -s -L "$ICON_URL" -o "public/app_icon.png"

if [ -f "public/app_icon.png" ] && [ -s "public/app_icon.png" ]; then
    ICONSET_DIR="public/AppIcon.iconset"
    rm -rf "$ICONSET_DIR"; mkdir -p "$ICONSET_DIR"
    for SIZE in 16 32 64 128 256 512 1024; do
        sips -z $SIZE $SIZE "public/app_icon.png" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" 2>/dev/null || true
        RETINA=$((SIZE * 2))
        sips -z $RETINA $RETINA "public/app_icon.png" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" 2>/dev/null || true
    done
    if command -v iconutil &> /dev/null; then
        iconutil -c icns "$ICONSET_DIR" -o "public/app_icon.icns" 2>/dev/null || \
            cp "public/app_icon.png" "public/app_icon.icns"
    else
        cp "public/app_icon.png" "public/app_icon.icns"
    fi
    rm -rf "$ICONSET_DIR"
    echo "✅ Icon ready"
else
    echo "⚠ No icon"
fi

# ===============================================
# SOURCE
# ===============================================

cat > "src/MXKeysManager.h" << 'EOF'
#import <Foundation/Foundation.h>

@interface MXKeysManager : NSObject
@property (nonatomic, assign) BOOL running;
- (void)start;
- (void)stop;
- (void)switchToChannelDirect:(int)channel;
@property (nonatomic, assign, readonly) BOOL deviceConnected;
@property (nonatomic, strong, readonly) NSString *deviceName;
@property (nonatomic, assign, readonly) int batteryLevel;
@property (nonatomic, strong, readonly) NSString *batteryLevelString;
@end
EOF

cat > "src/MXKeysManager.m" << 'EOF'
#import "MXKeysManager.h"
#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOKitLib.h>

// ============================================
// CONFIG
// ============================================

#define LOGITECH_VID 0x046D
#define MX_KEYS_MINI_PID     0xB369   // Bluetooth direct
#define MX_KEYS_MINI_MAC_PID 0xB36A   // "for Mac" variant

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
#define FUNCTION_GET_BATTERY_UNIFIED 0x01   // 0x1004 get_status
#define FUNCTION_GET_BATTERY_STATUS  0x00   // 0x1000 get_battery_level_status

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
@property (nonatomic, assign) BOOL awaitingHostInfo;

// Battery cache survives reconnect
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
        _awaitingHostInfo = NO;
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

    // Strict PID match to MX Keys Mini. Fallback on name only if PID is unknown.
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
        // Keep battery cache so the menu doesn't blank during a switch.
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
    // So the SWID is in the LOW nibble, not the high nibble. The template
    // had this backwards, which discarded every reply.
    uint8_t function = (report[3] >> 4) & 0x0F;
    uint8_t swid     = report[3] & 0x0F;
    if (swid != SWID) return;

    // ---- Feature index replies on feature 0x00 (ROOT) ----
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
            // Now chain the battery lookup — 500 ms later so the keyboard
            // isn't still busy with the first reply.
            [self performSelector:@selector(lookupBattery) withObject:nil afterDelay:0.5];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DeviceUpdated" object:nil];
            return;
        }

        if (self.awaitingBatteryIndex) {
            self.awaitingBatteryIndex = NO;
            if (idx == 0 || idx == 0xFF) {
                if (self.batteryIsUnified) {
                    // Fall back from 0x1004 to 0x1000
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

    // ---- Host info reply (ChangeHost feature) ----
    if (self.awaitingHostInfo && self.changeHostIndex != 0 &&
        report[2] == self.changeHostIndex && function == FUNCTION_GET_HOST_INFO) {
        self.awaitingHostInfo = NO;
        uint8_t count = report[4];
        uint8_t current = report[5];
        printf("[MXKeys] Host info: %d hosts, currently on slot %d (host %d)\n",
               count, current, current + 1);
        fflush(stdout);
        return;
    }

    // ---- Battery value reply ----
    if (self.awaitingBatteryValue && self.batteryIndex != 0 && report[2] == self.batteryIndex) {
        uint8_t raw = report[4];
        BOOL ok = NO;
        int pct = -1;

        if (self.batteryIsUnified) {
            // Keyboard's 0x1004 layout differs from the mouse's. It reports the
            // raw percentage directly in byte 4, without setting a "valid" flag
            // in byte 5. So accept any value 1..100 as a percentage.
            if (raw > 0 && raw <= 100) {
                pct = raw;
                ok = YES;
            }
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

- (void)readCurrentHost {
    if (!self.deviceReady || !self.hidDevice || !self.changeHostIndexFound) return;
    if (self.awaitingHostInfo) return;

    self.awaitingHostInfo = YES;
    uint8_t cmd[20] = {0};
    cmd[0] = HIDPP_REPORT_ID_LONG;
    cmd[1] = DEVICE_INDEX_DIRECT;
    cmd[2] = self.changeHostIndex;
    cmd[3] = (uint8_t)((FUNCTION_GET_HOST_INFO << 4) | SWID);
    cmd[4] = 0x00;

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
        printf("[MXKeys] ❌ ChangeHost feature not discovered yet\n");
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

// Cache-aware accessors
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
EOF

cat > "src/AppDelegate.h" << 'EOF'
#import <Cocoa/Cocoa.h>
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
EOF

cat > "src/AppDelegate.m" << 'EOF'
#import "AppDelegate.h"
#import "MXKeysManager.h"
#import <Carbon/Carbon.h>

// Hotkey: Cmd + Shift + F12
#define HOTKEY_KEYCODE  kVK_F12
#define HOTKEY_MODS     (cmdKey | shiftKey)
#define HOTKEY_ID       1
#define HOTKEY_SIG      'WnKl'

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) MXKeysManager *keysManager;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, strong) NSMenuItem *deviceMenuItem;
@property (nonatomic, strong) NSMenuItem *batteryMenuItem;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) EventHotKeyRef hotKeyRef;
@property (nonatomic, assign) EventHandlerRef hotKeyHandlerRef;
@end

static OSStatus WineHotKeyHandler(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData);

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.keysManager = [[MXKeysManager alloc] init];
    self.isActive = NO;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"⌨️ --%";

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateDisplay)
                                                 name:@"DeviceUpdated"
                                               object:nil];

    NSMenu *menu = [[NSMenu alloc] init];

    self.toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@"Start Host Switching"
                                                      action:@selector(toggleFlow:)
                                               keyEquivalent:@"s"];
    self.toggleMenuItem.target = self;
    [menu addItem:self.toggleMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    self.deviceMenuItem = [[NSMenuItem alloc] initWithTitle:@"Device: Not connected"
                                                      action:nil
                                               keyEquivalent:@""];
    [menu addItem:self.deviceMenuItem];

    self.batteryMenuItem = [[NSMenuItem alloc] initWithTitle:@"Battery: --"
                                                       action:nil
                                                keyEquivalent:@""];
    [menu addItem:self.batteryMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *switchTitle = [[NSMenuItem alloc] initWithTitle:@"── Switch Host ──"
                                                          action:nil
                                                   keyEquivalent:@""];
    [menu addItem:switchTitle];

    NSMenuItem *h1 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 1"
                                                action:@selector(switchToHost1:)
                                         keyEquivalent:@"1"];
    h1.target = self; [menu addItem:h1];

    NSMenuItem *h2 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 2"
                                                action:@selector(switchToHost2:)
                                         keyEquivalent:@"2"];
    h2.target = self; [menu addItem:h2];

    NSMenuItem *h3 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 3"
                                                action:@selector(switchToHost3:)
                                         keyEquivalent:@"3"];
    h3.target = self; [menu addItem:h3];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *killWine = [[NSMenuItem alloc] initWithTitle:@"Kill Wine Now  (⌘⇧F12)"
                                                       action:@selector(killWineProcesses)
                                                keyEquivalent:@""];
    killWine.target = self;
    [menu addItem:killWine];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                       action:@selector(quitApp:)
                                                keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;

    [self registerWineHotKey];

    [self performSelector:@selector(autoStart) withObject:nil afterDelay:0.5];
}

- (void)registerWineHotKey {
    EventTypeSpec eventType;
    eventType.eventClass = kEventClassKeyboard;
    eventType.eventKind  = kEventHotKeyPressed;

    InstallApplicationEventHandler(&WineHotKeyHandler,
                                   1,
                                   &eventType,
                                   (__bridge void *)self,
                                   &_hotKeyHandlerRef);

    EventHotKeyID hotKeyID;
    hotKeyID.signature = HOTKEY_SIG;
    hotKeyID.id        = HOTKEY_ID;

    OSStatus status = RegisterEventHotKey(HOTKEY_KEYCODE,
                                          HOTKEY_MODS,
                                          hotKeyID,
                                          GetApplicationEventTarget(),
                                          0,
                                          &_hotKeyRef);
    if (status == noErr) {
        printf("[MXKeys] ✅ Registered Cmd+Shift+F12 for Wine killer\n");
    } else {
        printf("[MXKeys] ⚠️ Hotkey registration failed (%d) — another app may own Cmd+Shift+F12\n", (int)status);
    }
    fflush(stdout);
}

- (void)autoStart {
    self.isActive = YES;
    [self.keysManager start];
    self.toggleMenuItem.title = @"Stop Host Switching";
    [self updateDisplay];
}

- (void)toggleFlow:(id)sender {
    self.isActive = !self.isActive;
    if (self.isActive) {
        [self.keysManager start];
        self.toggleMenuItem.title = @"Stop Host Switching";
    } else {
        [self.keysManager stop];
        self.toggleMenuItem.title = @"Start Host Switching";
    }
    [self updateDisplay];
}

- (void)switchToHost1:(id)sender { [self.keysManager switchToChannelDirect:0]; }
- (void)switchToHost2:(id)sender { [self.keysManager switchToChannelDirect:1]; }
- (void)switchToHost3:(id)sender { [self.keysManager switchToChannelDirect:2]; }

- (void)killWineProcesses {
    printf("[MXKeys] 🔪 Killing Wine processes...\n");
    fflush(stdout);

    NSString *username = NSUserName();
    NSString *cmd = [NSString stringWithFormat:
        @"pkill -9 -U %@ wineserver wine wine64 wine-preloader wine64-preloader 2>/dev/null; "
        @"pgrep -U %@ -f \".exe\" | xargs kill -9 2>/dev/null",
        username, username];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/bash";
    task.arguments = @[@"-c", cmd];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSFileHandle *fh = [pipe fileHandleForReading];

    [task launch];
    [task waitUntilExit];

    NSData *data = [fh readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (output.length > 0) {
        printf("[MXKeys] Kill output: %s\n", [output UTF8String]);
        fflush(stdout);
    }
    printf("[MXKeys] Wine kill exit status: %d\n", [task terminationStatus]);
    fflush(stdout);
}

- (void)updateDisplay {
    if (self.keysManager.deviceConnected) {
        NSString *b = self.keysManager.batteryLevelString ?: @"--%";
        self.statusItem.button.title = [NSString stringWithFormat:@"⌨️ %@", b];
        self.deviceMenuItem.title = [NSString stringWithFormat:@"Device: %@", self.keysManager.deviceName];
        self.batteryMenuItem.title = [NSString stringWithFormat:@"Battery: %@", b];
    } else {
        self.statusItem.button.title = @"⌨️ --%";
        self.deviceMenuItem.title = @"Device: Not connected";
        self.batteryMenuItem.title = @"Battery: --";
    }
    self.statusItem.button.alternateTitle = self.statusItem.button.title;
}

- (void)quitApp:(id)sender {
    if (self.hotKeyRef) { UnregisterEventHotKey(self.hotKeyRef); self.hotKeyRef = NULL; }
    if (self.hotKeyHandlerRef) { RemoveEventHandler(self.hotKeyHandlerRef); self.hotKeyHandlerRef = NULL; }
    [self.keysManager stop];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.hotKeyRef) UnregisterEventHotKey(self.hotKeyRef);
    if (self.hotKeyHandlerRef) RemoveEventHandler(self.hotKeyHandlerRef);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

static OSStatus WineHotKeyHandler(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData) {
    AppDelegate *self = (__bridge AppDelegate *)userData;
    if (!self) return noErr;

    EventHotKeyID hkID;
    GetEventParameter(theEvent, kEventParamDirectObject, typeEventHotKeyID,
                      NULL, sizeof(hkID), NULL, &hkID);

    if (hkID.signature == HOTKEY_SIG && hkID.id == HOTKEY_ID) {
        [self killWineProcesses];
    }
    return noErr;
}

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

echo -e "${CYAN}🔨 Compiling MX Keys Mini + Wine Killer...${NC}"

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
    <string>MX Keys Switch needs Bluetooth to control your Logitech keyboard</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>MX Keys Switch needs Input Monitoring to talk to your Logitech keyboard via HID++.</string>
</dict>
</plist>
EOF

cp "Info.plist" "$APP_BUNDLE/Contents/"

if [ -f "public/app_icon.icns" ]; then
    cp "public/app_icon.icns" "$APP_BUNDLE/Contents/Resources/app_icon.icns"
    echo "✅ App icon added"
fi

clang -framework Cocoa -framework Foundation -framework AppKit \
      -framework CoreGraphics -framework IOKit -framework Carbon \
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

if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo -e "${CYAN}🔏 Signing with $SIGN_IDENTITY${NC}"
    codesign --force --deep --sign "$SIGN_IDENTITY" \
             --identifier "$BUNDLE_ID" \
             --options runtime \
             "$APP_BUNDLE" 2>/dev/null || {
        codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE" 2>/dev/null || true
    }
else
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE" 2>/dev/null || true
fi
xattr -cr "$APP_BUNDLE"

rm -rf "$HOME/Applications/$APP_BUNDLE"
mkdir -p "$HOME/Applications"
cp -R "$APP_BUNDLE" "$HOME/Applications/"

echo ""
echo -e "${GREEN}✅ MX Keys Mini + Wine Killer built${NC}"
echo ""
echo "  ⌨️  Menu bar: switch host 1/2/3, kill Wine, quit"
echo "  ⌘⇧F12: kills Wine processes from anywhere"
echo ""

open "$HOME/Applications/$APP_BUNDLE"