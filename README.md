# MX Flow Switch + MX Keys Mini Switcher

**Recreate Logitech Flow over Bluetooth for MX Mouse Master 3 and MX Keys Mini keyboards — no USB receiver, no Logitech software, no account.**

Two lightweight macOS menu bar apps that let you switch your mouse and keyboard between up to three Macs using screen edges, a physical button, a menu bar item, or a global hotkey. Batteries are shown in the menu bar. Wine processes can be killed system-wide from any app, including fullscreen games.

---

## Features

### MXFlowSwitch (mouse)

- **Edge switching** — move the cursor to the left or right edge of the screen to hop to the adjacent Mac
- **Top button multi-click** — 1 / 2 / 3 clicks on the top mode-shift button jump directly to channel 1 / 2 / 3
- **Auto-detected home channel** — each Mac figures out which channel it is on by querying the mouse, so the same binary runs everywhere with zero config
- **Battery in the menu bar** — real percentage snapped to 100 / 80 / 50 / 10, cached across channel switches
- **Manual fallback** — menu bar items for direct channel switching and Start / Stop

### MXKeysSwitch (keyboard + Wine killer)

- **Menu bar host switching** — send the MX Keys Mini to Host 1 / 2 / 3
- **Battery in the menu bar** — reads both the modern and legacy battery features
- **⌘⇧F12 kills Wine** — works system-wide, including when a fullscreen game has focus, via a `CGEventTap`
- **Menu bar "Kill Wine Now"** — same action, one click

Both apps run as background menu bar items with no Dock icon.

---

## Requirements

