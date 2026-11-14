// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import AppKit
import UniformTypeIdentifiers

/// The menu-bar popover window(s) of the MenuBarExtra (not the status item's own window, not panels).
@MainActor
func popoverWindows() -> [NSWindow] {
    NSApp.windows.filter { w in
        guard w.isVisible, !(w is NSSavePanel) else { return false }
        let name = String(describing: type(of: w))
        if name.contains("StatusBar") { return false }
        return name.contains("MenuBarExtra") || (w is NSPanel && w.level.rawValue >= NSWindow.Level.popUpMenu.rawValue && w.frame.width > 200)
    }
}

/// Hides the popover visually while `body` runs (a panel or alert in front of it), WITHOUT ordering it out: the window
/// stays ordered in, so the MenuBarExtra keeps managing it (click-outside, Escape and status-icon dismissal keep working;
/// orderOut/orderFront behind SwiftUI's back left it stuck on screen). Always restored, also if `body` throws or returns early.
@MainActor
func withPopoverHidden<T>(_ body: () -> T) -> T {
    let windows = popoverWindows()
    let saved = windows.map { ($0, $0.alphaValue, $0.ignoresMouseEvents) }
    windows.forEach { $0.alphaValue = 0; $0.ignoresMouseEvents = true }
    defer { saved.forEach { w, alpha, ignores in w.alphaValue = alpha; w.ignoresMouseEvents = ignores } }
    return body()
}

/// The menu-bar item's button, found through the status-bar windows (nil if not found).
@MainActor
private func statusItemButton() -> NSStatusBarButton? {
    func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews { if let b = find(in: sub) { return b } }
        return nil
    }
    for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
        if let b = find(in: w.contentView) { return b }
    }
    return nil
}

/// Dismisses the popover the way a click on the status icon does, so the MenuBarExtra's own state stays in sync.
/// If the button cannot be found the popover simply stays open (it remains closable normally).
@MainActor
func dismissPopoverViaStatusItem() {
    guard !popoverWindows().isEmpty, let button = statusItemButton() else { return }
    button.performClick(nil)
}

/// Save panel for a CSV file, shared by the Contacts and History exports. The app is an accessory (LSUIElement) app and
/// the panel opens from a menu-bar popover that would cover it, so the popover is made invisible (alpha 0, no mouse
/// events) while the panel is up; it is never ordered out. `restorePopover`: leave it open afterwards (backup before a
/// write, whose pending action lives in the popover's views); otherwise it is dismissed like a status-icon click.
/// Callers must have collected everything they need before calling. Returns nil if cancelled.
@MainActor
func chooseCSVSaveURL(fileName: String, restorePopover: Bool = false) -> URL? {
    let url: URL? = withPopoverHidden {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = fileName
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return panel.runModal() == .OK ? panel.url : nil
    }
    if !restorePopover { dismissPopoverViaStatusItem() }
    return url
}
