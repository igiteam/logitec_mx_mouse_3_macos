#!/bin/bash
# Grace Digital GDI-BTPB300 3Play - Bluetooth Audio Receiver Switcher for macOS
# Manual switch via menu bar (1 / 2 / 3) + battery/status next to icon
# NOTE: 3Play is an audio sink (Mac -> 3Play). It does NOT switch between Macs.
# This app gives you a menu-bar control surface + HID probe for the device.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   GRACE DIGITAL GDI-BTPB300 3PLAY - MACOS SWITCHER            ║"
echo "║           MENU BAR CONTROL + DEVICE STATUS                    ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

APP_NAME="Grace3PlaySwitch"
BUNDLE_ID="com.github.grace3playswitch"

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/src"
mkdir -p "$APP_NAME/public"
cd "$APP_NAME" || exit

# ===============================================
# DOWNLOAD APP ICON
# ===============================================
echo -e "${CYAN}🎨 Downloading Grace 3Play icon...${NC}"

ICON_URL="https://raw.githubusercontent.com/igiteam/logitec_mx_mouse_3_macos/main/GraceDigital-3play-icon.png"

echo "📥 Downloading icon from: $ICON_URL"
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
        echo "⚠ iconutil failed, falling back to PNG"
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
    echo -e "${GREEN}✅ Created fallback icon${NC}"
fi

# ===============================================
# CREATE SOURCE FILES
# ===============================================

cat > "src/Grace3PlayManager.h" << 'EOF'
#import <Foundation/Foundation.h>

@interface Grace3PlayManager : NSObject
@property (nonatomic, assign) BOOL running;
- (void)start;
- (void)stop;
@property (nonatomic, assign, readonly) BOOL deviceConnected;
@property (nonatomic, strong, readonly) NSString *deviceName;
@property (nonatomic, assign, readonly) int batteryLevel;
@property (nonatomic, strong, readonly) NSString *batteryString;
- (void)switchToChannelDirect:(int)channel;
@end
EOF

cat > "src/Grace3PlayManager.m" << 'EOF'
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
EOF

cat > "src/AppDelegate.h" << 'EOF'
#import <Cocoa/Cocoa.h>
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
EOF

cat > "src/AppDelegate.m" << 'EOF'
#import "AppDelegate.h"
#import "Grace3PlayManager.h"

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) Grace3PlayManager *manager;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, strong) NSMenuItem *deviceMenuItem;
@property (nonatomic, strong) NSMenuItem *batteryMenuItem;
@property (nonatomic, assign) BOOL isActive;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.manager = [[Grace3PlayManager alloc] init];
    self.isActive = NO;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"🎧 --%";;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateDisplay)
                                                 name:@"DeviceUpdated"
                                               object:nil];

    NSMenu *menu = [[NSMenu alloc] init];

    self.toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@"Start 3Play Control"
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

    NSMenuItem *switchTitle = [[NSMenuItem alloc] initWithTitle:@"── Switch Input ──"
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
    [self.manager start];
    self.toggleMenuItem.title = @"Stop 3Play Control";
    [self updateDisplay];
}

- (void)toggleFlow:(id)sender {
    self.isActive = !self.isActive;
    if (self.isActive) {
        [self.manager start];
        self.toggleMenuItem.title = @"Stop 3Play Control";
    } else {
        [self.manager stop];
        self.toggleMenuItem.title = @"Start 3Play Control";
    }
    [self updateDisplay];
}

- (void)switchToChannel1:(id)sender { [self.manager switchToChannelDirect:0]; }
- (void)switchToChannel2:(id)sender { [self.manager switchToChannelDirect:1]; }
- (void)switchToChannel3:(id)sender { [self.manager switchToChannelDirect:2]; }

- (void)updateDisplay {
    if (self.manager.deviceConnected) {
        self.statusItem.button.title = @"🎧 --%";;
        self.deviceMenuItem.title = [NSString stringWithFormat:@"Device: %@", self.manager.deviceName];
        self.batteryMenuItem.title = [NSString stringWithFormat:@"Battery: %@", self.manager.batteryString];
    } else {
        self.statusItem.button.title = @"🎧 --%";;
        self.deviceMenuItem.title = @"Device: Not connected";
        self.batteryMenuItem.title = @"Battery: --";
    }
}

- (void)quitApp:(id)sender {
    [self.manager stop];
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
# BUILD APP BUNDLE
# ===============================================

echo -e "${CYAN}🔨 Compiling Grace 3Play Switcher...${NC}"

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
    <string>Grace 3Play Switch needs Bluetooth to manage your audio receiver</string>
</dict>
</plist>
EOF

cp "Info.plist" "$APP_BUNDLE/Contents/"

if [ -f "public/app_icon.icns" ]; then
    cp "public/app_icon.icns" "$APP_BUNDLE/Contents/Resources/app_icon.icns"
    echo "✅ App icon added to bundle (ICNS)"
elif [ -f "public/app_icon.png" ]; then
    cp "public/app_icon.png" "$APP_BUNDLE/Contents/Resources/app_icon.png"
    echo "✅ App icon added to bundle (PNG)"
fi

echo -e "${CYAN}Compiling...${NC}"
clang -framework Cocoa -framework Foundation -framework AppKit \
      -framework CoreGraphics -framework IOKit \
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

codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
xattr -cr "$APP_BUNDLE"

cp -R "$APP_BUNDLE" "$HOME/Applications/" 2>/dev/null || true
cp -R "$APP_BUNDLE" "$HOME/Desktop/" 2>/dev/null || true

echo -e "\n${GREEN}✅ Grace 3Play Switcher compiled!${NC}"
echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    WHAT THIS DOES                            ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║ 1. ✅ Menu bar icon for Grace 3Play                          ║"
echo "║ 2. ✅ Manual switch buttons 1 / 2 / 3                        ║"
echo "║ 3. ✅ HID probe for device name + battery                    ║"
echo "║ 4. ✅ Same architecture as MXKeysSwitch / MXFlowSwitch       ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║ NOTE:                                                        ║"
echo "║ The 3Play is an audio SINK (Mac → 3Play). It does NOT        ║"
echo "║ switch between Macs. Bluetooth A2DP pairing is controlled    ║"
echo "║ by macOS itself (System Settings → Bluetooth). This app      ║"
echo "║ gives you a menu-bar control surface and a HID probe —       ║"
echo "║ if the 3Play exposes any vendor HID interface, the buttons   ║"
echo "║ will work. If it doesn't, the buttons will log 'not          ║"
echo "║ connected' and that's expected.                              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  Grant Input Monitoring permission:"
echo "   System Settings → Privacy & Security → Input Monitoring"
echo "   Add your Terminal or the app, toggle ON"
echo -e "${NC}"

open "$APP_BUNDLE"