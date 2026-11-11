import SwiftUI

@main
struct FritzPhoneApp: App {
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
