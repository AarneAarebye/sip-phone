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
    public init(id: String, name: String, numbers: [PhoneNumber]) { self.id = id; self.name = name; self.numbers = numbers }
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
