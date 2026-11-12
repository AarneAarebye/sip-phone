import SwiftUI
import AppKit

/// The app is an accessory (menu bar only) app, so its Settings window would open behind other apps.
/// While Settings is on screen the app becomes a regular app and is activated; it reverts on close.
struct SettingsWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var closeObserver: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, closeObserver == nil else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                NSApp.setActivationPolicy(.accessory)
                if let o = self?.closeObserver { NotificationCenter.default.removeObserver(o) }
                self?.closeObserver = nil
            }
        }
    }
}
