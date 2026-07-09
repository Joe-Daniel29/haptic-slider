# Haptic Slider

Adds trackpad **haptic feedback** when you interact with native macOS sliders — brightness, volume, and any standard system slider. The tactile "detent" clicks you feel dragging sliders on iPhone, brought to the Mac's Force Touch trackpad, system-wide.

Works when you **drag** a slider, **scroll** the wheel over one, or nudge a focused slider with the **arrow keys**.

Runs quietly as a **menu-bar app** (no dock icon).

<!-- Optional: drop a screenshot/GIF here -->

## Requirements

- **A Force Touch trackpad** (built-in on modern MacBooks, or a Magic Trackpad 2+). Haptics do **not** work with a regular mouse.
- macOS 14 or later (developed on macOS 26).
- Xcode, to build from source.

## How it works

When you grab a native slider, the app identifies it via the macOS **Accessibility API** (`AXSlider`), locks onto that element, and tracks its value for the whole drag — value changes are pushed via an `AXObserver`, with event polling as fallback. Each time the value crosses a detent boundary it fires a Force Touch tap (`NSHapticFeedbackManager`); hitting either end gives a firm "thud". Detent density scales with the slider's physical length, so short and long sliders feel consistent. Hover detection is event-driven and throttled, so it uses almost no energy when idle.

It reads a slider's **numeric position only** — never your content, text, or keystrokes.

## Build & run

1. Open `haptic-slider.xcodeproj` in Xcode and press **⌘R**.
   *(The project uses automatic "Sign to Run Locally" signing — no Apple Developer account needed.)*
2. Or from the command line:
   ```sh
   xcodebuild -project haptic-slider.xcodeproj -scheme haptic-slider -destination 'platform=macOS' build
   ```

To run the unit tests for the detent math:

```sh
./run-tests.sh
```

## First launch

1. Click the **menu-bar icon** → **Grant Access…** (a setup window also opens on first launch, or whenever access is missing).
2. Enable **haptic-slider** in **System Settings → Privacy & Security → Accessibility**.
3. It auto-enables. Open **System Settings → Displays** and drag the **brightness** slider — you'll feel the detents.

## Settings (menu-bar panel)

- **Enable slider haptics** — master on/off
- **Scroll & arrow-key haptics** — ticks when scrolling the wheel over a slider or nudging a focused slider with arrow keys
- **Strong pulse at ends** — the firm "thud" when a slider hits 0 or max
- **Launch at login**
- **Setup Guide…** — re-opens the welcome/setup window
- **Developer Mode** — reveals diagnostics plus tuning (feedback pattern, detent count, thud waveform, a test slider)

## Installing a prebuilt copy (for non-developers)

The app isn't notarized (that requires a paid Apple Developer account), so macOS **quarantines** any copy downloaded from the internet and refuses to open it — on recent macOS the old *right-click → Open* trick no longer works for un-notarized apps.

1. Move **haptic-slider.app** to **/Applications**.
2. Remove the quarantine flag (Terminal):
   ```sh
   xattr -dr com.apple.quarantine "/Applications/haptic-slider.app"
   ```
   *Alternatively: try to open the app once, then go to System Settings → Privacy & Security and click **Open Anyway**.*
3. Launch it and grant Accessibility access as above.

Copies built locally with Xcode, or transferred by AirDrop/USB, are not quarantined and skip step 2.

## Limitations

- Works on native AppKit sliders. Custom-drawn sliders in some apps (certain Electron/web UIs) don't expose Accessibility roles and won't trigger haptics.
- Not notarized — see the install note above. Seamless install for any user requires notarization (a paid Apple Developer account).

## Project layout

| File | What it is |
|---|---|
| `haptic_sliderApp.swift` | App entry, single-instance guard, welcome-window lifecycle |
| `HapticEngine.swift` | The engine: hover detection, drag lock, AXObserver, scroll/keyboard haptics |
| `DetentMath.swift` | Pure detent/endpoint math (unit-tested via `Tests/`) |
| `DeepHaptics.swift` | Private MultitouchSupport bridge for the real Taptic waveforms |
| `MenuContent.swift` | Menu-bar control panel |
| `WelcomeView.swift` | First-run / setup window |
| `DiagnosticsView.swift` | Developer Mode diagnostics + test slider |

## License

MIT — see `LICENSE`.
