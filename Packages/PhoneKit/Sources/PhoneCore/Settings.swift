import Foundation

/// How in-call keypad digits (DTMF) are sent.
public enum DTMFMethod: String, Codable, CaseIterable, Sendable {
    /// RTP telephone-event (RFC 2833/4733), the usual default.
    case rfc2833
    /// SIP INFO request with an application/dtmf-relay body.
    case sipInfo
    /// RFC 2833 followed by SIP INFO for the same digit. Diagnostic only: the remote side may hear it twice.
    case both
    /// Audio tones mixed into the call's outgoing audio.
    case inband

    public var label: String {
        switch self {
        case .rfc2833: return "RFC 2833"
        case .sipInfo: return "SIP INFO"
        case .both: return "RFC 2833 + SIP INFO"
        case .inband: return "In-band audio"
        }
    }

    /// Single methods actually sent on the wire, in order.
    public var wireMethods: [DTMFMethod] { self == .both ? [.rfc2833, .sipInfo] : [self] }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var fritzHost = "fritz.box"
    public var sipUser = ""
    public var tr064User = ""
    public var countryCode = "49"
    public var areaCode = ""
    public var keepAwakeOnPower = true
    public var launchAtLogin = false
    public var dtmfMethod: DTMFMethod = .rfc2833
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case fritzHost, sipUser, tr064User, countryCode, areaCode, keepAwakeOnPower, launchAtLogin, dtmfMethod
    }

    /// Tolerant: a missing (older stored settings) or unknown value keeps the default for that field only.
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
