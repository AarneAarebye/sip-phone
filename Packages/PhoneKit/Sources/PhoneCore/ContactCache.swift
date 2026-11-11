import Foundation

public protocol ContactCache: Sendable {
    func load() -> [Contact]
    func save(_ contacts: [Contact])
}

public struct JSONFileContactCache: ContactCache {
    private let url: URL
    public init(url: URL) { self.url = url }
    public static func standard() -> JSONFileContactCache {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FritzPhone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return JSONFileContactCache(url: dir.appendingPathComponent("contacts.json"))
    }
    public func load() -> [Contact] { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Contact].self, from: $0) } ?? [] }
    public func save(_ contacts: [Contact]) { try? JSONEncoder().encode(contacts).write(to: url, options: .atomic) }
}
