// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

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
    /// FRITZ!Box id of that phone book (nil in older caches; see `bookID`).
    public let phoneBookID: String?
    public init(id: String, name: String, numbers: [PhoneNumber], phoneBook: String? = nil, phoneBookID: String? = nil) {
        self.id = id; self.name = name; self.numbers = numbers; self.phoneBook = phoneBook; self.phoneBookID = phoneBookID
    }

    /// The effective book id: the stored one, else the all-digit prefix of an "<bookId>-<contactId>" id, else nil.
    /// The only place that knows about the id-prefix fallback.
    public var bookID: String? {
        if let phoneBookID { return phoneBookID }
        guard let dash = id.firstIndex(of: "-") else { return nil }
        let prefix = id[..<dash]
        return !prefix.isEmpty && prefix.allSatisfy(\.isASCII) && prefix.allSatisfy(\.isNumber) ? String(prefix) : nil
    }

    private enum CodingKeys: String, CodingKey { case id, name, numbers, phoneBook, phoneBookID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        numbers = try c.decode([PhoneNumber].self, forKey: .numbers)
        phoneBook = try c.decodeIfPresent(String.self, forKey: .phoneBook)
        phoneBookID = try c.decodeIfPresent(String.self, forKey: .phoneBookID)
    }
}

public struct PhoneBookSummary: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let contactCount: Int
    public init(id: String, name: String, contactCount: Int) { self.id = id; self.name = name; self.contactCount = contactCount }
}

public enum PhoneBooks {
    /// Books in order of first appearance. Name comes from the contacts' `phoneBook`, else "Phone book <id>".
    /// Contacts without a book id are not part of any book.
    public static func summaries(from contacts: [Contact]) -> [PhoneBookSummary] {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for c in contacts {
            guard let id = c.bookID else { continue }
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
            if names[id] == nil, let n = c.phoneBook, !n.isEmpty { names[id] = n }
        }
        return order.map { PhoneBookSummary(id: $0, name: names[$0] ?? "Phone book \($0)", contactCount: counts[$0] ?? 0) }
    }

    /// Contacts whose book is not disabled (contacts without a book id are always kept).
    public static func visible(_ contacts: [Contact], disabled: [String]) -> [Contact] {
        guard !disabled.isEmpty else { return contacts }
        let off = Set(disabled)
        return contacts.filter { c in c.bookID.map { !off.contains($0) } ?? true }
    }

    /// Picker selection (nil = all books) combined with the text search.
    public static func filter(_ contacts: [Contact], bookID: String?, query: String) -> [Contact] {
        contacts.filter { c in (bookID == nil || c.bookID == bookID) && ContactFilter.matches(c, query) }
    }

    /// The books actually selected: stored ids that still exist and are not switched off.
    /// nil = all books (nothing stored, or none of the stored ids is valid any more).
    public static func effectiveSelection(stored: [String], books: [PhoneBookSummary], disabled: [String]) -> Set<String>? {
        let valid = Set(books.map(\.id)).subtracting(disabled)
        let chosen = Set(stored).intersection(valid)
        return chosen.isEmpty ? nil : chosen
    }

    /// Set selection (nil = all books) combined with the text search.
    public static func filter(_ contacts: [Contact], bookIDs: Set<String>?, query: String) -> [Contact] {
        contacts.filter { c in
            (bookIDs.map { ids in c.bookID.map(ids.contains) ?? false } ?? true) && ContactFilter.matches(c, query)
        }
    }

    /// Toggles one book in the selection, starting from the effective one; the result is in book order.
    public static func toggled(_ id: String, effective: Set<String>?, books: [PhoneBookSummary]) -> [String] {
        var set = effective ?? []
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        return books.map(\.id).filter(set.contains)
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
