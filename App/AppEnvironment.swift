// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import ServiceManagement
import PhoneCore
import FritzTR064
import SIPEngine
import VPN
import SystemAdapters

/// The pinned FRITZ!Box certificate fingerprint, in the app's (sandbox container) user defaults.
final class UserDefaultsPinStore: PinStore, @unchecked Sendable {
    static let key = "tr064CertFingerprint"
    func load() -> String? { UserDefaults.standard.string(forKey: Self.key) }
    func save(_ fingerprint: String) { UserDefaults.standard.set(fingerprint, forKey: Self.key) }
    func clear() { UserDefaults.standard.removeObject(forKey: Self.key) }
}

/// Late-bound phone book service so changing settings does not require rebuilding AppCore.
/// Keeps one client (and TLS session) per credentials set; rebuilt only when they change.
final class LivePhoneBook: PhoneBookService, @unchecked Sendable {
    private let credentials: @Sendable () -> (host: String, user: String, password: String)?
    private let pins: PinStore
    private let lock = NSLock()
    private var key: String?
    private var transport: URLSessionTransport?
    private var client: FritzTR064Client?
    /// The client used by the latest call; nil when that call found TR-064 not configured.
    private var lastUsed: FritzTR064Client?

    init(pins: PinStore, credentials: @escaping @Sendable () -> (host: String, user: String, password: String)?) {
        self.pins = pins; self.credentials = credentials
    }

    private func current() throws -> FritzTR064Client {
        guard let c = credentials() else {
            lock.withLock { lastUsed = nil }
            throw FritzError.notConfigured
        }
        let k = [c.host, c.user, c.password].joined(separator: "\u{1F}")
        return lock.withLock {
            if let client, key == k { lastUsed = client; return client }
            transport?.invalidate()
            let t = URLSessionTransport(username: c.user, password: c.password, pins: pins)
            let cl = FritzTR064Client(host: c.host, transport: t)
            transport = t; client = cl; key = k; lastUsed = cl
            return cl
        }
    }

    /// Short, sanitized summary of the latest TR-064 request (for the phone-book failure notice).
    var failureDetail: String? { lock.withLock { lastUsed }?.lastDiagnostics?.shortSummary }

    /// Settings "Test TR-064 login": one authenticated call through the same cached client and credentials.
    func checkLogin() async -> TR064LoginCheck {
        do { return try await current().checkLogin() }
        catch { return TR064LoginCheck(verdict: .notConfigured, diagnostics: nil, errorDescription: error.localizedDescription) }
    }
    func loadContacts() async throws -> [Contact] { try await current().loadContacts() }
    func loadCallList() async throws -> [CallRecord] { try await current().loadCallList() }
}

@MainActor final class AppEnvironment {
    let settingsStore = SettingsStore()
    let secrets: SecretStore = KeychainSecretStore()
    let core: AppCore
    let pinStore = UserDefaultsPinStore()
    private let phoneBook: LivePhoneBook
    /// Held for the app lifetime: the IOPS run-loop callback keeps an unretained pointer to it.
    lazy var monitors = SystemMonitors(core: core)

    init() {
        let store = settingsStore, secrets = secrets, pins = pinStore
        let book = LivePhoneBook(pins: pins) {
            let s = store.load()
            guard !s.tr064User.isEmpty, let pw = secrets.get(SecretKey.tr064Password) else { return nil }
            return (s.fritzHost, s.tr064User, pw)
        }
        phoneBook = book
        core = AppCore(sip: PJSIPEngine(), phoneBook: book, vpn: VPNManager(secrets: secrets, extensionBundleId: "com.aarneaarebye.sipphone.PacketTunnel",
                                                                    routing: { Self.routing(store.load()) }),
                       reachability: FritzBoxReachability(host: { store.load().fritzHost }, pinned: { pins.load() }),
                       power: IOKitPowerAssertion(), cache: JSONFileContactCache.standard(), settings: store.load(),
                       sipConfig: {
                           let s = store.load()
                           guard !s.sipUser.isEmpty, let pw = secrets.get(SecretKey.sipPassword) else { return nil }
                           let media = Self.mediaAddress(s)
                           return SIPConfig(host: s.fritzHost, user: s.sipUser, password: pw,
                                            mediaAddressMode: media.mode, mediaBindAddress: media.bind)
                       },
                       phoneBookFailureDetail: { book.failureDetail })
    }