- macOS 11 (Big Sur) or later
- Logitech MX Master 3 / 3S / 4 or MX Keys Mini connected over **Bluetooth**
- Xcode Command Line Tools (`xcode-select --install`)
- A self-signed code signing certificate named `MXFlowLocal` (recommended — see [Stable Permissions](#stable-permissions))

A USB receiver is **not** required and **not** supported.

---

## Getting Started

### Build and install

    git clone https://github.com/igiteam/logitec_mx_mouse_3_macos
    cd logitec_mx_mouse_3_macos

    chmod +x ./mx_flow_switch.sh
    ./mx_flow_switch.sh

    chmod +x ./mx_keyboard_mini.sh
    ./mx_keyboard_mini.sh

Each script compiles the Objective-C source, produces a signed `.app` bundle, installs it to `~/Applications/`, and launches it.

### First launch

1. **Right-click → Open** on the app the first time (bypasses Gatekeeper)
2. Grant **Input Monitoring** when prompted
   - System Settings → Privacy & Security → Input Monitoring
3. For MXKeysSwitch only: grant **Accessibility** as well
   - System Settings → Privacy & Security → Accessibility

After granting, **quit and relaunch** the app so the permissions take effect.

### Stable Permissions

macOS ties Input Monitoring and Accessibility grants to a code signature. Ad-hoc signing (`codesign -s -`) produces a new signature on every rebuild, so the grants are lost each time you compile.

To fix this permanently, create a self-signed certificate once:

1. Open **Keychain Access**
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: `MXFlowLocal`
4. Identity Type: **Self Signed Root**
5. Certificate Type: **Code Signing**
6. Click **Create**, then **Done**

Both build scripts detect this certificate automatically and sign with it. Grant permissions once, rebuild as often as you like.

---

## Usage

### Mouse

| Trigger | Action |
|---|---|
| Move cursor to **left edge** | Switch to the Mac to the left |
| Move cursor to **right edge** | Switch to the Mac to the right |
| **1 click** on top button | Jump to channel 1 |
| **2 clicks** on top button | Jump to channel 2 |
| **3+ clicks** on top button | Jump to channel 3 (fires instantly) |
| Menu bar → Channel 1 / 2 / 3 | Direct switch |

### Keyboard

| Trigger | Action |
|---|---|
| Menu bar → Switch to Host 1 / 2 / 3 | Move the keyboard to that host |
| **⌘⇧F12** (anywhere) | Kill all Wine processes |

---

## How It Works

### HID++ 2.0 over Bluetooth

Both devices speak Logitech's HID++ 2.0 protocol over a Bluetooth HID interface. The apps communicate using long reports (report ID `0x11`, device index `0xFF`) and standard feature lookups.

### Feature discovery

Feature indices are **not** hardcoded. On connect, each app sends a `ROOT.getFeature` request for the feature it needs (for example, `0x1814` for `CHANGE_HOST`) and reads the returned index. This means the same binary works across firmware revisions.

### Home channel detection (mouse)

The `CHANGE_HOST.getHostInfo` reply includes the currently-connected host slot. Each Mac reads this on connect to know whether it is channel 1, 2, or 3 — no per-Mac builds, no config files.

### Battery

- Mouse: prefers `UNIFIED_BATTERY` (`0x1004`); falls back to `BATTERY_STATUS` (`0x1000`) on older firmware. Values are snapped to 100 / 80 / 50 / 10 to match the discrete levels the hardware reports.
- Keyboard: reads `0x1004` directly; the keyboard reports percentages without the "valid" flag the mouse sets, so the parser accepts any value in `1..100`.

Battery readings are cached across channel switches so the menu bar icon doesn't blank out when the mouse or keyboard is on another Mac.

### Wine kill hotkey

A `CGEventTap` at `kCGSessionEventTap` sees keyboard events **before** the focused application, which is why the hotkey works in games that would otherwise swallow it. The tap runs on the main run loop and re-enables itself if macOS disables it for taking too long.

---

## Project Layout

    logitec_mx_mouse_3_macos/
    ├── mx_flow_switch.sh          # Builds and installs MXFlowSwitch.app
    ├── mx_keys_switch.sh          # Builds and installs MXKeysSwitch.app
    ├── README.md                  # This file
    ├── LICENSE                    # MIT
    └── (build artifacts)
        MXFlowSwitch/
        │   └── src/
        │       ├── MXFlowManager.h
        │       ├── MXFlowManager.m
        │       ├── AppDelegate.h
        │       ├── AppDelegate.m
        │       └── main.m
        └── MXKeysSwitch/
            └── src/
                ├── MXKeysManager.h
                ├── MXKeysManager.m
                ├── AppDelegate.h
                ├── AppDelegate.m
                └── main.m

Each build script is self-contained: it downloads the icon, writes the source files, compiles with `clang`, signs the bundle, and installs it. You can copy either `.sh` file to a fresh machine and build from scratch.

---

## Configuration

### Edge threshold (mouse)

In `MXFlowManager.m`:

    #define EDGE_THRESHOLD 5   // pixels from the screen edge to trigger

Smaller values require the cursor to be closer to the very edge; larger values trigger sooner. The current setting is tuned so VS Code scrollbars at the right edge don't accidentally trigger a switch.

### Wine-kill hotkey (keyboard)

In `AppDelegate.m`:

    #define WATCHED_KEYCODE  kVK_F12
    #define WATCHED_MODS     (kCGEventFlagMaskCommand | kCGEventFlagMaskShift)

Change these to rebind the kill hotkey to any key code and modifier combination.

---

## Troubleshooting

**Battery shows `--%`**
Wait 30 seconds for the first read. If it never populates, toggle **Stop → Start** in the menu bar to force a fresh connection and feature lookup.

**Mouse doesn't switch at an edge**
The cursor must reach the literal last pixel column (or first, on the left). If the mouse is currently on another Mac, only that Mac can issue a switch back — this app has to be running on the currently-active host to receive the switch command.

**Keyboard host switch appears to send but nothing happens**
Check the terminal for `✅ Switch to host N sent`. If that line prints and the keyboard does not move, the `CHANGE_HOST` function byte may differ on your firmware. The default is `0x01`; some firmware variants use `0x1E`. Change `FUNCTION_SET_HOST` in `MXKeysManager.m` accordingly.

**⌘⇧F12 doesn't fire in games**
Accessibility permission must be granted **before** the app launches, because the event tap is created at startup. Quit the app fully, confirm it is enabled in System Settings → Privacy & Security → Accessibility, then reopen.

**App won't open (Gatekeeper)**
Right-click the `.app` → **Open** → **Open**. This is a one-time bypass per app; subsequent launches work with a normal double-click.

---

## What Is Not Included

**Audio flow.** Switching audio output between Macs over the network is a separate project with its own latency, codec, and routing trade-offs. A realistic future addition would be a companion daemon that broadcasts channel changes over Bonjour and each Mac adjusts its local audio output — but that is out of scope for the current apps.

**Easy-Switch button interception on the keyboard.** The MX Keys Mini's Easy-Switch buttons are not divertable to HID++ events, so the keyboard can only be a follower, not a leader. Menu bar switching is the only trigger for now.

---

## Support

Open an issue on GitHub with:

- macOS version (`sw_vers`)
- Whether the device is on Bluetooth or a USB receiver
- The full terminal output from launching the app (all `[MXFlow]` or `[MXKeys]` lines)
- The specific trigger that failed and what you expected to happen

The terminal output is the single most useful diagnostic — it shows the exact bytes the device is sending and which feature indices were discovered.

---

## Contributing

Contributions are welcome. Before opening a pull request:

1. Test on your own hardware — the code is sensitive to firmware differences between MX Master 3, 3S, and 4, and between MX Keys Mini revisions
2. Keep the console output readable. The current logging prints every HID++ frame; if you add more, gate it behind a flag
3. Do not introduce a dependency on Logi Options+, Solaar, or any external daemon. The whole point of this project is that it runs standalone

For larger changes, open an issue first to discuss the approach.

---

## Maintainer

Maintained by the repository owner. Original protocol work inspired by the wider Logitech HID++ community, with reference to the HID++ 2.0 specification and Solaar's device descriptors.

---

## License

MIT. See `LICENSE` for the full text.

---

## Acknowledgments

- Logitech's HID++ 2.0 specification (publicly documented by the community)
- Solaar (pwr-Solaar/Solaar) for cross-referencing feature IDs and device descriptors
- MX Battery projects for prior art on HID++ 2.0 over Bluetooth on macOS