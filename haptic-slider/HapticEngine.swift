//
//  HapticEngine.swift
//  haptic-slider
//

import SwiftUI
import AppKit
import ApplicationServices
import Combine

/// Thin wrapper around the public Force Touch haptics API.
/// Only does anything on a Force Touch trackpad / Magic Trackpad 2+ — a mouse feels nothing.
enum Haptics {
    static func fire(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}

/// System-wide slider haptics.
///
/// Per-frame hit-testing loses the slider mid-drag (the cursor sits on the thumb, which
/// reports as an AXGroup). So we detect the AXSlider on *hover*, LOCK its element reference
/// on mouse-down, and track that locked reference for the whole drag — via an AXObserver
/// (value changes are pushed to us, so fast flings can't outrun our reads) with the drag
/// events as a polling fallback. Hover detection is event-driven and throttled, so the app
/// does no work when the mouse is still (near-zero idle energy).
///
/// Scroll-wheel ticks over a hovered slider and arrow-key nudges on a focused slider get
/// the same detent treatment (toggleable via `scrollKeyHaptics`).
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
    /// Detent count for a ~200 pt slider; the effective count scales with each
    /// control's physical length (see DetentTracker.scaledDetents).
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
    /// Haptics for scroll-wheel ticks over a slider and arrow-key nudges on a
    /// keyboard-focused slider.
    @Published var scrollKeyHaptics = true {
        didSet { UserDefaults.standard.set(scrollKeyHaptics, forKey: "scrollKeyHaptics") }
    }

    /// Persisted user intent (independent of whether we're currently trusted/running).
    private(set) var enabledPref: Bool

    private var trustTimer: Timer?
    private var lastHover: CFTimeInterval = 0
    private var monitors: [Any] = []

    private let sysWide = AXUIElementCreateSystemWide()
    private let axQueue = DispatchQueue(label: "haptic.ax.probe")

    // Drag state — the locked slider and its detent tracker.
    private var hoveredSlider: AXUIElement?
    private var activeSlider: AXUIElement?
    private var dragTracker: DetentTracker?
    private var axObserver: AXObserver?
    private var lastActuation: CFTimeInterval = 0

    // Scroll-wheel state — primed at hover time so the first tick isn't swallowed.
    private var scrollTracker: DetentTracker?
    private var lastScrollRead: CFTimeInterval = 0

    // Keyboard state — the last focused slider we saw, so repeated arrow presses
    // compare against a stable baseline.
    private var keySlider: AXUIElement?
    private var keyTracker: DetentTracker?

    init() {
        let d = UserDefaults.standard
        enabledPref = d.object(forKey: "enabled") as? Bool ?? true
        if let raw = d.object(forKey: "pattern") as? Int,
           let p = NSHapticFeedbackManager.FeedbackPattern(rawValue: raw) { pattern = p }
        if let n = d.object(forKey: "detents") as? Int, n > 0 { detents = n }
        if let e = d.object(forKey: "endpointPulse") as? Bool { endpointPulse = e }
        if let s = d.object(forKey: "endpointStyle") as? Int { endpointStyle = s }
        if let sk = d.object(forKey: "scrollKeyHaptics") as? Bool { scrollKeyHaptics = sk }

        // Cap how long any AX call into another app can stall us — a hung target
        // app must never freeze the engine (or our own UI).
        AXUIElementSetMessagingTimeout(sysWide, 0.1)

        if trusted {
            if enabledPref { start() }
        } else {
            startTrustPolling()
        }
    }

