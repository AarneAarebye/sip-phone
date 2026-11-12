// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import SwiftUI
import AppKit

/// The app is an accessory (menu bar only) app, so its windows (Settings, About, licences) would open behind
/// other apps. Whenever such a window becomes key (first open and every reopen) the app becomes a regular
/// app and is activated; it reverts to accessory when the last of these windows closes.
struct SettingsWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?

        deinit { removeObservers() }

        private func removeObservers() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if observedWindow !== window {   // install once per window
                removeObservers()
                observedWindow = window
                let nc = NotificationCenter.default
                observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated { if let window { Probe.activate(window) } }
                })
                observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { Probe.openWindows.remove(ObjectIdentifier(window)) }
                        if Probe.openWindows.isEmpty { _ = NSApp.setActivationPolicy(.accessory) }
                    }
                })
            }
            Probe.activate(window)   // first open, in case the window became key before observing
        }

        /// Windows with an activator that are open; the Dock icon stays while any of them is.
        @MainActor private static var openWindows: Set<ObjectIdentifier> = []

        @MainActor private static func activate(_ window: NSWindow) {
            openWindows.insert(ObjectIdentifier(window))
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}
