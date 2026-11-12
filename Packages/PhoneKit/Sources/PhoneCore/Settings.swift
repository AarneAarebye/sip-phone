import Foundation

/// How in-call keypad digits (DTMF) are sent.
public enum DTMFMethod: String, Codable, CaseIterable, Sendable {
    /// Audio tones mixed into the call's outgoing audio. The default: the only method that reaches the phone on the FRITZ!Box 6591 Cable.
    case inband
    /// RTP telephone-event (RFC 2833/4733).
    case rfc2833
    /// SIP INFO request with an application/dtmf-relay body.
    case sipInfo

    public var label: String {
        switch self {
        case .inband: return "In-band audio tones (recommended)"
        case .rfc2833: return "RFC 2833"
        case .sipInfo: return "SIP INFO"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var fritzHost = "fritz.box"
    public var sipUser = ""
    public var tr064User = ""
    public var countryCode = "49"
    public var areaCode = ""
    public var keepAwakeOnPower = true
    public var launchAtLogin = false
    public var dtmfMethod: DTMFMethod = .inband
    /// Ids of FRITZ!Box phone books switched off (hidden in Contacts, not used for caller names). New books are on.
    public var disabledPhoneBooks: [String] = []
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case disabledPhoneBooks, fritzHost, sipUser, tr064User, countryCode, areaCode, keepAwakeOnPower, launchAtLogin, dtmfMethod
    }

    /// Tolerant: a missing (older stored settings) or unknown value (including the removed "both") keeps the default for that field only.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = AppSettings()
        fritzHost = value(.fritzHost, d.fritzHost)
        sipUser = value(.sipUser, d.sipUser)
        tr064User = value(.tr064User, d.tr064User)
        countryCode = value(.countryCode, d.countryCode)
        areaCode = value(.areaCode, d.areaCode)
        keepAwakeOnPower = value(.keepAwakeOnPower, d.keepAwakeOnPower)
        launchAtLogin = value(.launchAtLogin, d.launchAtLogin)
        dtmfMethod = value(.dtmfMethod, d.dtmfMethod)
        disabledPhoneBooks = value(.disabledPhoneBooks, d.disabledPhoneBooks)
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "appSettings"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> AppSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }
    public func save(_ s: AppSettings) { defaults.set(try? JSONEncoder().encode(s), forKey: key) }
}
