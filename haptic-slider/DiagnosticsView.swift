//
//  DiagnosticsView.swift
//  haptic-slider
//
//  Developer Mode diagnostics (the old test harness).
//

import SwiftUI
import AppKit

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

            // Tuning — label left, control right.
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
