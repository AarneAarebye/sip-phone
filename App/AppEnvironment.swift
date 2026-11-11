import Foundation
import PhoneCore
import FritzTR064

final class UserDefaultsPinStore: PinStore, @unchecked Sendable {
    func load() -> String? { UserDefaults.standard.string(forKey: "tr064CertFingerprint") }
    func save(_ fingerprint: String) { UserDefaults.standard.set(fingerprint, forKey: "tr064CertFingerprint") }
}

/// Late-bound phone book service so changing settings does not require rebuilding AppCore.
final class LivePhoneBook: PhoneBookService, @unchecked Sendable {
    private let make: @Sendable () -> PhoneBookService?
    init(make: @escaping @Sendable () -> PhoneBookService?) { self.make = make }
    func loadContacts() async throws -> [Contact] { try await (make() ?? { throw FritzError.missingField("TR-064 login") }()).loadContacts() }
    func loadCallList() async throws -> [CallRecord] { try await (make() ?? { throw FritzError.missingField("TR-064 login") }()).loadCallList() }
}

@MainActor final class AppEnvironment {
    let settingsStore = SettingsStore()
    let secrets: SecretStore = KeychainSecretStore()
    let core: AppCore

    init() {
        let store = settingsStore, secrets = secrets
        let book = LivePhoneBook {
            let s = store.load()
            guard !s.tr064User.isEmpty, let pw = secrets.get(SecretKey.tr064Password) else { return nil }
            return FritzTR064Client(host: s.fritzHost,
                                    transport: URLSessionTransport(username: s.tr064User, password: pw, pins: UserDefaultsPinStore()))
        }
        core = AppCore(sip: UnavailableSIPEngine(), phoneBook: book, vpn: UnavailableVPN(),
                       reachability: TCPReachability(host: { store.load().fritzHost }),
                       power: NoopPower(), cache: JSONFileContactCache.standard(), settings: store.load(),
                       sipConfig: {
                           let s = store.load()
                           guard !s.sipUser.isEmpty, let pw = secrets.get(SecretKey.sipPassword) else { return nil }
                           return SIPConfig(host: s.fritzHost, user: s.sipUser, password: pw)
                       })
    }

    func applySettings(_ s: AppSettings, tr064Password: String?, sipPassword: String?) async {
        settingsStore.save(s)
        if let p = tr064Password, !p.isEmpty { try? secrets.set(p, for: SecretKey.tr064Password) }
        if let p = sipPassword, !p.isEmpty { try? secrets.set(p, for: SecretKey.sipPassword) }
        core.updateSettings(s)
        await core.retry()
    }
}