    /// Poll trust so the dot goes green the instant access is granted — and auto-start
    /// the engine once we're trusted, if the user left it enabled. The timer kills
    /// itself as soon as trust lands, so there's zero recurring idle work afterwards.
    private func startTrustPolling() {
        trustTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            self.trusted = true
            if self.enabledPref && !self.engineOn { self.start() }
            self.trustTimer?.invalidate()
            self.trustTimer = nil
        }
        RunLoop.main.add(t, forMode: .common)
        trustTimer = t
    }

    /// Re-check trust on demand (called when the menu panel opens) — covers the
    /// rare case of access being revoked while we're running.
    func refreshTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        if now {
            if enabledPref && !engineOn { start() }
        } else {
            stop()
            startTrustPolling()
        }
    }

    /// Triggers the system prompt → System Settings → Privacy & Security → Accessibility.
    func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted { startTrustPolling() }
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

        let down   = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.onDown() }
        let drag   = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.onDrag() }
        let up     = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.onUp() }
        let move   = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.onMove() }
        let scroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in self?.onScroll() }
        let key    = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.onKey(e) }
        monitors = [down, drag, up, move, scroll, key].compactMap { $0 }
    }

    func stop(clearPref: Bool = false) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        removeObserver()
        hoveredSlider = nil
        activeSlider = nil
        dragTracker = nil
        scrollTracker = nil
        keySlider = nil
        keyTracker = nil
        pendingTicks = 0
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
            // Prime the scroll tracker here (hover time) so a scroll-wheel tick's
            // *first* detent isn't lost establishing a baseline.
            let tracker = found.map { self.makeTracker(for: $0) }
            DispatchQueue.main.async {
                guard self.activeSlider == nil, self.engineOn else { return }
                self.hoveredSlider = found
                self.scrollTracker = tracker
                self.status = found != nil ? "over a slider — grab it" : "on — drag a slider"
            }
        }
    }

    // MARK: - Drag lifecycle

    private func onDown() {
        guard let slider = hoveredSlider else {
            activeSlider = nil
            dragTracker = nil
            return
        }
        activeSlider = slider
        pendingTicks = 0   // a fresh grab never inherits queued ticks
        // A hung target app must not stall us mid-drag beyond 50 ms per read.
        AXUIElementSetMessagingTimeout(slider, 0.05)
        var tracker = makeTracker(for: slider)
        if let v = readValue(slider) {
            tracker.prime(v)   // don't thud just because we grabbed at an end
            valueText = String(format: "%.3f", v)
        }
        dragTracker = tracker
        installObserver(on: slider)
        status = "🔒 tracking slider"

        // Identify this drag in the diagnostics log.
        var pid: pid_t = 0
        AXUIElementGetPid(slider, &pid)
        DiagLog.shared.log([
            "ev": "grab", "src": "drag",
            "app": NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)",
            "desc": readString(slider, kAXDescriptionAttribute)
                ?? readString(slider, kAXTitleAttribute) ?? "?",
            "min": tracker.minV, "max": tracker.maxV,
            "len": readLength(slider) ?? -1,
            "detents": tracker.detents,
            "v0": readValue(slider) ?? -1,
            "observer": axObserver != nil,
        ])
    }

    private func onDrag() {
        guard let slider = activeSlider, let v = readValueLogged(slider, src: "drag") else { return }
        process(&dragTracker, v, src: "drag")
    }

    private func onUp() {
        let slider = activeSlider
        let hadObserver = axObserver != nil
        let alreadyThudded = dragTracker?.atEndpoint ?? false
        activeSlider = nil
        status = engineOn ? "on — drag a slider" : "off"
        DiagLog.shared.log(["ev": "release", "ticksTotal": tickCount])

        // A fast fling settles at the end AFTER the last drag event. The AXObserver
        // keeps pushing value changes, so leave it (and the tracker) alive briefly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.activeSlider == nil else { return }   // new drag owns them now
            self.removeObserver()
            self.dragTracker = nil
        }

        // Polling fallback when observer registration failed for this app.
        if !hadObserver, endpointPulse, !alreadyThudded, let slider {
            checkEndpointSettle(slider, attempt: 0)
        }
    }

    private func checkEndpointSettle(_ slider: AXUIElement, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
            guard let self, self.engineOn, self.activeSlider == nil, self.dragTracker != nil else { return }
            if let v = self.readValue(slider) {
                self.process(&self.dragTracker, v, src: "settle")
                if self.dragTracker?.atEndpoint == true { return }
            }
            if attempt < 3 {
                self.checkEndpointSettle(slider, attempt: attempt + 1)   // ~35/70/105/140ms
            }
        }
    }

    // MARK: - AXObserver (value changes pushed during the drag)

    private func installObserver(on slider: AXUIElement) {
        removeObserver()
        var pid: pid_t = 0
        guard AXUIElementGetPid(slider, &pid) == .success else { return }

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let engine = Unmanaged<HapticEngine>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in engine.observedValueChanged(element) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(obs, slider, kAXValueChangedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver = obs
    }

    private func removeObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
    }

    private func observedValueChanged(_ element: AXUIElement) {
        guard engineOn, dragTracker != nil, let v = readValueLogged(element, src: "ax") else { return }
        process(&dragTracker, v, src: "ax")
    }

    // MARK: - Scroll wheel over a hovered slider

    private func onScroll() {
        guard scrollKeyHaptics, activeSlider == nil, let slider = hoveredSlider else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastScrollRead >= 0.02 else { return }   // momentum events come fast
        lastScrollRead = now

        axQueue.async { [weak self] in
            guard let self else { return }
            let v = self.readValue(slider)
            DispatchQueue.main.async {
                guard self.engineOn, self.activeSlider == nil, let v else { return }
                self.process(&self.scrollTracker, v, src: "scroll")
            }
        }
    }

    // MARK: - Arrow keys on a keyboard-focused slider

    private static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]   // ← → ↓ ↑

    private func onKey(_ e: NSEvent) {
        guard scrollKeyHaptics, Self.arrowKeyCodes.contains(e.keyCode) else { return }
        // Give the focused app a beat to apply the nudge, then read the result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.probeFocusedSlider()
        }
    }

    private func probeFocusedSlider() {
        axQueue.async { [weak self] in
            guard let self else { return }
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(self.sysWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return }
            let el = f as! AXUIElement
            guard self.role(of: el) == (kAXSliderRole as String) else { return }

            let isSameSlider = self.keySlider.map { CFEqual($0, el) } ?? false
            let v = self.readValue(el)
            let freshTracker: DetentTracker? = isSameSlider ? nil : self.makeTracker(for: el)
            DispatchQueue.main.async {
                guard self.engineOn else { return }
                if var t = freshTracker {
                    // Newly focused slider: establish the baseline (the first press
                    // primes; subsequent presses tick).
                    if let v { t.prime(v) }
                    self.keySlider = el
                    self.keyTracker = t
                } else if let v {
                    self.process(&self.keyTracker, v, src: "key")
                }
            }
        }
    }

    // MARK: - Detent firing

    /// Feed a value through a tracker and fire whatever it warrants.
    /// Every sample — fired or not — lands in the diagnostics log with the
    /// tracker's full decision, so skipped ticks can be diagnosed per slider.
    private func process(_ tracker: inout DetentTracker?, _ v: Double, src: String) {
        guard var t = tracker else { return }
        let out = t.step(v, endpointPulse: endpointPulse)
        tracker = t
        valueText = String(format: "%.3f", v)

        let fired: String
        switch out.event {
        case .detent:
            // Sparse value streams (Control Centre volume/keyboard update at
            // ~half the rate of brightness) cross 2–3 boundaries per sample.
            // Every crossed boundary earns a tick — the scheduler spaces them.
            enqueueTicks(max(1, out.boundariesCrossed))
            fired = "detent"
        case .endpoint:
            pendingTicks = 0   // the wall supersedes any queued detents
            fireThud(); tickCount += 1
            fired = "endpoint"
        case nil:
            fired = out.hysteresisSuppressed ? "hysteresis-skip" : "none"
        }
        DiagLog.shared.log([
            "ev": "sample", "src": src, "v": v,
            "idx": out.index, "prev": out.previousIndex ?? -1,
            "crossed": out.boundariesCrossed,
            "frac": (out.fraction * 1000).rounded() / 1000,
            "fired": fired,
        ])
    }

    // MARK: - Tick scheduler
    //
    // Fires one tick per crossed detent boundary, never closer together than
    // `tickSpacing` — merged crossings become distinct taps instead of one,
    // and bursty streams get an even rhythm. The backlog is capped so a
    // click-teleport across the track can't queue a buzz.

    private var pendingTicks = 0
    private var tickDrainScheduled = false
    private let tickSpacing: CFTimeInterval = 0.022   // just above the actuator blur threshold
    private let maxPendingTicks = 3

    private func enqueueTicks(_ n: Int) {
        pendingTicks = min(pendingTicks + n, maxPendingTicks)
        drainTicks()
    }

    private func drainTicks() {
        guard !tickDrainScheduled, pendingTicks > 0 else { return }
        let since = CFAbsoluteTimeGetCurrent() - lastActuation
        if since >= tickSpacing {
            pendingTicks -= 1
            fireDetent()
            tickCount += 1
            if pendingTicks > 0 { scheduleDrain(after: tickSpacing) }
        } else {
            scheduleDrain(after: tickSpacing - since)
        }
    }

    private func scheduleDrain(after delay: CFTimeInterval) {
        tickDrainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.tickDrainScheduled = false
            self.drainTicks()
        }
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

    // MARK: - AX helpers

    /// Build a tracker for a slider: its real min/max range plus its physical
    /// length, so detent density stays constant across short and long sliders.
    private func makeTracker(for el: AXUIElement) -> DetentTracker {
        let minV = readNumber(el, kAXMinValueAttribute) ?? 0.0
        let maxV = readNumber(el, kAXMaxValueAttribute) ?? 1.0
        var t = DetentTracker(baseDetents: detents, minV: minV, maxV: maxV, length: readLength(el))
        if let v = readValue(el) { t.prime(v) }
        return t
    }

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

    /// Like `readValue`, but a failed read lands in the diagnostics log with its
    /// AXError — dropped reads are invisible otherwise, and they're the current
    /// suspect for skipped ticks (timeout while the target app is busy).
    private func readValueLogged(_ el: AXUIElement, src: String) -> Double? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
        guard err == .success, let val = v, CFGetTypeID(val) == CFNumberGetTypeID() else {
            DiagLog.shared.log(["ev": "readfail", "src": src, "err": Int(err.rawValue)])
            return nil
        }
        var d = 0.0
        CFNumberGetValue((val as! CFNumber), .doubleType, &d)
        return d
    }

    private func readString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    private func readNumber(_ el: AXUIElement, _ attr: String) -> Double? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == CFNumberGetTypeID() else { return nil }
        var d = 0.0
        CFNumberGetValue((val as! CFNumber), .doubleType, &d)
        return d
    }

    /// The slider's long dimension in points (nil if the app doesn't report a size).
    private func readLength(_ el: AXUIElement) -> Double? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue((val as! AXValue), .cgSize, &size) else { return nil }
        return Double(max(size.width, size.height))
    }
}
