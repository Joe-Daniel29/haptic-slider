//
//  ContentView.swift
//  haptic-slider
//
//  Created by Joe Daniel on 06/07/26.
//

import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement
import Combine

/// Thin wrapper around the public Force Touch haptics API.
/// Only does anything on a Force Touch trackpad / Magic Trackpad 2+ — a mouse feels nothing.
enum Haptics {
    static func fire(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}

/// Private-framework bridge to the Taptic Engine for the REAL force-touch waveforms —
/// including the deep-click "thud" that the public NSHapticFeedbackManager can't produce.
/// Reached via MultitouchSupport.framework's MTActuator API (loaded with dlopen so it
/// works under Apple-Silicon pointer auth). Fully defensive: if anything fails,
/// `available` is false and callers fall back to the public API — never crashes.
///
/// Waveform IDs: 1 weak · 2 strong "Force Touch" click · 3 buzz · 4 light · 5 medium · 6 strong tap.
final class DeepHaptics {
    static let shared = DeepHaptics()

    private typealias CreateListFn    = @convention(c) () -> Unmanaged<CFArray>?
    private typealias CreateActuatorFn = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenFn          = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuateFn       = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32

    private var actuator: UnsafeMutableRawPointer?
    private var actuateFn: ActuateFn?

    var available: Bool { actuator != nil && actuateFn != nil }

    private init() { setup() }

    private func setup() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY),
              let sList    = dlsym(handle, "MTDeviceCreateList"),
              let sCreate  = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let sOpen    = dlsym(handle, "MTActuatorOpen"),
              let sActuate = dlsym(handle, "MTActuatorActuate")
        else { return }

        let createList     = unsafeBitCast(sList,    to: CreateListFn.self)
        let createActuator = unsafeBitCast(sCreate,  to: CreateActuatorFn.self)
        let open           = unsafeBitCast(sOpen,    to: OpenFn.self)
        let actuate        = unsafeBitCast(sActuate, to: ActuateFn.self)

        guard let list = createList()?.takeRetainedValue() else { return }
        // Pick the first device that actually has an actuator we can open (the trackpad).
        for i in 0 ..< CFArrayGetCount(list) {
            guard let devPtr = CFArrayGetValueAtIndex(list, i) else { continue }
            // MTDeviceGetDeviceID is unstable; the device ID lives at struct offset 64.
            let deviceID = UnsafeRawPointer(devPtr).loadUnaligned(fromByteOffset: 64, as: UInt64.self)
            guard let act = createActuator(deviceID) else { continue }
            if open(act) == 0 {   // kIOReturnSuccess
                actuator = act
                actuateFn = actuate
                return
            }
        }
    }

    /// Play a raw waveform. Returns false if the private API is unavailable.
    @discardableResult
    func actuate(_ waveformID: Int32) -> Bool {
        guard let act = actuator, let fn = actuateFn else { return false }
        return fn(act, waveformID, 0, 0, 0) == 0
    }
}

/// System-wide slider haptics.
///
/// Per-frame hit-testing loses the slider mid-drag (the cursor sits on the thumb, which
/// reports as an AXGroup). So we detect the AXSlider on *hover*, LOCK its element reference
/// on mouse-down, and read that locked reference's value for the whole drag — firing one
/// haptic each time the value crosses a detent boundary. Hover detection is event-driven
/// and throttled, so the app does no work when the mouse is still (near-zero idle energy).
final class HapticEngine: ObservableObject {
    static let shared = HapticEngine()

    @Published var trusted = AXIsProcessTrusted()
    @Published var engineOn = false
    @Published var status = "idle"
    @Published var valueText = "—"
    @Published var tickCount = 0
    @Published var pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment {
        didSet { UserDefaults.standard.set(pattern.rawValue, forKey: "pattern") }
    }
    @Published var detents = 32 {
        didSet { UserDefaults.standard.set(detents, forKey: "detents") }
    }
    @Published var endpointPulse = true {
        didSet { UserDefaults.standard.set(endpointPulse, forKey: "endpointPulse") }
    }
    /// Taptic waveform ID for the "hit the wall" pulse at the ends.
    /// 1 weak · 2 strong Force-Touch click (the deep thud) · 3 buzz · 4 light · 5 medium · 6 strong tap.
    @Published var endpointStyle = 2 {
        didSet { UserDefaults.standard.set(endpointStyle, forKey: "endpointStyle") }
    }

    /// Persisted user intent (independent of whether we're currently trusted/running).
    private(set) var enabledPref: Bool

