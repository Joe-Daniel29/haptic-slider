//
//  DeepHaptics.swift
//  haptic-slider
//

import Foundation
import CoreFoundation

/// Private-framework bridge to the Taptic Engine for the REAL force-touch waveforms —
/// including the deep-click "thud" that the public NSHapticFeedbackManager can't produce.
/// Reached via MultitouchSupport.framework's MTActuator API (loaded with dlopen so it
/// works under Apple-Silicon pointer auth). Fully defensive: if anything fails,
/// `available` is false and callers fall back to the public API — never crashes.
///
/// Waveform IDs: 1 weak · 2 strong "Force Touch" click · 3 buzz · 4 light · 5 medium · 6 strong tap.
final class DeepHaptics {
    static let shared = DeepHaptics()

    private typealias CreateListFn     = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetDeviceIDFn    = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateActuatorFn = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenCloseFn      = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuateFn        = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32

    private var createList: CreateListFn?
    private var getDeviceID: GetDeviceIDFn?     // optional symbol — may not exist
    private var createActuator: CreateActuatorFn?
    private var openActuator: OpenCloseFn?
    private var closeActuator: OpenCloseFn?     // optional symbol — may not exist
    private var actuateFn: ActuateFn?

    private var actuator: UnsafeMutableRawPointer?
    /// Throttles reconnect attempts after an actuate failure (trackpad sleep /
    /// Magic Trackpad drop-off) so we don't rescan the device list in a tight loop.
    private var lastReconnect: CFTimeInterval = 0

    var available: Bool { actuator != nil && actuateFn != nil }

    private init() {
        loadSymbols()
        connect()
    }

    private func loadSymbols() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY),
              let sList    = dlsym(handle, "MTDeviceCreateList"),
              let sCreate  = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let sOpen    = dlsym(handle, "MTActuatorOpen"),
              let sActuate = dlsym(handle, "MTActuatorActuate")
        else { return }

        createList     = unsafeBitCast(sList,    to: CreateListFn.self)
        createActuator = unsafeBitCast(sCreate,  to: CreateActuatorFn.self)
        openActuator   = unsafeBitCast(sOpen,    to: OpenCloseFn.self)
        actuateFn      = unsafeBitCast(sActuate, to: ActuateFn.self)
        // Nice-to-have symbols; everything works without them.
        if let s = dlsym(handle, "MTDeviceGetDeviceID") {
            getDeviceID = unsafeBitCast(s, to: GetDeviceIDFn.self)
        }
        if let s = dlsym(handle, "MTActuatorClose") {
            closeActuator = unsafeBitCast(s, to: OpenCloseFn.self)
        }
    }

    /// Candidate device IDs for one MTDevice. The raw struct offset (64) is what
    /// verifiably works today; the MTDeviceGetDeviceID symbol is the safety net for
    /// a future macOS relayout of the (private, undocumented) struct.
    private func deviceIDCandidates(for dev: UnsafeMutableRawPointer) -> [UInt64] {
        var ids: [UInt64] = [UnsafeRawPointer(dev).loadUnaligned(fromByteOffset: 64, as: UInt64.self)]
        if let fn = getDeviceID {
            var id: UInt64 = 0
            if fn(dev, &id) == 0, id != 0, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// (Re)scan the multitouch device list and open the first working actuator
    /// (the trackpad). Safe to call again after a disconnect/reconnect.
    private func connect() {
        guard let createList, let createActuator, let openActuator else { return }
        if let old = actuator {
            _ = closeActuator?(old)
            actuator = nil
        }
        guard let list = createList()?.takeRetainedValue() else { return }
        for i in 0 ..< CFArrayGetCount(list) {
            guard let devPtr = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: devPtr)
            for id in deviceIDCandidates(for: dev) {
                guard let act = createActuator(id) else { continue }
                if openActuator(act) == 0 {   // kIOReturnSuccess
                    actuator = act
                    return
                }
            }
        }
    }

    /// Play a raw waveform. Returns false if the private API is unavailable.
    /// On failure, tries one throttled reconnect (covers a trackpad that slept
    /// or a Magic Trackpad that dropped off and came back) and retries once.
    @discardableResult
    func actuate(_ waveformID: Int32) -> Bool {
        guard let fn = actuateFn else { return false }
        if let act = actuator, fn(act, waveformID, 0, 0, 0) == 0 { return true }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastReconnect > 3 else { return false }
        lastReconnect = now
        connect()
        guard let act = actuator else { return false }
        return fn(act, waveformID, 0, 0, 0) == 0
    }
}
