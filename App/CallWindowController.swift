import AppKit
import SwiftUI
import PhoneCore

/// Floating call panel, shown while `core.activeCall != nil`. Non-activating, so it never changes the
/// app's activation policy (SettingsActivation owns that).
@MainActor final class CallWindowController {
    private var panel: NSPanel?
    private let core: AppCore
    init(core: AppCore) { self.core = core }

    func update() {
        if core.activeCall != nil {
            if panel == nil {
                let p = NSPanel(contentViewController: NSHostingController(rootView: InCallView(core: core)))
                p.styleMask = [.titled, .nonactivatingPanel, .fullSizeContentView]
                p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
                p.level = .floating; p.isReleasedWhenClosed = false
                p.center()
                panel = p
            }
            panel?.orderFrontRegardless()
        } else {
            panel?.close(); panel = nil
        }
    }
}
