// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import PhoneCore

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

    public func entryData(bookID: String, entryID: String) async throws -> String {
        let r = try await call("GetPhonebookEntry", [("NewPhonebookID", bookID), ("NewPhonebookEntryID", entryID)])
        guard let d = r["NewPhonebookEntryData"], !d.isEmpty else { throw FritzError.missingField("NewPhonebookEntryData") }
        return d
    }

    @discardableResult
    public func setEntry(bookID: String, entryID: String, data: String) async throws -> String {
        let r = try await writeCall("SetPhonebookEntry", [("NewPhonebookID", bookID), ("NewPhonebookEntryID", entryID),
                                                          ("NewPhonebookEntryData", data)])
        return r["NewPhonebookEntryUniqueID"] ?? entryID
    }

    public func deleteEntry(bookID: String, entryID: String) async throws {
        _ = try await writeCall("DeletePhonebookEntry", [("NewPhonebookID", bookID), ("NewPhonebookEntryID", entryID)])
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
