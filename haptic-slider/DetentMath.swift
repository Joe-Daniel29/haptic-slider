//
//  DetentMath.swift
//  haptic-slider
//
//  Pure detent/endpoint math — deliberately free of AppKit/AX so it can be
//  compiled standalone and unit-tested (see Tests/ + run-tests.sh).
//

import Foundation

/// Tracks one slider's value stream and decides when to fire a detent tick or an
/// endpoint thud. One instance per interaction source (drag / scroll / keyboard),
/// primed at the starting value, fed every subsequent value.
struct DetentTracker {
    /// Effective detent count for this control (after length scaling).
    let detents: Int
    let minV: Double
    let maxV: Double

    private(set) var lastIndex: Int?
    private(set) var atEndpoint = false

    /// Hysteresis: after crossing into an adjacent detent, the value must travel
    /// this fraction of a detent past the boundary before it counts. Kills
    /// double-fires from AX read jitter sitting right on a boundary.
    static let hysteresis = 0.08

    /// ~200 pt is a "standard" slider; the user's detent count applies to that,
    /// then scales with the control's physical length so detent *density* stays
    /// constant — like real hardware. Clamped so tiny/huge sliders stay sane.
    static func scaledDetents(base: Int, length: Double?) -> Int {
        guard let length, length > 0 else { return base }
        return min(64, max(4, Int((Double(base) * length / 200.0).rounded())))
    }

    enum Event: Equatable {
        case detent    // crossed a detent boundary
        case endpoint  // arrived at 0 / max — the firm "thud"
    }

    init(baseDetents: Int, minV: Double, maxV: Double, length: Double? = nil) {
        self.detents = Self.scaledDetents(base: baseDetents, length: length)
        // Degenerate/missing range → assume normalized 0…1 (matches AX fallback).
        if maxV > minV {
            self.minV = minV
            self.maxV = maxV
        } else {
            self.minV = 0
            self.maxV = 1
        }
    }

    private func norm(_ v: Double) -> Double {
        min(1, max(0, (v - minV) / (maxV - minV)))
    }

    func isEndpoint(_ v: Double) -> Bool {
        let n = norm(v)
        return n <= 0.003 || n >= 0.997
    }

    private func index(of v: Double) -> Int {
        min(detents - 1, Int((norm(v) * Double(detents)).rounded(.towardZero)))
    }

    /// Set the baseline at grab/focus time — no event fires for the starting
    /// position (grabbing a slider already at an end must not thud).
    mutating func prime(_ v: Double) {
        lastIndex = index(of: v)
        atEndpoint = isEndpoint(v)
    }

    /// Everything one value-step decided — what fired and why/why not.
    /// Consumed by the engine's diagnostics log; `update` keeps the simple API.
    struct Outcome {
        var event: Event?
        var index: Int
        var previousIndex: Int?
        var boundariesCrossed: Int      // |idx − last| when a move registered, else 0
        var hysteresisSuppressed: Bool  // a crossing happened but jitter-filtering ate it
        var fraction: Double            // position within the current detent, 0…1
    }

    /// Feed a new value; returns the haptic event it warrants, if any.
    mutating func update(_ v: Double, endpointPulse: Bool) -> Event? {
        step(v, endpointPulse: endpointPulse).event
    }

    /// Like `update`, but reports the full decision for diagnostics.
    mutating func step(_ v: Double, endpointPulse: Bool) -> Outcome {
        let p = norm(v) * Double(detents)
        let idx = min(detents - 1, Int(p.rounded(.towardZero)))
        // Fraction into the current detent (1.0 when pinned at max, so the top
        // detent isn't permanently suppressed by the hysteresis check below).
        let frac = p >= Double(detents) ? 1.0 : p - p.rounded(.down)
        var out = Outcome(event: nil, index: idx, previousIndex: lastIndex,
                          boundariesCrossed: 0, hysteresisSuppressed: false, fraction: frac)

        // Endpoints (0.000 / max): a firm "thud", fired once on arrival.
        if endpointPulse && isEndpoint(v) {
            if !atEndpoint {
                atEndpoint = true
                out.boundariesCrossed = lastIndex.map { abs(idx - $0) } ?? 0
                lastIndex = idx
                out.event = .endpoint
            }
            return out
        }
        atEndpoint = false

        guard let last = lastIndex else {
            lastIndex = idx
            return out
        }
        guard idx != last else { return out }
        // Adjacent-detent hysteresis: barely past the boundary is jitter, not a move.
        if idx == last + 1, frac < Self.hysteresis { out.hysteresisSuppressed = true; return out }
        if idx == last - 1, frac > 1 - Self.hysteresis { out.hysteresisSuppressed = true; return out }
        out.boundariesCrossed = abs(idx - last)
        lastIndex = idx
        out.event = .detent
        return out
    }
}
