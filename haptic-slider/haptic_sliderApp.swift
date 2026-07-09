//
//  haptic_sliderApp.swift
//  haptic-slider
//
//  Created by Joe Daniel on 06/07/26.
//

import SwiftUI
import AppKit
import ApplicationServices

@main
struct haptic_sliderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = HapticEngine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: engine)
        } label: {
            Image(systemName: "hand.point.up.braille")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Enforces a single running instance and shows a first-run welcome window so the app
/// never appears to "launch into nothing" (it's a menu-bar agent with no main window).
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Idempotent launch: if another copy is already running, focus it and quit.
        let me = NSRunningApplication.current
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
            return
        }

        _ = HapticEngine.shared   // spin up the engine

        // Show setup on first run — and on ANY launch where we can't function because
        // Accessibility access is missing. That second clause is the reinstall case:
        // `didOnboard` lives in UserDefaults (~/Library/Preferences), which survives
        // deleting the app, but the Accessibility grant usually does not. Without it a
        // reinstall would launch silently into a menu-bar icon that does nothing.
        if !UserDefaults.standard.bool(forKey: "didOnboard") || !AXIsProcessTrusted() {
            // Defer to next runloop tick so the app is ready to front a window.
            DispatchQueue.main.async { [weak self] in self?.showWelcome() }
        }
    }

    /// Show (or re-show) the welcome / setup window. Also reachable from the menu
    /// panel's "Setup Guide…" button.
    func showWelcome() {
        if welcomeWindow == nil {
            let host = NSHostingController(rootView: WelcomeView { [weak self] in self?.finishOnboarding() })
            let win = NSWindow(contentViewController: host)
            win.styleMask = [.titled, .closable, .fullSizeContentView]
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.delegate = self
            welcomeWindow = win
        }
        // Become a regular app briefly so the window can take focus and come to front.
        NSApp.setActivationPolicy(.regular)
        welcomeWindow?.center()
        welcomeWindow?.makeKeyAndOrderFront(nil)
        welcomeWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "didOnboard")
        welcomeWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only, no dock icon
    }
}
