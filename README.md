# MX Flow Switch

**Switch your MX Master 3S between Macs by moving to screen edges.**

A lightweight macOS menu bar app that gives you Logitech Flow functionality over Bluetooth. No USB receiver, no Logitech software, no bullshit.

## How It Works

- Move your mouse to the **left edge** → switches to Channel 1
- Move your mouse to the **right edge** → switches to Channel 2
- Battery percentage shown next to the menu bar icon
- Manual switch buttons (1, 2, 3) in the menu bar

## Installation

1. Download `MXFlowSwitch.app`
2. Move to `/Applications`
3. Open it (right-click → Open on first launch if Gatekeeper complains)
4. Grant **Input Monitoring** permission when prompted
   - System Settings → Privacy & Security → Input Monitoring
5. Click the mouse icon 🖱️ in your menu bar → "Start Flow Switching"

## Requirements

- macOS 11 (Big Sur) or later
- Logitech MX Master 3 / 3S / 4 over **Bluetooth** (USB receiver not required)

## Configuration

Edit the channel mapping in `MXFlowManager.m` before compiling:

```c
#define CHANNEL_LEFT   0   // Switch to Channel 1 when hitting left edge
#define CHANNEL_RIGHT  1   // Switch to Channel 2 when hitting right edge
#define CHANNEL_CENTER 2   // Current Mac's channel (Channel 3)
```

How It Works Under The Hood
    Uses HID++ 2.0 over Bluetooth (long reports, device index 0xFF)
    Discovers CHANGE_HOST feature (0x1814) dynamically
    Reads battery via UNIFIED_BATTERY (0x1004)
    No network, no telemetry, no Logitech account

Troubleshooting

Battery shows --%: 30 seconds for the first read.

Mouse doesn't switch: Try changing CHANNEL_LEFT and CHANNEL_RIGHT values (0/1, 1/2, or 0/2).

App won't open: Right-click → Open → Open (bypasses Gatekeeper once).
Build from Source
```bash
chmod +x ./mx_flow_switch.sh
./mx_flow_switch.sh
```

Credits
Protocol implementation inspired by MX Battery and the HID++ specs.

License
MIT