//
//  MenuContent.swift
//  haptic-slider
//

import SwiftUI
import AppKit
import ServiceManagement

/// The menu-bar control panel.
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
            row("Scroll & arrow-key haptics") {
                Toggle("", isOn: $engine.scrollKeyHaptics)
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!engine.trusted || !engine.engineOn)
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
                Button("Setup Guide…") {
                    (NSApp.delegate as? AppDelegate)?.showWelcome()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 280)
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            engine.refreshTrust()   // catch access revoked while we were running
        }
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
