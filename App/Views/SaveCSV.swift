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
    panel.level = .modalPanel
    return panel.runModal() == .OK ? panel.url : nil
}
