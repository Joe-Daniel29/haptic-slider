//
//  WelcomeView.swift
//  haptic-slider
//

import SwiftUI
import AppKit

/// First-run welcome / setup window (so the app never "silently" launches into nothing).
/// Also shown on any launch where Accessibility access is missing — which is exactly
/// what a reinstall looks like (UserDefaults survive an uninstall, the TCC grant doesn't).
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
