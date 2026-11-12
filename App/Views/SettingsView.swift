import SwiftUI
import PhoneCore

struct SettingsView: View {
    let env: AppEnvironment
    @State private var s = AppSettings()
    @State private var tr064Password = ""
    @State private var sipPassword = ""
    @State private var wireguard = ""
    @State private var saveError: String?
    @State private var loginItemMessage: String?

    var body: some View {
        Form {
            Section("FRITZ!Box") {
                TextField("Address", text: $s.fritzHost)
                TextField("Phone extension user (SIP)", text: $s.sipUser)
                SecureField("SIP password (leave empty to keep)", text: $sipPassword)
                TextField("FRITZ!Box user (TR-064)", text: $s.tr064User)
                SecureField("TR-064 password (leave empty to keep)", text: $tr064Password)
            }
            Section("Numbers") {
                TextField("Country code", text: $s.countryCode)
                TextField("Local area code (e.g. 030)", text: $s.areaCode)
            }
            Section("VPN (WireGuard)") {
                TextEditor(text: $wireguard).font(.system(.caption, design: .monospaced)).frame(height: 90)
                Text("Paste the .conf exported from the FRITZ!Box. It is stored in the Keychain.").font(.caption2)
            }
            Section("Behaviour") {
                Toggle("Keep Mac awake while on power", isOn: $s.keepAwakeOnPower)
                Toggle("Launch at login", isOn: $s.launchAtLogin)
            }
            if let loginItemMessage { Text(loginItemMessage).font(.caption).foregroundStyle(.red) }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            Button("Save") {
                Task {
                    let r = await env.applySettings(s, tr064Password: tr064Password, sipPassword: sipPassword,
                                                    wireguardConfig: wireguard)
                    saveError = r.saveError; loginItemMessage = r.loginItemMessage
                    if saveError == nil { tr064Password = ""; sipPassword = ""; wireguard = "" }
                }
            }
        }
        .formStyle(.grouped).frame(width: 440).padding()
        .onAppear {
            s = env.settingsStore.load()
            s.launchAtLogin = LaunchAtLogin.isOn(AppEnvironment.loginItemStatus())
        }
        .background(SettingsWindowActivator())
    }
}
