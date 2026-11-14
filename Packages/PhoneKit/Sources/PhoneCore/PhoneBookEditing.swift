// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

/// Number types the FRITZ!Box knows in a phone book entry.
public enum PhoneNumberType: String, CaseIterable, Sendable {
    case home, work, mobile, faxWork = "fax_work", other

    public var label: String {
        switch self {
        case .home: "Home"; case .work: "Work"; case .mobile: "Mobile"; case .faxWork: "Fax"; case .other: "Other"
        }
    }
    /// Unknown strings from the box fall back to `.other` when edited.
    public static func from(_ raw: String) -> PhoneNumberType { PhoneNumberType(rawValue: raw) ?? .other }
}

/// What the edit sheet produces: a name and numbers.
public struct ContactDraft: Equatable, Sendable {
    public var name: String
    public var numbers: [PhoneNumber]
    public init(name: String, numbers: [PhoneNumber]) { self.name = name; self.numbers = numbers }

    public init(_ contact: Contact) {
        self.init(name: contact.name,
                  numbers: contact.numbers.map { PhoneNumber(number: $0.number, type: PhoneNumberType.from($0.type).rawValue) })
    }

    /// Trimmed copy without empty number rows.
    public var cleaned: ContactDraft {
        ContactDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                     numbers: numbers.compactMap {
                         let n = $0.number.trimmingCharacters(in: .whitespacesAndNewlines)
                         return n.isEmpty ? nil : PhoneNumber(number: n, type: PhoneNumberType.from($0.type).rawValue)
                     })
    }

    /// nil when valid; otherwise a message for the user.
    public var validationError: String? {
        let c = cleaned
        if c.name.isEmpty { return "Enter a name." }
        if c.numbers.isEmpty { return "Enter at least one phone number." }
        let allowed = Set("0123456789+*#()-./ ")
        for n in c.numbers where !n.number.allSatisfy({ allowed.contains($0) }) || !n.number.contains(where: \.isNumber) {
            return "A phone number may only contain digits, spaces and + * # ( ) - . /"
        }
        return nil
    }
}

public enum PhoneBookEditError: Error, Equatable, LocalizedError {
    case invalid(String)
    case readOnly
    case noEntryID
    /// The box refused the write (no phone-book right, or a SOAP fault).
    case refused(String)
    /// Copy succeeded but removing the original did not: the contact now exists in both books.
    case copiedButNotRemoved(String)
    case notAvailable

    public var errorDescription: String? {
        switch self {
        case .invalid(let m): return m
        case .readOnly: return "This phone book is read-only."
        case .noEntryID: return "This contact has no entry id from the FRITZ!Box yet. Refresh the phone books and try again."
        case .refused(let m): return m
        case .copiedButNotRemoved(let m):
            return "The contact was copied, but the original could not be removed (\(m)). It now exists in both books; nothing was lost."
        case .notAvailable: return "Editing phone books is not available."
        }
    }
}

/// Raw access to the box's phone-book entries (X_AVM-DE_OnTel). Entry data is the `<contact>` XML.
public protocol PhoneBookEditing: Sendable {
    func entryData(bookID: String, entryID: String) async throws -> String
    /// Empty `entryID` creates a new entry. Returns the entry's id.
    @discardableResult
    func setEntry(bookID: String, entryID: String, data: String) async throws -> String
    func deleteEntry(bookID: String, entryID: String) async throws
}

public enum TransferMode: Equatable, Sendable { case move, copy }

/// Add, edit, delete, move and copy on top of `PhoneBookEditing`. Never deletes before the create succeeded.
public struct PhoneBookEditor: Sendable {
    public let service: PhoneBookEditing
    public init(_ service: PhoneBookEditing) { self.service = service }

    public func create(bookID: String, draft: ContactDraft) async throws {
        if let e = draft.validationError { throw PhoneBookEditError.invalid(e) }
        try await service.setEntry(bookID: bookID, entryID: "", data: PhoneBookEntryXML.build(draft.cleaned))
    }

    /// Reads the current entry first and only replaces name and numbers, so e-mail and other data survive.
    public func update(bookID: String, entryID: String, draft: ContactDraft) async throws {
        if let e = draft.validationError { throw PhoneBookEditError.invalid(e) }
        guard !entryID.isEmpty else { throw PhoneBookEditError.noEntryID }
        let existing = try await service.entryData(bookID: bookID, entryID: entryID)
        let merged = try PhoneBookEntryXML.merge(existing: existing, draft: draft.cleaned)
        try await service.setEntry(bookID: bookID, entryID: entryID, data: merged)
    }

    public func delete(bookID: String, entryID: String) async throws {
        guard !entryID.isEmpty else { throw PhoneBookEditError.noEntryID }
        try await service.deleteEntry(bookID: bookID, entryID: entryID)
    }

