#!/bin/bash

# xbox_wheel_listener.sh
# Listens for Xbox Lotus Steering Wheel USB events
# Based on XID protocol documentation (bSubType = 0x10 = Steering wheel)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Vendor and Product IDs from debug
RADICA_VID="0x0e4c"
WHEEL_PID="0x1101"
HUB_PID="0xa101"

# XID protocol constants (from documentation)
XID_CLASS="0x88"
XID_SUBCLASS="0x42"
XID_SUBTYPE_STEERING="0x10"

echo -e "${PURPLE}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     🎮 XBOX LOTUS STEERING WHEEL - USB LISTENER              ║"
echo "║        XID Protocol: bSubType = 0x10 (Steering wheel)        ║"
echo "║        Press Ctrl+C to stop                                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Function to check if wheel is connected
check_wheel() {
    system_profiler SPUSBDataType 2>/dev/null | grep -q "Radica"
    return $?
}

# Function to get wheel status with XID info
get_wheel_status() {
    local usb_info=$(system_profiler SPUSBDataType 2>/dev/null)
    
    if echo "$usb_info" | grep -q "Product ID: $WHEEL_PID"; then
        echo -e "${GREEN}CONNECTED${NC}"
        return 0
    elif echo "$usb_info" | grep -q "Radica"; then
        echo -e "${YELLOW}HUB ONLY (wheel not responding)${NC}"
        return 1
    else
        echo -e "${RED}DISCONNECTED${NC}"
        return 2
    fi
}

# Function to get wheel details with XID analysis
show_wheel_details() {
    echo -e "${CYAN}📋 WHEEL DETAILS (XID Analysis):${NC}"
    
    local usb_info=$(system_profiler SPUSBDataType 2>/dev/null | grep -A 30 "Radica")
    
    # Show raw USB info
    echo "$usb_info" | head -30
    
    # Check for XID class/subclass
    if echo "$usb_info" | grep -q "Class.*$XID_CLASS"; then
        echo -e "${GREEN}   ✅ XID Device Class detected (0x88)${NC}"
    fi
    
    if echo "$usb_info" | grep -q "SubClass.*$XID_SUBCLASS"; then
        echo -e "${GREEN}   ✅ XID Controller SubClass detected (0x42)${NC}"
    fi
    
    # Steering wheel specific info
    echo -e "${CYAN}   🎮 According to XID spec: bSubType = 0x10 = Steering wheel${NC}"
    echo -e "${YELLOW}   ⚠️  No macOS driver = no HID input. Works on Linux (xpad) and Windows (x360ce)${NC}"
}

# Show XID protocol reference
show_xid_reference() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           XID PROTOCOL REFERENCE (Steering Wheel)           ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Input Report (20 bytes):                                   ║"
    echo "║    Offset 2: Digital buttons (D-pad, Start, Back)          ║"
    echo "║    Offset 10: Left trigger (analog, 0-255)                 ║"
    echo "║    Offset 11: Right trigger (analog, 0-255)                ║"
    echo "║    Offset 12-13: Steering axis (0x0000 = center)           ║"
    echo "║    Offset 14-15: Throttle/Accelerator                      ║"
    echo "║    Offset 16-17: Brake                                     ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Output Report (6 bytes) - Force Feedback:                 ║"
    echo "║    Offset 2-3: Left actuator (vibration motor)            ║"
    echo "║    Offset 4-5: Right actuator (vibration motor)           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Try to read raw USB data using system_profiler (no driver needed)
read_raw_usb() {
    echo -e "${CYAN}🔍 Reading raw USB device info...${NC}"
    
    # Get the USB location path
    local location=$(system_profiler SPUSBDataType 2>/dev/null | grep -A 5 "Product ID: $WHEEL_PID" | grep "Location ID" | awk '{print $3}')
    
    if [ -n "$location" ]; then
        echo -e "${GREEN}   Device at location: $location${NC}"
        echo -e "${YELLOW}   Raw USB data requires libusb or direct IOKit access${NC}"
        echo -e "   Try: sudo python3 -c \"import usb.core; dev = usb.core.find(idVendor=0x0e4c, idProduct=0x1101); print(dev)\""
    else
        echo -e "${RED}   Wheel not found${NC}"
    fi
}

# Listen for USB events using log stream
listen_usb_events() {
    echo -e "${CYAN}👂 Listening for USB events...${NC}"
    echo -e "${YELLOW}   Plug/unplug your Xbox wheel to see events${NC}\n"
    
    log stream --predicate 'eventMessage contains "USB"' --style syslog 2>/dev/null | while read line; do
        if echo "$line" | grep -qi "attach\|detach\|0x0e4c\|Radica\|0x88\|0x42"; then
            echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} USB event detected"
            sleep 1
            echo -e "   Status: $(get_wheel_status)"
            
            if check_wheel; then
                echo -e "${GREEN}   ✅ Wheel is now connected!${NC}"
                show_wheel_details
            else
                echo -e "${RED}   ❌ Wheel disconnected${NC}"
            fi
            echo ""
        fi
    done
}

# Manual polling mode
manual_mode() {
    echo -e "${CYAN}🔄 Manual polling mode (checks every 2 seconds)${NC}"
    echo -e "${YELLOW}   Plug/unplug your wheel to see changes${NC}\n"
    
    local last_status=""
    
    while true; do
        local current_status=$(get_wheel_status)
        
        if [ "$current_status" != "$last_status" ]; then
            echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} Status changed: $last_status → $current_status"
            
            if echo "$current_status" | grep -q "CONNECTED"; then
                echo -e "${GREEN}   🎮 Steering wheel detected!${NC}"
                show_wheel_details
                echo -e "\n${YELLOW}   ⚠️  No HID driver = no button presses yet${NC}"
                echo -e "   📝 Solution: Linux (xpad driver) or Windows (x360ce)"
                echo -e "   📝 macOS requires 360Controller (broken on Big Sur+)"
            fi
            
            last_status="$current_status"
        fi
        
        sleep 2
    done
}

# Show current wheel status only
show_status_only() {
    echo -e "\n${CYAN}Current status: $(get_wheel_status)${NC}\n"
    if check_wheel; then
        show_wheel_details
    fi
}

# Main menu
echo ""
echo -e "${CYAN}Select mode:${NC}"
echo "  1) Listen for USB events (real-time, no polling)"
echo "  2) Manual polling mode (shows status changes)"
echo "  3) Show XID protocol reference"
echo "  4) Try raw USB read (Python + libusb)"
echo "  5) Show current wheel status only"
echo "  6) Show all USB devices (filtered for Xbox)"
echo ""
read -p "Choice (1-6): " mode

case $mode in
    1)
        echo -e "\n${GREEN}Starting USB event listener...${NC}\n"
        listen_usb_events
        ;;
    2)
        manual_mode
        ;;
    3)
        show_xid_reference
        ;;
    4)
        read_raw_usb
        ;;
    5)
        show_status_only
        ;;
    6)
        echo -e "\n${CYAN}🔍 USB devices (Xbox/Controller filter):${NC}\n"
        system_profiler SPUSBDataType 2>/dev/null | grep -E "Xbox|Radica|Controller|Product ID|Vendor ID" | grep -A 2 -B 2 "Radica\|0x0e4c"
        ;;
    *)
        echo -e "${RED}Invalid choice${NC}"
        ;;
esac