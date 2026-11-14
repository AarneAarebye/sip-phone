// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
import PhoneCore
@testable import FritzTR064

private func reply(_ action: String, _ fields: [String: String]) -> Data {
    let body = fields.map { "<\($0.key)>\(SOAP.escape($0.value))</\($0.key)>" }.joined()
    return Data("""
    <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
    <u:\(action)Response xmlns:u="urn:dslforum-org:service:X_AVM-DE_OnTel:1">\(body)</u:\(action)Response>\
    </s:Body></s:Envelope>
    """.utf8)
}

private func action(_ r: URLRequest) -> String {
    (r.value(forHTTPHeaderField: "SOAPAction") ?? "").split(separator: "#").last.map { $0.dropLast() }.map(String.init) ?? ""
}

final class EditingTests: XCTestCase {
    func testParserKeepsEntryID() throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "phonebook", withExtension: "xml", subdirectory: "Fixtures")))
        XCTAssertEqual(try PhoneBookParser.parse(data).map(\.entryID), ["11", "12"])
        let none = Data("<phonebooks><phonebook><contact><person><realName>A</realName></person></contact></phonebook></phonebooks>".utf8)
        XCTAssertNil(try PhoneBookParser.parse(none).first?.entryID)
    }

    func testLoadContactsCarriesEntryIDAndReadOnly() async throws {
        let book = Data("<phonebooks><phonebook name=\"X\"><contact><person><realName>A</realName></person><uniqueid>5</uniqueid></contact></phonebook></phonebooks>".utf8)
        let transport = FakeTransport { req in
            switch action(req) {
            case "GetPhonebookList": return reply("GetPhonebookList", ["NewPhonebookList": "0,1"])
            case "GetPhonebook":
                let one = String(decoding: req.httpBody ?? Data(), as: UTF8.self).contains(">1<")
                return reply("GetPhonebook", ["NewPhonebookURL": "https://fritz.box:49443/pb.xml", "NewPhonebookExtraID": one ? "google" : ""])
            default: return book
            }
        }
        let cs = try await FritzTR064Client(host: "fritz.box", transport: transport).loadContacts()
        XCTAssertEqual(cs.map(\.entryID), ["5", "5"])
        XCTAssertEqual(cs.map(\.phoneBookReadOnly), [false, true])
    }

    func testSetEntrySendsEscapedDataAndEmptyIDForCreate() async throws {
        let transport = FakeTransport { _ in reply("SetPhonebookEntry", ["NewPhonebookEntryUniqueID": "42"]) }
        let client = FritzTR064Client(host: "fritz.box", transport: transport)
        let draft = ContactDraft(name: "A<b>&\"c\"", numbers: [PhoneNumber(number: "030", type: "home")])
        try await PhoneBookEditor(client).create(bookID: "2", draft: draft)
        let req = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(action(req), "SetPhonebookEntry")
        XCTAssertEqual(req.url?.path, "/upnp/control/x_contact")
        let body = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("<NewPhonebookID>2</NewPhonebookID>"))
        XCTAssertTrue(body.contains("<NewPhonebookEntryID></NewPhonebookEntryID>"))
        XCTAssertFalse(body.contains("<realName>"), "entry XML must be escaped inside the SOAP element")
        // Round trip: unescaping the SOAP argument gives well-formed entry XML with the original name.
        let args = try SOAP.parseResponse(try XCTUnwrap(req.httpBody))
        let entry = try XMLDocument(xmlString: try XCTUnwrap(args["NewPhonebookEntryData"]), options: [])
        XCTAssertEqual(try entry.nodes(forXPath: "//realName").first?.stringValue, "A<b>&\"c\"")
    }

    func testEntryDataAndDeleteRequests() async throws {
        let transport = FakeTransport { req in
            action(req) == "GetPhonebookEntry"
                ? reply("GetPhonebookEntry", ["NewPhonebookEntryData": "<contact><uniqueid>7</uniqueid></contact>"])
                : reply("DeletePhonebookEntry", [:])
        }
        let client = FritzTR064Client(host: "fritz.box", transport: transport)
        let data = try await client.entryData(bookID: "0", entryID: "7")
        XCTAssertEqual(data, "<contact><uniqueid>7</uniqueid></contact>")
        try await client.deleteEntry(bookID: "0", entryID: "7")
        let body = String(decoding: try XCTUnwrap(transport.requests.last?.httpBody), as: UTF8.self)
        XCTAssertEqual(action(try XCTUnwrap(transport.requests.last)), "DeletePhonebookEntry")
        XCTAssertTrue(body.contains("<NewPhonebookEntryID>7</NewPhonebookEntryID>"))
    }

    func testRefusedWritesBecomeReadableErrors() async {
        let refusals: [Error] = [FritzError.unauthorized, FritzError.http(500), FritzError.fault(code: "606", description: "x")]
        for failure in refusals {
            let client = FritzTR064Client(host: "fritz.box", transport: FakeTransport { _ in throw failure })
            do { try await client.deleteEntry(bookID: "0", entryID: "1"); XCTFail() }
            catch let e as PhoneBookEditError {
                guard case .refused(let m) = e else { return XCTFail("\(e)") }
                XCTAssertTrue(m.contains("right to edit phone books"), m)
            } catch { XCTFail("\(error)") }
        }
    }

    func testCertificateChangedIsNotMaskedAsRefusal() async {
        let client = FritzTR064Client(host: "fritz.box", transport: FakeTransport { _ in throw FritzError.certificateChanged })
        do { try await client.deleteEntry(bookID: "0", entryID: "1"); XCTFail() }
        catch { XCTAssertEqual(error as? FritzError, .certificateChanged) }
    }

    func testMoveEndToEndAgainstFakeBox() async throws {
        let transport = FakeTransport { req in
            switch action(req) {
            case "GetPhonebookEntry":
                return reply("GetPhonebookEntry", ["NewPhonebookEntryData": "<contact><person><realName>A</realName></person><uniqueid>7</uniqueid></contact>"])
            case "SetPhonebookEntry": return reply("SetPhonebookEntry", ["NewPhonebookEntryUniqueID": "1"])
            default: return reply("DeletePhonebookEntry", [:])
            }
        }
        let client = FritzTR064Client(host: "fritz.box", transport: transport)
        try await PhoneBookEditor(client).transfer(from: "0", entryID: "7", to: "1", mode: .move)
        XCTAssertEqual(transport.requests.map(action), ["GetPhonebookEntry", "SetPhonebookEntry", "DeletePhonebookEntry"])
    }
}
