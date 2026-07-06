//
//  haptic_sliderApp.swift
//  haptic-slider
//
//  Created by Joe Daniel on 06/07/26.
//

import SwiftUI

@main
struct haptic_sliderApp: App {
    @StateObject private var engine = HapticEngine()
    @AppStorage("menuIcon") private var menuIcon = "hand.point.up.braille"

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: engine)
        } label: {
            Image(systemName: safeIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// Guard against an invalid symbol name blanking the menu bar.
    private var safeIcon: String {
        NSImage(systemSymbolName: menuIcon, accessibilityDescription: nil) != nil
            ? menuIcon : "hand.point.up.braille"
    }
}