    /// Create in the target first (with the full original entry), delete the source only after that succeeded.
    public func transfer(from sourceBook: String, entryID: String, to targetBook: String, mode: TransferMode) async throws {
        guard !entryID.isEmpty else { throw PhoneBookEditError.noEntryID }
        guard sourceBook != targetBook else { throw PhoneBookEditError.invalid("Choose a different phone book.") }
        let raw = try await service.entryData(bookID: sourceBook, entryID: entryID)
        try await service.setEntry(bookID: targetBook, entryID: "", data: try PhoneBookEntryXML.forCopy(raw))
        if mode == .move {
            do { try await service.deleteEntry(bookID: sourceBook, entryID: entryID) }
            catch { throw PhoneBookEditError.copiedButNotRemoved(error.localizedDescription) }
        }
    }
}

/// Books a contact may be moved or copied to, and whether it may be edited at all.
public enum TransferTargets {
    /// Other, enabled, writable books.
    public static func targets(for contact: Contact, books: [PhoneBookSummary], disabled: [String]) -> [PhoneBookSummary] {
        books.filter { $0.id != contact.bookID && !$0.readOnly && !disabled.contains($0.id) }
    }
    public static func canEdit(_ contact: Contact) -> Bool {
        !contact.phoneBookReadOnly && contact.bookID != nil && !(contact.entryID ?? "").isEmpty
    }
}

/// `<contact>` records as used by SetPhonebookEntry. All user text is XML-escaped.
public enum PhoneBookEntryXML {
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // Drop control characters XML 1.0 cannot carry.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private static func telephony(_ numbers: [PhoneNumber]) -> String {
        let items = numbers.enumerated().map { i, n in
            "<number type=\"\(escape(PhoneNumberType.from(n.type).rawValue))\" prio=\"\(i == 0 ? 1 : 0)\" id=\"\(i)\">\(escape(n.number))</number>"
        }.joined()
        return "<telephony nid=\"\(numbers.count)\">\(items)</telephony>"
    }

    public static func build(_ draft: ContactDraft) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><contact><category>0</category>"
            + "<person><realName>\(escape(draft.name))</realName></person>\(telephony(draft.numbers))</contact>"
    }

    /// Replaces realName and the telephony block of an existing record, keeping everything else.
    public static func merge(existing: String, draft: ContactDraft) throws -> String {
        let doc = try parse(existing)
        guard let contact = doc.rootElement(), contact.name == "contact" else { throw unreadable }
        let person: XMLElement
        if let p = contact.elements(forName: "person").first { person = p } else {
            person = XMLElement(name: "person"); contact.insertChild(person, at: 0)
        }
        for old in person.elements(forName: "realName") { person.removeChild(at: old.index) }
        person.insertChild(XMLElement(name: "realName", stringValue: draft.name), at: 0)
        for old in contact.elements(forName: "telephony") { contact.removeChild(at: old.index) }
        let tel = XMLElement(name: "telephony")
        tel.addAttribute(XMLNode.attribute(withName: "nid", stringValue: String(draft.numbers.count)) as! XMLNode)
        for (i, n) in draft.numbers.enumerated() {
            let e = XMLElement(name: "number", stringValue: n.number)
            e.addAttribute(XMLNode.attribute(withName: "type", stringValue: PhoneNumberType.from(n.type).rawValue) as! XMLNode)
            e.addAttribute(XMLNode.attribute(withName: "prio", stringValue: i == 0 ? "1" : "0") as! XMLNode)
            e.addAttribute(XMLNode.attribute(withName: "id", stringValue: String(i)) as! XMLNode)
            tel.addChild(e)
        }
        let at = contact.elements(forName: "person").first.map { $0.index + 1 } ?? 0
        contact.insertChild(tel, at: at)
        return doc.xmlString(options: [.nodeCompactEmptyElement])
    }

    /// The record without its `uniqueid`, so the target book assigns a new one.
    public static func forCopy(_ existing: String) throws -> String {
        let doc = try parse(existing)
        guard let contact = doc.rootElement(), contact.name == "contact" else { throw unreadable }
        for e in contact.elements(forName: "uniqueid") { contact.removeChild(at: e.index) }
        return doc.xmlString(options: [.nodeCompactEmptyElement])
    }

    private static let unreadable = PhoneBookEditError.invalid("The FRITZ!Box entry could not be read.")

    private static func parse(_ s: String) throws -> XMLDocument {
        do { return try XMLDocument(xmlString: s, options: []) } catch { throw unreadable }
    }
}

/// CSV backup of a phone book: one row per number (a contact without numbers gets one row).
public enum ContactCSV {
    public static let header = ["Phone book", "Name", "Type", "Number"]

    public static func build(_ contacts: [Contact]) -> String {
        var lines = [header.map(CallLogCSV.escape).joined(separator: ",")]
        for c in contacts {
            let book = c.phoneBook ?? ""
            let rows = c.numbers.isEmpty ? [PhoneNumber(number: "", type: "")] : c.numbers
            for n in rows {
                lines.append([book, c.name, n.type, n.number].map(CallLogCSV.escape).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func defaultFileName(book: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        let safe = String(book.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return String(format: "phonebook-backup-%@-%04d-%02d-%02d.csv", safe.isEmpty ? "book" : safe, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
