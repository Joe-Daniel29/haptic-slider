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
    @Published var detents = 16 {
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
            Haptics.fire(pattern)
            tickCount += 1
        }
    }

    private func isAtEndpoint(_ v: Double) -> Bool {
        let norm = maxV > minV ? (v - minV) / (maxV - minV) : v
        return norm <= 0.0005 || norm >= 0.9995
    }

    /// The "hit the wall" feel at 0 / max. Uses the real Taptic waveform (the deep click)
    /// via the private API; if that's unavailable, falls back to a tight public double-tap.
    func fireThud() {
        if DeepHaptics.shared.actuate(Int32(endpointStyle)) { return }
        Haptics.fire(.alignment)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.010) { Haptics.fire(.alignment) }
    }

    private func onUp() {
        activeSlider = nil
        status = engineOn ? "on — drag a slider" : "off"
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
    @AppStorage("menuIcon") private var menuIcon = "hand.point.up.braille"
    @State private var launchAtLogin = false

    /// Curated menu-bar icon choices (all valid SF Symbols, template-friendly).
    private let iconOptions: [(symbol: String, label: String)] = [
        ("slider.horizontal.3", "Slider"),
        ("hand.tap", "Tap"),
        ("hand.point.up.braille", "Braille"),
        ("waveform", "Waveform"),
        ("wave.3.right", "Waves"),
        ("dot.radiowaves.left.and.right", "Signal"),
    ]

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

            Toggle("Enable slider haptics", isOn: Binding(
                get: { engine.engineOn },
                set: { engine.setEnabled($0) }))
                .toggleStyle(.switch)
                .disabled(!engine.trusted)

            Picker("Feedback", selection: $engine.pattern) {
                Text("Alignment").tag(NSHapticFeedbackManager.FeedbackPattern.alignment)
                Text("Generic").tag(NSHapticFeedbackManager.FeedbackPattern.generic)
                Text("Level").tag(NSHapticFeedbackManager.FeedbackPattern.levelChange)
            }

            HStack {
                Text("Detents")
                Spacer()
                Picker("", selection: $engine.detents) {
                    ForEach([8, 16, 24, 32], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }

            Toggle("Strong pulse at ends (0 & max)", isOn: $engine.endpointPulse)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }

            HStack(spacing: 6) {
                Text("Menu bar icon")
                Spacer()
                ForEach(iconOptions, id: \.symbol) { opt in
                    Button { menuIcon = opt.symbol } label: {
                        Image(systemName: opt.symbol)
                            .frame(width: 26, height: 22)
                            .background(menuIcon == opt.symbol ? Color.accentColor.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(opt.label)
                }
            }

            Divider()

            Toggle("Developer Mode", isOn: $developerMode).font(.caption)
            if developerMode { DiagnosticsView(engine: engine) }

            Divider()

            HStack {
                Button("Setup Guide") { (NSApp.delegate as? AppDelegate)?.showWelcome() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
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

    @State private var isBuzzing = false
    @State private var buzzTimer: Timer?
    @State private var burstIntervalMs = 80
    @State private var burstTimer: Timer?
    @State private var burstRemaining = 0
    @State private var burstFired = 0
    @State private var activityToken: NSObjectProtocol?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(engine.status).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("val \(engine.valueText)").font(.system(.caption2, design: .monospaced))
                Text("ticks \(engine.tickCount)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
            }

            HStack(spacing: 6) {
                Button("Generic") { Haptics.fire(.generic) }
                Button("Align")   { Haptics.fire(.alignment) }
                Button("Level")   { Haptics.fire(.levelChange) }
            }
            .buttonStyle(.bordered).controlSize(.small)

            HStack(spacing: 6) {
                Text("End waveform").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $engine.endpointStyle) {
                    Text("1 · weak").tag(1)
                    Text("2 · strong (deep)").tag(2)
                    Text("3 · buzz").tag(3)
                    Text("4 · light").tag(4)
                    Text("5 · medium").tag(5)
                    Text("6 · strong tap").tag(6)
                }
                .labelsHidden().fixedSize().controlSize(.small)
                Button("Test") { engine.fireThud() }.controlSize(.small)
            }
            Text(DeepHaptics.shared.available
                 ? "Deep haptics: ON (real Taptic waveforms)"
                 : "Deep haptics: unavailable — using fallback")
                .font(.caption2)
                .foregroundStyle(DeepHaptics.shared.available ? .green : .orange)

            HStack(spacing: 8) {
                Toggle("Buzz", isOn: $isBuzzing)
                    .toggleStyle(.switch).controlSize(.mini)
                    .onChange(of: isBuzzing) { _, on in on ? startBuzz() : stopBuzz() }
                Picker("", selection: $burstIntervalMs) {
                    ForEach([30, 50, 80, 120], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                Button("Burst") { startBurst() }.disabled(burstRemaining > 0).controlSize(.small)
                Text("\(burstFired)/12").font(.system(.caption2, design: .monospaced))
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .onDisappear { stopBuzz(); stopBurst() }
    }

    private func beginActivityIfNeeded() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "haptic timing")
    }
    private func endActivityIfIdle() {
        guard buzzTimer == nil, burstTimer == nil, let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
    }

    private func startBuzz() {
        stopBuzz(); beginActivityIfNeeded()
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in Haptics.fire(.levelChange) }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        buzzTimer = timer
    }
    private func stopBuzz() { buzzTimer?.invalidate(); buzzTimer = nil; endActivityIfIdle() }

    private func startBurst() {
        stopBurst(); beginActivityIfNeeded()
        burstRemaining = 12; burstFired = 0
        let timer = Timer(timeInterval: TimeInterval(burstIntervalMs) / 1000.0, repeats: true) { _ in
            Haptics.fire(.levelChange)
            withAnimation { burstFired += 1 }
            burstRemaining -= 1
            if burstRemaining <= 0 { stopBurst() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        burstTimer = timer
    }
    private func stopBurst() { burstTimer?.invalidate(); burstTimer = nil; burstRemaining = 0; endActivityIfIdle() }
}
