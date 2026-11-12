// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import SwiftUI

@main
struct SipPhoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MainView(core: delegate.env.core)
        } label: {
            Image(systemName: delegate.env.core.connection == .ready ? "phone.fill" : "phone")
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(env: delegate.env) }
    }
}
