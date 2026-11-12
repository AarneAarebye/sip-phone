import AppKit
import SwiftUI
import PhoneCore

/// Non-activating panel that can become key when clicked, so the Answer button's Return shortcut works
/// without activating the app (and without disturbing SettingsActivation's activation policy).
private final class CallPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating call panel, shown while `core.activeCall != nil`.
@MainActor final class CallWindowController {
    private var panel: NSPanel?
    private let core: AppCore
    init(core: AppCore) { self.core = core }

    func update() {
        if core.activeCall != nil {
            if panel == nil {
                let p = CallPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                                  styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
                p.contentViewController = NSHostingController(rootView: InCallView(core: core))
                p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
                p.level = .floating; p.isReleasedWhenClosed = false
                p.center()
                panel = p
                // Shown but NOT made key: someone typing in another app must not answer by pressing Return.
                // A click on the panel makes it key (non-activating), which enables the Return shortcut.
                p.orderFrontRegardless()
            } else {
                panel?.orderFrontRegardless()
            }
        } else {
            MicNotice.shared.incoming = nil
            panel?.close(); panel = nil
        }
    }
}