    private var trustTimer: Timer?
    private var lastHover: CFTimeInterval = 0
    private var monitors: [Any] = []

    private let sysWide = AXUIElementCreateSystemWide()
    private let axQueue = DispatchQueue(label: "haptic.ax.probe")

    private var hoveredSlider: AXUIElement?
    private var activeSlider: AXUIElement?
    private var lastIndex = 0
    private var atEndpoint = false
    private var lastActuation: CFTimeInterval = 0
    private var minV = 0.0
    private var maxV = 1.0

    init() {
        let d = UserDefaults.standard
        enabledPref = d.object(forKey: "enabled") as? Bool ?? true
        if let raw = d.object(forKey: "pattern") as? Int,
           let p = NSHapticFeedbackManager.FeedbackPattern(rawValue: raw) { pattern = p }
        if let n = d.object(forKey: "detents") as? Int, n > 0 { detents = n }
        if let e = d.object(forKey: "endpointPulse") as? Bool { endpointPulse = e }
        if let s = d.object(forKey: "endpointStyle") as? Int { endpointStyle = s }

        // Poll trust so the dot goes green the instant access is granted — and auto-start
        // the engine once we're trusted, if the user left it enabled.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = AXIsProcessTrusted()
            if now != self.trusted { self.trusted = now }
            if now && self.enabledPref && !self.engineOn { self.start() }
        }
        RunLoop.main.add(t, forMode: .common)
        trustTimer = t

