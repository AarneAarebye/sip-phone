import Foundation

public struct PhoneNumber: Codable, Equatable, Sendable {
    public let number: String
    public let type: String
    public init(number: String, type: String) { self.number = number; self.type = type }
}

public struct Contact: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let numbers: [PhoneNumber]
    /// Display name of the FRITZ!Box phone book this contact comes from (nil in caches written before this existed).
    public let phoneBook: String?
    public init(id: String, name: String, numbers: [PhoneNumber], phoneBook: String? = nil) {
        self.id = id; self.name = name; self.numbers = numbers; self.phoneBook = phoneBook
    }

    private enum CodingKeys: String, CodingKey { case id, name, numbers, phoneBook }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        numbers = try c.decode([PhoneNumber].self, forKey: .numbers)
        phoneBook = try c.decodeIfPresent(String.self, forKey: .phoneBook)
    }
}

public enum CallRecordType: Equatable, Sendable { case incoming, missed, outgoing, rejected }

public struct CallRecord: Equatable, Identifiable, Sendable {
    public let id: Int
    public let type: CallRecordType
    public let remoteNumber: String
    public let name: String?
    public let date: Date
    public let duration: TimeInterval
    public init(id: Int, type: CallRecordType, remoteNumber: String, name: String?, date: Date, duration: TimeInterval) {
        self.id = id; self.type = type; self.remoteNumber = remoteNumber; self.name = name; self.date = date; self.duration = duration
    }
}

public protocol PhoneBookService: Sendable {
    func loadContacts() async throws -> [Contact]
    func loadCallList() async throws -> [CallRecord]
}
