// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import AppKit
import SwiftUI
import PhoneCore

/// Non-activating panel that can become key when clicked, so the Answer button's Return shortcut works
/// without activating the app (and without disturbing SettingsActivation's activation policy).
private final class CallPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating call panel, shown while `core.activeCall != nil`. It cannot be closed or minimised while a call
/// exists (no window buttons), does not hide when the app deactivates, and is re-shown on every call change.
@MainActor final class CallWindowController {
    /// The app's controller, for the popover's "Show call window" button.
    private(set) static weak var current: CallWindowController?
    private var panel: NSPanel?
    private let core: AppCore
    init(core: AppCore) { self.core = core; Self.current = self }

    /// Brings the call panel to the front (creating it if needed) while a call exists.
    func showPanel() { update(); panel?.orderFrontRegardless() }

    func update() {
        if core.activeCall != nil {
            if panel == nil {
                let p = CallPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                                  styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
                p.contentViewController = NSHostingController(rootView: InCallView(core: core))
                p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
                for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
                // NSPanel hides on app deactivation by default: a menu-bar app deactivates as soon as another app
                // is clicked, which made the panel (and its Hang up button) vanish during a live call.
                p.hidesOnDeactivate = false
                p.isMovableByWindowBackground = true
                p.level = .floating; p.isReleasedWhenClosed = false
                p.center()
                panel = p
                // Shown but NOT made key: someone typing in another app must not answer by pressing Return.
                // A click on the panel makes it key (non-activating), which enables the Return shortcut.
                p.orderFrontRegardless()
            } else if let p = panel, !p.isVisible {
                p.orderFrontRegardless()   // re-show a panel that was hidden or ordered out
            }
        } else {
            MicNotice.shared.incoming = nil
            panel?.close(); panel = nil
        }
    }
}
