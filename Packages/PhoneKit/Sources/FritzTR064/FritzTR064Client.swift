// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import PhoneCore
import os

public final class FritzTR064Client: PhoneBookService, PhoneBookEditing, @unchecked Sendable {
    public static let defaultPort = 49443
    private let base: URL
    private let transport: HTTPTransport

    public init(host: String, port: Int = FritzTR064Client.defaultPort, transport: HTTPTransport) {
        self.base = URL(string: "https://\(host):\(port)")!
        self.transport = transport
    }

    private func call(_ action: String, _ args: [(String, String)] = []) async throws -> [String: String] {
        var req = URLRequest(url: base.appendingPathComponent("upnp/control/x_contact"))
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(SOAP.onTelService)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = SOAP.envelope(service: SOAP.onTelService, action: action, arguments: args)
        return try SOAP.parseResponse(try await transport.send(req))
    }

    /// Sanitized record of the transport's most recent request (see `TransportDiagnostics`).
    public var lastDiagnostics: TransportDiagnostics? { transport.lastDiagnostics }

    /// Login test: reads model and FRITZ!OS version from the unauthenticated `/tr64desc.xml` (best effort),
    /// then makes one authenticated call (`GetPhonebookList`) through the normal code path.
    public func checkLogin() async -> TR064LoginCheck {
        var model: String?, firmware: String?
        if let desc = try? await transport.send(URLRequest(url: base.appendingPathComponent("tr64desc.xml"))),
           let fields = try? SOAP.parseResponse(desc) {
            model = fields["modelName"].map { TransportDiagnostics.clean($0, max: 60) }
            firmware = fields["Display"].map { TransportDiagnostics.clean($0, max: 30) }
        }
        var failure: Error?
        do { _ = try await call("GetPhonebookList") } catch { failure = error }
        let d = lastDiagnostics
        return TR064LoginCheck(verdict: TR064Diagnosis.verdict(diagnostics: d, error: failure), diagnostics: d,
                               errorDescription: failure.map { TransportDiagnostics.clean($0.localizedDescription, max: 300) },
                               model: model, firmware: firmware)
    }

    public func loadContacts() async throws -> [Contact] {
        let list = try await call("GetPhonebookList")["NewPhonebookList"] ?? "0"
        var books: [(id: String, name: String, contacts: [Contact], readOnly: Bool)] = []
        for id in list.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !id.isEmpty {
            let reply = try await call("GetPhonebook", [("NewPhonebookID", id)])
            guard let s = reply["NewPhonebookURL"], let url = Self.rebase(s, onto: base) else { throw FritzError.missingField("NewPhonebookURL") }
            let contacts = try PhoneBookParser.parse(try await transport.send(URLRequest(url: url)))
            // A non-empty extra id means the book comes from an online provider: the box does not store it.
            let readOnly = !(reply["NewPhonebookExtraID"] ?? "").isEmpty
            books.append((id, contacts.lazy.compactMap(\.phoneBook).first ?? "Phone book \(id)", contacts, readOnly))
        }
        // Books sharing a name get their id appended, e.g. "Telefonbuch (1)", so they stay distinguishable.
        let counts = Dictionary(books.map { ($0.name, 1) }, uniquingKeysWith: +)
        var all: [Contact] = []
        for book in books {
            let display = counts[book.name, default: 0] > 1 ? "\(book.name) (\(book.id))" : book.name
            all += book.contacts.map { Contact(id: "\(book.id)-\($0.id)", name: $0.name, numbers: $0.numbers, phoneBook: display, phoneBookID: book.id,
                                                                                                    entryID: $0.entryID, phoneBookReadOnly: book.readOnly) }
        }
        return all
    }

    // MARK: Phone book editing (X_AVM-DE_OnTel)

    /// Write calls: the box answers 401/500 or a SOAP fault when the TR-064 user lacks the phone-book right.
    private func writeCall(_ action: String, _ args: [(String, String)]) async throws -> [String: String] {
        do { return try await call(action, args) }
        catch let e as FritzError {
            if case .fault(let code, _) = e, code == "713" { throw PhoneBookEditError.entryNotFound }
            switch e {
            case .unauthorized, .http(401), .http(500), .http(403), .fault:
                throw PhoneBookEditError.refused(Self.refusalText(e))
            default: throw e
            }
        }
    }

    static func refusalText(_ e: FritzError) -> String {
        var s = "The FRITZ!Box refused the change. Check that the TR-064 user has the right to edit "
            + "phone books (FRITZ!Box > System > FRITZ!Box users > the user > \"FRITZ!Box settings, "
            + "VoIP, phone and smart home\" / contacts) and that the phone book is not read-only."
        if case .fault(let code, _) = e { s += " (error \(code))" }
        else if case .http(let c) = e { s += " (HTTP \(c))" }
        return s
    }

