// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import AppKit
import UniformTypeIdentifiers

/// Save panel for a CSV file, shared by the Contacts and History exports. The app is an accessory (LSUIElement) app
/// and the panel opens from a menu-bar popover, so it is activated first. Returns the chosen URL, or nil if cancelled.
@MainActor
func chooseCSVSaveURL(fileName: String) -> URL? {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = fileName
    // The menu-bar popover floats at pop-up-menu level and would cover the panel; sit one level above it.
    // The popover stays open on purpose: closing it would tear down the view that continues the write flow.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    return panel.runModal() == .OK ? panel.url : nil
}
