import SwiftUI
import AppKit
import PhoneCore

struct SettingsView: View {
    let env: AppEnvironment
    @State private var s = AppSettings()
    @State private var tr064Password = ""
    @State private var sipPassword = ""
    @State private var wireguard = ""
    @State private var saveError: String?
    @State private var loginItemMessage: String?
    @State private var hasPin = false
    @State private var sipStored = false
    @State private var tr064Stored = false
    @State private var wgStored = false
    @State private var replacingWG = false
    @State private var confirmRemoveWG = false
    @State private var testingLogin = false
    @State private var loginReport: String?
    @State private var windowRef = WindowRef()

    private func refreshStored() {
        sipStored = env.isStored(SecretKey.sipPassword)
        tr064Stored = env.isStored(SecretKey.tr064Password)
        wgStored = env.isStored(SecretKey.wireguardConfig)
    }

    @ViewBuilder private func storedCaption(_ stored: Bool) -> some View {
        if stored {
            Label("Stored in Keychain", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
        } else {
            Text("Not set").font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        Form {
            Section("FRITZ!Box") {
                TextField("Address", text: $s.fritzHost)
                TextField("Phone extension user (SIP)", text: $s.sipUser)
                SecureField("SIP password (leave empty to keep)", text: $sipPassword)
                storedCaption(sipStored)
                TextField("FRITZ!Box user (TR-064)", text: $s.tr064User)
                SecureField("TR-064 password (leave empty to keep)", text: $tr064Password)
                storedCaption(tr064Stored)
            }
            Section("Certificate") {
                HStack {
                    Text(hasPin ? "The FRITZ!Box certificate is pinned." : "No certificate pinned yet.").font(.caption)
                    Spacer()
                    Button("Forget pinned certificate") {
                        Task { await env.forgetPinnedCertificate(); hasPin = env.hasPinnedCertificate }
                    }.disabled(!hasPin)
                }
                Text("Only after replacing or resetting your FRITZ!Box. The next connection's certificate is trusted.").font(.caption2)
            }
            Section("Diagnostics") {
                HStack {
                    Button("Test TR-064 login") {
                        testingLogin = true
                        Task { loginReport = await env.testTR064Login(); testingLogin = false }
                    }.disabled(testingLogin)
                    if testingLogin { ProgressView().controlSize(.small) }
                    Spacer()
                    if let loginReport, !testingLogin {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(loginReport, forType: .string)
                        }
                    }
                }
                Text("Uses the saved settings and Keychain password. The result contains no user name or password.").font(.caption2)
                if let loginReport {
                    Text(loginReport).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                Picker("Keypad tone method", selection: $s.dtmfMethod) {
                    ForEach(DTMFMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("In-band is the only method that reaches the phone on the FRITZ!Box 6591 Cable. RFC 2833 and SIP INFO are kept for other setups.")
                    Text("Takes effect after Save, also during a call. The in-call keypad shows the result of each press.")
                }.font(.caption2)
                Text("Last call: \(env.core.lastCallMedia ?? "no call audio yet")")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            Section("Numbers") {
                TextField("Country code", text: $s.countryCode)
                TextField("Local area code (e.g. 030)", text: $s.areaCode)
            }
            Section("VPN (WireGuard)") {
                if wgStored && !replacingWG {
                    HStack {
                        Label("WireGuard configuration stored in Keychain", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                        Spacer()
                        Button("Replace…") { replacingWG = true }
                        Button("Remove", role: .destructive) { confirmRemoveWG = true }
                    }
                } else {
                    TextEditor(text: $wireguard).font(.system(.caption, design: .monospaced)).frame(height: 90)
                    Text("Paste the .conf exported from the FRITZ!Box. It is stored in the Keychain.").font(.caption2)
                    if wgStored {
                        Button("Cancel") { replacingWG = false; wireguard = "" }
                    } else {
                        storedCaption(false)
                    }
                }
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
                    if saveError == nil { tr064Password = ""; sipPassword = ""; wireguard = ""; replacingWG = false }
                    refreshStored()
                    if SettingsSavePolicy.shouldCloseAfterSave(saveError: saveError, loginItemMessage: loginItemMessage) {
                        windowRef.window?.performClose(nil)
                    }
                }
            }
        }
        .formStyle(.grouped).frame(width: 440).padding()
        .confirmationDialog("Remove the WireGuard configuration from the Keychain?", isPresented: $confirmRemoveWG) {
            Button("Remove", role: .destructive) {
                saveError = env.removeSecret(SecretKey.wireguardConfig)
                refreshStored()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            s = env.settingsStore.load()
            hasPin = env.hasPinnedCertificate
            refreshStored()
            s.launchAtLogin = LaunchAtLogin.isOn(AppEnvironment.loginItemStatus())
        }
        .background(SettingsWindowActivator())
        .background(WindowReader(ref: windowRef))
    }
}

/// Holds the window that hosts the Settings view.
final class WindowRef { weak var window: NSWindow? }

private struct WindowReader: NSViewRepresentable {
    let ref: WindowRef
    func makeNSView(context: Context) -> NSView { Reader(ref: ref) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Reader: NSView {
        let ref: WindowRef
        init(ref: WindowRef) { self.ref = ref; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); ref.window = window }
    }
}
