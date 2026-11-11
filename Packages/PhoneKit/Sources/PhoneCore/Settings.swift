import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var fritzHost = "fritz.box"
    public var sipUser = ""
    public var tr064User = ""
    public var countryCode = "49"
    public var areaCode = ""
    public var keepAwakeOnPower = true
    public var launchAtLogin = false
    public init() {}
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
