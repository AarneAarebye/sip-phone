import Foundation
import PhoneCore
import FritzTR064
import SIPEngine
import VPN

final class UserDefaultsPinStore: PinStore, @unchecked Sendable {
    func load() -> String? { UserDefaults.standard.string(forKey: "tr064CertFingerprint") }
    func save(_ fingerprint: String) { UserDefaults.standard.set(fingerprint, forKey: "tr064CertFingerprint") }
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

    init(pins: PinStore, credentials: @escaping @Sendable () -> (host: String, user: String, password: String)?) {
        self.pins = pins; self.credentials = credentials
    }

    private func current() throws -> FritzTR064Client {
        guard let c = credentials() else { throw FritzError.missingField("TR-064 login") }
        let k = [c.host, c.user, c.password].joined(separator: "\u{1F}")
        return lock.withLock {
            if let client, key == k { return client }
            transport?.invalidate()
            let t = URLSessionTransport(username: c.user, password: c.password, pins: pins)
            let cl = FritzTR064Client(host: c.host, transport: t)
            transport = t; client = cl; key = k
            return cl
        }
    }
    func loadContacts() async throws -> [Contact] { try await current().loadContacts() }
    func loadCallList() async throws -> [CallRecord] { try await current().loadCallList() }
}

@MainActor final class AppEnvironment {
    let settingsStore = SettingsStore()
    let secrets: SecretStore = KeychainSecretStore()
    let core: AppCore

    init() {
        let store = settingsStore, secrets = secrets
        let book = LivePhoneBook(pins: UserDefaultsPinStore()) {
            let s = store.load()
            guard !s.tr064User.isEmpty, let pw = secrets.get(SecretKey.tr064Password) else { return nil }
            return (s.fritzHost, s.tr064User, pw)
        }
        core = AppCore(sip: PJSIPEngine(), phoneBook: book, vpn: VPNManager(secrets: secrets, extensionBundleId: "com.aarneaarebye.fritzphone.PacketTunnel"),
                       reachability: TCPReachability(host: { store.load().fritzHost }),
                       power: NoopPower(), cache: JSONFileContactCache.standard(), settings: store.load(),
                       sipConfig: {
                           let s = store.load()
                           guard !s.sipUser.isEmpty, let pw = secrets.get(SecretKey.sipPassword) else { return nil }
                           return SIPConfig(host: s.fritzHost, user: s.sipUser, password: pw)
                       })
    }

    /// Returns an error message if a secret could not be stored (nothing else is applied in that case).
    func applySettings(_ s: AppSettings, tr064Password: String?, sipPassword: String?, wireguardConfig: String? = nil) async -> String? {
        let pending: [(String?, String, String)] = [
            (tr064Password, SecretKey.tr064Password, "TR-064 password"),
            (sipPassword, SecretKey.sipPassword, "SIP password"),
            (wireguardConfig, SecretKey.wireguardConfig, "WireGuard configuration"),
        ]
        for (value, key, label) in pending {
            guard let v = value, !v.isEmpty else { continue }
            do { try secrets.set(v, for: key) }
            catch { return "Could not save \(label) to the Keychain: \(error.localizedDescription)" }
        }
        settingsStore.save(s)
        core.updateSettings(s)
        await core.retry()
        return nil
    }
}