    // Entry ids: the plain *Entry actions take a position index in the box's list (AVM TR-064 Contact SCPD,
    // PhonebookEntryID), which shifts when entries are deleted. The app only knows the entry's `<uniqueid>`
    // from the phone book XML, so every entry action here uses the *UID variants (since FRITZ!OS 7.0x).

    private static let log = Logger(subsystem: "com.aarneaarebye.sipphone", category: "phonebook")

    /// Logs action name, numeric ids and the fault code only: never names, numbers, credentials or XML.
    private func logged(_ action: String, bookID: String, entryID: String?, _ args: [(String, String)],
                        write: Bool) async throws -> [String: String] {
        let idText = entryID.map { $0.isEmpty ? "(none)" : $0 } ?? "-"
        do {
            let r = write ? try await writeCall(action, args) : try await call(action, args)
            Self.log.info("\(action, privacy: .public) book=\(bookID, privacy: .public) uid=\(idText, privacy: .public) ok")
            return r
        } catch {
            var code = "-"
            if case PhoneBookEditError.refused = error { code = "refused" }
            if let f = error as? FritzError {
                switch f { case .fault(let c, _): code = c; case .http(let h): code = "http\(h)"; default: code = "other" }
            } else if case PhoneBookEditError.entryNotFound = error { code = "713" }
            Self.log.error("\(action, privacy: .public) book=\(bookID, privacy: .public) uid=\(idText, privacy: .public) failed code=\(code, privacy: .public)")
            throw error
        }
    }

    /// 713 (SpecifiedArrayIndexInvalid) means the phone book id or entry id does not exist on the box.
    private static func mapMissing(_ e: Error) -> Error {
        if case FritzError.fault(let code, _) = e, code == "713" { return PhoneBookEditError.entryNotFound }
        return e
    }

    public func entryData(bookID: String, entryID: String) async throws -> String {
        let r: [String: String]
        do {
            r = try await logged("GetPhonebookEntryUID", bookID: bookID, entryID: entryID,
                                 [("NewPhonebookID", bookID), ("NewPhonebookEntryUniqueID", entryID)], write: false)
        } catch { throw Self.mapMissing(error) }
        guard let d = r["NewPhonebookEntryData"], !d.isEmpty else { throw PhoneBookEditError.entryNotFound }
        return d
    }

    /// Empty `entryID` creates a new entry; otherwise `data` must carry `<uniqueid>` (see `PhoneBookEntryXML.merge`).
    @discardableResult
    public func setEntry(bookID: String, entryID: String, data: String) async throws -> String {
        let r = try await logged("SetPhonebookEntryUID", bookID: bookID, entryID: entryID,
                             [("NewPhonebookID", bookID), ("NewPhonebookEntryData", data)], write: true)
        return r["NewPhonebookEntryUniqueID"] ?? entryID
    }

    public func deleteEntry(bookID: String, entryID: String) async throws {
        _ = try await logged("DeletePhonebookEntryUID", bookID: bookID, entryID: entryID,
                             [("NewPhonebookID", bookID), ("NewPhonebookEntryUniqueID", entryID)], write: true)
    }

    public func loadCallList() async throws -> [CallRecord] {
        let reply = try await call("GetCallList")
        guard let s = reply["NewCallListURL"], let url = Self.rebase(s, onto: base, extraQuery: "max=200") else { throw FritzError.missingField("NewCallListURL") }
        return try CallListParser.parse(try await transport.send(URLRequest(url: url)))
    }

    /// Download URLs from SOAP replies are never fetched as given: only their path and query are kept and put
    /// onto the configured `https://host:port` base, so an `http://` or foreign-host URL cannot bypass the
    /// certificate pin or receive the credentials. nil when the reply has no usable path.
    static func rebase(_ reply: String, onto base: URL, extraQuery: String? = nil) -> URL? {
        guard let given = URLComponents(string: reply.trimmingCharacters(in: .whitespacesAndNewlines)),
              !given.percentEncodedPath.isEmpty,
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let path = given.percentEncodedPath
        c.percentEncodedPath = path.hasPrefix("/") ? path : "/" + path
        var query = given.percentEncodedQuery.flatMap { $0.isEmpty ? nil : $0 }
        if let extraQuery { query = query.map { $0 + "&" + extraQuery } ?? extraQuery }
        c.percentEncodedQuery = query
        c.fragment = nil
        return c.url
    }
}
