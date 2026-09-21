#!/bin/bash
# WineKiller.app - Simple app that kills Wine processes and exits

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              WINE PROCESS KILLER                        ║"
echo "║           Kill Wine processes with one click             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

APP_NAME="WineKiller"
BUNDLE_ID="com.github.winekiller"

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/src"
cd "$APP_NAME" || exit

# ===============================================
# CREATE ICON
# ===============================================
echo -e "${CYAN}🎨 Downloading Wine icon...${NC}"

ICON_URL="https://raw.githubusercontent.com/igiteam/winejs/refs/heads/main/images/winex_x86_64.png"
ICON_FILE="appicon.${ICON_URL##*.}"
ICON_FILE="${ICON_FILE%\?*}"

echo "📥 Downloading icon from: $ICON_URL"
curl -s -L "$ICON_URL" -o "/tmp/$ICON_FILE"

if [ -f "/tmp/$ICON_FILE" ] && [ -s "/tmp/$ICON_FILE" ]; then
    echo "✅ Icon downloaded successfully!"
    
    mkdir -p public
    cp "/tmp/$ICON_FILE" "public/app_icon.png"
    
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
    mkdir -p public
    echo "🍷" > public/app_icon.txt
    cp public/app_icon.txt public/app_icon.icns
    echo -e "${GREEN}✅ Created fallback icon${NC}"
fi

# ===============================================
# CREATE OBJECTIVE-C SOURCE
# ===============================================

cat > "src/main.m" << 'EOF'
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Kill Wine processes
    [self killWineProcesses];
    
    // Quit immediately after killing
    [NSApp terminate:nil];
}

- (void)killWineProcesses {
    NSLog(@"🔪 Killing Wine processes...");
    
    // Get current username
    NSString *username = NSUserName();
    
    // Build the kill command
    NSString *killCommand = [NSString stringWithFormat:
        @"pkill -9 -U %@ wineserver wine wine64 wine-preloader wine64-preloader 2>/dev/null; "
        @"pgrep -U %@ -f \".exe\" | xargs kill -9 2>/dev/null",
        username, username];
    
    // Run the command
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/bash";
    task.arguments = @[@"-c", killCommand];
    
    // Capture output
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    
    NSFileHandle *fileHandle = [pipe fileHandleForReading];
    
    [task launch];
    [task waitUntilExit];
    
    // Read output
    NSData *data = [fileHandle readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if (output.length > 0) {
        NSLog(@"Kill output: %@", output);
    }
    
    // Get exit status
    int status = [task terminationStatus];
    if (status == 0) {
        NSLog(@"✅ Wine processes killed successfully");
    } else {
        NSLog(@"⚠️ No Wine processes found to kill (exit: %d)", status);
    }
}

@end

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

echo -e "${CYAN}🔨 Compiling Wine Killer...${NC}"

APP_BUNDLE="$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/"{MacOS,Resources}

# Create Info.plist
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
    <string>10.15</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

cp "Info.plist" "$APP_BUNDLE/Contents/"

# Copy the app icon
if [ -f "public/app_icon.icns" ]; then
    cp "public/app_icon.icns" "$APP_BUNDLE/Contents/Resources/app_icon.icns"
    echo "✅ App icon added to bundle"
elif [ -f "public/app_icon.png" ]; then
    cp "public/app_icon.png" "$APP_BUNDLE/Contents/Resources/app_icon.png"
    echo "✅ App icon added to bundle (PNG)"
fi

# Compile
clang -framework Cocoa -framework Foundation -fobjc-arc -mmacosx-version-min=10.15 -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" src/main.m 2> build_errors.log

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Compilation successful!${NC}"
else
    echo -e "${RED}❌ Compilation failed:${NC}"
    cat build_errors.log
    exit 1
fi

# Sign and fix permissions
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
xattr -cr "$APP_BUNDLE"

# Copy to Applications and Desktop
cp -R "$APP_BUNDLE" "$HOME/Applications/" 2>/dev/null || true
cp -R "$APP_BUNDLE" "$HOME/Desktop/" 2>/dev/null || true

echo ""
echo -e "${GREEN}✅ Wine Killer built successfully!${NC}"
echo -e "${CYAN}📁 App installed to:${NC} $HOME/Applications/$APP_BUNDLE"
echo -e "${CYAN}📁 Desktop copy:${NC} $HOME/Desktop/$APP_BUNDLE"
echo ""
echo -e "${GREEN}✨ Features:${NC}"
echo "   • Click the app to kill all Wine processes"
echo "   • App automatically quits after killing"
echo "   • No menu bar icon - simple app"
echo ""

# Launch the app
echo -e "${CYAN}🚀 Launching Wine Killer...${NC}"
open "$APP_BUNDLE"