    /// Effective media-address mode for the next registration: "tunnel interface" needs a tunnel address
    /// (a utun IPv4 in the home network); without one it falls back to automatic.
    nonisolated static func mediaAddress(_ s: AppSettings) -> (mode: MediaAddressMode, bind: String?) {
        guard s.mediaAddressMode == .tunnelInterface else { return (s.mediaAddressMode, nil) }
        let cidr = s.homeNetworkCIDR.trimmingCharacters(in: .whitespaces)
        guard let ip = MediaAddress.tunnelAddress(from: MediaAddress.currentIPv4Interfaces(), homeNetwork: cidr.isEmpty ? nil : cidr)
        else { return (.automatic, nil) }
        return (.tunnelInterface, ip)
    }

    /// Split tunnel and home-network override from Settings (read at every VPN start).
    nonisolated static func routing(_ s: AppSettings) -> TunnelRouting {
        let cidr = s.homeNetworkCIDR.trimmingCharacters(in: .whitespaces)
        return TunnelRouting(splitTunnel: s.splitTunnel, homeNetwork: cidr.isEmpty ? nil : cidr)
    }

    /// Whether a secret is stored in the Keychain (never reads the value).
    func isStored(_ key: String) -> Bool { secrets.contains(key) }

    /// Deletes a stored secret. Returns an error message on failure. Does not reconnect.
    func removeSecret(_ key: String) -> String? {
        do { try secrets.set(nil, for: key); return nil }
        catch { return "Could not remove the item from the Keychain: \(error.localizedDescription)" }
    }

    /// Runs the TR-064 login test with the saved settings and Keychain password; returns sanitized text.
    func testTR064Login() async -> String { await phoneBook.checkLogin().text }

    var hasPinnedCertificate: Bool { pinStore.load() != nil }

    /// After replacing or resetting the FRITZ!Box: trust the certificate seen on the next connection.
    func forgetPinnedCertificate() async {
        pinStore.clear()
        await core.retry()   // re-probes without the pin and reloads the phone book, which pins the new certificate
    }

    struct ApplyResult { var saveError: String?; var loginItemMessage: String? }

    static func loginItemStatus() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }

    /// `saveError`: a secret could not be stored (nothing else is applied then).
    /// `loginItemMessage`: launch-at-login problem; everything else was applied and saved.
    func applySettings(_ s: AppSettings, tr064Password: String?, sipPassword: String?, wireguardConfig: String? = nil) async -> ApplyResult {
        let pending: [(String?, String, String)] = [
            (tr064Password, SecretKey.tr064Password, "TR-064 password"),
            (sipPassword, SecretKey.sipPassword, "SIP password"),
            (wireguardConfig, SecretKey.wireguardConfig, "WireGuard configuration"),
        ]
        for (value, key, label) in pending {
            guard let v = value, !v.isEmpty else { continue }
            do { try secrets.set(v, for: key) }
            catch { return ApplyResult(saveError: "Could not save \(label) to the Keychain: \(error.localizedDescription)") }
        }
        settingsStore.save(s)
        core.updateSettings(s)
        await core.retry()
        var message: String?
        do {
            // The Xcode 27 SDK declares unregister() async but register() synchronous.
            switch LaunchAtLogin.action(desired: s.launchAtLogin, status: Self.loginItemStatus()) {
            case .register:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    message = "Approve SIP Phone in System Settings > General > Login Items."
                } else if SMAppService.mainApp.status == .notFound {
                    message = "Launch at login failed: the app was not found by the system."
                }
            case .unregister: try await SMAppService.mainApp.unregister()
            case .none: break
            }
        } catch { message = "Launch at login failed: \(error.localizedDescription)" }
        return ApplyResult(loginItemMessage: message)
    }
}
