// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import AppKit
import UniformTypeIdentifiers

/// The menu-bar popover window(s) of the MenuBarExtra (not the status item's own window, not panels).
@MainActor
private func popoverWindows() -> [NSWindow] {
    NSApp.windows.filter { w in
        guard w.isVisible, !(w is NSSavePanel) else { return false }
        let name = String(describing: type(of: w))
        if name.contains("StatusBar") { return false }
        return name.contains("MenuBarExtra") || (w is NSPanel && w.level.rawValue >= NSWindow.Level.popUpMenu.rawValue && w.frame.width > 200)
    }
}

/// Save panel for a CSV file, shared by the Contacts and History exports. The app is an accessory (LSUIElement) app and
/// the panel opens from a menu-bar popover that would cover it, so the popover is ordered out while the panel is up.
/// `restorePopover`: bring it back afterwards (backup before a write, whose pending action lives in the popover's views);
/// otherwise it stays dismissed. Callers must have collected everything they need before calling. Returns nil if cancelled.
@MainActor
func chooseCSVSaveURL(fileName: String, restorePopover: Bool = false) -> URL? {
    let hidden = popoverWindows()
    hidden.forEach { $0.orderOut(nil) }
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = fileName
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    let url = panel.runModal() == .OK ? panel.url : nil
    if restorePopover { hidden.forEach { $0.orderFront(nil) } }
    return url
}
