// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import SwiftUI

/// Icon-only "Export CSV" button, identical in the Contacts and History headers.
struct ExportCSVButton: View {
    let help: String
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "arrow.down.doc") }
            .accessibilityLabel("Export CSV")
            .help(help)
            .disabled(disabled)
    }
}
