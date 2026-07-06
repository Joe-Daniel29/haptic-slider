# Haptic Slider

Adds trackpad **haptic feedback** when you drag native macOS sliders — brightness, volume, and any standard system slider. The tactile "detent" clicks you feel dragging sliders on iPhone, brought to the Mac's Force Touch trackpad, system-wide.

Runs quietly as a **menu-bar app** (no dock icon).

<!-- Optional: drop a screenshot/GIF here -->

## Requirements

- **A Force Touch trackpad** (built-in on modern MacBooks, or a Magic Trackpad 2+). Haptics do **not** work with a regular mouse.
- macOS 13 or later (developed on macOS 26).
- Xcode, to build from source.

## How it works

When you grab a native slider, the app identifies it via the macOS **Accessibility API** (`AXSlider`), locks onto that element, and reads its value as you drag. Each time the value crosses a detent boundary it fires a Force Touch tap (`NSHapticFeedbackManager`). Hover detection is event-driven and throttled, so it uses almost no energy when idle.

It reads a slider's **numeric position only** — never your content, text, or keystrokes.

## Build & run

1. Open `haptic-slider.xcodeproj` in Xcode and press **⌘R**.
   *(The project uses automatic "Sign to Run Locally" signing — no Apple Developer account needed.)*
2. Or from the command line:
   ```sh
   xcodebuild -project haptic-slider.xcodeproj -scheme haptic-slider -destination 'platform=macOS' build
   ```

## First launch

1. Click the **menu-bar icon** → **Grant Access…**
2. Enable **haptic-slider** in **System Settings → Privacy & Security → Accessibility**.
3. It auto-enables. Open **System Settings → Displays** and drag the **brightness** slider — you'll feel the detents.

## Settings (menu-bar panel)

- **Enable slider haptics** — master on/off
- **Feedback** — Alignment / Generic / Level pattern
- **Detents** — how many taps across a slider (8–32)
- **Launch at login**
- **Menu bar icon** — pick your favorite
- **Developer Mode** — reveals haptic-test diagnostics

## Installing a prebuilt copy (for non-developers)

Because the app isn't notarized, macOS Gatekeeper will warn on first open:

1. Move **haptic-slider.app** to **/Applications**.
2. **Right-click the app → Open**, then confirm **Open** in the dialog
   *(or System Settings → Privacy & Security → **Open Anyway**)*.
3. Grant Accessibility access as above.

## Limitations

- Works on native AppKit sliders. Custom-drawn sliders in some apps (certain Electron/web UIs) don't expose Accessibility roles and won't trigger haptics.
- Not notarized — see the install note above. Seamless install for any user requires notarization (a paid Apple Developer account).

## License

MIT — see `LICENSE`.