        if trusted && enabledPref { start() }
    }

    /// Triggers the system prompt → System Settings → Privacy & Security → Accessibility.
    func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    func setEnabled(_ on: Bool) {
        enabledPref = on
        UserDefaults.standard.set(on, forKey: "enabled")
        on ? start() : stop()
    }

    func start() {
        guard trusted else { return }
        stop(clearPref: false)
        engineOn = true
        status = "on — drag a slider"
        tickCount = 0

        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.onDown() }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.onDrag() }
        let up   = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.onUp() }
        let move = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.onMove() }
        monitors = [down, drag, up, move].compactMap { $0 }
    }

    func stop(clearPref: Bool = false) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        hoveredSlider = nil
        activeSlider = nil
        engineOn = false
        status = "off"
        valueText = "—"
        if clearPref { enabledPref = false }
    }

    // MARK: - Hover (throttled, event-driven)

    private func onMove() {
        guard activeSlider == nil else { return }      // dragging → use locked ref
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastHover >= 0.08 else { return }  // cap ~12 Hz while moving
        lastHover = now

        let loc = NSEvent.mouseLocation
        guard let primaryH = NSScreen.screens.first?.frame.height else { return }
        let x = Float(loc.x), y = Float(primaryH - loc.y)

        axQueue.async { [weak self] in
            guard let self else { return }
            var el: AXUIElement?
            let found = (AXUIElementCopyElementAtPosition(self.sysWide, x, y, &el) == .success)
                ? el.flatMap { self.sliderElement($0) } : nil
            DispatchQueue.main.async {
                guard self.activeSlider == nil, self.engineOn else { return }
                self.hoveredSlider = found
                self.status = found != nil ? "over a slider — grab it" : "on — drag a slider"
            }
        }
    }

    // MARK: - Drag lifecycle

    private func onDown() {
        guard let slider = hoveredSlider else { activeSlider = nil; return }
        activeSlider = slider
        readRange(slider)
        if let v = readValue(slider) {
            lastIndex = detentIndex(v)
            atEndpoint = isAtEndpoint(v)   // don't thud just because we grabbed at an end
            valueText = String(format: "%.3f", v)
        }
        status = "🔒 tracking slider"
    }

    private func onDrag() {
        guard let slider = activeSlider, let v = readValue(slider) else { return }
        valueText = String(format: "%.3f", v)
        let idx = detentIndex(v)

        // Endpoints (0.000 / max): a firm "thud", fired once on arrival.
        if endpointPulse && isAtEndpoint(v) {
            if !atEndpoint {
                atEndpoint = true
                lastIndex = idx
                fireThud()
                tickCount += 1
            }
            return
        }
        atEndpoint = false

        if idx != lastIndex {
            lastIndex = idx
            fireDetent()
            tickCount += 1
        }
    }

    private func isAtEndpoint(_ v: Double) -> Bool {
        let norm = maxV > minV ? (v - minV) / (maxV - minV) : v
        return norm <= 0.003 || norm >= 0.997
    }

    /// One detent tick. Routed through the engine so it knows when it last actuated.
    func fireDetent() {
        Haptics.fire(pattern)
        lastActuation = CFAbsoluteTimeGetCurrent()
    }

    /// The "hit the wall" feel at 0 / max, using the real Taptic waveform (deep click) via
    /// the private API. If a detent fired within the Taptic re-arm window, a fast fling
    /// would otherwise swallow the thud — so hold it just long enough for the engine to be
    /// ready. On the endpoint that ~45 ms is imperceptible but makes the thud reliable.
    func fireThud() {
        let since = CFAbsoluteTimeGetCurrent() - lastActuation
        let play = { [weak self] in
            guard let self else { return }
            if !DeepHaptics.shared.actuate(Int32(self.endpointStyle)) {
                Haptics.fire(.alignment)   // fallback when the private API is unavailable
            }
            self.lastActuation = CFAbsoluteTimeGetCurrent()
        }
        if since < 0.045 {
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.045 - since), execute: play)
        } else {
            play()
        }
    }

    private func onUp() {
        let slider = activeSlider
        let alreadyThudded = atEndpoint
        activeSlider = nil
        atEndpoint = false
        status = engineOn ? "on — drag a slider" : "off"

        // A fast fling settles at the end AFTER the last drag event, and AX value reads
        // lag during quick motion — so poll a few times as it comes to rest.
        if endpointPulse, !alreadyThudded, let slider {
            checkEndpointSettle(slider, attempt: 0)
        }
    }

    private func checkEndpointSettle(_ slider: AXUIElement, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
            guard let self, self.engineOn, self.activeSlider == nil else { return }
            if let v = self.readValue(slider), self.isAtEndpoint(v) {
                self.fireThud()
                self.tickCount += 1
            } else if attempt < 3 {
                self.checkEndpointSettle(slider, attempt: attempt + 1)   // ~35/70/105/140ms
            }
        }
    }

    private func detentIndex(_ v: Double) -> Int {
        let norm = maxV > minV ? (v - minV) / (maxV - minV) : v
        return Int((norm * Double(detents)).rounded(.towardZero))
    }

    // MARK: - AX helpers

    private func sliderElement(_ el: AXUIElement, maxDepth: Int = 5) -> AXUIElement? {
        var current: AXUIElement? = el
        var depth = 0
        while let c = current, depth < maxDepth {
            if role(of: c) == (kAXSliderRole as String) { return c }
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &parent) == .success,
               let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() {
                current = (p as! AXUIElement)
            } else {
                current = nil
            }
            depth += 1
        }
        return nil
    }

    private func role(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success,
              let s = v as? String else { return nil }
        return s
    }

    private func readValue(_ el: AXUIElement) -> Double? { readNumber(el, kAXValueAttribute) }

    private func readRange(_ el: AXUIElement) {
        minV = readNumber(el, kAXMinValueAttribute) ?? 0.0
        maxV = readNumber(el, kAXMaxValueAttribute) ?? 1.0
        if maxV <= minV { minV = 0.0; maxV = 1.0 }
    }

    private func readNumber(_ el: AXUIElement, _ attr: String) -> Double? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == CFNumberGetTypeID() else { return nil }
        var d = 0.0
        CFNumberGetValue((val as! CFNumber), .doubleType, &d)
        return d
    }
}

// MARK: - Menu-bar control panel

struct MenuContent: View {
    @ObservedObject var engine: HapticEngine
    @AppStorage("developerMode") private var developerMode = false
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.point.up.braille")
                Text("Haptic Slider Control").font(.headline)
                Spacer()
                Circle()
                    .fill(engine.engineOn ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
            }

