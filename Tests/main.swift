//
//  Tests/main.swift — unit tests for DetentTracker (the pure detent math).
//
//  Run via ./run-tests.sh — compiles this together with the app's
//  DetentMath.swift into a standalone binary; no Xcode test target needed.
//

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("  ok — \(name)") } else { failures += 1; print("✘ FAIL — \(name)") }
}

// MARK: scaledDetents — density scaling with slider length

expect(DetentTracker.scaledDetents(base: 32, length: nil) == 32, "nil length keeps base count")
expect(DetentTracker.scaledDetents(base: 32, length: 200) == 32, "200 pt is the baseline")
expect(DetentTracker.scaledDetents(base: 32, length: 100) == 16, "half-length slider halves detents")
expect(DetentTracker.scaledDetents(base: 32, length: 400) == 64, "double-length slider doubles detents")
expect(DetentTracker.scaledDetents(base: 32, length: 10) == 4, "tiny slider clamps at 4")
expect(DetentTracker.scaledDetents(base: 32, length: 10_000) == 64, "huge slider clamps at 64")
expect(DetentTracker.scaledDetents(base: 32, length: 0) == 32, "zero length falls back to base")

// MARK: basic detent crossings

var t = DetentTracker(baseDetents: 10, minV: 0, maxV: 1)
t.prime(0.05)   // detent 0
expect(t.update(0.08, endpointPulse: false) == nil, "movement inside one detent → no tick")
expect(t.update(0.15, endpointPulse: false) == .detent, "crossing a boundary fires")
expect(t.update(0.15, endpointPulse: false) == nil, "same value again → no repeat")
expect(t.update(0.55, endpointPulse: false) == .detent, "multi-detent jump still fires once")

// MARK: hysteresis at a boundary

var h = DetentTracker(baseDetents: 10, minV: 0, maxV: 1)
h.prime(0.15)   // detent 1
expect(h.update(0.201, endpointPulse: false) == nil, "barely over the boundary (jitter) suppressed")
expect(h.update(0.25, endpointPulse: false) == .detent, "clearly into the next detent fires")
expect(h.update(0.199, endpointPulse: false) == nil, "jitter back across the boundary suppressed")
expect(h.update(0.15, endpointPulse: false) == .detent, "a real move back fires")

// MARK: endpoints

var e = DetentTracker(baseDetents: 10, minV: 0, maxV: 100)
e.prime(50)
expect(e.update(99.9, endpointPulse: true) == .endpoint, "arriving at max thuds")
expect(e.update(100, endpointPulse: true) == nil, "staying pinned → thud fires once")
expect(e.update(50, endpointPulse: true) == .detent, "leaving the end re-arms (and ticks)")
expect(e.update(0.1, endpointPulse: true) == .endpoint, "arriving at min thuds")

var g = DetentTracker(baseDetents: 10, minV: 0, maxV: 100)
g.prime(100)
expect(g.update(100, endpointPulse: true) == nil, "grabbing a slider already at the end doesn't thud")
expect(g.update(99.8, endpointPulse: true) == nil, "still inside the endpoint zone → quiet")

var p = DetentTracker(baseDetents: 10, minV: 0, maxV: 1)
p.prime(0.5)
expect(p.update(1.0, endpointPulse: false) == .detent, "endpoint pulse off → plain detent at max")

// MARK: degenerate / real-world ranges

var d = DetentTracker(baseDetents: 10, minV: 5, maxV: 5)
d.prime(0.25)
expect(d.update(0.45, endpointPulse: false) == .detent, "degenerate range falls back to 0…1")

var r = DetentTracker(baseDetents: 16, minV: -50, maxV: 50)   // e.g. a balance slider
r.prime(0)
expect(r.update(7.5, endpointPulse: false) == .detent, "negative-min range normalizes correctly")

// MARK: -

if failures == 0 {
    print("All tests passed.")
    exit(0)
} else {
    print("\(failures) test(s) FAILED.")
    exit(1)
}
