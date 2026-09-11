#!/bin/bash
# MX Keys Mini - Offline Host Switcher for macOS
# Manual switch via menu bar (no edge detection - keyboards have no cursor)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║       MX KEYS MINI - OFFLINE HOST SWITCHER FOR MACOS          ║"
echo "║            MANUAL SWITCH VIA MENU BAR (1 / 2 / 3)             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

APP_NAME="MXKeysSwitch"
BUNDLE_ID="com.github.mxkeysswitch"

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/src"
mkdir -p "$APP_NAME/public"
cd "$APP_NAME" || exit

# ===============================================
# DOWNLOAD APP ICON
# ===============================================
echo -e "${CYAN}🎨 Downloading keyboard icon...${NC}"

ICON_URL="https://raw.githubusercontent.com/igiteam/logitec_mx_mouse_3_macos/main/logitec-mouse-mx-3.png"

echo "📥 Downloading icon from: $ICON_URL"
curl -s -L "$ICON_URL" -o "public/app_icon.png"

if [ -f "public/app_icon.png" ] && [ -s "public/app_icon.png" ]; then
    echo "✅ Icon downloaded successfully!"

    ICONSET_DIR="public/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"

    for SIZE in 16 32 64 128 256 512 1024; do
        sips -z $SIZE $SIZE "public/app_icon.png" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" 2>/dev/null || true
        RETINA=$((SIZE * 2))
        sips -z $RETINA $RETINA "public/app_icon.png" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" 2>/dev/null || true
    done

    if command -v iconutil &> /dev/null; then
        iconutil -c icns "$ICONSET_DIR" -o "public/app_icon.icns" 2>/dev/null
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
    echo -e "${GREEN}✅ Created fallback icon${NC}"
fi

# ===============================================
# SOURCE FILES
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
EOF

cat > "src/AppDelegate.h" << 'EOF'
#import <Cocoa/Cocoa.h>
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
EOF

cat > "src/AppDelegate.m" << 'EOF'
#import "AppDelegate.h"
#import "MXKeysManager.h"

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) MXKeysManager *keysManager;
@property (nonatomic, strong) NSMenuItem *toggleMenuItem;
@property (nonatomic, strong) NSMenuItem *deviceMenuItem;
@property (nonatomic, strong) NSMenuItem *batteryMenuItem;
@property (nonatomic, assign) BOOL isActive;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.keysManager = [[MXKeysManager alloc] init];
    self.isActive = NO;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"⌨️";

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

    NSMenuItem *switch1 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 1"
                                                      action:@selector(switchToHost1:)
                                               keyEquivalent:@"1"];
    switch1.target = self;
    [menu addItem:switch1];

    NSMenuItem *switch2 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 2"
                                                      action:@selector(switchToHost2:)
                                               keyEquivalent:@"2"];
    switch2.target = self;
    [menu addItem:switch2];

    NSMenuItem *switch3 = [[NSMenuItem alloc] initWithTitle:@"Switch to Host 3"
                                                      action:@selector(switchToHost3:)
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

- (void)updateDisplay {
    if (self.keysManager.deviceConnected) {
        self.statusItem.button.title = @"⌨️";
        self.deviceMenuItem.title = [NSString stringWithFormat:@"Device: %@", self.keysManager.deviceName];
        self.batteryMenuItem.title = [NSString stringWithFormat:@"Battery: %@", self.keysManager.batteryLevelString];
    } else {
        self.statusItem.button.title = @"⌨️";
        self.deviceMenuItem.title = @"Device: Not connected";
        self.batteryMenuItem.title = @"Battery: --";
    }
}

- (void)quitApp:(id)sender {
    [self.keysManager stop];
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

echo -e "${CYAN}🔨 Compiling MX Keys Mini Switcher...${NC}"

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
    <string>MX Keys Switch needs Bluetooth to control your Logitech keyboard</string>
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

echo -e "\n${GREEN}✅ MX Keys Mini Switcher compiled!${NC}"
echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                     WHAT THIS DOES                            ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║ 1. ✅ Connects to MX Keys Mini over Bluetooth                ║"
echo "║ 2. ✅ Dynamically discovers ChangeHost feature index         ║"
echo "║ 3. ✅ Switches host via menu bar (Host 1 / 2 / 3)            ║"
echo "║ 4. ✅ Shows device name and battery level in menu            ║"
echo "║ 5. ✅ No edge detection (keyboard has no cursor)             ║"
echo "║ 6. ✅ No USB receiver needed                                 ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║ TO USE:                                                       ║"
echo "║ 1. Grant Input Monitoring permission                         ║"
echo "║ 2. Click ⌨️ in menu bar                                       ║"
echo "║ 3. Use 'Switch to Host 1/2/3' to change host                 ║"
echo "║ 4. Check console output for debug info                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  Grant Input Monitoring permission:"
echo "   System Settings → Privacy & Security → Input Monitoring"
echo "   Add your Terminal or the app, toggle ON"
echo -e "${NC}"

open "$APP_BUNDLE"

# What's different from the mouse version
# Feature	Mouse version	Keyboard version
# Edge detection	Watches cursor position	Removed — no cursor on a keyboard
# Feature index	Hardcoded 0x18 fallback	Discovered dynamically from IRoot response only
# Battery %	Assumed percentage	Handles both percentage and level enum (Critical/Low/Good/Full)
# Device match	Name contains "MX Master"	Name contains "MX Keys Mini" or PID 0xB369/0xB36A
# Menu icon	🖱️ 85%	⌨️ (static) + battery as separate menu row
# Trigger	Auto on edge	Manual only via menu bar
# What to expect when you run it
#     The script builds the app and launches it. A ⌨️ icon appears in the menu bar.
#     Watch the terminal output. You should see:
#         Found MX Keys Mini: MX Keys Mini (PID 0xB369)
#         ✅ ChangeHost feature index: 0xXX (whatever index your firmware uses)
#         🔋 Battery: N% or 🔋 Battery level: Good

#     If ChangeHost feature not found appears, the feature lookup failed — make sure the keyboard is connected via Bluetooth, not the Logi Bolt receiver. HID++ 2.0 long reports work reliably over Bluetooth but the Bolt receiver may need a different report path.
#     Use the menu bar → Switch to Host 1 / 2 / 3 to change host.

# Known caveats
#     Battery percentage may not appear. The MX Keys Mini's UnifiedBattery feature often only reports a level enum, not a percentage. The app handles this and shows Critical / Low / Good / Full instead. If it shows --, the keyboard's battery is being managed by macOS natively and not exposed over HID++.
#     Feature index discovery timing. The lookup happens once when the keyboard connects. If the keyboard is asleep when you launch the app, discovery will fail. Wake the keyboard, then toggle Stop/Start in the menu.
#     Host switching is one-way. HID++ can tell the keyboard which host to connect to, but the keyboard only sends the switch command if the currently active host is the one issuing it. This means: to switch back from Host 2 to Host 1, you need this app running on Host 1 — which won't work if the keyboard is currently connected to Host 2. For true two-way Flow behavior, you'd need the logitech-flow-kvm architecture where one machine acts as the leader and tells the others.