            if !engine.trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility access needed").font(.subheadline).bold()
                    Text("Haptic Slider watches which slider you're dragging to add trackpad "
                         + "feedback. It reads a slider's position only — never your content.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Grant Access…") { engine.requestTrust() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            row("Enable slider haptics") {
                Toggle("", isOn: Binding(get: { engine.engineOn },
                                         set: { engine.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).disabled(!engine.trusted)
            }
            row("Strong pulse at ends") {
                Toggle("", isOn: $engine.endpointPulse)
                    .labelsHidden().toggleStyle(.switch)
            }
            row("Launch at login") {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            }

            Divider()

            row("Developer Mode") {
                Toggle("", isOn: $developerMode)
                    .labelsHidden().toggleStyle(.checkbox)
            }
            if developerMode { DiagnosticsView(engine: engine) }

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 280)
        .onAppear { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
    }

    /// A settings row: label on the left, control flush to the right edge (macOS style).
    @ViewBuilder
    private func row<Control: View>(_ label: String,
                                    @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            control()
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

// MARK: - First-run welcome (so it never "silently" launches into nothing)

struct WelcomeView: View {
    @ObservedObject var engine = HapticEngine.shared
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 76, height: 76)

            VStack(spacing: 4) {
                Text("Haptic Slider Control").font(.title2.bold())
                Text("It's now running in your menu bar.").foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.up.forward").foregroundStyle(.tint).font(.title3)
                Text("Look for the braille icon at the **top-right** of your screen. "
                     + "Click it anytime to change settings or turn it off.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            if engine.trusted {
                Label("Ready — drag any slider to feel it", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            } else {
                VStack(spacing: 10) {
                    Text("One quick step to turn it on:").font(.callout).foregroundStyle(.secondary)
                    Button("Grant Accessibility Access…") { engine.requestTrust() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Text("This lets it detect which slider you're dragging. "
                         + "It never reads your content or keystrokes.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(engine.trusted ? "Done" : "I'll do it later") { onDone() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 380)
    }
}

// MARK: - Developer Mode diagnostics (the old test harness)

struct DiagnosticsView: View {
    @ObservedObject var engine: HapticEngine

    private let waveforms: [(id: Int, name: String)] = [
        (1, "1 · weak"), (2, "2 · deep"), (3, "3 · buzz"),
        (4, "4 · light"), (5, "5 · medium"), (6, "6 · strong"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEVELOPER").font(.caption2.bold()).foregroundStyle(.tertiary)

            // Live state — confirms the engine is detecting a slider and firing.
            HStack(spacing: 6) {
                Circle().fill(engine.engineOn ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(engine.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("val \(engine.valueText)").font(.system(.caption2, design: .monospaced))
                Text("· \(engine.tickCount)")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.green)
            }
            Text(DeepHaptics.shared.available ? "Deep haptics: ON" : "Deep haptics: off — public fallback")
                .font(.caption2)
                .foregroundStyle(DeepHaptics.shared.available ? .green : .orange)

            Divider()

            // Tuning — moved here from the main panel. Label left, control right.
            settingRow("Feedback") {
                Picker("", selection: $engine.pattern) {
                    Text("Alignment").tag(NSHapticFeedbackManager.FeedbackPattern.alignment)
                    Text("Generic").tag(NSHapticFeedbackManager.FeedbackPattern.generic)
                    Text("Level").tag(NSHapticFeedbackManager.FeedbackPattern.levelChange)
                }
                .labelsHidden().fixedSize().controlSize(.small)
            }
            settingRow("Detents") {
                Picker("", selection: $engine.detents) {
                    ForEach([8, 16, 24, 32], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            settingRow("Thud waveform") {
                Picker("", selection: $engine.endpointStyle) {
                    ForEach(waveforms, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
            }

            Divider()

            // A precise test slider (driven by its own value, not Accessibility) —
            // drag it to feel detents + the end thud without leaving the app.
            Text("Try it — drag this").font(.caption2).foregroundStyle(.secondary)
            HapticTestSlider(engine: engine)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    /// A settings row: caption label on the left, control flush right.
    @ViewBuilder
    private func settingRow<Control: View>(_ label: String,
                                           @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            control()
        }
    }
}

/// In-app test slider. Because it owns its value, haptics fire on the exact value change
/// (no Accessibility lag) — so the end thud never gets missed, even on a fast fling.
struct HapticTestSlider: View {
    @ObservedObject var engine: HapticEngine

    @State private var value = 0.5
    @State private var lastIdx = -1
    @State private var atEnd = false

    var body: some View {
        Slider(value: $value, in: 0...1) { editing in
            if editing { lastIdx = idx(value); atEnd = isEnd(value) }   // reset on grab
        }
        .controlSize(.small)
        .onChange(of: value) { _, v in handle(v) }
    }

    private func isEnd(_ v: Double) -> Bool { v <= 0.0005 || v >= 0.9995 }
    private func idx(_ v: Double) -> Int { Int((v * Double(engine.detents)).rounded(.towardZero)) }

    private func handle(_ v: Double) {
        if isEnd(v) {
            if !atEnd { atEnd = true; engine.fireThud() }
            return
        }
        atEnd = false
        let i = idx(v)
        if i != lastIdx { lastIdx = i; engine.fireDetent() }
    }
}
